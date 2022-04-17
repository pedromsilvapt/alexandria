const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn Channel(comptime BufferType: type) type {
    return struct {
        const Self = @This();

        pub const Elem = std.meta.Elem(BufferType);
        pub const buffer_is_slice = @typeInfo(BufferType) != .Array;

        allocator: if (buffer_is_slice) Allocator else void,
        buffer: BufferType,
        cursor: usize = 0,
        size: usize = 0,
        closed: bool = false,
        // Synchronization primitives
        mutex: std.Thread.Mutex,
        receive_event: std.Thread.StaticResetEvent,
        send_event: std.Thread.StaticResetEvent,
        name: []const u8 = "<channel>",

        pub usingnamespace if (buffer_is_slice) struct {
            pub fn init(allocator: Allocator, capacity: usize) !Self {
                var buffer = try allocator.alloc(Elem, capacity);

                return Self{
                    .allocator = allocator,
                    .buffer = buffer,
                    .cursor = 0,
                    .size = 0,
                    .closed = false,
                    .mutex = std.Thread.Mutex{},
                    .receive_event = std.Thread.StaticResetEvent{},
                    .send_event = std.Thread.StaticResetEvent{},
                };
            }
        } else struct {
            pub fn init() Self {
                return Self{
                    .allocator = {},
                    .buffer = undefined,
                    .cursor = 0,
                    .size = 0,
                    .closed = false,
                    .mutex = std.Thread.Mutex{},
                    .receive_event = std.Thread.StaticResetEvent{},
                    .send_event = std.Thread.StaticResetEvent{},
                };
            }
        };

        pub fn deinit(self: *@This()) void {
            if (buffer_is_slice) {
                self.allocator.free(self.buffer);
            }
        }

        pub fn close(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.closed) {
                self.closed = true;

                self.send_event.set();
                self.receive_event.set();
            }
        }

        fn internalSend(self: *@This(), msg: Elem, comptime blocking: bool) !(if (blocking) void else bool) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.ChannelClosed;

            while (self.size >= self.buffer.len and !self.closed) {
                if (blocking) {
                    // Release the mutex so that when we wait on the event, the send method can acquire the lock if it wants
                    // NOTE Be careful, the code must not fail after this release and before the next acquire, otherwise the defer
                    // will trigger and we will have double released this self.mutex
                    self.mutex.unlock();

                    self.receive_event.wait();

                    // After the event as been set we need to acquire the lock once again
                    // Before we can check the size to see if there is anything waiting for us
                    self.mutex.lock();
                } else {
                    return false;
                }
            }

            if (self.closed) return error.ChannelClosed;

            var index = self.cursor + self.size;

            if (index >= self.buffer.len) {
                index -= self.buffer.len;
            }

            self.size += 1;

            self.buffer[index] = msg;

            if (self.size == 1) {
                self.send_event.set();

                // We have the lock now, so if size is 1, no one could have increased it yet
                // Which means there is no reason for the event to be set. Thus, we can reset it
                self.send_event.reset();
            }

            if (!blocking) {
                return true;
            }
        }

        pub fn trySend(self: *@This(), msg: Elem) !bool {
            return try self.internalSend(msg, false);
        }

        pub fn send(self: *@This(), msg: Elem) !void {
            try self.internalSend(msg, true);
        }

        pub fn internalReceive(self: *@This(), comptime blocking: bool) !(if (blocking) Elem else ?Elem) {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed) return error.ChannelClosed;

            while (self.size == 0 and !self.closed) {
                if (blocking) {
                    // Release the mutex so that when we wait on the event, the send method can acquire the lock if it wants
                    // NOTE Be careful, the code must not fail after this release and before the next acquire, otherwise the defer
                    // will trigger and we will have double released this self.mutex
                    self.mutex.unlock();

                    self.send_event.wait();

                    // After the event as been set we need to acquire the lock once again
                    // Before we can check the size to see if there is anything waiting for us
                    self.mutex.lock();
                } else {
                    return null;
                }
            }

            if (self.closed) return error.ChannelClosed;

            var msg = self.buffer[self.cursor];

            self.cursor += 1;
            self.size -= 1;

            if (self.cursor >= self.buffer.len) {
                self.cursor = 0;
            }

            if (self.size + 1 == self.buffer.len) {
                self.receive_event.set();

                // We have the lock now, so if size is buffer len, no one could have increased it yet
                // Which means there is no reason for the event to be set. Thus, we can reset it
                self.receive_event.reset();
            }

            return msg;
        }

        pub fn tryReceive(self: *@This()) !?Elem {
            return try self.internalReceive(false);
        }

        pub fn receive(self: *@This()) !Elem {
            return try self.internalReceive(true);
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "Channel single thread" {
    var channel = Channel([2]i32).init();
    try expectEqual(true, try channel.trySend(1));
    try expectEqual(true, try channel.trySend(2));
    try expectEqual(false, try channel.trySend(3));

    try expectEqual(@as(?i32, 1), try channel.tryReceive());
    try expectEqual(@as(?i32, 2), try channel.tryReceive());
    try expectEqual(@as(?i32, null), try channel.tryReceive());

    try expectEqual(true, try channel.trySend(4));
    try expectEqual(true, try channel.trySend(5));
    try expectEqual(@as(?i32, 4), try channel.tryReceive());

    try expectEqual(true, try channel.trySend(6));
    try expectEqual(@as(?i32, 5), try channel.tryReceive());
    try expectEqual(@as(?i32, 6), try channel.tryReceive());

    try expectEqual(@as(?i32, null), try channel.tryReceive());
}
