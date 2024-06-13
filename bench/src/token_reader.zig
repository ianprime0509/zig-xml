const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var data_stream = std.io.fixedBufferStream(data);
    var token_reader = xml.tokenReader(std.heap.c_allocator, data_stream.reader(), .{
        .DecoderType = xml.encoding.Utf8Decoder,
    });
    defer token_reader.deinit();
    while (true) {
        const token = try token_reader.next();
        if (token == .eof) break;
    }
}
