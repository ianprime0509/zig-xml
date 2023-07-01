const c = @cImport({
    @cDefine("LIBXML_READER_ENABLED", "1");
    @cInclude("libxml/xmlreader.h");
});

pub const main = @import("common.zig").main;

pub fn runBench(data: []const u8) !void {
    const reader = c.xmlReaderForMemory(data.ptr, @intCast(data.len), null, "utf-8", 0);
    while (true) {
        switch (c.xmlTextReaderRead(reader)) {
            -1 => return error.ParseFailed,
            0 => break,
            else => {},
        }
    }
    if (c.xmlTextReaderClose(reader) == -1) {
        return error.ParseFailed;
    }
}
