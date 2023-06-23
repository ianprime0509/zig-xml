const c = @cImport(@cInclude("mxml.h"));

pub const main = @import("common.zig").main;

pub fn runBench(data: [:0]const u8) !void {
    if (c.mxmlSAXLoadString(null, data, null, &callback, null)) |node| {
        _ = c.mxmlRelease(node);
    } else {
        return error.ParseFailed;
    }
}

var seen_root_node = false;

fn callback(node: ?*c.mxml_node_t, event: c.mxml_sax_event_t, _: ?*anyopaque) callconv(.C) void {
    if (!seen_root_node and event == c.MXML_SAX_ELEMENT_OPEN) {
        _ = c.mxmlRetain(node);
        seen_root_node = true;
    }
}
