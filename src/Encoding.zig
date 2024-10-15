const std = @import("std");
const xml = @import("xml.zig");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

context: *const anyopaque,
guessFn: *const fn (context: *const anyopaque, text: []const u8) void,
checkEncodingFn: *const fn (context: *const anyopaque, xml_encoding: []const u8) bool,
transcodeFn: *const fn (context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult,

const Encoding = @This();

pub const TranscodeResult = struct {
    err: bool,
    dest_written: usize,
    src_read: usize,
};

pub fn guess(encoding: Encoding, text: []const u8) void {
    encoding.guessFn(encoding.context, text);
}

pub fn checkEncoding(encoding: Encoding, xml_encoding: []const u8) bool {
    return encoding.checkEncodingFn(encoding.context, xml_encoding);
}

pub fn transcode(encoding: Encoding, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
    return encoding.transcodeFn(encoding.context, dest, src);
}

pub const utf8: Encoding = .{
    .context = undefined,
    .guessFn = &utf8Guess,
    .checkEncodingFn = &utf8CheckEncoding,
    .transcodeFn = &utf8Transcode,
};

fn utf8Guess(context: *const anyopaque, text: []const u8) void {
    _ = context;
    _ = text;
}

fn utf8CheckEncoding(context: *const anyopaque, xml_encoding: []const u8) bool {
    _ = context;
    return std.ascii.eqlIgnoreCase(xml_encoding, "UTF-8");
}

fn utf8Transcode(context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
    _ = context;
    var dest_written: usize = 0;
    var src_read: usize = 0;
    const err = while (src_read < src.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(src[src_read]) catch break true;
        if (src_read + cp_len > src.len or dest_written + cp_len > dest.len) break false;
        switch (cp_len) {
            1 => {
                dest[dest_written] = src[src_read];
                dest_written += 1;
                src_read += 1;
            },
            2, 3, 4 => {
                const slice = src[src_read..][0..cp_len];
                if (!std.unicode.utf8ValidateSlice(slice)) break true;
                @memcpy(dest[dest_written..][0..cp_len], slice);
                dest_written += cp_len;
                src_read += cp_len;
            },
            else => unreachable,
        }
    } else false;
    return .{
        .err = err,
        .dest_written = dest_written,
        .src_read = src_read,
    };
}

test utf8 {
    var fbs = std.io.fixedBufferStream(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>Hello, world!</root>
        \\
    );
    var doc = xml.encodedDocument(std.testing.allocator, fbs.reader(), xml.Encoding.utf8);
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, world!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

pub const Utf16 = struct {
    endian: std.builtin.Endian,

    pub const init: Utf16 = .{ .endian = .big };

    pub fn encoding(utf16: *Utf16) Encoding {
        return .{
            .context = utf16,
            .guessFn = &Utf16.guess,
            .checkEncodingFn = &Utf16.checkEncoding,
            .transcodeFn = &Utf16.transcode,
        };
    }

    fn guess(context: *const anyopaque, text: []const u8) void {
        const utf16: *Utf16 = @alignCast(@constCast(@ptrCast(context)));
        utf16.endian = if (std.mem.startsWith(u8, text, "\xFF\xFE")) .little else .big;
    }

    fn checkEncoding(context: *const anyopaque, xml_encoding: []const u8) bool {
        _ = context;
        return std.ascii.eqlIgnoreCase(xml_encoding, "UTF-16");
    }

    fn transcode(context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
        const utf16: *const Utf16 = @alignCast(@ptrCast(context));
        var dest_written: usize = 0;
        var src_read: usize = 0;
        const err = while (src_read + 1 < src.len) {
            const cu = std.mem.readInt(u16, src[src_read..][0..2], utf16.endian);
            if (std.unicode.utf16IsLowSurrogate(cu)) break true;
            const cp, const units: usize = if (std.unicode.utf16IsHighSurrogate(cu)) pair: {
                if (src_read + 3 >= src.len) break false;
                const low = std.mem.readInt(u16, src[src_read + 2 ..][0..2], utf16.endian);
                break :pair .{ std.unicode.utf16DecodeSurrogatePair(&.{ cu, low }) catch break true, 2 };
            } else .{ cu, 1 };
            const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
            if (dest_written + cp_len >= dest.len) break false;
            dest_written += std.unicode.utf8Encode(cp, dest[dest_written..]) catch unreachable;
            src_read += 2 * units;
        } else false;
        return .{
            .err = err,
            .dest_written = dest_written,
            .src_read = src_read,
        };
    }
};

test Utf16 {
    const utf16_xml = std.unicode.utf8ToUtf16LeStringLiteral("\u{FEFF}" ++
        \\<?xml version="1.0" encoding="UTF-16"?>
        \\<root>Hello, world!</root>
        \\
    );
    var utf16_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer utf16_bytes.deinit(std.testing.allocator);
    for (utf16_xml) |cu| {
        std.mem.writeInt(u16, try utf16_bytes.addManyAsArray(std.testing.allocator, 2), cu, .little);
    }

    var fbs = std.io.fixedBufferStream(utf16_bytes.items);
    var encoding = xml.Encoding.Utf16.init;
    var doc = xml.encodedDocument(std.testing.allocator, fbs.reader(), encoding.encoding());
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, world!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

pub const Default = union(enum) {
    utf8,
    utf16: Utf16,

    pub const init: Default = .utf8;

    pub fn encoding(default: *Default) Encoding {
        return .{
            .context = default,
            .guessFn = &Default.guess,
            .checkEncodingFn = &Default.checkEncoding,
            .transcodeFn = &Default.transcode,
        };
    }

    fn guess(context: *const anyopaque, text: []const u8) void {
        const default: *Default = @alignCast(@constCast(@ptrCast(context)));
        default.* = if (std.mem.startsWith(u8, text, "\xFE\xFF"))
            .{ .utf16 = .{ .endian = .big } }
        else if (std.mem.startsWith(u8, text, "\xFF\xFE"))
            .{ .utf16 = .{ .endian = .little } }
        else
            .utf8;
    }

    fn checkEncoding(context: *const anyopaque, xml_encoding: []const u8) bool {
        const default: *const Default = @alignCast(@ptrCast(context));
        return switch (default.*) {
            .utf8 => utf8.checkEncoding(xml_encoding),
            .utf16 => |*utf16| Utf16.checkEncoding(utf16, xml_encoding),
        };
    }

    fn transcode(context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
        const default: *const Default = @alignCast(@ptrCast(context));
        return switch (default.*) {
            .utf8 => utf8.transcode(dest, src),
            .utf16 => |*utf16| Utf16.transcode(utf16, dest, src),
        };
    }
};

test Default {
    const utf16_xml = std.unicode.utf8ToUtf16LeStringLiteral("\u{FEFF}" ++
        \\<?xml version="1.0" encoding="UTF-16"?>
        \\<root>Hello, world!</root>
        \\
    );
    var utf16_bytes: std.ArrayListUnmanaged(u8) = .{};
    defer utf16_bytes.deinit(std.testing.allocator);
    for (utf16_xml) |cu| {
        std.mem.writeInt(u16, try utf16_bytes.addManyAsArray(std.testing.allocator, 2), cu, .little);
    }

    var fbs = std.io.fixedBufferStream(utf16_bytes.items);
    var encoding = xml.Encoding.Default.init;
    var doc = xml.encodedDocument(std.testing.allocator, fbs.reader(), encoding.encoding());
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, world!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}
