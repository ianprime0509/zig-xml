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

    pub fn format(
        loc: Location,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try writer.print("{}:{}", .{ loc.line, loc.column });
    }

    test format {
        const loc: Location = .{ .line = 45, .column = 5 };
        var buf: [4]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{}", .{loc});
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

/// A thin wrapper around a `Reader` which guarantees that the underlying
/// `Reader.Source` will return only errors in `SourceError`, allowing the
/// reader functions to be exposed with more precise error sets.
pub fn GenericReader(comptime SourceError: type) type {
    return struct {
        reader: Reader,

        /// See `Reader.deinit`.
        pub inline fn deinit(reader: *@This()) void {
            reader.reader.deinit();
        }

        pub const ReadError = Reader.ReadError || SourceError;

        /// See `Reader.read`.
        pub inline fn read(reader: *@This()) ReadError!Reader.Node {
            return @errorCast(reader.reader.read());
        }

        /// See `Reader.readElementText`.
        pub inline fn readElementText(reader: *@This()) (ReadError || Allocator.Error)![]const u8 {
            return @errorCast(reader.reader.readElementText());
        }

        pub inline fn readElementTextAlloc(reader: *@This(), gpa: Allocator) (ReadError || Allocator.Error)![]u8 {
            return @errorCast(reader.reader.readElementTextAlloc(gpa));
        }

        /// See `Reader.readElementTextWrite`.
        pub inline fn readElementTextWrite(reader: *@This(), writer: anytype) (ReadError || @TypeOf(writer).Error)!void {
            return @errorCast(reader.reader.readElementTextWrite(writer.any()));
        }

        /// See `Reader.skipProlog`.
        pub inline fn skipProlog(reader: *@This()) ReadError!void {
            return @errorCast(reader.reader.skipProlog());
        }

        /// See `Reader.skipElement`.
        pub inline fn skipElement(reader: *@This()) ReadError!void {
            return @errorCast(reader.reader.skipElement());
        }

        /// See `Reader.skipDocument`.
        pub inline fn skipDocument(reader: *@This()) ReadError!void {
            return @errorCast(reader.reader.skipDocument());
        }

        /// See `Reader.location`.
        pub inline fn location(reader: @This()) Location {
            return reader.reader.location();
        }

        /// See `Reader.errorCode`.
        pub inline fn errorCode(reader: @This()) Reader.ErrorCode {
            return reader.reader.errorCode();
        }

        /// See `Reader.errorLocation`.
        pub inline fn errorLocation(reader: @This()) Location {
            return reader.reader.errorLocation();
        }

        /// See `Reader.xmlDeclarationVersion`.
        pub inline fn xmlDeclarationVersion(reader: @This()) []const u8 {
            return reader.reader.xmlDeclarationVersion();
        }

        /// See `Reader.xmlDeclarationEncoding`.
        pub inline fn xmlDeclarationEncoding(reader: @This()) ?[]const u8 {
            return reader.reader.xmlDeclarationEncoding();
        }

        /// See `Reader.xmlDeclarationStandalone`.
        pub inline fn xmlDeclarationStandalone(reader: @This()) ?bool {
            return reader.reader.xmlDeclarationStandalone();
        }

        /// See `Reader.elementName`.
        pub inline fn elementName(reader: @This()) []const u8 {
            return reader.reader.elementName();
        }

        /// See `Reader.elementNameNs`.
        pub inline fn elementNameNs(reader: @This()) PrefixedQName {
            return reader.reader.elementNameNs();
        }

        /// See `Reader.attributeCount`.
        pub inline fn attributeCount(reader: @This()) usize {
            return reader.reader.attributeCount();
        }

        /// See `Reader.attributeName`.
        pub inline fn attributeName(reader: @This(), n: usize) []const u8 {
            return reader.reader.attributeName(n);
        }

        /// See `Reader.attributeNameNs`.
        pub inline fn attributeNameNs(reader: @This(), n: usize) PrefixedQName {
            return reader.reader.attributeNameNs(n);
        }

        /// See `Reader.attributeValue`.
        pub inline fn attributeValue(reader: *@This(), n: usize) Allocator.Error![]const u8 {
            return reader.reader.attributeValue(n);
        }

        /// See `Reader.attributeValueAlloc`.
        pub inline fn attributeValueAlloc(reader: @This(), gpa: Allocator, n: usize) Allocator.Error![]u8 {
            return reader.reader.attributeValueAlloc(gpa, n);
        }

        /// See `Reader.attributeValueWrite`.
        pub inline fn attributeValueWrite(reader: @This(), n: usize, writer: anytype) @TypeOf(writer).Error!void {
            return @errorCast(reader.reader.attributeValueWrite(n, writer.any()));
        }

        /// See `Reader.attributeValueRaw`.
        pub inline fn attributeValueRaw(reader: @This(), n: usize) []const u8 {
            return reader.reader.attributeValueRaw(n);
        }

        /// See `Reader.attributeLocation`.
        pub inline fn attributeLocation(reader: @This(), n: usize) Location {
            return reader.reader.attributeLocation(n);
        }

        /// See `Reader.attributeIndex`.
        pub inline fn attributeIndex(reader: @This(), name: []const u8) ?usize {
            return reader.reader.attributeIndex(name);
        }

        /// See `Reader.attributeIndexNs`.
        pub inline fn attributeIndexNs(reader: @This(), ns: []const u8, local: []const u8) ?usize {
            return reader.reader.attributeIndexNs(ns, local);
        }

        /// See `Reader.comment`.
        pub inline fn comment(reader: *@This()) Allocator.Error![]const u8 {
            return reader.reader.comment();
        }

        /// See `Reader.commentWrite`.
        pub inline fn commentWrite(reader: @This(), writer: anytype) @TypeOf(writer).Error!void {
            return @errorCast(reader.reader.commentWrite(writer.any()));
        }

        /// See `Reader.commentRaw`.
        pub inline fn commentRaw(reader: @This()) []const u8 {
            return reader.reader.commentRaw();
        }

        /// See `Reader.piTarget`.
        pub inline fn piTarget(reader: @This()) []const u8 {
            return reader.reader.piTarget();
        }

        /// See `Reader.piData`.
        pub inline fn piData(reader: *@This()) Allocator.Error![]const u8 {
            return reader.reader.piData();
        }

        /// See `Reader.piDataWrite`.
        pub inline fn piDataWrite(reader: @This(), writer: anytype) @TypeOf(writer).Error!void {
            return @errorCast(reader.reader.piDataWrite(writer.any()));
        }

        /// See `Reader.piDataRaw`.
        pub inline fn piDataRaw(reader: @This()) []const u8 {
            return reader.reader.piDataRaw();
        }

        /// See `Reader.text`.
        pub inline fn text(reader: *@This()) Allocator.Error![]const u8 {
            return reader.reader.text();
        }

        /// See `Reader.textWrite`.
        pub inline fn textWrite(reader: @This(), writer: anytype) @TypeOf(writer).Error!void {
            return @errorCast(reader.reader.textWrite(writer.any()));
        }

        /// See `Reader.textRaw`.
        pub inline fn textRaw(reader: @This()) []const u8 {
            return reader.reader.textRaw();
        }

        /// See `Reader.cdataWrite`.
        pub inline fn cdataWrite(reader: @This(), writer: anytype) @TypeOf(writer).Error!void {
            return @errorCast(reader.reader.cdataWrite(writer.any()));
        }

        /// See `Reader.cdata`.
        pub inline fn cdata(reader: *@This()) Allocator.Error![]const u8 {
            return reader.reader.cdata();
        }

        /// See `Reader.cdataRaw`.
        pub inline fn cdataRaw(reader: @This()) []const u8 {
            return reader.reader.cdataRaw();
        }

        /// See `Reader.entityReferenceName`.
        pub inline fn entityReferenceName(reader: @This()) []const u8 {
            return reader.reader.entityReferenceName();
        }

        /// See `Reader.characterReferenceChar`.
        pub inline fn characterReferenceChar(reader: @This()) u21 {
            return reader.reader.characterReferenceChar();
        }

        /// See `Reader.characterReferenceName`.
        pub inline fn characterReferenceName(reader: @This()) []const u8 {
            return reader.reader.characterReferenceName();
        }

        /// See `Reader.namespaceUri`.
        pub inline fn namespaceUri(reader: @This(), prefix: []const u8) []const u8 {
            return reader.reader.namespaceUri(prefix);
        }

        /// Returns the underlying raw `Reader`.
        pub inline fn raw(reader: *@This()) *Reader {
            return &reader.reader;
        }
    };
}

/// A UTF-8-encoded XML document stored entirely in memory.
pub const StaticDocument = struct {
    data: []const u8,
    pos: usize,

    pub const Error = error{};

    pub fn init(data: []const u8) StaticDocument {
        return .{ .data = data, .pos = 0 };
    }

    pub fn reader(doc: *StaticDocument, gpa: Allocator, options: Reader.Options) GenericReader(Error) {
        return .{ .reader = Reader.init(gpa, doc.source(), options) };
    }

    pub fn source(doc: *StaticDocument) Reader.Source {
        return .{
            .context = doc,
            .moveFn = &move,
            .checkEncodingFn = &checkEncodingUtf8,
        };
    }

    fn move(context: *const anyopaque, advance: usize, len: usize) anyerror![]const u8 {
        const doc: *StaticDocument = @alignCast(@constCast(@ptrCast(context)));
        doc.pos += advance;
        const rest_doc = doc.data[doc.pos..];
        return rest_doc[0..@min(len, rest_doc.len)];
    }
};

test StaticDocument {
    var doc: StaticDocument = .init(
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    );
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

/// An XML document streamed from a `std.io.GenericReader`. The document content
/// may be encoded using UTF-8 or UTF-16.
///
/// See `streamingDocument` for a simple way to create a `StreamingDocument` from
/// an existing generic reader.
pub fn StreamingDocument(comptime ReaderType: type) type {
    return struct {
        stream: ReaderType,
        state: enum {
            start,
            utf8,
            utf16be,
            utf16le,
        },

        read: [4096]u8,
        read_len: usize,
        transcode_buf: [3]u8,
        transcode_buf_len: u2,

        buf: []u8,
        pos: usize,
        avail: usize,
        gpa: Allocator,

        pub const Error = ReaderType.Error || Allocator.Error;

        pub fn init(gpa: Allocator, stream: ReaderType) @This() {
            return .{
                .stream = stream,
                .state = .start,

                .read = undefined,
                .read_len = 0,
                .transcode_buf = undefined,
                .transcode_buf_len = 0,

                .buf = &.{},
                .pos = 0,
                .avail = 0,
                .gpa = gpa,
            };
        }

        pub fn deinit(doc: *@This()) void {
            doc.gpa.free(doc.buf);
            doc.* = undefined;
        }

        pub fn reader(doc: *@This(), gpa: Allocator, options: Reader.Options) GenericReader(Error) {
            return .{ .reader = Reader.init(gpa, doc.source(), options) };
        }

        pub fn source(doc: *@This()) Reader.Source {
            return .{
                .context = doc,
                .moveFn = &move,
                .checkEncodingFn = &checkEncoding,
            };
        }

        fn move(context: *const anyopaque, advance: usize, len: usize) anyerror![]const u8 {
            const doc: *@This() = @alignCast(@constCast(@ptrCast(context)));
            doc.pos += advance;
            if (len <= doc.avail - doc.pos) return doc.buf[doc.pos..][0..len];
            doc.discardRead();
            try doc.fillBuffer(len);
            return doc.buf[0..@min(len, doc.avail)];
        }

        fn discardRead(doc: *@This()) void {
            doc.avail -= doc.pos;
            std.mem.copyForwards(u8, doc.buf[0..doc.avail], doc.buf[doc.pos..][0..doc.avail]);
            doc.pos = 0;
        }

        const min_buf_len = 4096;

        fn fillBuffer(doc: *@This(), target_len: usize) !void {
            if (target_len > doc.buf.len) {
                const new_buf_len = @max(min_buf_len, std.math.ceilPowerOfTwoAssert(usize, target_len));
                doc.buf = try doc.gpa.realloc(doc.buf, new_buf_len);
            }
            read: switch (doc.state) {
                .start => {
                    doc.read_len = try doc.stream.readAll(&doc.read);
                    if (std.mem.startsWith(u8, doc.read[0..doc.read_len], "\xFE\xFF")) {
                        doc.state = .utf16be;
                    } else if (std.mem.startsWith(u8, doc.read[0..doc.read_len], "\xFF\xFE")) {
                        doc.state = .utf16le;
                    } else {
                        doc.state = .utf8;
                        // Since doc.read.len == min_buf_len, we know we can copy
                        // all of the read buffer into the document buffer.
                        @memcpy(doc.buf[0..doc.read_len], doc.read[0..doc.read_len]);
                        doc.avail += doc.read_len;
                    }
                    continue :read doc.state;
                },
                .utf8 => {
                    doc.avail += try doc.stream.readAll(doc.buf[doc.avail..]);
                },
                .utf16be, .utf16le => {
                    const endian: std.builtin.Endian = if (doc.state == .utf16be) .big else .little;
                    while (doc.avail < doc.buf.len) {
                        const read = try doc.stream.readAll(doc.read[doc.read_len..]);
                        if (read == 0 and doc.transcode_buf_len == 0 and doc.read_len == 0) break;
                        doc.read_len += read;
                        doc.transcodeUtf16(endian);
                    }
                },
            }
        }

        /// Transcodes UTF-16 from the read buffer into UTF-8 in the document
        /// buffer. Invalid UTF-16 is transcoded to invalid UTF-8.
        fn transcodeUtf16(doc: *@This(), endian: std.builtin.Endian) void {
            if (doc.transcode_buf_len > 0) {
                const can_copy = @min(doc.transcode_buf_len, doc.buf.len - doc.avail);
                @memcpy(doc.buf[doc.avail..][0..can_copy], doc.transcode_buf[0..can_copy]);
                std.mem.copyForwards(u8, &doc.transcode_buf, doc.transcode_buf[can_copy..]);
                doc.transcode_buf_len -= can_copy;
            }

            var read_pos: usize = 0;
            while (doc.avail < doc.buf.len and read_pos < doc.read_len) {
                const cp: u21, const src_len: usize = next_cp: {
                    if (read_pos + 1 == doc.read_len) {
                        // Odd number of bytes in UTF-16 input.
                        // We know this is the end of the document, since the
                        // read buffer has an even length, and we always attempt
                        // to fill the read buffer as much as possible on every
                        // read. Hence, a mismatched high surrogate will work to
                        // produce invalid UTF-8.
                        break :next_cp .{ 0xD800 + @as(u16, doc.read[read_pos]), 1 };
                    }
                    const u = std.mem.readInt(u16, doc.read[read_pos..][0..2], endian);
                    if (std.unicode.utf16IsHighSurrogate(u)) {
                        // High surrogate
                        if (read_pos + 4 > doc.read_len) {
                            // We might have more input; try reading more.
                            if (doc.read_len == doc.read.len) break;
                            // Otherwise, this is just an unpaired surrogate.
                            break :next_cp .{ u, 2 };
                        }
                        const low = std.mem.readInt(u16, doc.read[read_pos + 2 ..][0..2], endian);
                        if (std.unicode.utf16DecodeSurrogatePair(&.{ u, low })) |cp| {
                            break :next_cp .{ cp, 4 };
                        } else |_| {
                            break :next_cp .{ u, 2 };
                        }
                    } else {
                        break :next_cp .{ u, 2 };
                    }
                };

                read_pos += src_len;
                // No error is possible since the codepoint was decoded from
                // UTF-16, so it can't be too large (and utf8CodepointSequenceLength
                // doesn't check for unpaired surrogates).
                const enc_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
                if (doc.avail + enc_len <= doc.buf.len) {
                    // Happy path: encode directly into the available buffer.
                    _ = std.unicode.wtf8Encode(cp, doc.buf[doc.avail..]) catch unreachable;
                    doc.avail += enc_len;
                } else {
                    // Encode into a temporary buffer and keep what we can't
                    // encode in the transcode buffer.
                    const can_encode = doc.buf.len - doc.avail;
                    var buf: [4]u8 = undefined;
                    _ = std.unicode.wtf8Encode(cp, &buf) catch unreachable;
                    @memcpy(doc.buf[doc.avail..][0..can_encode], buf[0..can_encode]);
                    doc.avail += can_encode;
                    const must_store = enc_len - can_encode;
                    @memcpy(doc.transcode_buf[0..must_store], buf[can_encode..][0..must_store]);
                    doc.transcode_buf_len = @intCast(must_store);
                }
            }
            std.mem.copyForwards(u8, &doc.read, doc.read[read_pos..]);
            doc.read_len -= read_pos;
        }

        fn checkEncoding(context: *const anyopaque, encoding: []const u8) bool {
            const doc: *const @This() = @alignCast(@ptrCast(context));
            return switch (doc.state) {
                .start => unreachable, // Can't check encoding before reading anything.
                .utf8 => std.ascii.eqlIgnoreCase(encoding, "UTF-8"),
                .utf16be, .utf16le => std.ascii.eqlIgnoreCase(encoding, "UTF-16"),
            };
        }
    };
}

pub fn streamingDocument(gpa: Allocator, reader: anytype) StreamingDocument(@TypeOf(reader)) {
    return StreamingDocument(@TypeOf(reader)).init(gpa, reader);
}

test streamingDocument {
    var fbs = std.io.fixedBufferStream(
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    );
    var doc = xml.streamingDocument(std.testing.allocator, fbs.reader());
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

test "streamingDocument with UTF-16BE" {
    try testStreamingDocumentUtf16(.big);
}

test "streamingDocument with UTF-16LE" {
    try testStreamingDocumentUtf16(.little);
}

fn testStreamingDocumentUtf16(comptime endian: std.builtin.Endian) !void {
    var fbs = std.io.fixedBufferStream(utf16BytesLiteral(endian, "\u{FEFF}" ++
        \\<?xml version="1.0"?>
        \\<root>Hello, 世界 👋!</root>
        \\
    ));
    var doc = xml.streamingDocument(std.testing.allocator, fbs.reader());
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.xml_declaration, try reader.read());
    try expectEqualStrings("1.0", reader.xmlDeclarationVersion());

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.text, try reader.read());
    try expectEqualStrings("Hello, 世界 👋!", reader.textRaw());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings("root", reader.elementName());

    try expectEqual(.eof, try reader.read());
}

inline fn utf16BytesLiteral(comptime endian: std.builtin.Endian, comptime utf8: []const u8) []const u8 {
    const utf16 = std.unicode.utf8ToUtf16LeStringLiteral(utf8);
    var utf16_bytes: [utf16.len * 2]u8 = undefined;
    for (utf16, 0..) |cu, i| {
        std.mem.writeInt(u16, utf16_bytes[i * 2 ..][0..2], cu, endian);
    }
    const utf16_bytes_final = utf16_bytes;
    return &utf16_bytes_final;
}

test "streamingDocument with extremely long element name" {
    const name = "a" ** 65536;
    var fbs = std.io.fixedBufferStream("<" ++ name ++ "/>");
    var doc = xml.streamingDocument(std.testing.allocator, fbs.reader());
    defer doc.deinit();
    var reader = doc.reader(std.testing.allocator, .{});
    defer reader.deinit();

    try expectEqual(.element_start, try reader.read());
    try expectEqualStrings(name, reader.elementName());

    try expectEqual(.element_end, try reader.read());
    try expectEqualStrings(name, reader.elementName());

    try expectEqual(.eof, try reader.read());
}

fn checkEncodingUtf8(context: *const anyopaque, encoding: []const u8) bool {
    _ = context;
    return std.ascii.eqlIgnoreCase(encoding, "UTF-8");
}

pub const Writer = @import("Writer.zig");

pub fn GenericWriter(comptime SinkError: type) type {
    return struct {
        writer: Writer,

        /// See `Writer.deinit`.
        pub inline fn deinit(writer: *@This()) void {
            writer.writer.deinit();
        }

        // TODO: not all the write functions actually need to allocate
        pub const WriteError = Writer.WriteError || SinkError || Allocator.Error;

        /// See `Writer.eof`.
        pub inline fn eof(writer: *@This()) WriteError!void {
            return @errorCast(writer.writer.eof());
        }

        /// See `Writer.bom`.
        pub inline fn bom(writer: *@This()) WriteError!void {
            return @errorCast(writer.writer.bom());
        }

        /// See `Writer.xmlDeclaration`.
        pub inline fn xmlDeclaration(writer: *@This(), encoding: ?[]const u8, standalone: ?bool) WriteError!void {
            return @errorCast(writer.writer.xmlDeclaration(encoding, standalone));
        }

        /// See `Writer.elementStart`.
        pub inline fn elementStart(writer: *@This(), name: []const u8) WriteError!void {
            return @errorCast(writer.writer.elementStart(name));
        }

        /// See `Writer.elementStartNs`.
        pub inline fn elementStartNs(writer: *@This(), ns: []const u8, local: []const u8) WriteError!void {
            return @errorCast(writer.writer.elementStartNs(ns, local));
        }

        /// See `Writer.elementEnd`.
        pub inline fn elementEnd(writer: *@This()) WriteError!void {
            return @errorCast(writer.writer.elementEnd());
        }

        /// See `Writer.elementEndEmpty`.
        pub inline fn elementEndEmpty(writer: *@This()) WriteError!void {
            return @errorCast(writer.writer.elementEndEmpty());
        }

        /// See `Writer.attribute`.
        pub inline fn attribute(writer: *@This(), name: []const u8, value: []const u8) WriteError!void {
            return @errorCast(writer.writer.attribute(name, value));
        }

        /// See `Writer.attributeNs`.
        pub inline fn attributeNs(writer: *@This(), ns: []const u8, local: []const u8, value: []const u8) WriteError!void {
            return @errorCast(writer.writer.attributeNs(ns, local, value));
        }

        /// See `Writer.comment`.
        pub inline fn comment(writer: *@This(), s: []const u8) WriteError!void {
            return @errorCast(writer.writer.comment(s));
        }

        /// See `Writer.pi`.
        pub inline fn pi(writer: *@This(), target: []const u8, data: []const u8) WriteError!void {
            return @errorCast(writer.writer.pi(target, data));
        }

        /// See `Writer.text`.
        pub inline fn text(writer: *@This(), s: []const u8) WriteError!void {
            return @errorCast(writer.writer.text(s));
        }

        /// See `Writer.cdata`.
        pub inline fn cdata(writer: *@This(), s: []const u8) WriteError!void {
            return @errorCast(writer.writer.cdata(s));
        }

        /// See `Writer.characterReference`.
        pub inline fn characterReference(writer: *@This(), c: u21) WriteError!void {
            return @errorCast(writer.writer.characterReference(c));
        }

        /// See `Writer.entityReference`.
        pub inline fn entityReference(writer: *@This(), name: []const u8) WriteError!void {
            return @errorCast(writer.writer.entityReference(name));
        }

        /// See `Writer.embed`.
        pub inline fn embed(writer: *@This(), s: []const u8) WriteError!void {
            return @errorCast(writer.writer.embed(s));
        }

        /// See `Writer.bindNs`.
        pub inline fn bindNs(writer: *@This(), prefix: []const u8, ns: []const u8) WriteError!void {
            return @errorCast(writer.writer.bindNs(prefix, ns));
        }

        /// Returns the underlying raw `Writer`.
        pub inline fn raw(writer: *@This()) *Writer {
            return &writer.writer;
        }
    };
}

pub fn StreamingOutput(comptime WriterType: type) type {
    return struct {
        stream: WriterType,

        pub const Error = WriterType.Error;

        pub fn writer(out: *const @This(), gpa: Allocator, options: Writer.Options) GenericWriter(Error) {
            return .{ .writer = Writer.init(gpa, out.sink(), options) };
        }

        pub fn sink(out: *const @This()) Writer.Sink {
            return .{
                .context = out,
                .writeFn = &write,
            };
        }

        fn write(context: *const anyopaque, data: []const u8) anyerror!void {
            const out: *const @This() = @alignCast(@ptrCast(context));
            var pos: usize = 0;
            while (pos < data.len) {
                pos += try out.stream.write(data[pos..]);
            }
        }
    };
}

pub fn streamingOutput(writer: anytype) StreamingOutput(@TypeOf(writer)) {
    return .{ .stream = writer };
}

test streamingOutput {
    var raw = std.ArrayList(u8).init(std.testing.allocator);
    defer raw.deinit();
    const out = xml.streamingOutput(raw.writer());
    var writer = out.writer(std.testing.allocator, .{ .indent = "  " });
    defer writer.deinit();

    try writer.xmlDeclaration("UTF-8", null);
    try writer.elementStart("test");
    try writer.elementStart("inner");
    try writer.text("Hello, world!");
    try writer.elementEnd();
    try writer.elementEnd();

    try expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<test>
        \\  <inner>Hello, world!</inner>
        \\</test>
    , raw.items);
}

test {
    _ = Location;
    _ = QName;
    _ = PrefixedQName;
    _ = Reader;
    _ = Writer;
}
