const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const encoding = @import("encoding.zig");
const Scanner = @import("Scanner.zig");

/// A single XML token.
pub const Token = union(enum) {
    /// XML declaration.
    xml_declaration: XmlDeclaration,
    /// Element start tag.
    element_start: ElementStart,
    /// Element content.
    element_content: ElementContent,
    /// Element end tag.
    element_end: ElementEnd,
    /// End of an empty element.
    element_end_empty,
    /// Attribute start.
    attribute_start: AttributeStart,
    /// Attribute value content.
    attribute_content: AttributeContent,
    /// Comment start.
    comment_start,
    /// Comment content.
    comment_content: CommentContent,
    /// Processing instruction (PI) start.
    pi_start: PiStart,
    /// PI content.
    pi_content: PiContent,

    pub const XmlDeclaration = struct {
        version: []const u8,
        encoding: ?[]const u8 = null,
        standalone: ?bool = null,
    };

    pub const ElementStart = struct {
        name: []const u8,
    };

    pub const ElementContent = struct {
        content: Content,
    };

    pub const ElementEnd = struct {
        name: []const u8,
    };

    pub const AttributeStart = struct {
        name: []const u8,
    };

    pub const AttributeContent = struct {
        content: Content,
        final: bool = false,
    };

    pub const CommentContent = struct {
        content: []const u8,
        final: bool = false,
    };

    pub const PiStart = struct {
        target: []const u8,
    };

    pub const PiContent = struct {
        content: []const u8,
        final: bool = false,
    };

    /// A bit of content of an element or attribute.
    pub const Content = union(enum) {
        /// Raw text content (does not contain any entities).
        text: []const u8,
        /// A Unicode codepoint.
        codepoint: u21,
        /// An entity reference, such as `&amp;`. The range covers the name (`amp`).
        entity: []const u8,
    };
};

/// Wraps a `std.io.Reader` in a `TokenReader` with the default buffer size
/// (4096).
pub fn tokenReader(
    reader: anytype,
    decoder: anytype,
    comptime options: TokenReaderOptions,
) TokenReader(@TypeOf(reader), @TypeOf(decoder), options) {
    return TokenReader(@TypeOf(reader), @TypeOf(decoder), options).init(reader, decoder);
}

/// Options for a `TokenReader`.
pub const TokenReaderOptions = struct {
    /// The size of the internal buffer.
    ///
    /// This limits the byte length of "non-splittable" content, such as
    /// element and attribute names. Longer such content will result in
    /// `error.Overflow`.
    buffer_size: usize = 4096,
    /// Whether to normalize line endings and attribute values according to the
    /// XML specification.
    ///
    /// If this is set to false, no normalization will be done: for example,
    /// the line ending sequence `\r\n` will appear as-is in returned tokens
    /// rather than the normalized `\n`.
    enable_normalization: bool = true,
};

/// An XML parser which wraps a `std.io.Reader` and returns low-level tokens.
///
/// An internal buffer of size `buffer_size` is used to store data read from
/// the reader, which is referenced by the returned tokens.
///
/// This parser offers several advantages over `Scanner` for higher-level
/// use-cases:
///
/// - The returned `Token`s use byte slices rather than positional ranges.
/// - The `next` function can be used in the typical Zig iterator pattern.
///   There is no `ok` token which must be ignored, and there is no need to
///   directly signal the end of input (the `Reader` provides this indication).
/// - The line ending and attribute value normalization steps required by the
///   XML specification (minus further attribute value normalization which
///   depends on DTD information) are performed.
///
/// However, due to its use of an internal buffer and transcoding all input to
/// UTF-8, it is not as efficient as a `Scanner` where these considerations are
/// important. Additionally, `buffer_size` limits the maximum byte length of
/// "unsplittable" content, such as element and attribute names (but not
/// "splittable" content, such as element text content and attribute values).
pub fn TokenReader(
    comptime ReaderType: type,
    comptime DecoderType: type,
    comptime options: TokenReaderOptions,
) type {
    return struct {
        scanner: Scanner,
        reader: ReaderType,
        decoder: DecoderType,
        /// Buffered content read by the reader for the current token.
        ///
        /// Events may reference this buffer via slices. The contents of the
        /// buffer (up until `scanner.pos`) are always valid UTF-8.
        buffer: [options.buffer_size]u8 = undefined,
        /// Whether the last codepoint read was a carriage return (`\r`).
        ///
        /// This is relevant for line break normalization.
        after_cr: if (options.enable_normalization) bool else void = if (options.enable_normalization) false,
        /// The length of the raw codepoint data currently stored in `buffer`
        /// starting at `scanner.pos`.
        cp_len: usize = 0,

        const Self = @This();

        pub const Error = error{
            InvalidEncoding,
            Overflow,
            UnexpectedEndOfInput,
        } || ReaderType.Error || DecoderType.Error || Scanner.Error;

        const max_encoded_codepoint_len = @max(DecoderType.max_encoded_codepoint_len, 4);

        pub fn init(reader: ReaderType, decoder: DecoderType) Self {
            return .{
                .scanner = Scanner{},
                .reader = reader,
                .decoder = decoder,
            };
        }

        /// Returns the next token from the input.
        ///
        /// The slices in the returned token are only valid until the next call
        /// to `next`.
        pub fn next(self: *Self) Error!?Token {
            if (self.scanner.pos > 0) {
                // If the scanner position is > 0, that means we emitted an event
                // on the last call to next, and should try to reset the
                // position again in an effort to not run out of buffer space
                // (ideally, the scanner should be resettable after every token,
                // but we do not depend on this).
                if (self.scanner.resetPos()) |token| {
                    if (token != .ok) {
                        return try self.bufToken(token);
                    }
                } else |_| {
                    // Failure to reset isn't fatal (yet); we can still try to
                    // complete the token below
                }
            }

            while (true) {
                if (self.scanner.pos + max_encoded_codepoint_len >= self.buffer.len) {
                    if (self.scanner.resetPos()) |token| {
                        if (token != .ok) {
                            return try self.bufToken(token);
                        }
                    } else |_| {
                        // Failure to reset here still isn't fatal, since we
                        // may end up getting shorter codepoints which manage
                        // to complete the current token.
                    }
                }

                const c = (try self.nextCodepoint()) orelse {
                    try self.scanner.endInput();
                    return null;
                };
                if (!self.decoder.isUtf8Compatible()) {
                    // If the decoder is not compatible with UTF-8, we have to
                    // reencode the codepoint we just read into UTF-8, since
                    // `buffer` must always be valid UTF-8.
                    self.cp_len = unicode.utf8CodepointSequenceLength(c) catch unreachable;
                    if (self.scanner.pos + self.cp_len >= self.buffer.len) {
                        return error.Overflow;
                    }
                    _ = unicode.utf8Encode(c, self.buffer[self.scanner.pos .. self.scanner.pos + self.cp_len]) catch unreachable;
                }
                const token = try self.scanner.next(c, self.cp_len);
                if (token != .ok) {
                    return try self.bufToken(token);
                }
            }
        }

        const nextCodepoint = if (options.enable_normalization) nextCodepointNormalized else nextCodepointRaw;

        fn nextCodepointNormalized(self: *Self) !?u21 {
            var b = (try self.nextCodepointRaw()) orelse return null;
            if (self.after_cr) {
                self.after_cr = false;
                if (b == '\n') {
                    // \n after \r is ignored because \r was already processed
                    // as a line ending
                    b = (try self.nextCodepointRaw()) orelse return null;
                }
            }
            if (b == '\r') {
                self.after_cr = true;
                b = '\n';
                self.buffer[self.scanner.pos] = '\n';
            }
            if (self.scanner.state == .attribute_content and (b == '\t' or b == '\r' or b == '\n')) {
                b = ' ';
                self.buffer[self.scanner.pos] = ' ';
            }
            return b;
        }

        fn nextCodepointRaw(self: *Self) !?u21 {
            self.cp_len = 0;
            var b = self.reader.readByte() catch |e| switch (e) {
                error.EndOfStream => return null,
                else => |other| return other,
            };
            while (true) {
                if (self.scanner.pos + self.cp_len == self.buffer.len) {
                    return error.Overflow;
                }
                self.buffer[self.scanner.pos + self.cp_len] = b;
                self.cp_len += 1;
                if (try self.decoder.next(b)) |c| {
                    return c;
                }
                b = self.reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => return error.UnexpectedEndOfInput,
                    else => |other| return other,
                };
            }
        }

        fn bufToken(self: *Self, token: Scanner.Token) !Token {
            const buf_token: Token = switch (token) {
                .ok => unreachable,
                .xml_declaration => |xml_declaration| .{ .xml_declaration = .{
                    .version = self.bufRange(xml_declaration.version),
                    .encoding = if (xml_declaration.encoding) |enc| self.bufRange(enc) else null,
                    .standalone = xml_declaration.standalone,
                } },
                .element_start => |element_start| .{ .element_start = .{
                    .name = self.bufRange(element_start.name),
                } },
                .element_content => |element_content| .{ .element_content = .{
                    .content = self.bufContent(element_content.content),
                } },
                .element_end => |element_end| .{ .element_end = .{
                    .name = self.bufRange(element_end.name),
                } },
                .element_end_empty => .element_end_empty,
                .attribute_start => |attribute_start| .{ .attribute_start = .{
                    .name = self.bufRange(attribute_start.name),
                } },
                .attribute_content => |attribute_content| .{ .attribute_content = .{
                    .content = self.bufContent(attribute_content.content),
                    .final = attribute_content.final,
                } },
                .comment_start => .comment_start,
                .comment_content => |comment_content| .{ .comment_content = .{
                    .content = self.bufRange(comment_content.content),
                    .final = comment_content.final,
                } },
                .pi_start => |pi_start| .{ .pi_start = .{
                    .target = self.bufRange(pi_start.target),
                } },
                .pi_content => |pi_content| .{ .pi_content = .{
                    .content = self.bufRange(pi_content.content),
                    .final = pi_content.final,
                } },
            };
            if (buf_token == .xml_declaration) {
                if (buf_token.xml_declaration.encoding) |declared_encoding| {
                    try self.decoder.adaptTo(declared_encoding);
                }
            }
            return buf_token;
        }

        inline fn bufContent(self: *const Self, content: Scanner.Token.Content) Token.Content {
            return switch (content) {
                .text => |text| .{ .text = self.bufRange(text) },
                .codepoint => |codepoint| .{ .codepoint = codepoint },
                .entity => |entity| .{ .entity = self.bufRange(entity) },
            };
        }

        inline fn bufRange(self: *const Self, range: Scanner.Range) []const u8 {
            return self.buffer[range.start..range.end];
        }
    };
}

test TokenReader {
    try testValid(.{},
        \\<?xml version="1.0"?>
        \\<?some-pi?>
        \\<!-- A processing instruction with content follows -->
        \\<?some-pi-with-content content?>
        \\<root>
        \\  <p class="test">Hello, <![CDATA[world!]]></p>
        \\  <line />
        \\  <?another-pi?>
        \\  Text content goes here.
        \\  <div><p>&amp;</p></div>
        \\</root>
        \\<!-- Comments are allowed after the end of the root element -->
        \\
        \\<?comment So are PIs ?>
        \\
        \\
    , &.{
        .{ .xml_declaration = .{ .version = "1.0" } },
        .{ .pi_start = .{ .target = "some-pi" } },
        .{ .pi_content = .{ .content = "", .final = true } },
        .comment_start,
        .{ .comment_content = .{ .content = " A processing instruction with content follows ", .final = true } },
        .{ .pi_start = .{ .target = "some-pi-with-content" } },
        .{ .pi_content = .{ .content = "content", .final = true } },
        .{ .element_start = .{ .name = "root" } },
        .{ .element_content = .{ .content = .{ .text = "\n  " } } },
        .{ .element_start = .{ .name = "p" } },
        .{ .attribute_start = .{ .name = "class" } },
        .{ .attribute_content = .{ .content = .{ .text = "test" }, .final = true } },
        .{ .element_content = .{ .content = .{ .text = "Hello, " } } },
        .{ .element_content = .{ .content = .{ .text = "world!" } } },
        .{ .element_end = .{ .name = "p" } },
        .{ .element_content = .{ .content = .{ .text = "\n  " } } },
        .{ .element_start = .{ .name = "line" } },
        .element_end_empty,
        .{ .element_content = .{ .content = .{ .text = "\n  " } } },
        .{ .pi_start = .{ .target = "another-pi" } },
        .{ .pi_content = .{ .content = "", .final = true } },
        .{ .element_content = .{ .content = .{ .text = "\n  Text content goes here.\n  " } } },
        .{ .element_start = .{ .name = "div" } },
        .{ .element_start = .{ .name = "p" } },
        .{ .element_content = .{ .content = .{ .entity = "amp" } } },
        .{ .element_end = .{ .name = "p" } },
        .{ .element_end = .{ .name = "div" } },
        .{ .element_content = .{ .content = .{ .text = "\n" } } },
        .{ .element_end = .{ .name = "root" } },
        .comment_start,
        .{ .comment_content = .{ .content = " Comments are allowed after the end of the root element ", .final = true } },
        .{ .pi_start = .{ .target = "comment" } },
        .{ .pi_content = .{ .content = "So are PIs ", .final = true } },
    });
}

test "normalization" {
    try testValid(.{}, "<root>Line 1\rLine 2\r\nLine 3\nLine 4\n\rLine 6\r\n\rLine 8</root>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .element_content = .{ .content = .{ .text = "Line 1\nLine 2\nLine 3\nLine 4\n\nLine 6\n\nLine 8" } } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testValid(.{}, "<root attr=' Line 1\rLine 2\r\nLine 3\nLine 4\t\tMore    content\n\rLine 6\r\n\rLine 8 '/>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .attribute_start = .{ .name = "attr" } },
        .{ .attribute_content = .{
            .content = .{ .text = " Line 1 Line 2 Line 3 Line 4  More    content  Line 6  Line 8 " },
            .final = true,
        } },
        .element_end_empty,
    });
    try testValid(.{ .enable_normalization = false }, "<root>Line 1\rLine 2\r\nLine 3\nLine 4\n\rLine 6\r\n\rLine 8</root>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .element_content = .{ .content = .{ .text = "Line 1\rLine 2\r\nLine 3\nLine 4\n\rLine 6\r\n\rLine 8" } } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testValid(.{ .enable_normalization = false }, "<root attr=' Line 1\rLine 2\r\nLine 3\nLine 4\t\tMore    content\n\rLine 6\r\n\rLine 8 '/>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .attribute_start = .{ .name = "attr" } },
        .{ .attribute_content = .{
            .content = .{ .text = " Line 1\rLine 2\r\nLine 3\nLine 4\t\tMore    content\n\rLine 6\r\n\rLine 8 " },
            .final = true,
        } },
        .element_end_empty,
    });
}

fn testValid(comptime options: TokenReaderOptions, input: []const u8, expected_tokens: []const Token) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = tokenReader(input_stream.reader(), encoding.Utf8Decoder{}, options);
    var i: usize = 0;
    while (try input_reader.next()) |token| : (i += 1) {
        if (i >= expected_tokens.len) {
            std.debug.print("Unexpected token after end: {}\n", .{token});
            return error.TestFailed;
        }
        testing.expectEqualDeep(expected_tokens[i], token) catch |e| {
            std.debug.print("(at index {})\n", .{i});
            return e;
        };
    }
    if (i != expected_tokens.len) {
        std.debug.print("Expected {} tokens, found {}\n", .{ expected_tokens.len, i });
        return error.TestFailed;
    }
}
