const std = @import("std");
const assert = std.debug.assert;

pub const OperationProgress = struct {
    ctx: Ptr,
    on_update: fn (f64) void,

    pub fn init(ctx: Ptr) OperationProgress {
        return .{
            .ctx = ctx,
        };
    }
};

pub fn Signal(comptime ArgsType: type) type {
    return struct {
        pub const Args = ArgsType;
        pub const Callback = fn (ctx: usize, args: Args) void;

        _ctx: usize = 0,
        _callback: ?Callback = null,
        _timer: ?std.time.Timer = null,

        pub fn triggerDebounced(self: *@This(), args: Args, debounce: u64) void {
            // Variable indicating we can skip this trigger
            var skip: bool = false;

            deb: {
                if (self._timer) |*timer| {
                    const elapsed = timer.read();

                    if (elapsed <= debounce) {
                        skip = true;
                    } else {
                        timer.reset();
                    }
                } else {
                    self._timer = std.time.Timer.start() catch break :deb;
                }
            }

            if (!skip) {
                self.trigger(args);
            }
        }

        pub fn trigger(self: *const @This(), args: Args) void {
            if (self._callback) |callback| {
                callback(self._ctx, args);
            }
        }

        pub fn connect(self: *@This(), ctx: anytype, comptime callback: fn (*std.meta.Child(@TypeOf(ctx)), args: Args) void) void {
            const T = comptime std.meta.Child(@TypeOf(ctx));
            self._ctx = Ptr.to(ctx);

            self._callback = struct {
                pub fn wrapper(ctx_raw: usize, args: Args) void {
                    var ctx_typed = Ptr.as(T, ctx_raw);

                    callback(ctx_typed, args);
                }
            }.wrapper;
        }

        pub fn connectDyn(self: *@This(), ctx: usize, callback: Callback) void {
            self._ctx = ctx;
            self._callback = callback;
        }

        pub fn disconnect(self: *@This()) void {
            self._ctx = 0;
            self._callback = null;
        }
    };
}

pub const Ptr = struct {
    pub fn to(ptr: anytype) usize {
        return @ptrToInt(ptr);
    }

    pub fn as(comptime T: type, id: usize) *T {
        assert(id > 0);

        return @intToPtr(*T, id);
    }
};
