const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var in: std.Io.Reader = .fixed(data);
    var reader: xml.Reader.Streaming = .init(std.heap.c_allocator, &in, .{});
    defer reader.deinit();
    while (try reader.interface.read() != .eof) {}
}
