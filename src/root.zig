const std = @import("std");
const testing = std.testing;

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
    writer: []const u8,
    /// Date string as returned by asctime().
    /// This identifier is exactly 26 bytes.
    date: *const [26]u8,
    /// Order of magnitude of the time unit.
    /// 0 = 1s, 1 = 0.1s, 9 = 1ns, etc.
    timescale: i8,
    /// File type.
    filetype: FileType,
    /// Endianness used for reals, usually equivalent to the native
    /// endianness of the writer.
    real_endian: std.builtin.Endian,

    pub fn read(reader: anytype) !Header {
        const start_time = try reader.readInt(u64, .big);
        const end_time = try reader.readInt(u64, .big);

        // magic is
        var real_magic: f64 = undefined;
        try reader.readAll(std.mem.asBytes(&real_magic));
        // FIXME: calculate the actual endianness

        const writer_memory_use = try reader.readInt(u64, .big);
        const num_scopes = try reader.readInt(u64, .big);
        const num_hierarchy_vars = try reader.readInt(u64, .big);
        const num_vars = try reader.readInt(u64, .big);
        const num_vc_blocks = try reader.readInt(u64, .big);
        const timescale = try reader.readInt(i8, .little);
        // try reader.skipBytes()
    }
};

pub const Hierarchy = struct {
    /// Uncompressed hierarchy data, consisting of tags and names.
    uncompressed_data: []const u8,
};

pub const Geometry = struct {
    /// Uncompressed geometry data, consisting of lengths represented
    /// as variable length integers.
    uncompressed_data: []const u8,
};

// pub const Blackout = struct {
//     num_blackouts:
// };

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
