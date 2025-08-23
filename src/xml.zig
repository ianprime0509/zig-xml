const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const xml = @This();

pub const Location = struct {
    line: usize,
    column: usize,

    pub const start: Location = .{ .line = 1, .column = 1 };

    pub fn update(loc: *Location, s: []const u8) void {
        var pos: usize = 0;
        while (std.mem.indexOfAnyPos(u8, s, pos, "\r\n")) |nl_pos| {
            loc.line += 1;
            loc.column = 1;
            if (s[nl_pos] == '\r' and nl_pos + 1 < s.len and s[nl_pos + 1] == '\n') {
                pos = nl_pos + 2;
            } else {
                pos = nl_pos + 1;
            }
        }
        loc.column += s.len - pos;
    }

    pub fn format(loc: Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}:{}", .{ loc.line, loc.column });
    }

    test format {
        const loc: Location = .{ .line = 45, .column = 5 };
        var buf: [4]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{f}", .{loc});
        try expectEqualStrings("45:5", s);
    }
};

pub const QName = struct {
    ns: []const u8,
    local: []const u8,

    pub fn is(qname: QName, ns: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, qname.ns, ns) and std.mem.eql(u8, qname.local, local);
    }
};

pub const PrefixedQName = struct {
    prefix: []const u8,
    ns: []const u8,
    local: []const u8,

    pub fn is(qname: PrefixedQName, ns: []const u8, local: []const u8) bool {
        return std.mem.eql(u8, qname.ns, ns) and std.mem.eql(u8, qname.local, local);
    }
};

pub const predefined_entities = std.StaticStringMap([]const u8).initComptime(.{
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "amp", "&" },
    .{ "apos", "'" },
    .{ "quot", "\"" },
});

pub const ns_xml = "http://www.w3.org/XML/1998/namespace";
pub const ns_xmlns = "http://www.w3.org/2000/xmlns/";
pub const predefined_namespace_uris = std.StaticStringMap([]const u8).initComptime(.{
    .{ "xml", ns_xml },
    .{ "xmlns", ns_xmlns },
});
pub const predefined_namespace_prefixes = std.StaticStringMap([]const u8).initComptime(.{
    .{ ns_xml, "xml" },
    .{ ns_xmlns, "xmlns" },
});

pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");

test {
    _ = Location;
    _ = QName;
    _ = PrefixedQName;
    _ = Reader;
    _ = Writer;
}
