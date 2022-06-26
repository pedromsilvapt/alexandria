const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ResizableStaticBuffer = @import("./resizable_static_buffer.zig").ResizableStaticBuffer;

// Static buffer size to be used for path names, before the dynamic buffer must be
// allocated from the heap
const path_buffer_size = 4096;

/// A Directory represents a list of files organized in an hierarchical fashion. 
/// Each file can have some data associated with it
pub fn Directory(comptime FileData: type, comptime Options: type) type {
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

        /// The caller owns the `manifest` object. When this method ends/fails, it is the responsability
        /// of the caller to deinit the manifest.
        /// `manifest` should be of the type `*ManifestReader(anytype)`
        pub fn loadFromManifest(self: *@This(), manifest: anytype) !void {
            while (try manifest.next()) |entry| {
                _ = try self.addFile(entry.name, entry.kind.file.data);
            }
        }

        /// Reads the files list from the manifest stored in the provided file
        pub fn loadFromManifestFile(self: *@This(), file_path: []const u8) !void {
            var manifest = try ManifestReader(std.io.reader.Reader).initFromFile(file_path);
            defer manifest.deinit();

            try self.loadFromManifest(&manifest);
        }

        /// The caller owns the `manifest` object. When this method ends/fails,
        /// it is the responsability of the caller to deinit the manifest.
        /// `manifest` should be of the type `*ManifestWriter(anytype)`
        pub fn writeToManifest(self: *@This(), manifest: anytype) !void {
            try manifest.writeAll(self.allocator, &self.root);
            try manifest.flush();
        }

        /// Reads the files list into the manifest stored in the provided file
        pub fn writeToManifestFile(self: *@This(), file_path: []const u8) !void {
            var manifest = try ManifestWriter(std.io.writer.Writer).initFromFile(file_path);
            defer manifest.deinit();

            try self.writeToManifest(&manifest);
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

        //
        pub fn ManifestReader(comptime ReaderType: type) type {
            return struct {
                io_reader: std.io.BufferedReader(4096, ReaderType),
                line_buffer: [1024 * 4]u8 = [_]u8{0} ** (1024 * 4),

                pub fn init(reader: ReaderType) @This() {
                    return .{
                        .io_reader = std.io.bufferedReader(reader),
                    };
                }

                pub fn initFromFile(file_path: []const u8) !@This() {
                    // Open the file
                    var file: std.fs.File = try std.fs.cwd().openFile(file_path, .{ .read = true });

                    // Initialize the deserializer
                    return @This().init(file);
                }

                pub fn deinit(self: *@This()) void {
                    if (@hasDecl(ReaderType, "close")) {
                        self.io_reader.close();
                    } else if (@hasDecl(ReaderType, "deinit")) {
                        self.io_reader.deinit();
                    }
                }

                pub fn next(self: *@This()) !?Entry {
                    var reader = self.io_reader.reader();

                    var result: ?Entry = null;

                    while (result == null) {
                        // Read an entire line into the buffer
                        var line_buffer = (try reader.readUntilDelimiterOrEof(&self.line_buffer, '\n')) orelse break;

                        var start: usize = 0;
                        var end: usize = 0;

                        // Skip any whitespaces from the begining
                        var path = path_blk: {
                            // Skip white spaces
                            while (start < line_buffer.len and isWhiteSpace(line_buffer[start])) {
                                start += 1;
                            }

                            // If the entire line was whitespace, we can just return an empty slice right away
                            if (start >= line_buffer.len) break :path_blk &[_]u8{};

                            end = start + 1;

                            while (end < line_buffer.len and line_buffer[end] != ';') {
                                end += 1;
                            }

                            break :path_blk line_buffer[start..end];
                        };

                        // If this line is empty
                        if (path.len == 0) {
                            continue;
                        }

                        // Skip any whitespaces from the begining
                        var data_str = data_blk: {
                            start = end + 1;

                            if (start > line_buffer.len) {
                                return error.UnexpectedBreakLine;
                            }

                            end = start + 1;

                            while (end < line_buffer.len and line_buffer[end] != ';') {
                                end += 1;
                            }

                            break :data_blk line_buffer[start..end];
                        };

                        var data = try Options.dataFromString(data_str);

                        result = Entry{
                            .name = path,
                            .name_owned = false,
                            .kind = .{
                                .file = FileEntry{ .data = data },
                            },
                        };
                    }

                    return result;
                }
            };
        }

        pub fn ManifestWriter(comptime WriterType: type) type {
            return struct {
                io_writer: std.io.BufferedWriter(4096, WriterType),

                pub fn init(writer: WriterType) @This() {
                    return .{
                        .io_writer = std.io.bufferedWriter(writer),
                    };
                }

                pub fn initFromFile(file_path: []const u8) !@This() {
                    // Open the file
                    var file: std.fs.File = try std.fs.cwd().openFile(file_path, .{ .write = true });

                    // Initialize the deserializer
                    return @This().init(file);
                }

                pub fn deinit(self: *@This()) void {
                    if (@hasDecl(@TypeOf(self.io_writer), "close")) {
                        self.io_writer.close();
                    } else if (@hasDecl(@TypeOf(self.io_writer), "deinit")) {
                        self.io_writer.deinit();
                    }
                }

                /// Writes a single entry to the manifest. If the entry is a folder,
                /// does nothing.
                pub fn write(self: *@This(), path: []const u8, entry: *const Entry) !void {
                    // As of now, we are not writing folders to the manifest file
                    if (entry.kind == .file) {
                        // Create a writer from the IO writer
                        var writer = self.io_writer.writer();

                        if (path.len > 0) {
                            try writer.writeAll(path);

                            // If this file belongs inside a sub-path, and that sub-path
                            // does not end in a forward slash '/', we must write it manually
                            if (path[path.len - 1] != '/') {
                                try writer.writeByte('/');
                            }
                        }

                        // Write the file name
                        try writer.writeAll(entry.name);

                        // Write the separator
                        try writer.writeByte(';');

                        // Write the data payload from this file
                        try Options.dataToWriter(writer, entry.kind.file.data);

                        // And finally write a new line separator
                        try writer.writeByte('\n');
                    }
                }

                /// Writes this entry, and all it's children (if there are any)
                /// to the manifest file. Folder entries are used to get their
                /// children files, but the folders themselves are not saved 
                /// to the manifest
                pub fn writeAll(self: *@This(), allocator: Allocator, entry: *const Entry) !void {
                    // Buffer for us to write save the full path of the file as we go down
                    var path_buffer = ResizableStaticBuffer(u8, path_buffer_size).init(allocator);
                    defer path_buffer.deinit();

                    // All paths begin with a forward slash
                    try path_buffer.write("/");

                    var next_node: ?*const Entry = entry;

                    // Because of the way we iterate on the entries to print them,
                    // we could reach a situation where we would be trying to print
                    // either a sibling or a parent of this initial entry.
                    // We do not want that, we only want to print this entry or
                    // it's descendants, and so we keep their references here so
                    // we know when we have to stop writing entries
                    const stop_on_sibling: ?*const Entry = entry._sibling;
                    const stop_on_parent: ?*const Entry = entry._parent;

                    // NOTE Below, we might call some entries "root" instead of root.
                    // That's because we do not mean the actual root entry of the tree,
                    // just the entry that was given as an initial argument to this function

                    while (next_node) |node| {
                        // If the node is a file, we must write it to the manifest
                        if (node.kind == .file) {
                            try self.write(path_buffer.getSliceConst(), node);
                        }

                        // Determine what our next node should be. First we check if we have children
                        if (node.kind == .folder and node.kind.folder._child != null) {
                            // If the node has any children, we don't write it
                            // Instead, we go to the children first, and later
                            // we go to this entry's sibling or parent.
                            next_node = node.kind.folder._child;

                            // Ignore folders with no names (such as the root folder)
                            if (node.name.len > 0) {
                                // Append this folder name to the path buffer
                                try path_buffer.write(node.name);
                                try path_buffer.write("/");
                            }
                        } else if (node._sibling) |sibling| {
                            // If the sibling of this node is the sibling of the "root" entry, we skip it
                            if (stop_on_sibling != null and stop_on_sibling.? == sibling) {
                                next_node = null;
                            } else {
                                next_node = sibling;
                            }
                        } else if (node._parent) |parent| {
                            // If we have a parent, then we can assume our parent is a folder (files have no children)
                            assert(parent.kind == .folder);

                            // If we have a parent, but it is the parent of the "root" entry
                            if (stop_on_parent != null and stop_on_parent.? == parent) {
                                next_node = null;
                            } else {
                                // We don't need to go to our parent or it's children,
                                // since we have already traversed through them.
                                // We can instead go straight to the parent's sibling (can be null)
                                next_node = parent._sibling;
                            }

                            // Ignroe folders with no names
                            if (parent.name.len > 0) {
                                // We must release the path buffer associated with
                                // the segment of the parent's node name (the "+ 1"
                                // represents the forward slash)
                                path_buffer.release(parent.name.len + 1);
                            }
                        } else {
                            // If our current node has no children, siblings or parent,
                            // then we have no nodes left to go through
                            next_node = null;
                        }
                    }
                }

                /// Flush any buffered contents
                pub fn flush(self: *@This()) !void {
                    try self.io_writer.flush();
                }
            };
        }
    };
}

/// Return true if the character is a whitespace ASCII character.
fn isWhiteSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r';
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

    try std.testing.expect(Directory(i32, void).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/".len, start);
    try std.testing.expectEqual("/root".len, end);
    try std.testing.expectEqualStrings("root", path[start..end]);

    try std.testing.expect(Directory(i32, void).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/root/".len, start);
    try std.testing.expectEqual("/root/folder_a".len, end);
    try std.testing.expectEqualStrings("folder_a", path[start..end]);

    try std.testing.expect(Directory(i32, void).getNextPathSegment(path, &start, &end));
    try std.testing.expectEqual("/root/folder_a/".len, start);
    try std.testing.expectEqual("/root/folder_a/file1.txt".len, end);
    try std.testing.expectEqualStrings("file1.txt", path[start..end]);

    try std.testing.expect(!Directory(i32, void).getNextPathSegment(path, &start, &end));
}

test "Create a basic directory structure" {
    var directory = Directory(i32, void).init(std.testing.allocator);
    defer directory.deinit();

    // Try to write to different files on the same sub-folder
    _ = try directory.addFile("/root/folder_a/file1.txt", 5);
    _ = try directory.addFile("/root/folder_a/file2.txt", 10);
    // Create a new file on a different sub-folder
    _ = try directory.addFile("/root/folder_b/file2.txt", 15);
    // Overwrite this last file
    _ = try directory.addFile("/root/folder_b/file2.txt", 20);

    const Entry = Directory(i32, void).Entry;

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

test "Directory manifest reader" {
    // Initialize the input test data
    var buffer: [4096]u8 = undefined;
    // Do this trick because a string literal type is []const u8
    var input = try std.fmt.bufPrint(&buffer,
        \\ /root/folder_a/file1.txt;5
        \\ /root/folder_a/file2.txt;10
        \\ /root/folder_b/file2.txt;15
        \\   
        \\ /root/folder_b/file2.txt;20
        \\ 
        \\
        \\
    , .{});

    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();

    const Options = struct {
        pub fn dataFromString(string: []const u8) !i32 {
            return std.fmt.parseInt(i32, string, 10);
        }
    };

    // Initialize the ManifestReader
    const ManifestReader = Directory(i32, Options).ManifestReader(@TypeOf(reader));
    var manifest = ManifestReader.init(reader);
    defer manifest.deinit();

    const Entry = Directory(i32, Options).Entry;

    // Declare a varaible to hold our entry pointers
    var node: ?Entry = null;

    // Try to get /root/folder_a/file1.txt
    node = try manifest.next();
    try std.testing.expect(node != null);
    try expectEntryFile("/root/folder_a/file1.txt", @as(i32, 5), node.?);

    // Try to get /root/folder_a/file2.txt
    node = try manifest.next();
    try std.testing.expect(node != null);
    try expectEntryFile("/root/folder_a/file2.txt", @as(i32, 10), node.?);

    // Try to get /root/folder_b/file2.txt
    node = try manifest.next();
    try std.testing.expect(node != null);
    try expectEntryFile("/root/folder_b/file2.txt", @as(i32, 15), node.?);

    // Try to get /root/folder_b/file2.txt
    node = try manifest.next();
    try std.testing.expect(node != null);
    try expectEntryFile("/root/folder_b/file2.txt", @as(i32, 20), node.?);

    node = try manifest.next();
    try std.testing.expect(node == null);
}

test "Load manifest into a directory object" {
    // Initialize the input test data
    var buffer: [4096]u8 = undefined;
    // Do this trick because a string literal type is []const u8
    var input = try std.fmt.bufPrint(&buffer,
        \\ /root/folder_a/file1.txt;5
        \\ /root/folder_a/file2.txt;10
        \\ /root/folder_b/file2.txt;15
        \\   
        \\ /root/folder_b/file2.txt;20
        \\ 
        \\
        \\
    , .{});

    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();

    const Options = struct {
        pub fn dataFromString(string: []const u8) !i32 {
            return std.fmt.parseInt(i32, string, 10);
        }
    };

    // Initialize the ManifestReader
    const ManifestReader = Directory(i32, Options).ManifestReader(@TypeOf(reader));
    var manifest = ManifestReader.init(reader);
    defer manifest.deinit();

    // Configure the directory
    var directory = Directory(i32, Options).init(std.testing.allocator);
    defer directory.deinit();

    // Load the files from the manifest
    try directory.loadFromManifest(&manifest);
}

test "Load and write manifest into and from a directory object" {
    // Initialize the input test data
    var buffer: [4096]u8 = undefined;
    // Do this trick because a string literal type is []const u8
    var input = try std.fmt.bufPrint(&buffer,
        \\ /root/folder_a/file1.txt;5
        \\ /root/folder_a/file2.txt;10
        \\ /root/folder_b/file3.txt;15
        \\ /root/folder_b/file4.txt;20
        \\
    , .{});

    var stream_reader = std.io.fixedBufferStream(input);
    var reader = stream_reader.reader();

    var output: [4096]u8 = undefined;
    var stream_writer = std.io.fixedBufferStream(&output);
    var writer = stream_writer.writer();

    const Options = struct {
        pub fn dataFromString(string: []const u8) !i32 {
            return std.fmt.parseInt(i32, string, 10);
        }

        pub fn dataToWriter(io_writer: anytype, number: i32) !void {
            try io_writer.print("{}", .{number});
        }
    };

    // Initialize the ManifestReader
    const ManifestReader = Directory(i32, Options).ManifestReader(@TypeOf(reader));
    var manifest_reader = ManifestReader.init(reader);
    defer manifest_reader.deinit();

    // Initialize the ManifestWriter
    const ManifestWriter = Directory(i32, Options).ManifestWriter(@TypeOf(writer));
    var manifest_writer = ManifestWriter.init(writer);
    defer manifest_writer.deinit();

    // Configure the directory
    var directory = Directory(i32, Options).init(std.testing.allocator);
    defer directory.deinit();

    // Load the files from the manifest
    try directory.loadFromManifest(&manifest_reader);

    // Write the files into the manifest
    try directory.writeToManifest(&manifest_writer);

    // Compare the results
    try std.testing.expectEqualStrings(
        \\/root/folder_b/file4.txt;20
        \\/root/folder_b/file3.txt;15
        \\/root/folder_a/file2.txt;10
        \\/root/folder_a/file1.txt;5
        \\
    , stream_writer.getWritten());
}
