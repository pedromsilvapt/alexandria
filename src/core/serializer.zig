const std = @import("std");
const assert = std.debug.assert;
const mzg_pack = @import("mzg_pack");

const Allocator = std.mem.Allocator;

pub const NodesSerialization = enum(u1) {
    all = 0,
    leafs = 1,
};

pub const SerializeOptions = struct {
    nodes: NodesSerialization = .all,
};

pub fn FileHashSerializer(comptime FileHash: type) type {
    return struct {
        /// Serialize a file hash according to the options given
        pub fn serialize(self: FileHash, serializer: anytype, options: SerializeOptions) !void {
            // Serialize the version of the schema being used
            try serializer.serialize(@as(u4, 1));
            // Serialize the type of hashing used (even if for now only one hashing can be used)
            try serializer.serialize(FileHash.algorithm);

            // Serialize the fields of the file hash
            try serializer.serialize(self.file_path);
            try serializer.serialize(self.size);
            try serializer.serialize(self.piece_size);
            try serializer.serialize(self.piece_count);

            // At the end, serialize the fields of the hash tree
            try self.hash_tree.serialize(serializer, options);
        }

        pub fn deserialize(deserializer: anytype) !FileHash {
            var version = try deserializer.deserialize(u4);

            if (version != 1) return error.InvalidVersion;

            // Serialize the type of hashing used (even if for now only one hashing can be used)
            var hashing_algorithm = try deserializer.deserialize(@TypeOf(FileHash.algorithm));

            if (hashing_algorithm != FileHash.algorithm) return error.InvalidHashingAlgorithm;

            // Serialize the fields of the file hash
            var file_path = try deserializer.deserializeString();
            var size = try deserializer.deserialize(usize);
            var piece_size = try deserializer.deserialize(usize);
            var piece_count = try deserializer.deserialize(usize);

            // At the end, serialize the fields of the hash tree
            var hash_tree = try FileHash.Merkle.deserialize(deserializer);

            return FileHash{
                .file_path = file_path,
                .size = size,
                .piece_size = piece_size,
                .piece_count = piece_count,
                .hash_tree = hash_tree,
            };
        }

        // Compile-time constant for our file name buffer size
        pub const hash_file_name_len = bitHexSizeOf(FileHash.Merkle.NodeType);
        pub const hash_file_extension_len = ".hash".len;
        pub const HashFileNameArray = [hash_file_name_len + hash_file_extension_len]u8;

        /// Return a stack-allocated buffer of type [x]u8 containing the ASCII hexadecimal value containing the canonical
        /// file name for this file hash structure. The file name is the hexadecimal root hash with the .hash file extension.
        pub fn getSerializedFileName(self: FileHash) HashFileNameArray {
            var file_name: HashFileNameArray = [_]u8{0} ** (hash_file_name_len + hash_file_extension_len);

            // Root node is at position 0
            var root_node = &std.mem.toBytes(self.hash_tree.nodes[0]);

            assert(hash_file_name_len >= root_node.len);

            const printed = std.fmt.bufPrint(&file_name, "{}.hash", .{
                std.fmt.fmtSliceHexLower(root_node),
            }) catch unreachable;

            assert(printed.len == file_name.len);

            return file_name;
        }

        /// Serialize this hash file in the given folder. If a file already exists there with the same name, it is truncated and overwritten!
        /// The file name is <root_hash>.hash, where the root hash is the hash stored at the root of the merkle tree.
        /// Accepts an options parameter to finetune the serialization process. Right now only supports configuring if all nodes are serialized,
        /// or only the leafs. Storing only the leafs cuts the file size in half, while very slightly increasing the deserialization time.
        pub fn serializeInFolderPath(self: FileHash, folder_path: []const u8, options: SerializeOptions) !void {
            var directory: std.fs.Dir = try std.fs.cwd().openDir(folder_path, .{});
            defer directory.close();

            var file_name = self.getSerializedFileName();

            // Open the file
            var file: std.fs.File = try directory.createFile(&file_name, .{ .truncate = true });
            defer file.close();

            var writer = file.writer();

            var serializer = mzg_pack.serializer(writer);

            try self.serialize(&serializer, options);
        }

        /// Deserialize a file from the given folder, with the given file path.
        /// Automatically detects if the serialized file is storing only the leafs, in which case automatically
        /// calculates all the hashes for the rest of the nodes.
        pub fn deserializeFromFolderPath(allocator: Allocator, folder_path: []const u8, file_name: []const u8) !FileHash {
            var directory: std.fs.Dir = try std.fs.cwd().openDir(folder_path, .{});
            defer directory.close();

            // Open the file
            var file: std.fs.File = try directory.openFile(file_name, .{ .read = true });
            defer file.close();

            // Create a reader for the serialized hash file
            var reader = file.reader();

            // Initialize the deserializer
            var deserializer = mzg_pack.deserializer(reader, allocator);

            return FileHash.deserialize(&deserializer);
        }
    };
}

/// Calculate the minimum len of an hexadecimal ASCII string, such that it can
/// represent a buffer with `size` bits (not bytes!)
pub fn bitHexSize(size: anytype) @TypeOf(size) {
    return std.math.divCeil(usize, size, 4) catch unreachable;
}

/// Calculate the minimum len of an hexadecimal ASCII string, such that it can
/// represent a buffer with `@bitSizeOf(T)` bits (not bytes!)
pub fn bitHexSizeOf(comptime T: type) usize {
    return bitHexSize(@bitSizeOf(T));
}

/// Returns true if the given type is a fixed-size byte array of some kind (such as [4]u8)
pub fn isByteArray(comptime T: type) bool {
    const info = @typeInfo(T);

    return info == .Array and info.Array.child == u8;
}

/// Mixin implementing serialization methods for a Merkle Tree.
pub fn MerkleSerializer(comptime Merkle: type) type {
    return struct {
        pub fn serialize(self: Merkle, serializer: anytype, options: SerializeOptions) !void {
            // Serialize the options used for this tree first
            try serializer.serialize(options.nodes);

            try serializer.serialize(self.shape.leafs);

            // Get the list of nodes to serialize. We can serialize the full nodes
            // or only the leafs, in which case we need ti rehash the rest of the nodes
            // when deserializing
            const nodes = switch (options.nodes) {
                .all => self.nodes,
                .leafs => self.getLeafsSliceConst(),
            };

            // If the Merkle.NodeType is [_]u8, we can save it in a more compact way
            if (isByteArray(Merkle.NodeType)) {
                try serializer.serializeBin(std.mem.sliceAsBytes(nodes));
            } else {
                try serializer.serialize(nodes);
            }
        }

        pub fn deserialize(deserializer: anytype) !Merkle {
            // Recreate the options structure that was used to serialize this hash file
            var options = .{
                .nodes = try deserializer.deserialize(NodesSerialization),
            };

            var leafs = try deserializer.deserialize(usize);

            if (leafs == 0) return error.InvalidLeafCount;

            // Calculate the shape of the Merkle Tree (number of nodes, leafs, etc...)
            var shape = Merkle.Shape.init(leafs);

            var nodes = try deserializer.allocator.alloc(Merkle.NodeType, shape.nodes);
            errdefer deserializer.allocator.free(nodes);

            const nodes_buffer = switch (options.nodes) {
                .all => nodes,
                .leafs => shape.getLeafsSlice(nodes),
            };

            // If the Merkle.NodeType is [_]u8, we can save it in a more compact way
            var deserialized_nodes = if (isByteArray(Merkle.NodeType))
                std.mem.bytesAsSlice(Merkle.NodeType, try deserializer.deserializeBinIntoBuffer(std.mem.sliceAsBytes(nodes_buffer)))
            else
                try deserializer.deserializeArrayIntoBuffer([]Merkle.NodeType, nodes_buffer);

            if (deserialized_nodes.len != nodes_buffer.len) return error.InvalidNodeCount;

            var merkle = Merkle{
                .allocator = deserializer.allocator,
                .shape = shape,
                .nodes = nodes,
            };

            if (options.nodes == .leafs) {
                merkle.rehash();
            }

            return merkle;
        }
    };
}
