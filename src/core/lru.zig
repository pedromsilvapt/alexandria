const std = @import("std");
const TailQueue = std.TailQueue;
const Allocator = std.mem.Allocator;
const HashMap = std.mem.HashMap;
const AutoHashMap = std.AutoHashMap;
const assert = std.debug.assert;

pub fn LRU(comptime Key: type, comptime Value: type) type {
    return struct {
        allocator: Allocator,
        hashmap: AutoHashMap(Key, *Node),
        queue: TailQueue(Entry),
        capacity: usize,

        const Node = TailQueue(Entry).Node;
        const Entry = struct {
            key: Key,
            value: Value,
        };
        pub const EvictedEntry = struct {
            key: ?Key = null,
            value: ?Value = null,
        };

        pub fn init(allocator: Allocator, capacity: usize) @This() {
            assert(capacity > 0);

            return .{
                .allocator = allocator,
                .hashmap = std.AutoHashMap(Key, *Node).init(allocator),
                .queue = TailQueue(Entry){},
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *@This()) void {
            // Free all the memory from the HashMap
            self.hashmap.deinit();

            var next_node = self.queue.first;
            while (next_node) |node| {
                next_node = node.next;

                self.allocator.destroy(node);
            }

            self.queue = .{};
        }

        /// Returns the number of elements currently saved by this queue.
        /// Is guaranteed to always be <= self.capacity
        pub fn count(self: *const @This()) usize {
            return self.queue.len;
        }

        /// Checks if a given key exists in this LRU cache
        pub fn contains(self: *const @This(), key: Key) bool {
            return self.hashmap.contains(key);
        }

        /// Returns the value associated with this key. If no such key exists in the cache, returns null.
        pub fn get(self: *@This(), key: Key) ?Value {
            if (self.hashmap.get(key)) |node| {
                self.promoteToFirst(node);

                return node.data.value;
            }

            return null;
        }

        /// Saves a value associated with the key in the LRU. If any key/value is evicted
        /// it is the responsability of the caller to properly dispose of them.
        /// 
        ///  1. If this key is already present, its value is replaced and pushed to the top of the queue.
        ///     The returned struct key is null and the value contains the old value that was replaced.
        ///  2. If this key is not present, and the cache is already full (self.count() == self.capacity)
        ///     then the oldest key/value are removed and this value is added to the top of the queue.
        ///     Both the old key and value are returned to be disposed of.
        ///  3. If this key is not present and the cache has free capacity, this value is added to the top
        ///     of the queue. The returned key and value are null, so there is nothing to be dispose of.
        pub fn put(self: *@This(), key: Key, value: Value) !EvictedEntry {
            // When saving something in an LRU cache, there are three possible cases:
            //  - The key already exists, in which case the new value replaces the old one
            //  - The key is new but the cache is full, in which case the oldest value
            //    is evicted (key and value) and are replaced by the ones
            //  - The key is new and the cache has capacity, in which case nothing is evicted
            // The evicted values are returned to the caller, in case they need to be disposed of.
            // For example, if either of them are heap allocated, they probably need to be freed
            var evicted_entry = EvictedEntry{};

            if (self.hashmap.get(key)) |node| {
                // If this item is already on our cache, just put it back to the top of the queue
                self.promoteToFirst(node);

                // Set the old value that was evicted by this operation, but keep the key (we did not evict it yet)
                evicted_entry.value = node.data.value;

                node.data.value = value;
            } else {
                assert(self.capacity > 0);

                // Check if we still have capacity in our cache
                if (self.queue.len < self.capacity) {
                    // Create new node and add to the queue
                    var node: *Node = try self.allocator.create(Node);
                    errdefer self.allocator.destroy(node);

                    try self.hashmap.put(key, node);
                    errdefer _ = self.hashmap.remove(key);

                    self.queue.prepend(node);

                    node.data = Entry{
                        .key = key,
                        .value = value,
                    };
                } else {
                    // Evict the last element from the queue and repurpose it's node
                    // We can assume node != null, since self.queue.len >= self.capacity and self.capacity > 0
                    var node = self.queue.pop().?;
                    _ = self.hashmap.remove(node.data.key);

                    try self.hashmap.put(key, node);
                    errdefer _ = self.hashmap.remove(key);

                    // Save the evicted values so they can be handled by the called
                    evicted_entry.key = node.data.key;
                    evicted_entry.value = node.data.value;

                    self.queue.prepend(node);

                    node.data = Entry{
                        .key = key,
                        .value = value,
                    };
                }
            }

            return evicted_entry;
        }

        /// Removes an element from this cache (if it is present)
        /// Returns an entry with the evicted keys and values.
        /// This function guarantees that either both key and value of the evicted entryare null 
        /// (when the element was not in the cache to begin with) or they are both present
        pub fn remove(self: *@This(), key: Key) EvictedEntry {
            var evicted_entry = EvictedEntry{};

            if (self.hashmap.get(key)) |node| {
                // Save the evicted values so they can be returned to the caller
                evicted_entry.key = node.data.key;
                evicted_entry.value = node.data.value;

                // Remove the node from the queue
                self.queue.remove(node);

                // Remove the node from the hash map as well
                _ = self.hashmap.remove(key);

                // Destroy the node instance
                self.allocator.destroy(node);
            }

            return evicted_entry;
        }

        /// Moves an element in the queue from whatever position it is in to the first position
        /// Assumes that the element is inside the queue in the beginning
        /// If the element is already in the first position, this is a no-op
        fn promoteToFirst(self: *@This(), node: *Node) void {
            // Compare the pointers, see if this node is not the first (most recent accessed)
            if (self.queue.first != node) {
                self.queue.remove(node);

                self.queue.prepend(node);
            }
        }
    };
}

fn expectQueue(lru: anytype, keys: anytype, values: anytype) !void {
    var node = lru.queue.last;

    inline for (keys) |key, i| {
        const key_typed = @as(@TypeOf(node.?.data.key), key);
        const value_typed = @as(@TypeOf(node.?.data.value), values[i]);

        try std.testing.expect(node != null);
        try std.testing.expectEqual(key_typed, node.?.data.key);
        try std.testing.expectEqual(value_typed, node.?.data.value);

        // Test the hashmap
        try std.testing.expect(lru.hashmap.contains(key_typed));
        var hashmap_node = lru.hashmap.get(key_typed);

        try std.testing.expect(hashmap_node != null);
        try std.testing.expectEqual(key_typed, hashmap_node.?.data.key);
        try std.testing.expectEqual(value_typed, hashmap_node.?.data.value);

        // Finally test that both hashmap nodes and queue nodes are exactly the same
        try std.testing.expectEqual(node.?, hashmap_node.?);

        node = node.?.prev;
    }
}

test "LRU for value types" {
    var lru = LRU(i32, u64).init(std.testing.allocator, 3);
    defer lru.deinit();

    // Timeline of keys in the LRU during this test: {oldest, penultimate, .., most recent}
    // 1. {}
    // 2. {3}
    // 3. {3, 4}
    // 4. {3, 4, 5}
    // 5. {4, 5, 6}
    // 6. {5, 6, 4}
    // 7. {5, 4}
    // 8. {5, 4, 7}

    // 1. {}
    try std.testing.expect(lru.contains(3) == false);
    try expectQueue(lru, .{}, .{});

    var entry: LRU(i32, u64).EvictedEntry = .{};
    var value: ?u64 = null;

    // 2. {3}
    // Put one entry and make sure nothing is evicted
    entry = try lru.put(3, 6);
    try std.testing.expectEqual(@as(?i32, null), entry.key);
    try std.testing.expectEqual(@as(?u64, null), entry.value);
    try expectQueue(lru, .{3}, .{6});

    // 3. {3, 4}
    // Put a second entry and make sure nothing is evicted
    entry = try lru.put(4, 8);
    try std.testing.expectEqual(@as(?i32, null), entry.key);
    try std.testing.expectEqual(@as(?u64, null), entry.value);
    try expectQueue(lru, .{ 3, 4 }, .{ 6, 8 });

    // 4. {3, 4, 5}
    // Put a third entry and make sure nothing is evicted
    entry = try lru.put(5, 10);
    try std.testing.expectEqual(@as(?i32, null), entry.key);
    try std.testing.expectEqual(@as(?u64, null), entry.value);
    try expectQueue(lru, .{ 3, 4, 5 }, .{ 6, 8, 10 });

    // 5. {4, 5, 6}
    // Put a fourth entry and make sure the oldest one is evicted
    entry = try lru.put(6, 12);
    try std.testing.expectEqual(@as(?i32, 3), entry.key);
    try std.testing.expectEqual(@as(?u64, 6), entry.value);
    try std.testing.expect(lru.contains(3) == false);
    try expectQueue(lru, .{ 4, 5, 6 }, .{ 8, 10, 12 });

    // 6. {5, 6, 4}
    // Get the entry key 4 (oldest), expect the proper value to be returned
    value = lru.get(4);
    try std.testing.expectEqual(@as(?u64, 8), value);
    try expectQueue(lru, .{ 5, 6, 4 }, .{ 10, 12, 8 });

    // 7. {5, 4}
    entry = lru.remove(6);
    try std.testing.expectEqual(@as(?i32, 6), entry.key);
    try std.testing.expectEqual(@as(?u64, 12), entry.value);
    try std.testing.expect(lru.contains(6) == false);
    try expectQueue(lru, .{ 5, 4 }, .{ 10, 8 });

    // 8. {5, 4, 7}
    entry = try lru.put(7, 14);
    try std.testing.expectEqual(@as(?i32, null), entry.key);
    try std.testing.expectEqual(@as(?u64, null), entry.value);
    try expectQueue(lru, .{ 5, 4, 7 }, .{ 10, 8, 14 });
}
