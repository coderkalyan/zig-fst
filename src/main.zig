const std = @import("std");
const fst = @import("root.zig");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("warp_hart_tb.fst", .{ .mode = .read_only });
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();

    while (true) {
        const tag = reader.readInt(u8, .big) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const block_length = try reader.readInt(u64, .big);
        std.debug.print("{}\n", .{tag});
        const block_type: fst.BlockType = @enumFromInt(tag);
        switch (block_type) {
            .header => {
                std.debug.print("{} {}\n", .{ block_type, block_length });
                // try reader.skipBytes(@sizeOf(u64), .{});
                const header = try fst.Header.read(reader);
                std.debug.print("{}\n", .{header});
                std.debug.print("{s} {s}\n", .{ header.writer.slice(), header.date });
            },
            .geometry => {
                const uncompressed_length = try reader.readInt(u64, .big);
                const count = try reader.readInt(u64, .big);
                std.debug.print("{} {} {} {}\n", .{ block_type, block_length, uncompressed_length, count });
                try reader.skipBytes(block_length - 8 - 9, .{});
            },
            else => {
                std.debug.print("{} {}\n", .{ block_type, block_length });
                try reader.skipBytes(block_length, .{});
            },
        }
    }
}
