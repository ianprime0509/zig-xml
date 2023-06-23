const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var data_stream = std.io.fixedBufferStream(data);
    var reader = xml.reader(std.heap.page_allocator, data_stream.reader(), xml.encoding.Utf8Decoder{}, .{});
    defer reader.deinit();
    while (try reader.next()) |_| {}
}
