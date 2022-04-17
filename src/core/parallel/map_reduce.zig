const std = @import("std");
const Allocator = std.mem.Allocator;
const Channel = @import("./channel.zig").Channel;

pub fn MapReduce(comptime Impl: type) type {
    const Helpers = struct {
        pub fn getArg(comptime function: anytype, comptime index: usize) type {
            return @typeInfo(@TypeOf(function)).Fn.args[index].arg_type.?;
        }

        pub fn getReturn(comptime function: anytype) type {
            return @typeInfo(@TypeOf(function)).Fn.return_type.?;
        }

        pub fn getMapFn() @TypeOf(@field(Impl, "map")) {
            return @field(Impl, "map");
        }

        pub fn getReduceFn() @TypeOf(@field(Impl, "reduce")) {
            return @field(Impl, "reduce");
        }

        pub fn getContext() type {
            if (@hasDecl(Impl, "Context")) {
                return @field(Impl, "Context");
            }

            // If no custom context type is provided, try to get it from the first argument
            // of the map function
            return getArg(getMapFn(), 0);
        }

        pub fn getType() type {
            if (@hasDecl(Impl, "Type")) {
                return @field(Impl, "Type");
            }

            // If no custom type is provided, try to get it from the second argument
            // of the map function
            return @typeInfo(getArg(getMapFn(), 1)).Pointer.child;
        }

        pub fn getResult() type {
            if (@hasDecl(Impl, "Result")) {
                return @field(Impl, "Result");
            }

            // If no custom result type is provided, try to get it from the return type
            // of the map function
            return getReturn(getMapFn());
        }

        pub fn getOptionalResult() type {
            const Result = getResult();

            if (@typeInfo(Result) == .Optional) {
                return Result;
            } else {
                return ?Result;
            }
        }
    };

    return struct {
        pub const Context = Helpers.getContext();
        pub const Type = Helpers.getType();
        pub const Result = Helpers.getResult();
        pub const OptionalResult = Helpers.getOptionalResult();

        pub const map_impl = Helpers.getMapFn();
        pub const reduce_impl = Helpers.getReduceFn();

        allocator: Allocator,
        workers: []Worker,

        pub fn init(allocator: Allocator, count: u64) !@This() {
            var workers = try allocator.alloc(Worker, count);
            errdefer {
                for (workers) |*worker| worker.deinit();

                allocator.free(workers);
            }

            for (workers) |*worker| {
                worker.* = Worker.init();
            }

            var map: @This() = .{
                .allocator = allocator,
                .workers = workers,
            };

            try map.spawn();

            return map;
        }

        pub fn deinit(self: *@This()) void {
            for (self.workers) |*worker| worker.terminate();

            for (self.workers) |*worker| worker.wait();

            for (self.workers) |*worker| worker.deinit();

            self.allocator.free(self.workers);
        }

        fn spawn(self: *@This()) !void {
            for (self.workers) |*worker| try worker.spawn();
        }

        pub fn run(self: *const @This(), context: Context, inputs: []Type) OptionalResult {
            // Divide the tasks by each worker
            var bucket_size = std.math.divTrunc(usize, inputs.len, self.workers.len) catch return null;
            var overflow: usize = inputs.len - (self.workers.len * bucket_size);

            var iter = InputChunkIterator{ .inputs = inputs, .bucket_size = bucket_size, .overflow = overflow };

            var worker_index: usize = 0;

            while (iter.next()) |chunk| {
                // TODO What if worker_index is greater than workers len
                var work_unit = WorkerMessage{ .WorkUnit = .{ .context = context, .inputs = chunk } };

                self.workers[worker_index].inputs.send(work_unit) catch {};

                worker_index += 1;
            }

            var output: OptionalResult = null;

            for (self.workers[0..worker_index]) |*worker| {
                var worker_output = worker.outputs.receive() catch break;

                if (output != null) {
                    output = reduce_impl(context, output.?, worker_output);
                } else {
                    output = worker_output;
                }
            }

            return output;
        }

        pub const InputChunkIterator = struct {
            inputs: []Type,
            bucket_size: usize,
            overflow: usize,
            _index: usize = 0,

            pub fn next(self: *InputChunkIterator) ?[]Type {
                if (self._index >= self.inputs.len) return null;

                var start: usize = self._index;
                var size: usize = self.bucket_size;

                if (self.overflow > 0) {
                    self.overflow -= 1;
                    size += 1;
                }

                size = std.math.min(size, self.inputs.len - self._index);

                self._index += size;

                return self.inputs[start .. start + size];
            }
        };

        pub const Worker = struct {
            thread: ?std.Thread = null,
            state: WorkerState = .Created,
            inputs: Channel([1]WorkerMessage) = Channel([1]WorkerMessage).init(),
            outputs: Channel([1]Result) = Channel([1]Result).init(),

            pub fn init() Worker {
                return .{};
            }

            pub fn deinit(self: *Worker) void {
                self.inputs.deinit();
                self.outputs.deinit();
            }

            pub fn spawn(self: *Worker) !void {
                self.state = .Waiting;
                errdefer self.state = .Terminated;

                self.thread = try std.Thread.spawn(.{}, Worker.main, .{self});
            }

            pub fn terminate(self: *Worker) void {
                self.inputs.send(WorkerMessage{ .Terminate = {} }) catch {};
            }

            pub fn wait(self: *Worker) void {
                self.thread.?.join();
            }

            pub fn main(self: *Worker) void {
                while (true) {
                    var message = self.inputs.receive() catch WorkerMessage{ .Terminate = {} };

                    self.state = .Processing;

                    switch (message) {
                        .WorkUnit => |unit| {
                            var output: OptionalResult = null;

                            for (unit.inputs) |*input| {
                                var mapped_output = map_impl(unit.context, input);

                                if (output != null) {
                                    output = reduce_impl(unit.context, output.?, mapped_output);
                                } else {
                                    output = mapped_output;
                                }
                            }

                            if (output != null) {
                                self.outputs.send(output.?) catch {};
                            }
                        },
                        .Terminate => break,
                    }

                    self.state = .Waiting;
                }

                self.state = .Terminated;
            }
        };

        pub const WorkerState = enum {
            /// The state after a Worker is created and before it is spawned.
            /// The thread is still not initialized at this point
            Created,

            /// After the thread has been spawned, and the event-loop is
            /// waiting for the next message
            Waiting,

            /// The event-loop has received a work unit and is processing it
            Processing,

            /// The event-loop has received the Terminate message and the thread
            /// has been disposed of
            Terminated,
        };

        pub const WorkerMessage = union(enum) {
            Terminate: void,
            WorkUnit: struct { context: Context, inputs: []Type },
        };
    };
}

test "Sum of multiplications with constant" {
    const allocator = std.testing.allocator;

    const IntMapReduce = MapReduce(struct {
        pub fn map(context: i32, value: *i32) i32 {
            return context * value.*;
        }

        pub fn reduce(context: i32, value_a: i32, value_b: i32) i32 {
            _ = context;

            return value_a + value_b;
        }
    });

    var map_reduce = try IntMapReduce.init(allocator, 4);
    defer map_reduce.deinit();

    var inputs = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 };

    var result = map_reduce.run(2, &inputs);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 72), result.?);

    result = map_reduce.run(4, &inputs);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 144), result.?);
}
