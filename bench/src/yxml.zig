const c = @cImport(@cInclude("yxml.h"));

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    var parser: c.yxml_t = undefined;
    var buf: [4096]u8 = undefined;
    c.yxml_init(&parser, &buf, buf.len);
    for (data) |b| {
        if (c.yxml_parse(&parser, b) < 0) {
            return error.ParseFailed;
        }
    }
    if (c.yxml_eof(&parser) != c.YXML_OK) {
        return error.ParseFailed;
    }
}
