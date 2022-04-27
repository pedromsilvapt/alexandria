const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
const Signal = @import("./signal.zig").Signal;
const GenericMerkle = @import("./merkle.zig").Merkle;
const fromHash = @import("./merkle.zig").fromHash;
const FileHashSerializer = @import("./serializer.zig").FileHashSerializer;
const ComputePool = @import("./parallel/compute_pool.zig").ComputePool;

pub fn FileHash(comptime algorithm: HashingAlgorithm, comptime Hasher: type) type {
    return struct {
        pub const Merkle = GenericMerkle([Hasher.digest_length]u8, fromHash(Hasher));

        pub const algorithm = algorithm;

        file_path: []const u8,
        size: u64,
        piece_size: u64,
        piece_count: usize,
        hash_tree: Merkle,
        on_hash_progress: Signal(usize) = .{},

        pub fn init(allocator: Allocator, file_path: []const u8) !@This() {
            var file_hash = try @This().initEmpty(allocator, file_path);

            // Free up memory if anything goes wrong and we cannot create the hash tree
            errdefer file_hash.deinit();

            try file_hash.rehash();

            return file_hash;
        }

        pub fn initEmpty(allocator: Allocator, file_path: []const u8) !@This() {
            // Open the file
            var file: std.fs.File = try std.fs.cwd().openFile(file_path, .{ .read = true });
            defer file.close();

            // Get the stat information for this path
            var stat = try file.stat();

            // TODO Handle other types (like symlinks)
            if (stat.kind != .File) {
                return error.NotAFile;
            }

            return try @This().initSized(allocator, file_path, stat.size);
        }

        pub fn initSized(allocator: Allocator, file_path: []const u8, size: u64) !@This() {
            // Calculate the pieces' size and count
            var piece_size = calculatePieceSize(size);
            var piece_count = calculatePieceCount(size, piece_size);

            var hash_tree = try Merkle.initEmpty(allocator, piece_count);

            return @This(){
                .file_path = file_path,
                .size = size,
                .piece_size = piece_size,
                .piece_count = piece_count,
                .hash_tree = hash_tree,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.hash_tree.deinit();
        }

        pub fn rehash(self: *@This()) !void {
            // Open the file
            var file: std.fs.File = try std.fs.cwd().openFile(self.file_path, .{ .read = true });
            defer file.close();

            // Get the stat information for this path
            var stat = try file.stat();

            // TODO Handle other types (like symlinks)
            if (stat.kind != .File) {
                return error.NotAFile;
            }

            // Grab it's size
            var size = stat.size;

            // Grab it's size
            var piece_size = calculatePieceSize(size);
            var piece_count = calculatePieceCount(size, piece_size);

            if (piece_count != self.piece_count) {
                var hash_tree = try Merkle.initEmpty(self.hash_tree.allocator, piece_count);

                // If the new tree is successfuly initialized, free the older one and replace it
                self.hash_tree.deinit();
                self.hash_tree = hash_tree;
            }

            // Update information
            self.size = size;
            self.piece_count = piece_count;
            self.piece_size = piece_size;

            try self.rehashFd(file);
        }

        pub fn rehashFd(self: *@This(), file: std.fs.File) !void {
            try self.rehashFdTree(file, &self.hash_tree);
        }

        pub fn rehashFdTree(self: *@This(), file: std.fs.File, hash_tree: *Merkle) !void {
            var file_buffer: [4096]u8 = undefined;
            var hash_buffer: Merkle.NodeType = undefined;

            var buf_stream = io.bufferedReader(file.reader());
            const reader = buf_stream.reader();

            var leafs = hash_tree.getLeafsSlice();
            var leaf_index: usize = 0;

            var bytes_read: usize = 0;
            var total_read: u64 = 0;
            var piece_left: usize = 0;

            while (leaf_index < leafs.len) : (leaf_index += 1) {
                var hasher = Hasher.init(.{});

                piece_left = self.piece_size;

                while (piece_left > 0) {
                    if (piece_left > file_buffer.len) {
                        bytes_read = try reader.read(&file_buffer);
                    } else {
                        bytes_read = try reader.read(file_buffer[0..piece_left]);
                    }

                    if (bytes_read == 0) {
                        break;
                    }

                    piece_left -= bytes_read;
                    total_read += bytes_read;

                    hasher.update(file_buffer[0..bytes_read]);
                }

                self.on_hash_progress.trigger(leaf_index);

                hasher.final(&hash_buffer);

                std.mem.copy(u8, &leafs[leaf_index], &hash_buffer);
            }

            if (total_read != self.size) {
                return error.IncompletePieces;
            }

            // Now that the leafs all have their hashes set, rehash the
            // rest of the nodes
            hash_tree.rehash();

            self.on_hash_progress.trigger(self.hash_tree.shape.nodes);
        }

        pub fn deinit(self: *@This()) void {
            self.hash_tree.deinit();
        }

        /// Calculates the piece size for a file based on the total file size.
        /// Files up to 50MiB: 32KiB piece size
        /// Files 50MiB to 150MiB: 64KiB piece size
        /// Files 150MiB to 350MiB: 128KiB piece size
        /// Files 350MiB to 512MiB: 256KiB piece size
        /// Files 512MiB to 1.0GiB: 512KiB piece size
        /// Files 1.0GiB to 2.0GiB: 1024KiB piece size
        /// Files 2.0GiB and up: 2048KiB piece size
        /// Piece sizes above 2048KiB are not recommended.
        ///
        /// Values taken from http://wiki.depthstrike.com/index.php/Recommendations#Torrent_Piece_Sizes_when_making_torrents
        pub fn calculatePieceSize(file_size: u64) u64 {
            const KB: u64 = comptime 1024;
            const MB: u64 = comptime 1024 * KB;
            const GB: u64 = comptime 1024 * MB;

            if (file_size < 50 * MB) {
                return 32 * KB;
            } else if (file_size < 150 * MB) {
                return 64 * KB;
            } else if (file_size < 350 * MB) {
                return 128 * KB;
            } else if (file_size < 512 * MB) {
                return 256 * KB;
            } else if (file_size < 1 * GB) {
                return 512 * KB;
            } else if (file_size < 2 * GB) {
                return 1 * MB;
            } else {
                return 2 * MB;
            }
        }

        /// Calculates the number of pieces needed to store the hashing of a file.
        /// Equivelent to `ceil(file_size / piece_size)`.
        pub fn calculatePieceCount(file_size: u64, piece_size: u64) usize {
            var rem = file_size % piece_size;
            var div = file_size / piece_size;

            if (rem > 0) {
                return div + 1;
            }

            return div;
        }

        pub usingnamespace FileHashSerializer(@This());
    };
}

/// These values are used for serialization purposes. Do not change them!
pub const HashingAlgorithm = enum(u4) {
    md5 = 1,
    sha256 = 2,
    sha512 = 3,
};

pub const FileHashMd5 = FileHash(HashingAlgorithm.md5, std.crypto.hash.Md5);

pub const FileHashSha256 = FileHash(HashingAlgorithm.sha256, std.crypto.hash.sha2.Sha256);

pub const FileHashSha512 = FileHash(HashingAlgorithm.sha512, std.crypto.hash.sha2.Sha512);
