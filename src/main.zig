const std = @import("std");
const fst = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("warp_hart_tb.fst", .{ .mode = .read_only });
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();

    while (true) {
        const tag = reader.readInt(u8, .big) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const block_type: fst.BlockType = @enumFromInt(tag);
        std.debug.print("{}\n", .{block_type});
        switch (block_type) {
            .header => {
                const header = try fst.Header.read(reader);
                // std.debug.print("{}\n", .{header});
                std.debug.print("{s} {s}\n", .{ header.writer.slice(), header.date });
            },
            .vcdata_dynamic_alias2 => {
                _ = try fst.ValueChange.read(allocator, reader);
            },
            .geometry => {
                const geometry = try fst.Geometry.read(allocator, reader);
                std.debug.print("{x}\n", .{geometry.uncompressed_data});
                defer geometry.deinit(allocator);
            },
            else => {
                const block_length = try reader.readInt(u64, .big);
                std.debug.print("{} {}\n", .{ block_type, block_length });
                try reader.skipBytes(block_length - @sizeOf(u64), .{});
            },
        }
    }
}
