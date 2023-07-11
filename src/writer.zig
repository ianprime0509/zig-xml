const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const ArrayList = std.ArrayList;
const Event = @import("reader.zig").Event;
const QName = @import("reader.zig").QName;

pub fn writer(w: anytype) Writer(@TypeOf(w)) {
    return .{ .w = w };
}

pub fn Writer(comptime WriterType: type) type {
    return struct {
        w: WriterType,

        const Self = @This();

        pub const Error = WriterType.Error;

        pub fn writeEvent(self: Self, event: Event) Error!void {
            switch (event) {
                .xml_declaration => |xml_declaration| {
                    try self.w.print("<?xml version=\"{}\"", .{fmtAttributeContent(xml_declaration.version)});
                    if (xml_declaration.encoding) |encoding| {
                        try self.w.print(" encoding=\"{}\"", .{fmtAttributeContent(encoding)});
                    }
                    if (xml_declaration.standalone) |standalone| {
                        try self.w.print(" standalone=\"{s}\"", .{if (standalone) "yes" else "no"});
                    }
                    try self.w.writeAll("?>\n");
                },
                .element_start => |element_start| {
                    try self.w.print("<{}", .{fmtQName(element_start.name)});
                    for (element_start.attributes) |attr| {
                        try self.w.print(" {}=\"{}\"", .{ fmtQName(attr.name), fmtAttributeContent(attr.value) });
                    }
                    try self.w.writeByte('>');
                },
                .element_content => |element_content| {
                    try self.w.print("{}", .{fmtElementContent(element_content.content)});
                },
                .element_end => |element_end| {
                    try self.w.print("</{s}>", .{fmtQName(element_end.name)});
                },
                .comment => |comment| {
                    try self.w.print("<!--{s}-->", .{comment.content});
                },
                .pi => |pi| {
                    try self.w.print("<?{s} {s}?>", .{ pi.target, pi.content });
                },
            }
        }
    };
}

test Writer {
    try testValid(&.{
        .{ .xml_declaration = .{ .version = "1.0", .encoding = "UTF-8", .standalone = true } },
        .{ .element_start = .{ .name = .{ .local = "root" } } },
        .{ .element_content = .{ .content = "Hello, world!" } },
        .{ .element_end = .{ .name = .{ .local = "root" } } },
    },
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root>Hello, world!</root>
    );
}

fn testValid(input: []const Event, expected: []const u8) !void {
    var output = ArrayList(u8).init(testing.allocator);
    defer output.deinit();
    var w = writer(output.writer());
    for (input) |event| {
        try w.writeEvent(event);
    }
    try testing.expectEqualStrings(expected, output.items);
}

pub fn fmtAttributeContent(data: []const u8) fmt.Formatter(formatAttributeContent) {
    return .{ .data = data };
}

fn formatAttributeContent(
    data: []const u8,
    comptime _: []const u8,
    _: fmt.FormatOptions,
    w: anytype,
) !void {
    for (data) |b| switch (b) {
        '\t' => try w.writeAll("&#9;"),
        '\n' => try w.writeAll("&#10;"),
        '\r' => try w.writeAll("&#13;"),
        '"' => try w.writeAll("&quot;"),
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        else => try w.writeByte(b),
    };
}

pub fn fmtElementContent(data: []const u8) fmt.Formatter(formatElementContent) {
    return .{ .data = data };
}

fn formatElementContent(
    data: []const u8,
    comptime _: []const u8,
    _: fmt.FormatOptions,
    w: anytype,
) !void {
    for (data) |b| switch (b) {
        '\r' => try w.writeAll("&#13;"),
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        else => try w.writeByte(b),
    };
}

pub fn fmtQName(data: QName) fmt.Formatter(formatQName) {
    return .{ .data = data };
}

fn formatQName(
    data: QName,
    comptime _: []const u8,
    _: fmt.FormatOptions,
    w: anytype,
) !void {
    if (data.prefix) |prefix| {
        try w.writeAll(prefix);
        try w.writeByte(':');
    }
    try w.writeAll(data.local);
}
