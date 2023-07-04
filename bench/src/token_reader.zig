const std = @import("std");
const xml = @import("xml");

pub const enable_tracy = true;

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var data_stream = std.io.fixedBufferStream(data);
    var token_reader = xml.tokenReader(data_stream.reader(), xml.encoding.Utf8Decoder{}, .{});
    while (try token_reader.next()) |_| {}
}
