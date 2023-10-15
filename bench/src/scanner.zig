const std = @import("std");
const xml = @import("xml");

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var scanner = xml.Scanner{};
    var data_stream = std.io.fixedBufferStream(data);
    var decoder = xml.encoding.Utf8Decoder{};
    var buf: [4]u8 = undefined;
    while (true) {
        const c = try decoder.readCodepoint(data_stream.reader(), &buf);
        if (!c.present) break;
        _ = try scanner.next(c.codepoint, c.byte_length);
    }
}
