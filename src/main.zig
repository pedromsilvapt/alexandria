const std = @import("std");
const FileHash = @import("./core/file_hash.zig").FileHashSha512;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (std.ascii.eqlIgnoreCase(args[1], "serialize")) {
        try serializeFile(allocator, args[2], args[3]);
    } else if (std.ascii.eqlIgnoreCase(args[1], "reserialize")) {
        try reserializeFile(allocator, args[2], args[3]);
    } else {
        std.log.err("Invalid command given, expected 'serialize' or 'reserialize", .{});
    }
}

pub fn serializeFile(
    allocator: Allocator,
    hashes_folder_path: []const u8,
    source_file_name: []const u8,
) !void {
    std.log.info("File hash test.", .{});

    var file = try FileHash.initEmpty(allocator, source_file_name);
    defer file.deinit();

    std.log.info("Piece Count = {}, Total Nodes' Size = {} bytes.", .{ file.piece_count, file.hash_tree.shape.getTotalSizeOfNodes() });

    try TerminalHashProgress.run(&file);

    var file_name = file.getSerializedFileName();
    std.log.info("Serializing file to = {s}", .{file_name});

    // Serialize
    try file.serializeInFolderPath(hashes_folder_path, .{ .nodes = .leafs });

    // Deserialize
    var file2 = try FileHash.deserializeFromFolderPath(allocator, hashes_folder_path, &file_name);
    defer file2.deinit();

    var root_node = file2.hash_tree.nodes[0];
    std.log.info("Deserialized node is = {}", .{std.fmt.fmtSliceHexLower(&root_node)});

    // Compare all the hashes and assert that they match
    assert(std.mem.eql(
        u8,
        std.mem.sliceAsBytes(file.hash_tree.nodes),
        std.mem.sliceAsBytes(file2.hash_tree.nodes),
    ));

    std.log.info("All hashes match!", .{});
}

pub fn reserializeFile(
    allocator: Allocator,
    hashes_folder_path: []const u8,
    source_file_name: []const u8,
) !void {
    std.log.info("Serialize and Deserialize test.", .{});

    // Deserialize
    var file = try FileHash.deserializeFromFolderPath(allocator, hashes_folder_path, source_file_name);
    defer file.deinit();

    var file_name = file.getSerializedFileName();
    std.log.info("Serializing file to = {s}", .{file_name});

    std.log.info("Serializing file to = {s}", .{file_name});

    // Serialize
    try file.serializeInFolderPath(hashes_folder_path, .{ .nodes = .leafs });

    // Deserialize
    var file2 = try FileHash.deserializeFromFolderPath(allocator, hashes_folder_path, &file_name);
    defer file2.deinit();

    var root_node = file2.hash_tree.nodes[0];
    std.log.info("Deserialized node is = {}", .{std.fmt.fmtSliceHexLower(&root_node)});

    // Compare all the hashes and assert that they match
    assert(std.mem.eql(
        u8,
        std.mem.sliceAsBytes(file.hash_tree.nodes),
        std.mem.sliceAsBytes(file2.hash_tree.nodes),
    ));

    std.log.info("All hashes match!", .{});
}

pub const TerminalHashProgress = struct {
    bar: std.Progress = .{},
    timer: std.time.Timer,
    file: ?*FileHash = null,
    speed_buffer: [160]u8 = [_]u8{0} ** 160,

    pub fn init() TerminalHashProgress {
        return TerminalHashProgress{ .timer = std.time.Timer.start() catch unreachable };
    }

    pub fn getRootNode(self: *TerminalHashProgress) *std.Progress.Node {
        return &self.bar.root;
    }

    pub fn start(self: *TerminalHashProgress, file: *FileHash) void {
        file.on_hash_progress.connect(self, update);

        _ = self.bar.start("Hash: ", file.hash_tree.shape.leafs) catch unreachable;

        self.timer.reset();

        self.file = file;
    }

    pub fn end(self: *TerminalHashProgress, file: *FileHash) void {
        file.on_hash_progress.disconnect();

        self.getRootNode().end();

        self.file = null;

        var elapsed = self.timer.read();

        const size_mb = @intToFloat(f64, file.size) / 1024 / 1024;
        const elapsed_ms = @intToFloat(f64, elapsed) / 1000000;
        const elapsed_s = elapsed_ms / 1000;

        std.log.info("Elapsed in {d:.3}ms, speed of {d:.2}MB/s.", .{ elapsed_ms, size_mb / elapsed_s });
    }

    fn update(self: *TerminalHashProgress, pieces: usize) void {
        self.getRootNode().setCompletedItems(pieces);

        if (self.file) |file| {
            var elapsed = self.timer.read();

            const size_mb = @intToFloat(f64, file.piece_size * (pieces + 1)) / 1024 / 1024;
            const elapsed_ms = @intToFloat(f64, elapsed) / 1000000;
            const elapsed_s = elapsed_ms / 1000;

            const speed = std.fmt.bufPrint(&self.speed_buffer, "Hash: {d:.3}ms, {d:.2}MB/s.", .{ elapsed_ms, size_mb / elapsed_s }) catch unreachable;

            self.getRootNode().name = speed;
        }

        self.bar.maybeRefresh();
    }

    pub fn run(file: *FileHash) !void {
        var progress = TerminalHashProgress.init();
        progress.start(file);
        try file.rehash();
        progress.end(file);
    }
};
