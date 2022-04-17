const Channel = @import("./channel.zig").Channel;
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn ComputePool(comptime Impl: type) type {
    const Helpers = struct {
        pub fn getArg(comptime function: anytype, comptime index: usize) type {
            return @typeInfo(@TypeOf(function)).Fn.args[index].arg_type.?;
        }

        pub fn getArgCount(comptime function: anytype) comptime_int {
            return @typeInfo(@TypeOf(function)).Fn.args.len;
        }

        pub fn getReturn(comptime function: anytype) type {
            return @typeInfo(@TypeOf(function)).Fn.return_type.?;
        }

        pub fn getComputeFn() @TypeOf(@field(Impl, "compute")) {
            return @field(Impl, "compute");
        }

        pub fn getComputeFnArgsCount() comptime_int {
            return getArgCount(getComputeFn());
        }

        pub fn getJob() type {
            if (@hasDecl(Impl, "Job")) {
                return @field(Impl, "Job");
            }

            // If no custom job type is provided, try to get it from the first argument
            // of the compute function
            return getArg(getComputeFn(), 0);
        }

        pub fn getContext() type {
            if (@hasDecl(Impl, "Context")) {
                return @field(Impl, "Context");
            }

            return void;
        }
    };

    return struct {
        pub const SelfComputePool = @This();

        pub const Job = Helpers.getJob();

        pub const Context = Helpers.getContext();

        pub const compute_impl = Helpers.getComputeFn();

        allocator: Allocator,
        workers: []Worker,
        jobs: Channel([]WorkerMessage),
        context: Context,

        pub fn init(allocator: Allocator, workers_count: usize, backlog_size: usize, context: Context) !@This() {
            assert(workers_count > 0);
            assert(backlog_size > 0);

            var workers = try allocator.alloc(Worker, workers_count);
            errdefer {
                // for (workers) |*worker| worker.deinit();

                allocator.free(workers);
            }

            // Initialize all the workers' structs
            for (workers) |*worker, i| {
                worker.* = Worker{ .index = i };
            }

            var jobs = try Channel([]WorkerMessage).init(allocator, backlog_size);
            errdefer jobs.deinit();

            return @This(){
                .allocator = allocator,
                .workers = workers,
                .jobs = jobs,
                .context = context,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.workers) |*worker| worker.terminate();

            for (self.workers) |*worker| worker.join();

            self.allocator.free(self.workers);

            self.jobs.deinit();
        }

        pub fn send(self: *@This(), job: Job) !void {
            try self.jobs.send(WorkerMessage{ .Compute = job });
        }

        pub fn trySend(self: *@This(), job: Job) !bool {
            return self.jobs.trySend(WorkerMessage{ .Compute = job });
        }

        pub fn spawn(self: *@This()) !void {
            for (self.workers) |*worker| {
                try worker.spawn(self);
            }
        }

        pub const Worker = struct {
            index: usize,
            thread: std.Thread = undefined,
            state: WorkerState = .Created,
            pool: ?*SelfComputePool = null,

            pub fn spawn(self: *Worker, pool: *SelfComputePool) !void {
                self.pool = pool;

                self.state = .Waiting;
                errdefer self.state = .Terminated;

                self.thread = try std.Thread.spawn(.{}, Worker.main, .{self});
            }

            pub fn terminate(self: *Worker) void {
                self.pool.?.jobs.send(WorkerMessage{ .Terminate = {} }) catch {};
            }

            pub fn join(self: *Worker) void {
                self.thread.join();
            }

            pub fn tryReceive(self: *Worker) !?WorkerMessage {
                return self.pool.?.jobs.tryReceive();
            }

            pub fn receive(self: *Worker) !WorkerMessage {
                return self.pool.?.jobs.receive();
            }

            pub fn main(self: *Worker) void {
                while (true) {
                    // Assume this function is only executed after spawn is called, which means that the jobs Channel is open
                    var message = self.receive() catch |err| switch (err) {
                        error.ChannelClosed => WorkerMessage{ .Terminate = {} },
                    };

                    self.state = .Processing;

                    switch (message) {
                        .Compute => |job| {
                            if (Helpers.getComputeFnArgsCount() == 1) {
                                compute_impl(job);
                            } else if (Helpers.getComputeFnArgsCount() == 2) {
                                compute_impl(job, self);
                            }
                        },
                        .Terminate => break,
                    }

                    // std.time.sleep(std.time.ns_per_ms * 1000);

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

            /// The event-loop has received a compute job and is processing it
            Processing,

            /// The event-loop has received the Terminate message and the thread
            /// has been disposed of
            Terminated,
        };

        pub const WorkerMessage = union(enum) {
            Terminate: void,
            Compute: Job,
        };
    };
}

const expectEqual = std.testing.expectEqual;

// Create the types needed for the test
const TestJob = struct {
    state: *State,
    work: u32,
};

const IncrComputePool = ComputePool(struct {
    pub const Job = TestJob;

    pub fn compute(job: TestJob) void {
        var i: u32 = 0;

        while (i < 10000) : (i += 1) {}

        std.mem.doNotOptimizeAway(i);

        job.state.mutex.lock();
        defer job.state.mutex.unlock();

        job.state.value += 1;
    }
});

test "Compute Pool" {
    // Declare the global state
    var state = State{
        .value = 0,
        .mutex = std.Thread.Mutex{},
    };

    // Create a pool
    var pool = try IncrComputePool.init(std.testing.allocator, 2, 8, {});
    errdefer pool.deinit();

    try pool.spawn();

    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });
    try pool.send(.{ .state = &state, .work = 10000 });

    pool.deinit();

    // `state.value` should be the same as the number of messages sent
    try expectEqual(@as(i32, 10), state.value);
}

fn TransformStruct(comptime T: type) type {
    return struct {
        pub const Type = i32;

        pub usingnamespace T;
    };
}
const State = struct {
    value: i32,
    mutex: std.Thread.Mutex,
    sink_pool: ?*SinkComputePool = null,
    results: ?Channel([]i32) = null,
    // finish_event: ?std.Thread.ResetEvent,
};

const SourceComputePool = ComputePool(struct {
    pub const Context = *State;

    pub const Worker = ComputePool(@This()).Worker;

    pub const Job = struct {
        messages: u32,
    };

    pub fn compute(job: Job, worker: *Worker) void {
        var i: u32 = 0;

        while (i < job.messages) : (i += 1) {
            worker.pool.?.context.sink_pool.?.send(.{ .work = 10000 }) catch unreachable;
        }

        worker.pool.?.context.results.?.send(@intCast(i32, job.messages)) catch unreachable;
    }
});

const SinkComputePool = ComputePool(struct {
    pub const Context = *State;

    pub const Worker = ComputePool(@This()).Worker;

    pub const Job = struct {
        work: u32,
    };

    pub fn compute(job: Job, worker: *Worker) void {
        var i: u32 = 0;

        while (i < job.work) : (i += 1) {}

        std.mem.doNotOptimizeAway(i);

        worker.pool.?.context.mutex.lock();
        defer worker.pool.?.context.mutex.unlock();

        worker.pool.?.context.value += 1;
    }
});

test "Two Compute Pools sending messages between them" {
    // Create the types needed for the test

    // Declare the global state
    var state = State{
        .value = 0,
        .mutex = std.Thread.Mutex{},
        // Create channel containing the results
        .results = try Channel([]i32).init(std.testing.allocator, 20),
        // Temporarily set the pool as null. Set the proper pointer atfer it has been initialized.
        .sink_pool = null,
    };
    defer state.results.?.deinit();

    // Create both pools
    var source_pool = try SourceComputePool.init(std.testing.allocator, 1, 2, &state);
    errdefer source_pool.deinit();

    var sink_pool = try SinkComputePool.init(std.testing.allocator, 2, 8, &state);
    errdefer sink_pool.deinit();
    state.sink_pool = &sink_pool;

    try source_pool.spawn();
    try sink_pool.spawn();

    try source_pool.send(.{ .messages = 6 });
    try source_pool.send(.{ .messages = 6 });

    try expectEqual(@as(i32, 6), try state.results.?.receive());
    try expectEqual(@as(i32, 6), try state.results.?.receive());

    source_pool.deinit();
    sink_pool.deinit();

    try expectEqual(@as(i32, 12), state.value);
}
