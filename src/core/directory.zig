const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

/// A Directory represents a list of files organized in an hierarchical fashion. 
/// Each file can have some data associated with it
pub fn Directory(comptime FileData: type) type {
    return struct {
        allocator: Allocator,
        root: Entry = Entry{
            .name = "",
            .kind = .{ .folder = FolderEntry{} },
        },

        pub fn init(allocator: Allocator) @This() {
            return @This(){
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            var next_node: ?*Entry = &self.root;

            while (next_node) |node| {
                if (node.kind == .folder) {
                    if (node.kind.folder._child) |child| {
                        // If the node has any children, we do not free it's memory right away
                        // Instead, we go to the children first, and only when we are coming up
                        // do we free the parent and move to the sibling
                        next_node = child;

                        continue;
                    }
                }

                if (node._sibling) |sibling| {
                    // If we have a sibling, we can move on to them and just free the current node
                    next_node = sibling;

                    self.deinitNode(node);
                } else if (node._parent) |parent| {
                    // If we have a parent, then we can assume our parent is a folder (files have no children)
                    assert(parent.kind == .folder);

                    // We have freed every child from our parent parent,
                    // so we no longer need the reference to the first child, and we can erase it
                    parent.kind.folder._child = null;
                    // Set our parent (recently with no children) as our next node
                    // This way we can handle itself, its siblings or it's parent (if it has any)
                    next_node = parent;

                    self.deinitNode(node);
                } else {
                    // If our current node has no children, siblings or parent, then we have no nodes left to go through
                    next_node = null;
                }
            }
        }

        fn deinitNode(self: *@This(), node: *Entry) void {
            if (node.name_owned) {
                self.allocator.free(node.name);
            }

            // No need to deinit our root node, it was never individually allocated
            if (node == &self.root) {
                return;
            }

            self.allocator.destroy(node);
        }

        /// Add a file to this directory, and attach to it the data provided
        /// Creates any missing sub-folders in it's way.
        /// If a file already exists in the same location, overwrites it
        ///
        /// TODO Change the default overwrite behavior, either by providing 
        /// separate functions, or by allowing passing an options object to configure it
        pub fn addFile(self: *@This(), path: []const u8, data: FileData) !*Entry {
            var start: usize = 0;
            var end: usize = 0;
            var node: *Entry = &self.root;
            var node_created: bool = false;

            while (getNextPathSegment(path, &start, &end)) {
                // `node` represents the parent node, which means it must be a folder
                // otherwise we cannot retrieve/create a child for this segment inside it
                if (node.kind != .folder) return error.PathIsNotFolder;

                // NOTE From here on out we can assume `node.kind == .folder`

                // Grab only the current path segment from the whole path
                const name: []const u8 = path[start..end];

                var child_node: ?*Entry = null;

                // If our current folder has children, attempt to find one child
                // with the same name
                if (node.kind.folder._child != null) {
                    var next_sibling_node = node.kind.folder._child;

                    while (next_sibling_node) |sibling_node| {
                        // If this is a good match for the folder/file we are looking for
                        if (std.mem.eql(u8, sibling_node.name, name)) {
                            child_node = sibling_node;
                            node_created = false;
                            break;
                        } else {
                            // Otherwise move on to the next sibling and keep looking
                            next_sibling_node = sibling_node._sibling;
                        }
                    }
                }

                if (child_node == null) {
                    // Allocate a slice of owned memory containing the folder/file name
                    var name_owned: []u8 = try self.allocator.alloc(u8, name.len);
                    errdefer self.allocator.free(name_owned);

                    // Copy the contents from `name` to `name_owned`
                    std.mem.copy(u8, name_owned, name);

                    // Allocate the node entry for this file
                    child_node = try self.allocator.create(Entry);
                    errdefer self.allocator.destroy(child_node.?);

                    // NOTE From here on out we can assume `child_node != null`

                    // Right now we don't know if `name` represents a file or a folder
                    // That can only be known after we get the next segment: if
                    // there is not, then we know it is a file. But for now, we pretend
                    // everything we create is a folder, and in the end, we "convert"
                    // the last folder to a file
                    child_node.?.* = Entry{
                        .name = name_owned,
                        .name_owned = true,
                        .kind = .{ .folder = FolderEntry{} },
                    };
                    node_created = true;

                    // For simplicity's sake, add new files to the top of the list.
                    // TODO In the future, append them, and possibly sort them by type and name
                    child_node.?._sibling = node.kind.folder._child;
                    child_node.?._parent = node;
                    node.kind.folder._child = child_node;
                }

                // We know child_node is not null here
                node = child_node.?;
            }

            if (node == &self.root) return error.PathIsNotFile;

            if (!node_created and node.kind != .file) return error.PathIsNotFile;

            // Convert the entry to a file
            node.kind = .{
                .file = FileEntry{
                    .data = data,
                },
            };

            return node;
        }

        pub fn getEntry(self: *@This(), path: []const u8) !?*Entry {
            var start: usize = 0;
            var end: usize = 0;

            var node: *Entry = &self.root;

            while (getNextPathSegment(path, &start, &end)) {
                // `node` represents the parent node, which means it must be a folder
                // otherwise we cannot retrieve a child for this segment from inside it
                if (node.kind != .folder) return error.PathIsNotFolder;

                // NOTE From here on out we can assume `node.kind == .folder`

                // Grab only the current path segment from the whole path
                const name: []const u8 = path[start..end];

                var child_node: ?*Entry = null;

                // If our current folder has children, attempt to find one child
                // with the same name
                if (node.kind.folder._child != null) {
                    var next_sibling_node = node.kind.folder._child;

                    while (next_sibling_node) |sibling_node| {
                        // If this is a good match for the folder/file we are looking for
                        if (std.mem.eql(u8, sibling_node.name, name)) {
                            child_node = sibling_node;
                            break;
                        } else {
                            // Otherwise move on to the next sibling and keep looking
                            next_sibling_node = sibling_node._sibling;
                        }
                    }
                }

                // If we could not find an entry for this path segment, stop the search and return
                if (child_node == null) {
                    return null;
                }

                node = child_node.?;
            }

            return node;
        }

        /// Return the next path segment. Start is inclusive, end is not inclusive
        /// If the value returns false, it means there was no next segment found in the path
        /// If the value returns true, then the next segment positions are stored
        /// in the argument variables `start` and `end` next segment is found in path[start..end]
        fn getNextPathSegment(path: []const u8, start: *usize, end: *usize) bool {
            // Variable representing the new start char index of the path segment
            // Always start on the next start after our current segment
            var new_start: usize = end.*;

            // Skip all the (optional) initial slashes
            while (new_start < path.len and path[new_start] == '/') {
                new_start += 1;
            }

            // If we only found forward slash '/' until the end, then this was
            // already the last path segment So we can just return false
            if (new_start >= path.len) {
                return false;
            }

            // Variable representing the new ending char index of the path segment
            var new_end: usize = new_start + 1;

            // Consume all characters until the next forward slash '/'
            while (new_end < path.len and path[new_end] != '/') {
                new_end += 1;
            }

            start.* = new_start;
            end.* = new_end;

            // Return true, indicating a path segment was found
            return true;
        }

        /// An entry represents either a directory or a file
        pub const Entry = struct {
            name: []const u8,
            name_owned: bool = false,
            kind: union(enum) {
                folder: FolderEntry,
                file: FileEntry,
            },
            _parent: ?*Entry = null,
            _sibling: ?*Entry = null,
        };

        /// An entry representing a folder
        pub const FolderEntry = struct {
            _child: ?*Entry = null,
        };

        pub const FileEntry = struct {
            data: FileData,
        };
    };
}

fn expectEqualEntry(a: anytype, b: anytype) !void {
    try std.testing.expectEqualStrings(a.name, b.name);

    if (a.kind == .folder) {
        try std.testing.expect(b.kind == .folder);
    } else if (a.kind == .file) {
        try std.testing.expect(b.kind == .file);
        try std.testing.expectEqual(a.kind.file.data, b.kind.file.data);
    }
}

fn expectEntryFolder(name: []const u8, b: anytype) !void {
    try expectEqualEntry(@TypeOf(b){
        .name = name,
        .name_owned = true,
        .kind = .{ .folder = .{} },
    }, b);
}

fn expectEntryFile(name: []const u8, data: anytype, b: anytype) !void {
    try expectEqualEntry(@TypeOf(b){
        .name = name,
        .name_owned = true,
        .kind = .{ .file = .{ .data = data } },
    }, b);
}

test "Walk over a path's segments" {
    const path = "/root/folder_a/file1.txt";

    var start: usize = 0;
    var end: usize = 0;

    try std.testing.expect(Directory(i32).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/".len, start);
    try std.testing.expectEqual("/root".len, end);
    try std.testing.expectEqualStrings("root", path[start..end]);

    try std.testing.expect(Directory(i32).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/root/".len, start);
    try std.testing.expectEqual("/root/folder_a".len, end);
    try std.testing.expectEqualStrings("folder_a", path[start..end]);

    try std.testing.expect(Directory(i32).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/root/folder_a/".len, start);
    try std.testing.expectEqual("/root/folder_a/file1.txt".len, end);
    try std.testing.expectEqualStrings("file1.txt", path[start..end]);

    try std.testing.expect(!Directory(i32).getNextPathSegment(path, &start, &end));
}

test "Create a basic directory structure" {
    var directory = Directory(i32).init(std.testing.allocator);
    defer directory.deinit();

    // Try to write to different files on the same sub-folder
    _ = try directory.addFile("/root/folder_a/file1.txt", 5);
    _ = try directory.addFile("/root/folder_a/file2.txt", 10);
    // Create a new file on a different sub-folder
    _ = try directory.addFile("/root/folder_b/file2.txt", 15);
    // Overwrite this last file
    _ = try directory.addFile("/root/folder_b/file2.txt", 20);

    const Entry = Directory(i32).Entry;

    // Declare a varaible to hold our entry pointers
    var node: ?*Entry = null;

    // Try to get /root
    node = try directory.getEntry("/root");
    try std.testing.expect(node != null);
    try expectEntryFolder("root", node.?.*);

    // Try to get /root/ (should be the same result)
    node = try directory.getEntry("/root/");
    try std.testing.expect(node != null);
    try expectEntryFolder("root", node.?.*);

    // Try to get /root/folder_a
    node = try directory.getEntry("/root/folder_a");
    try std.testing.expect(node != null);
    try expectEntryFolder("folder_a", node.?.*);

    // Try to get /root/folder_a/file1.txt
    node = try directory.getEntry("/root/folder_a/file1.txt");
    try std.testing.expect(node != null);
    try expectEntryFile("file1.txt", @as(i32, 5), node.?.*);

    // Try to get /root/folder_a/file2.txt
    node = try directory.getEntry("/root/folder_a/file2.txt");
    try std.testing.expect(node != null);
    try expectEntryFile("file2.txt", @as(i32, 10), node.?.*);

    // Try to get /root/folder_b/file2.txt
    node = try directory.getEntry("/root/folder_b/file2.txt");
    try std.testing.expect(node != null);
    try expectEntryFile("file2.txt", @as(i32, 20), node.?.*);
}
