const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var doc = xml.StaticDocument.init(data);
    var reader = doc.reader(std.heap.c_allocator, .{});
    defer reader.deinit();
    while (try reader.read() != .eof) {}
}
