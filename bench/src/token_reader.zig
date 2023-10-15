const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var data_stream = std.io.fixedBufferStream(data);
    var token_reader = xml.tokenReader(data_stream.reader(), .{
        .DecoderType = xml.encoding.Utf8Decoder,
    });
    while (try token_reader.next()) |_| {}
}
