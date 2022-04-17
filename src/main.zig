const std = @import("std");
const FileHash = @import("./core/file_hash.zig").FileHashMd5;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    std.log.info("File hash test.", .{});

    var file = try FileHash.initEmpty(allocator, args[1]);
    defer file.deinit();

    std.log.info("Piece Count = {}, Total Nodes' Size = {} bytes.", .{ file.piece_count, file.hash_tree.shape.getTotalSizeOfNodes() });

    try TerminalHashProgress.run(&file);
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
