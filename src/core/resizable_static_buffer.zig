const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;

/// Creates a buffer with a fixed static size allocated on the stack. 
/// If during runtime more space is needed, automatically switches to a heap-allocated
/// buffer that grows and shrinks as needed
pub fn ResizableStaticBuffer(comptime T: type, comptime static_size: usize) type {
    return struct {
        allocator: Allocator,
        static_buffer: [static_size]T = undefined,
        dynamic_buffer: ?ArrayListUnmanaged(T) = null,
        len: usize = 0,

        /// Initializes a buffer
        pub fn init(allocator: Allocator) @This() {
            return .{ .allocator = allocator };
        }

        /// Releases any heap memory held by this struct (if any)
        pub fn deinit(self: *@This()) void {
            if (self.dynamic_buffer) |*buffer| {
                buffer.deinit(self.allocator);
            }
        }

        /// Acquires the additional buffer space from the available capacity. 
        /// If the current buffer does not have enough capacity for it, attempts
        /// to allocate it dynamically in the heap, moving the contents of the 
        /// static buffer over
        pub fn acquire(self: *@This(), additional_size: usize) ![]T {
            // If we are using the dynamic buffer
            if (self.dynamic_buffer) |*list| {
                try list.ensureTotalCapacity(self.allocator, self.len + additional_size);

                var acquired_slice = list.items[self.len .. self.len + additional_size];

                self.len += additional_size;

                return acquired_slice;
            } else {
                // If we are using the static buffer and even with the additional
                // size requested, we still fit inside it
                if (self.len + additional_size <= static_size) {
                    var acquired_slice = self.static_buffer[self.len .. self.len + additional_size];

                    self.len += additional_size;

                    return acquired_slice;
                } else {
                    // If we are using the static buffer but with this additional
                    // size requirement we go over the limit, we must initialize
                    // a dynamic buffer and copy our current contents to it
                    var list = ArrayListUnmanaged(T){};

                    // Make sure there is enough space on the list
                    try list.ensureTotalCapacity(self.allocator, self.len + additional_size);

                    // Copy everything from the static array into the dynamic one
                    std.mem.copy(T, list.items, self.static_buffer[0..self.len]);

                    // Get the slice for the acquired part of the buffer
                    var acquired_slice = list.items[self.len .. self.len + additional_size];

                    self.len += additional_size;

                    return acquired_slice;
                }
            }
        }

        /// Release a certain amount of space from the buffer
        /// This size should always be less than or equal to the currently
        /// acquired length of the buffer
        pub fn release(self: *@This(), size: usize) void {
            assert(self.len >= size);

            self.len -= size;
        }

        /// Release a certain amount of space from the buffer, and try to compact
        /// it when possible
        /// This size should always be less than or equal to the currently
        /// acquired length of the buffer
        pub fn releaseCompact(self: *@This(), size: usize) void {
            self.release(size);
            self.compact();
        }

        /// Releases all the space from the buffer. Note that this does not
        /// release any memory that might actually be allocated from the heap,
        /// instead only reduces the length counter. The memory can still be reused
        /// by calling acquire later on
        pub fn releaseAll(self: *@This()) void {
            self.len = 0;
        }

        /// Releases all the space from the buffer and compacts the memory allocated
        /// in the heap, if any.
        pub fn releaseAllCompact(self: *@This()) void {
            self.releaseAll();

            self.compact();
        }

        /// When the dynamic buffer is in use, can release some memory depending 
        /// on the length of the buffer currently in use.
        /// When the static buffer is in use, does nothing
        pub fn compact(self: *@This()) void {
            if (self.dynamic_buffer) |*list| {
                if (self.len == 0) {
                    // Release the entire dynamic buffer
                    list.deinit(self.allocator);

                    // And set it as null so the static buffer can be used instead of it
                    self.dynamic_buffer = null;
                } else if (self.len <= static_size) {
                    // If we are using a dynamic buffer, but the used space
                    // fits inside the static buffer, copy it and release the memory

                    // Copy everything from the dynamic array into the static one
                    std.mem.copy(T, &self.static_buffer, list.items[0..self.len]);

                    // Release the dynamic array's memory
                    list.deinit(self.allocator);

                    self.dynamic_buffer = null;
                }

                // TODO Handle the case where len > static_size, but it's also
                // smaller than capacity by x%, so we can shrink it and release
                // some memory
            }
        }

        /// Get a slice for the currently in use buffer (static or dynamic)
        /// Should only be considered valid for as long as no size-changing
        /// operations are performed on the buffer
        pub fn getSlice(self: *@This()) []T {
            if (self.dynamic_buffer) |list| {
                return list.items[0..self.len];
            } else {
                return self.static_buffer[0..self.len];
            }
        }

        /// Get a const slice for the currently in use buffer (static or dynamic)
        /// Should only be considered valid for as long as no size-changing
        /// operations are performed on the buffer
        pub fn getSliceConst(self: *const @This()) []const T {
            if (self.dynamic_buffer) |list| {
                return list.items[0..self.len];
            } else {
                return self.static_buffer[0..self.len];
            }
        }

        /// Get a slice for a portion of the start of the buffer
        /// Should only be considered valid for as long as no size-changing 
        /// operations are performed on the buffer
        pub fn getSlicePrefix(self: *@This(), len: usize) []T {
            assert(self.len >= len);

            return self.getSlice()[0..len];
        }

        /// Get a const slice for a portion of the start of the buffer
        /// Should only be considered valid for as long as no size-changing 
        /// operations are performed on the buffer
        pub fn getSlicePrefixConst(self: *const @This(), len: usize) []const T {
            assert(self.len >= len);

            return self.getSliceConst()[0..len];
        }

        /// Get a slice for a portion of the end of the buffer
        /// Should only be considered valid for as long as no size-changing 
        /// operations are performed on the buffer
        pub fn getSliceSuffix(self: *@This(), len: usize) []T {
            assert(self.len >= len);

            return self.getSlice()[self.len - len .. self.len];
        }

        /// Get a const slice for a portion of the end of the buffer
        /// Should only be considered valid for as long as no size-changing 
        /// operations are performed on the buffer
        pub fn getSliceSuffixConst(self: *const @This(), len: usize) []const T {
            assert(self.len >= len);

            return self.getSliceConst()[self.len - len .. self.len];
        }
    };
}

test "No allocations StaticResizableBuffer" {
    var buffer = ResizableStaticBuffer(i32, 4).init(std.testing.allocator);
    defer buffer.deinit();

    // Buffer should be empty at the start
    try std.testing.expect(buffer.dynamic_buffer == null);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getSlice().len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getSliceConst().len);

    // Acquire 4 slots in the buffer
    var slice = try buffer.acquire(4);
    try std.testing.expectEqual(@as(usize, 4), slice.len);

    // Test retrieving segments of the buffer
    try std.testing.expectEqual(@as(usize, 2), buffer.getSlicePrefix(2).len);
    try std.testing.expectEqual(@as(usize, 2), buffer.getSlicePrefixConst(2).len);
    try std.testing.expectEqual(@as(usize, 2), buffer.getSliceSuffix(2).len);
    try std.testing.expectEqual(@as(usize, 2), buffer.getSliceSuffixConst(2).len);

    // Buffer should be static, with len 4
    try std.testing.expect(buffer.dynamic_buffer == null);
    try std.testing.expectEqual(@as(usize, 4), buffer.len);
    try std.testing.expectEqual(@as(usize, 4), buffer.getSlice().len);
    try std.testing.expectEqual(@as(usize, 4), buffer.getSliceConst().len);

    // Release half of the memory
    buffer.releaseCompact(2);

    // Buffer should be static, with len 2
    try std.testing.expect(buffer.dynamic_buffer == null);
    try std.testing.expectEqual(@as(usize, 2), buffer.len);
    try std.testing.expectEqual(@as(usize, 2), buffer.getSlice().len);
    try std.testing.expectEqual(@as(usize, 2), buffer.getSliceConst().len);

    // Release all the rest of the memory
    buffer.releaseCompact(2);

    // Buffer should be static, with len 0
    try std.testing.expect(buffer.dynamic_buffer == null);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getSlice().len);
    try std.testing.expectEqual(@as(usize, 0), buffer.getSliceConst().len);
}
