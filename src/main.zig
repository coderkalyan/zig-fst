const std = @import("std");
const fst = @import("root.zig");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("warp_hart_tb.fst", .{ .mode = .read_only });
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();

    const header = try fst.Header.read(reader);
    std.debug.print("{}\n", .{header});
    std.debug.print("{s} {s}\n", .{ header.writer.slice(), header.date });
}
