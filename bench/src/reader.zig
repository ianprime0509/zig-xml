const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var reader: xml.Reader.Static = .init(std.heap.c_allocator, data, .{});
    defer reader.deinit();
    while (try reader.interface.read() != .eof) {}
}
