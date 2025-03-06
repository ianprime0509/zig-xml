const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var fbs = std.io.fixedBufferStream(data);
    var doc = xml.streamingDocument(std.heap.c_allocator, fbs.reader());
    defer doc.deinit();
    var reader = doc.reader(std.heap.c_allocator, .{});
    defer reader.deinit();
    while (try reader.read() != .eof) {}
}
