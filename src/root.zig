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
    count: u64,
    /// Uncompressed geometry data, consisting of lengths represented
    /// as variable length integers.
    data: []const u8,

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
        errdefer allocator.free(uncompressed_data);
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
            .data = uncompressed_data,
        };
    }

    pub fn deinit(self: *const Geometry, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const ValueChange = struct {
    /// Start time of the block. The units are given by header_timescale.
    start_time: u64,
    /// End time of the block. The units are given by header_timescale.
    end_time: u64,
    /// Amount of buffer memory required when reading this block for a full Value Change traversal.
    memory_required: u64,
    /// Number of entries in the bits table.
    bits_count: u64,
    /// Uncompressed bits array.
    bits: []const u8,
    /// Number of waveforms in the waves table.
    waves_count: u64,
    /// Uncompressed set of deduplicated waveforms for this time period.
    waves: []const u8,
    /// Uncompressed position data.
    positions: []const u8,
    /// Number of items in the time table.
    times_count: u64,
    /// Uncompressed time table.
    times: []const u8,

    pub fn read(allocator: Allocator, reader: anytype) !ValueChange {
        const block_length = try reader.readInt(u64, .big);
        const start_time = try reader.readInt(u64, .big);
        const end_time = try reader.readInt(u64, .big);
        const memory_required = try reader.readInt(u64, .big);

        const preamble = 8 * 4;
        const remaining = block_length - preamble;
        const buffer = try allocator.alloc(u8, remaining);
        defer allocator.free(buffer);

        // because of various variable length arrays in the block
        // (no idea why it was designed this way), the best solution
        // is to read the whole array and then start reading it backwards
        const bytes_read = try reader.read(buffer);
        std.debug.assert(bytes_read == buffer.len);

        // fixed buffer stream exposes a reader interface for the buffer
        // which simplifies processing. it also allows seeking, which is
        // used to consume the buffer effectively backwards as needed
        var stream = std.io.fixedBufferStream(buffer);
        const stream_reader = stream.reader();

        // the first chunk of the variable length buffer can be read forwards,
        // to grab the bits array and associated metadata
        stream.seekTo(0) catch unreachable; // nop, just for clarity
        // original code calls this the frame array
        const bits_uncompressed_length = try readVarint64(stream_reader);
        const bits_compressed_length = try readVarint64(stream_reader);
        const bits_count = try readVarint64(stream_reader);

        var forward_pos = stream.getPos() catch unreachable;
        const bits_compressed = buffer[forward_pos .. forward_pos + bits_compressed_length];
        stream.seekBy(@intCast(bits_compressed_length)) catch unreachable;

        const waves_count = readVarint64(stream_reader) catch unreachable;
        const waves_packtype: WriterPackType = @enumFromInt(stream_reader.readInt(u8, .big) catch unreachable);

        // this is used to calculate the size of the waves data array
        // based on whats remaining after reading from the start and end
        forward_pos = stream.getPos() catch unreachable;

        // seek to end and read the compressed time data, with
        // length information stored after the data (again, why)
        stream.seekTo(buffer.len - 24) catch unreachable;
        const times_count = stream_reader.readInt(u64, .big) catch unreachable;
        const times_compressed_length = stream_reader.readInt(u64, .big) catch unreachable;
        const times_uncompressed_length = stream_reader.readInt(u64, .big) catch unreachable;

        // now that we know the compressed length, grab the actual data
        const time_end = buffer.len - 24;
        const times_compressed = buffer[time_end - times_compressed_length .. time_end];
        std.debug.assert(times_compressed.len == times_compressed_length);

        // stream should be back at end
        std.debug.assert((stream.getPos() catch unreachable) == buffer.len);
        stream.seekBy(-24 - @as(i64, @intCast(times_compressed_length)) - 8) catch unreachable;
        const position_length = stream_reader.readInt(u64, .big) catch unreachable;

        const position_end = buffer.len - 24 - times_compressed_length - 8;
        const positions_data = buffer[position_end - position_length .. position_end];
        std.debug.assert(positions_data.len == position_length);

        stream.seekBy(-8 - @as(i64, @intCast(position_length))) catch unreachable;
        const waves_compressed = buffer[forward_pos .. forward_pos + (stream.getPos() catch unreachable)];

        // decompress bits data
        const bits_uncompressed = try allocator.alloc(u8, bits_uncompressed_length);
        errdefer allocator.free(bits_uncompressed);
        if (bits_uncompressed_length != bits_compressed_length) {
            // bits is compressed with zlib, so uncompress
            var dest_len: u64 = bits_uncompressed.len;
            const ret = c.uncompress(bits_uncompressed.ptr, &dest_len, bits_compressed.ptr, bits_compressed.len);
            if (ret != c.Z_OK) return error.ZlibDecompressionFailed;
            std.debug.assert(dest_len == bits_uncompressed.len);
        } else {
            // bits data is uncompressed, just copy into return buffer
            @memcpy(bits_uncompressed, bits_compressed);
        }

        // decompress waves data
        std.debug.assert(waves_packtype == .zlib);
        _ = waves_compressed;
        // {
        //     var dest_len: u64 = waves_compressed; // FIXME: whats the size here?
        //     const ret = c.uncompress(bits_uncompressed.ptr, &dest_len, bits_compressed.ptr, bits_compressed.len);
        //     if (ret != c.Z_OK) return error.ZlibDecompressionFailed;
        //     std.debug.assert(dest_len == bits_compressed.len);
        // }

        // position data is uncompressed, just copy into return buffer
        const positions_data_copy = try allocator.alloc(u8, positions_data.len);
        errdefer allocator.free(positions_data_copy);
        @memcpy(positions_data_copy, positions_data);

        // decompress time data
        const times_uncompressed = try allocator.alloc(u8, times_uncompressed_length);
        errdefer allocator.free(times_uncompressed);
        if (times_uncompressed_length != times_compressed_length) {
            var dest_len: u64 = times_uncompressed.len;
            const ret = c.uncompress(times_uncompressed.ptr, &dest_len, times_compressed.ptr, times_compressed.len);
            if (ret != c.Z_OK) return error.ZlibDecompressionFailed;
            std.debug.assert(dest_len == times_uncompressed.len);
        } else {
            // time data is uncompressed, just copy into return buffer
            @memcpy(times_uncompressed, times_compressed);
        }

        return .{
            .start_time = start_time,
            .end_time = end_time,
            .memory_required = memory_required,
            .bits_count = bits_count,
            .bits = bits_uncompressed,
            .waves_count = waves_count,
            .waves = undefined,
            .positions = positions_data_copy,
            .times_count = times_count,
            .times = times_uncompressed,
        };
    }

    pub fn deinit(self: *const ValueChange, allocator: Allocator) void {
        allocator.free(self.bits);
        allocator.free(self.positions);
        allocator.free(self.times);
    }
};

// pub const Blackout = struct {
//     num_blackouts:
// };

fn readVarint64(reader: anytype) !u64 {
    var value: u64 = 0;
    for (0..8) |i| {
        const byte: u64 = try reader.readByte();
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
