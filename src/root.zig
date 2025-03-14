const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("zlib.h");
});

const Allocator = std.mem.Allocator;

pub const BlockType = enum(u8) {
    // FST_BL_HDR
    header = 0,
    // FST_BL_VCDATA
    vcdata = 1,
    // FST_BL_BLACKOUT
    blackout = 2,
    // FST_BL_GEOM
    geometry = 3,
    // FST_BL_HIER
    hierarchy = 4,
    // FST_BL_VCDATA_DYN_ALIAS
    vcdata_dynamic_alias = 5,
    // FST_BL_HIER_LZ4
    hierarchy_lz4 = 6,
    // FST_BL_HIER_LZ4DUO
    hierarchy_lz4duo = 7,
    // FST_BL_VCDATA_DYN_ALIAS2
    vcdata_dynamic_alias2 = 8,
    // FST_BL_ZWRAPPER
    zwrapper = 254,
    // FST_BL_SKIP
    skip = 255,
};

pub const WriterPackType = enum(u8) {
    // FST_WR_PT_ZLIB
    zlib = 'Z',
    // FST_WR_PT_FASTLZ
    fastlz = 'F',
    // FST_WR_PT_LZ4
    lz4 = '4',
};

pub const FileType = enum(u8) {
    // FST_FT_VERILOG
    verilog = 0,
    // FST_FT_VHDL
    vhdl = 1,
    // FST_FT_VERILOG_VHDL
    verilog_vhdl = 2,
};

pub const Block = struct {
    kind: BlockType,
    data: []const u8,
};

pub const Header = struct {
    /// Start time of the file. Units are given by timescale.
    start_time: u64,
    /// End time of the file. Units are given by timescale.
    end_time: u64,
    /// Timezero ($timezero in a VCD file). This is needed when
    /// the actual simulation start time is negative. It gives
    /// the real time of the "0" time. In other words it shifts
    /// all of the times that should be displayed.
    timezero: i64,
    /// Memory used when writing this file in bytes.
    writer_memory_use: u64,
    /// Number of Value Change blocks in the file.
    num_vc_blocks: u64,
    /// Number of scopes in the hierarchy.
    num_scopes: u64,
    /// Number of variables in the hierarchy.
    num_hierarchy_vars: u64,
    // Number of distinct variables in the file.
    num_vars: u64,
    /// String identifier of the simulator that wrote the file.
    /// Underlying memory is owned by the string buffer.
    /// This identifier is at most 128 bytes.
    writer: std.BoundedArray(u8, 128),
    /// Date string as returned by asctime().
    /// This identifier is exactly 26 bytes.
    date: [26]u8,
    /// Order of magnitude of the time unit.
    /// 0 = 1s, 1 = 0.1s, 9 = 1ns, etc.
    timescale: i8,
    /// File type.
    filetype: FileType,
    /// Endianness used for reals, usually equivalent to the native
    /// endianness of the writer.
    real_endian: std.builtin.Endian,

    pub fn read(reader: anytype) !Header {
        // all ints are parsed as big endian (not sure why, most systems are little endian)
        // reals can be set as either based on what the writer prefers. the detection process
        // is strange, see below.
        var buffer: [128]u8 = undefined;

        const block_length = try reader.readInt(u64, .big);
        std.debug.assert(block_length == 329);
        const start_time = try reader.readInt(u64, .big);
        const end_time = try reader.readInt(u64, .big);

        var real_magic: f64 = undefined;
        var bytes_read = try reader.read(std.mem.asBytes(&real_magic));
        std.debug.assert(bytes_read == @sizeOf(@TypeOf(real_magic)));
        // FIXME: calculate the actual endianness

        const writer_memory_use = try reader.readInt(u64, .big);
        const num_scopes = try reader.readInt(u64, .big);
        const num_hierarchy_vars = try reader.readInt(u64, .big);
        const num_vars = try reader.readInt(u64, .big);
        const num_vc_blocks = try reader.readInt(u64, .big);
        const timescale = try reader.readInt(i8, .big);

        // the writer (simulator identifier) is a null terminated string occupying 128 bytes
        // use temporary array + bounded array to avoid allocating
        bytes_read = try reader.read(&buffer);
        std.debug.assert(bytes_read == buffer.len);
        var writer: std.BoundedArray(u8, buffer.len) = .{};
        const ptr: [*:0]const u8 = @ptrCast(&buffer);
        writer.appendSliceAssumeCapacity(std.mem.span(ptr));

        bytes_read = try reader.read(buffer[0..26]);
        std.debug.assert(bytes_read == 26);

        // header reserved bytes
        try reader.skipBytes(93, .{});
        const filetype: FileType = @enumFromInt(try reader.readInt(u8, .big));
        const timezero = try reader.readInt(i64, .big);

        return .{
            .start_time = start_time,
            .end_time = end_time,
            .timezero = timezero,
            .writer_memory_use = writer_memory_use,
            .num_vc_blocks = num_vc_blocks,
            .num_scopes = num_scopes,
            .num_hierarchy_vars = num_hierarchy_vars,
            .num_vars = num_vars,
            .writer = writer,
            .date = buffer[0..26].*,
            .timescale = timescale,
            .filetype = filetype,
            .real_endian = .little, // FIXME: implement this
        };
    }
};

pub const Hierarchy = struct {
    /// Uncompressed hierarchy data, consisting of tags and names.
    uncompressed_data: []const u8,
};

pub const Geometry = struct {
    /// Uncompressed geometry data, consisting of lengths represented
    /// as variable length integers.
    count: u64,
    uncompressed_data: []const u8,

    pub fn read(allocator: Allocator, reader: anytype) !Geometry {
        const block_length = try reader.readInt(u64, .big);
        const uncompressed_length = try reader.readInt(u64, .big);
        const count = try reader.readInt(u64, .big);

        const compressed_length = block_length - 24;
        const compressed_data = try allocator.alloc(u8, compressed_length);
        defer allocator.free(compressed_data);

        const bytes_read = try reader.read(compressed_data);
        std.debug.assert(bytes_read == compressed_length);
        const uncompressed_data = try allocator.alloc(u8, uncompressed_length);
        if (uncompressed_length != compressed_length) {
            var dest_len: u64 = uncompressed_data.len;
            const ret = c.uncompress(uncompressed_data.ptr, &dest_len, compressed_data.ptr, compressed_data.len);
            if (ret != c.Z_OK) return error.ZlibDecompressionFailed;
            std.debug.assert(dest_len == uncompressed_data.len);
        } else {
            // if data is uncompressed, just copy into return buffer
            @memcpy(uncompressed_data, compressed_data);
        }

        return .{
            .count = count,
            .uncompressed_data = uncompressed_data,
        };
    }

    pub fn deinit(self: *const Geometry, allocator: Allocator) void {
        allocator.free(self.uncompressed_data);
    }
};

pub const ValueChange = struct {
    /// Start time of the block. The units are given by header_timescale.
    start_time: u64,
    /// End time of the block. The units are given by header_timescale.
    end_time: u64,
    /// Amount of buffer memory required when reading this block for a full Value Change traversal.
    memory_required: u64,
    /// Uncompressed length of the bits array.
    bits_length: u64,

    pub fn read(allocator: Allocator, reader: anytype) !Header {
        const block_length = try reader.readInt(u64, .big);
        const start_time = try reader.readInt(u64, .big);
        const end_time = try reader.readInt(u64, .big);
        const memory_required = try reader.readInt(u64, .big);
        std.debug.print("{} {} {} {}\n", .{ block_length, start_time, end_time, memory_required });

        const bits_uncompressed_length = try readVarInt(reader);
        const bits_compressed_length = try readVarInt(reader);
        const bits_count = try readVarInt(reader);
        _ = bits_count;
        std.debug.print("{}\n", .{bits_uncompressed_length});

        const compressed_bits = try allocator.alloc(u8, bits_compressed_length);
        defer allocator.free(compressed_bits);
        const bytes_read = try reader.read(compressed_bits);
        std.debug.assert(bytes_read == compressed_bits.len);

        const waves_count = try readVarInt(reader);
        _ = waves_count;
        const waves_packtype: WriterPackType = @enumFromInt(try reader.readByte());
        std.debug.print("{}\n", .{waves_packtype});
        const waves_length = try readVarInt(reader);
        std.debug.print("{}\n", .{waves_length});

        return undefined;
    }
};

// pub const Blackout = struct {
//     num_blackouts:
// };

fn readVarInt(reader: anytype) !u64 {
    var value: u64 = 0;
    for (0..8) |i| {
        const byte = try reader.readByte();
        value |= (byte & 0x7f) << @truncate(i * 7);
        if (byte & 0x80 == 0) return value;
    }

    // should this return an error in case of corrupt data?
    unreachable;
}

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
