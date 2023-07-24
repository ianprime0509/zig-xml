const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Event = @import("reader.zig").Event;
const QName = @import("reader.zig").QName;

/// Returns a `Writer` wrapping a `std.io.Writer`.
pub fn writer(w: anytype) Writer(@TypeOf(w)) {
    return .{ .w = w };
}

/// A streaming XML writer wrapping a `std.io.Writer`.
///
/// This writer exposes a selection of functions to write XML content with
/// proper escaping where possible.
///
/// Some write functions come in sets to allow streaming longer contents rather
/// than writing them all in one go: for example, `writeAttribute` is useful for
/// writing an entire attribute name-value pair in one shot, but if the attribute
/// value is potentially quite long, the sequence of `writeAttributeStart`,
/// followed by an arbitrary (even zero) number of `writeAttributeContent`,
/// followed by `writeAttributeEnd`, can be used as a lower-level alternative.
///
/// One interesting lower-level function is `writeElementStartEnd`, which is used
/// to tell the writer to finish the current element start tag (all attributes
/// have been written), in preparation for writing other content. The other
/// functions (such as `writeElementContent`) will call this themselves if the
/// writer is in the middle of a start tag, but calling this function directly
/// could be useful if the user plans to write directly to the underlying
/// writer.
///
/// Additionally, this writer makes no attempt at being able to write XML in
/// arbitrary styles. For example, the quote character is not configurable, and
/// there is no function for writing CDATA sections.
///
/// # Safety
///
/// There are caveats to the well-formedness of the resulting output:
///
/// 1. There is no protection against calling the various write functions out of
///    order. For example, calling `writeElementEnd` without a corresponding
///    `writeElementStart` will result in non-well-formed XML.
/// 2. Processing instructions (PIs) and comments do not support escaping their
///    content, so passing content to the corresponding write functions which
///    contains illegal sequences for those constructs will result in
///    unexpected outcomes. For example, calling `writeComment` with a value
///    containing `-->` will result in the writer happily writing out the raw
///    `-->` in the text of the comment, which will close the comment and write
///    the rest of the provided text as raw XML (followed by the writer's
///    inserted `-->`).
/// 3. There are no validations that the names of elements and attributes match
///    the allowed syntax for names. Likewise, there are no validations that the
///    `version` and `encoding` passed to `writeXmlDeclaration` match the
///    allowed syntax for those values.
///
/// As such, it is not safe to use all functionality of this writer with
/// arbitrary user-provided data. What _is_ safe, however, is the more common
/// case of using this writer with only attribute values and element content
/// containing user-provided data, since those can always be escaped properly.
pub fn Writer(comptime WriterType: type) type {
    return struct {
        w: WriterType,
        in_element_start: bool = false,

        const Self = @This();

        pub const Error = WriterType.Error;

        pub fn writeXmlDeclaration(self: *Self, version: []const u8, encoding: ?[]const u8, standalone: ?bool) Error!void {
            try self.w.print("<?xml version=\"{}\"", .{fmtAttributeContent(version)});
            if (encoding) |e| {
                try self.w.print(" encoding=\"{}\"", .{fmtAttributeContent(e)});
            }
            if (standalone) |s| {
                try self.w.print(" standalone=\"{s}\"", .{if (s) "yes" else "no"});
            }
            try self.w.writeAll("?>");
        }

        pub fn writeElementStart(self: *Self, name: QName) Error!void {
            if (self.in_element_start) {
                try self.writeElementStartEnd();
            }
            try self.w.print("<{}", .{fmtQName(name)});
            self.in_element_start = true;
        }

        pub fn writeElementStartEnd(self: *Self) Error!void {
            try self.w.writeByte('>');
            self.in_element_start = false;
        }

        pub fn writeElementContent(self: *Self, content: []const u8) Error!void {
            if (self.in_element_start) {
                try self.writeElementStartEnd();
            }
            try self.w.print("{}", .{fmtElementContent(content)});
        }

        pub fn writeElementEnd(self: *Self, name: QName) Error!void {
            if (self.in_element_start) {
                try self.w.writeAll(" />");
                self.in_element_start = false;
            } else {
                try self.w.print("</{}>", .{fmtQName(name)});
            }
        }

        pub fn writeAttribute(self: *Self, name: QName, content: []const u8) Error!void {
            try self.writeAttributeStart(name);
            try self.writeAttributeContent(content);
            try self.writeAttributeEnd();
        }

        pub fn writeAttributeStart(self: *Self, name: QName) Error!void {
            try self.w.print(" {}=\"", .{fmtQName(name)});
        }

        pub fn writeAttributeContent(self: *Self, content: []const u8) Error!void {
            try self.w.print("{}", .{fmtAttributeContent(content)});
        }

        pub fn writeAttributeEnd(self: *Self) Error!void {
            try self.w.writeByte('"');
        }

        pub fn writeComment(self: *Self, content: []const u8) Error!void {
            try self.writeCommentStart();
            try self.writeCommentContent(content);
            try self.writeCommentEnd();
        }

        pub fn writeCommentStart(self: *Self) Error!void {
            if (self.in_element_start) {
                try self.writeElementStartEnd();
            }
            try self.w.writeAll("<!--");
        }

        pub fn writeCommentContent(self: *Self, content: []const u8) Error!void {
            try self.w.writeAll(content);
        }

        pub fn writeCommentEnd(self: *Self) Error!void {
            try self.w.writeAll("-->");
        }

        pub fn writePi(self: *Self, target: []const u8, content: []const u8) Error!void {
            try self.writePiStart(target);
            try self.writePiContent(content);
            try self.writePiEnd();
        }

        pub fn writePiStart(self: *Self, target: []const u8) Error!void {
            if (self.in_element_start) {
                try self.writeElementStartEnd();
            }
            try self.w.print("<?{} ", .{target});
        }

        pub fn writePiContent(self: *Self, content: []const u8) Error!void {
            try self.w.writeAll(content);
        }

        pub fn writePiEnd(self: *Self) Error!void {
            try self.w.writeAll("?>");
        }
    };
}

test Writer {
    var output = ArrayListUnmanaged(u8){};
    defer output.deinit(testing.allocator);
    var xml_writer = writer(output.writer(testing.allocator));

    const xmlns_ns = "http://www.w3.org/2000/xmlns/";
    try xml_writer.writeXmlDeclaration("1.0", "UTF-8", true);
    // The ns part of the QName is not used when writing, but may factor in to
    // future (optional) safety checks
    try xml_writer.writeElementStart(.{ .prefix = "test", .ns = "http://example.com/ns/test", .local = "root" });
    try xml_writer.writeAttribute(.{ .prefix = "xmlns", .ns = xmlns_ns, .local = "test" }, "http://example.com/ns/test");
    try xml_writer.writeComment(" Hello, world! ");
    try xml_writer.writeElementContent("Some text & some other text. ");
    try xml_writer.writeElementContent("Another <sentence>.");
    try xml_writer.writeElementStart(.{ .local = "sub" });
    try xml_writer.writeAttribute(.{ .local = "escaped" }, "&<>\"'");
    try xml_writer.writeElementEnd(.{ .local = "sub" });
    try xml_writer.writeElementEnd(.{ .prefix = "test", .ns = "http://example.com/ns/test", .local = "root" });

    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        ++
        \\<test:root xmlns:test="http://example.com/ns/test">
        ++
        \\<!-- Hello, world! -->
        ++
        \\Some text &amp; some other text. Another &lt;sentence>.
        ++
        \\<sub escaped="&amp;&lt;>&quot;'" />
        ++
        \\</test:root>
    , output.items);
}

/// Returns a `std.fmt.Formatter` for escaped attribute content.
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

/// Returns a `std.fmt.Formatter` for escaped element content.
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

/// Returns a `std.fmt.Formatter` for a QName (formats as `prefix:local` or
/// just `local` if no prefix).
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
