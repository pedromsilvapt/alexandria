const std = @import("std");
const assert = std.debug.assert;
const Allocator = @import("std").mem.Allocator;

/// Zig implementation of a Complete Binary Merkle Tree, 
/// by looking only at the README of https://github.com/nervosnetwork/merkle-tree
pub fn Merkle(
    comptime NodeType: type,
    comptime hash: fn (*NodeType, *NodeType, *NodeType) void,
) type {
    return struct {
        pub const NodeType = NodeType;

        pub const Shape = struct {
            leafs: usize,
            nodes: usize,
            height: usize,

            pub const size_of_node = @sizeOf(NodeType);

            pub fn init(leaf_count: usize) Shape {
                // Calculate the number of leafs and nodes
                const node_count = leaf_count * 2 - 1;

                var height: usize = std.math.log2_int_ceil(usize, leaf_count) + 1;

                return .{
                    .leafs = leaf_count,
                    .nodes = node_count,
                    .height = height,
                };
            }

            pub fn getOffset(self: Shape) usize {
                return std.math.pow(usize, 2, self.height - 1) - self.leafs;
            }

            /// Provided with a slice of nodes, returns a sub-slice of it that
            /// corresponds only to the leaf-nodes
            pub fn getLeafsSlice(self: Shape, nodes: []NodeType) []NodeType {
                assert(nodes.len == self.nodes);

                return nodes[(self.leafs - 1)..self.nodes];
            }

            /// Given a leaf_index (0 <= leaf_index < leafs), return the node index
            /// where that leaf should be stored
            pub fn indexOfNode(self: Shape, leaf_index: usize) usize {
                assert(leaf_index < self.leafs);

                // The index of the first leaf node
                var first_leaf_node = self.leafs - 1;

                return first_leaf_node + leaf_index;
            }

            pub fn indexOfParent(self: Shape, node_index: usize) usize {
                // The root node has no parent
                assert(node_index > 0 and node_index < self.nodes);

                return (node_index - 1) / 2;
            }

            pub fn indexOfSibling(self: Shape, node_index: usize) usize {
                assert(node_index < self.nodes);
                // The root node has no sibling
                assert(node_index > 0);

                // TODO Study possibility to return null if the sibling index
                // is a leaf and is outside of the leafs (leafs < leafs_even and
                // sinbling index is the last one).
                return ((node_index + 1) ^ 1) - 1;
            }

            pub fn indexOfChildren(self: Shape, node_index: usize) usize {
                // if the node_index represents a leaf, then leafs have no children
                assert(node_index < self.leafs - 1);

                return 2 * node_index + 1;
            }

            pub fn getLevel(self: Shape, index: usize) Level {
                assert(index < self.height);

                const start = std.math.pow(usize, 2, index) - 1;
                const end = std.math.min(std.math.pow(usize, 2, index + 1) - 2, self.nodes - 1);

                return Level{
                    .index = index,
                    .start = start,
                    .len = end - start + 1,
                };
            }

            pub fn levels(self: Shape, direction: LevelsDirection) LevelsIterator {
                return LevelsIterator.init(self, direction);
            }

            pub fn getTotalSizeOfNodes(self: Shape) usize {
                return size_of_node * self.nodes;
            }
        };

        pub const Level = struct {
            index: usize,
            start: usize,
            len: usize,
        };

        pub const LevelsDirection = enum {
            up,
            down,
        };

        pub const LevelsIterator = struct {
            shape: Shape,
            index: ?usize,
            direction: LevelsDirection,

            pub fn init(shape: Shape, direction: LevelsDirection) LevelsIterator {
                var index: ?usize = null;

                if (direction == .up) {
                    // Start with the last level and go up
                    index = shape.height - 1;
                } else {
                    // Start with the first level and go down
                    index = 0;
                }

                return .{
                    .shape = shape,
                    .index = index,
                    .direction = direction,
                };
            }

            pub fn next(self: *LevelsIterator) ?Level {
                if (self.index) |index| {
                    if (self.direction == .up) {
                        if (index == 0) {
                            self.index = null;
                        } else {
                            self.index = index - 1;
                        }
                    } else if (self.direction == .down) {
                        if (index >= self.shape.height - 1) {
                            self.index = null;
                        } else {
                            self.index = index + 1;
                        }
                    }

                    return self.shape.getLevel(index);
                }

                return null;
            }
        };

        allocator: Allocator,
        shape: Shape,
        nodes: []NodeType,

        pub fn init(allocator: Allocator, leafs: []NodeType) !@This() {
            var tree = try @This().initEmpty(allocator, leafs.len);

            // Copy the leafs to the end portion of the nodes array
            std.mem.copy(NodeType, tree.getLeafsSlice(), leafs);

            // Calculate the hashes
            tree.rehash();

            return tree;
        }

        pub fn initEmpty(allocator: Allocator, leafs: usize) !@This() {
            if (leafs == 0) return error.InvalidLeafCount;

            // Calculate the shape of the Merkle Tree (number of nodes, leafs, etc...)
            var shape = Shape.init(leafs);

            // Allocate the array that will store all the nodes (including the leafs)
            var nodes = try allocator.alloc(NodeType, shape.nodes);

            return @This(){
                .allocator = allocator,
                .shape = shape,
                .nodes = nodes,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.nodes);
        }

        pub fn getLeafsSlice(self: *@This()) []NodeType {
            return self.shape.getLeafsSlice(self.nodes);
        }

        pub fn rehash(self: *@This()) void {
            // If we only have one leaf, then we also have one node only
            // That node is both the leaf and the root of the tree, so there is nothing
            // "above" it in the tree to hash
            if (self.shape.leafs > 1) {
                var parent: usize = self.shape.nodes - self.shape.leafs - 1;
                var child: usize = self.shape.nodes - 2;

                while (true) {
                    hash(&self.nodes[child], &self.nodes[child + 1], &self.nodes[parent]);

                    if (parent == 0) {
                        break;
                    }

                    parent -= 1;
                    child -= 2;
                }
            }
        }
    };
}

pub fn hashMd5(left: *[16]u8, right: *[16]u8, result: *[16]u8) void {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(left);
    md5.update(right);
    md5.final(result);
}

pub fn hashSha256(left: *[32]u8, right: *[32]u8, result: *[32]u8) void {
    var sha2 = std.crypto.hash.sha2.Sha256.init(.{});
    sha2.update(left);
    sha2.update(right);
    sha2.final(result);
}

pub const MerkleMd5 = Merkle([16]u8, hashMd5);

pub const MerkleSha256 = Merkle([32]u8, hashSha256);

// ------ Shape.init(7)
// Node Array: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 ]
//                               │                       │
//                               └───────────────────────┘
//                        ─┐             7 Leafs
//       ┌─────0────┐      │
//       │          │      │
//    ┌──1──┐     ┌─ 2──┐  │      (2 * 7 - 1)
//    │     │     │     │  │◄──── 13 Nodes
//  ┌─3─┐ ┌─4─┐ ┌─5─┐   6  │
//  │   │ │   │ │   │      │
//  7   8 9  10 11 12      │
//                        ─┘

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const TestingMerkle = MerkleMd5;
const TestingShape = TestingMerkle.Shape;

test "Shape.init" {
    const Shape = TestingShape;

    var tree = Shape.init(1);
    try expectEqual(@as(usize, 1), tree.leafs);
    try expectEqual(@as(usize, 1), tree.nodes);
    try expectEqual(@as(usize, 1), tree.height);

    tree = Shape.init(2);
    try expectEqual(@as(usize, 2), tree.leafs);
    try expectEqual(@as(usize, 3), tree.nodes);
    try expectEqual(@as(usize, 2), tree.height);

    tree = Shape.init(3);
    try expectEqual(@as(usize, 3), tree.leafs);
    try expectEqual(@as(usize, 5), tree.nodes);
    try expectEqual(@as(usize, 3), tree.height);

    tree = Shape.init(4);
    try expectEqual(@as(usize, 4), tree.leafs);
    try expectEqual(@as(usize, 7), tree.nodes);
    try expectEqual(@as(usize, 3), tree.height);

    tree = Shape.init(6);
    try expectEqual(@as(usize, 2), tree.getOffset());

    tree = Shape.init(7);
    try expectEqual(@as(usize, 7), tree.leafs);
    try expectEqual(@as(usize, 13), tree.nodes);
    try expectEqual(@as(usize, 4), tree.height);
    try expectEqual(@as(usize, 1), tree.getOffset());
}

test "Shape#indexOfNode" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    try expectEqual(@as(usize, 6), tree.indexOfNode(0));
    try expectEqual(@as(usize, 12), tree.indexOfNode(6));

    tree = Shape.init(1);
    try expectEqual(@as(usize, 0), tree.indexOfNode(0));
}

test "Shape#indexOfParent" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    try expectEqual(@as(usize, 5), tree.indexOfParent(12));
    try expectEqual(@as(usize, 2), tree.indexOfParent(6));
    try expectEqual(@as(usize, 0), tree.indexOfParent(2));

    try expectEqual(@as(usize, 3), tree.indexOfParent(7));
    try expectEqual(@as(usize, 1), tree.indexOfParent(3));
    try expectEqual(@as(usize, 0), tree.indexOfParent(1));
    try expectEqual(@as(usize, 4), tree.indexOfParent(9));
}

test "Shape#indexOfSibling" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    // TODO Change the expected to null if out-of-range leafs are implemented
    try expectEqual(@as(usize, 11), tree.indexOfSibling(12));
    try expectEqual(@as(usize, 5), tree.indexOfSibling(6));
    try expectEqual(@as(usize, 6), tree.indexOfSibling(5));
    try expectEqual(@as(usize, 1), tree.indexOfSibling(2));

    try expectEqual(@as(usize, 8), tree.indexOfSibling(7));
    try expectEqual(@as(usize, 4), tree.indexOfSibling(3));
    try expectEqual(@as(usize, 2), tree.indexOfSibling(1));
    try expectEqual(@as(usize, 10), tree.indexOfSibling(9));
}

test "Shape#indexOfChildren" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    try expectEqual(@as(usize, 5), tree.indexOfChildren(2));
    try expectEqual(@as(usize, 3), tree.indexOfChildren(1));
    try expectEqual(@as(usize, 1), tree.indexOfChildren(0));
}

test "Shape#levels(.down)" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    var iter = tree.levels(.down);
    var level: ?TestingMerkle.Level = null;

    // Level 0
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 0), level.?.index);
    try expectEqual(@as(?usize, 0), level.?.start);
    try expectEqual(@as(?usize, 1), level.?.len);

    // Level 1
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 1), level.?.index);
    try expectEqual(@as(?usize, 1), level.?.start);
    try expectEqual(@as(?usize, 2), level.?.len);

    // Level 2
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 2), level.?.index);
    try expectEqual(@as(?usize, 3), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);

    // Level 3
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 3), level.?.index);
    try expectEqual(@as(?usize, 7), level.?.start);
    try expectEqual(@as(?usize, 6), level.?.len);

    // Shape.init(6)
    tree = Shape.init(6);
    iter = tree.levels(.down);

    level = iter.next();
    // Level 0
    try expect(level != null);
    try expectEqual(@as(?usize, 0), level.?.index);
    try expectEqual(@as(?usize, 0), level.?.start);
    try expectEqual(@as(?usize, 1), level.?.len);

    // Level 1
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 1), level.?.index);
    try expectEqual(@as(?usize, 1), level.?.start);
    try expectEqual(@as(?usize, 2), level.?.len);

    // Level 2
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 2), level.?.index);
    try expectEqual(@as(?usize, 3), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);

    // Level 3
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 3), level.?.index);
    try expectEqual(@as(?usize, 7), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);
}

test "Shape#levels(.up)" {
    const Shape = TestingShape;

    var tree = Shape.init(7);
    var iter = tree.levels(.up);
    var level: ?TestingMerkle.Level = null;

    // Level 3
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 3), level.?.index);
    try expectEqual(@as(?usize, 7), level.?.start);
    try expectEqual(@as(?usize, 6), level.?.len);

    // Level 2
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 2), level.?.index);
    try expectEqual(@as(?usize, 3), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);

    // Level 1
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 1), level.?.index);
    try expectEqual(@as(?usize, 1), level.?.start);
    try expectEqual(@as(?usize, 2), level.?.len);

    // Level 0
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 0), level.?.index);
    try expectEqual(@as(?usize, 0), level.?.start);
    try expectEqual(@as(?usize, 1), level.?.len);

    // Shape.init(6)
    tree = Shape.init(6);
    iter = tree.levels(.down);

    level = iter.next();
    // Level 0
    try expect(level != null);
    try expectEqual(@as(?usize, 0), level.?.index);
    try expectEqual(@as(?usize, 0), level.?.start);
    try expectEqual(@as(?usize, 1), level.?.len);

    // Level 1
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 1), level.?.index);
    try expectEqual(@as(?usize, 1), level.?.start);
    try expectEqual(@as(?usize, 2), level.?.len);

    // Level 2
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 2), level.?.index);
    try expectEqual(@as(?usize, 3), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);

    // Level 3
    level = iter.next();
    try expect(level != null);
    try expectEqual(@as(?usize, 3), level.?.index);
    try expectEqual(@as(?usize, 7), level.?.start);
    try expectEqual(@as(?usize, 4), level.?.len);
}

test "Merkle#rehash" {
    var tree = try TestingMerkle.initEmpty(std.testing.allocator, 4);
    defer tree.deinit();

    _ = tree;
}
