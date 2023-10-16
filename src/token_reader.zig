const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const encoding = @import("encoding.zig");
const Scanner = @import("Scanner.zig");

/// A single XML token.
///
/// For efficiency, this is merely an enum specifying the token type. The actual
/// token data is available in `Token.Data`, in the token reader's `token_data`
/// field. The `fullToken` function can be used to get a `Token.Full`, which is
/// a tagged union type and may be easier to consume in certain circumstances.
pub const Token = enum {
    /// End of file.
    eof,
    /// XML declaration.
    xml_declaration,
    /// Element start tag.
    element_start,
    /// Element content.
    element_content,
    /// Element end tag.
    element_end,
    /// End of an empty element.
    element_end_empty,
    /// Attribute start.
    attribute_start,
    /// Attribute value content.
    attribute_content,
    /// Comment start.
    comment_start,
    /// Comment content.
    comment_content,
    /// Processing instruction (PI) start.
    pi_start,
    /// PI content.
    pi_content,

    /// The data associated with a token.
    ///
    /// Even token types which have no associated data are represented here, to
    /// provide some additional safety in safe build modes (where it can be
    /// checked whether the caller is referencing the correct data field).
    pub const Data = union {
        eof: void,
        xml_declaration: XmlDeclaration,
        element_start: ElementStart,
        element_content: ElementContent,
        element_end: ElementEnd,
        element_end_empty: void,
        attribute_start: AttributeStart,
        attribute_content: AttributeContent,
        comment_start: void,
        comment_content: CommentContent,
        pi_start: PiStart,
        pi_content: PiContent,
    };

    /// A token type plus data represented as a tagged union.
    pub const Full = union(Token) {
        eof,
        xml_declaration: XmlDeclaration,
        element_start: ElementStart,
        element_content: ElementContent,
        element_end: ElementEnd,
        element_end_empty,
        attribute_start: AttributeStart,
        attribute_content: AttributeContent,
        comment_start,
        comment_content: CommentContent,
        pi_start: PiStart,
        pi_content: PiContent,
    };

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

/// A location in a file.
pub const Location = struct {
    /// The line number, starting at 1.
    line: usize = 1,
    /// The column number, starting at 1. Columns are counted using Unicode
    /// codepoints.
    column: usize = 1,
    /// Whether the last character seen was a `\r`.
    after_cr: bool = false,

    /// Advances the location by a single codepoint.
    pub fn advance(self: *Location, c: u21) void {
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
            self.after_cr = false;
        } else if (c == '\r') {
            if (self.after_cr) {
                self.line += 1;
                self.column = 1;
            }
            self.column += 1;
            self.after_cr = true;
        } else if (self.after_cr) {
            self.line += 1;
            // Plain CR line endings cannot be detected as new lines
            // immediately, since they could be followed by LF. The following
            // character is what completes the line ending interpretation.
            self.column = 2;
            self.after_cr = false;
        } else {
            self.column += 1;
        }
    }
};

test Location {
    var loc = Location{};
    try expectLocation(loc, 1, 1);
    loc.advance('A');
    try expectLocation(loc, 1, 2);
    loc.advance('よ');
    try expectLocation(loc, 1, 3);
    loc.advance('🥰');
    try expectLocation(loc, 1, 4);
    loc.advance('\n');
    try expectLocation(loc, 2, 1);
    loc.advance('\r');
    loc.advance('\n');
    try expectLocation(loc, 3, 1);
    loc.advance('\r');
    loc.advance('A');
    try expectLocation(loc, 4, 2);
    loc.advance('\r');
    loc.advance('\r');
    loc.advance('A');
    try expectLocation(loc, 6, 2);
}

fn expectLocation(loc: Location, line: usize, column: usize) !void {
    if (loc.line != line or loc.column != column) {
        std.debug.print("expected {}:{}, found {}:{}", .{ line, column, loc.line, loc.column });
        return error.TestExpectedEqual;
    }
}

/// A drop-in replacement for `Location` which does not actually store location
/// information.
pub const NoOpLocation = struct {
    pub inline fn advance(_: *NoOpLocation, _: u21) void {}
};

/// Wraps a `std.io.Reader` in a `TokenReader` with the default buffer size
/// (4096).
pub fn tokenReader(
    reader: anytype,
    comptime options: TokenReaderOptions,
) TokenReader(@TypeOf(reader), options) {
    return TokenReader(@TypeOf(reader), options).init(reader, .{});
}

/// Options for a `TokenReader`.
pub const TokenReaderOptions = struct {
    /// The type of decoder to use.
    DecoderType: type = encoding.DefaultDecoder,
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
    /// Whether to keep track of the current location in the document.
    track_location: bool = false,
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
pub fn TokenReader(comptime ReaderType: type, comptime options: TokenReaderOptions) type {
    return struct {
        scanner: Scanner,
        reader: ReaderType,
        decoder: options.DecoderType,
        /// The data for the most recently returned token.
        token_data: Token.Data = undefined,
        /// The current location in the file (if enabled).
        location: if (options.track_location) Location else NoOpLocation = .{},
        /// Buffered content read by the reader for the current token.
        ///
        /// Events may reference this buffer via slices. The contents of the
        /// buffer (up until `scanner.pos`) are always valid UTF-8.
        buffer: [options.buffer_size]u8 = undefined,
        /// Whether the last codepoint read was a carriage return (`\r`).
        ///
        /// This is relevant for line break normalization.
        after_cr: if (options.enable_normalization) bool else void = if (options.enable_normalization) false,

        const Self = @This();

        pub const Error = error{
            InvalidEncoding,
            InvalidPiTarget,
            Overflow,
            UnexpectedEndOfInput,
        } || ReaderType.Error || options.DecoderType.Error || Scanner.Error;

        const max_encoded_codepoint_len = @max(options.DecoderType.max_encoded_codepoint_len, 4);

        pub fn init(reader: ReaderType, decoder: options.DecoderType) Self {
            return .{
                .scanner = Scanner{},
                .reader = reader,
                .decoder = decoder,
            };
        }

        /// Returns the full token (including data) from the most recent call to
        /// `next`. `token` must be the token returned from the last call to
        /// `next`.
        pub fn fullToken(self: *const Self, token: Token) Token.Full {
            return switch (token) {
                inline else => |tag| @unionInit(Token.Full, @tagName(tag), @field(self.token_data, @tagName(tag))),
            };
        }

        /// Returns the next token from the input.
        ///
        /// The slices in the `token_data` stored during this call are only
        /// valid until the next call to `next`.
        pub fn next(self: *Self) Error!Token {
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

                const c = try self.nextCodepoint();
                if (!c.present) {
                    try self.scanner.endInput();
                    self.token_data = .{ .eof = {} };
                    return .eof;
                }
                const token = try self.scanner.next(c.codepoint, c.byte_length);
                if (token != .ok) {
                    return try self.bufToken(token);
                }
            }
        }

        const nextCodepoint = if (options.enable_normalization) nextCodepointNormalized else nextCodepointRaw;

        fn nextCodepointNormalized(self: *Self) !encoding.ReadResult {
            var c = try self.nextCodepointRaw();
            if (!c.present) return c;
            if (self.after_cr) {
                self.after_cr = false;
                if (c.codepoint == '\n') {
                    // \n after \r is ignored because \r was already processed
                    // as a line ending
                    c = try self.nextCodepointRaw();
                    if (!c.present) return c;
                }
            }
            if (c.codepoint == '\r') {
                self.after_cr = true;
                c.codepoint = '\n';
                self.buffer[self.scanner.pos] = '\n';
            }
            if (self.scanner.state == .attribute_content and
                (c.codepoint == '\t' or c.codepoint == '\r' or c.codepoint == '\n'))
            {
                c.codepoint = ' ';
                self.buffer[self.scanner.pos] = ' ';
            }
            return c;
        }

        fn nextCodepointRaw(self: *Self) !encoding.ReadResult {
            const c = try self.decoder.readCodepoint(self.reader, self.buffer[self.scanner.pos..]);
            if (c.present) self.location.advance(c.codepoint);
            return c;
        }

        fn bufToken(self: *Self, token: Scanner.Token) !Token {
            switch (token) {
                .ok => unreachable,
                .xml_declaration => {
                    self.token_data = .{ .xml_declaration = .{
                        .version = self.bufRange(self.scanner.token_data.xml_declaration.version),
                        .encoding = if (self.scanner.token_data.xml_declaration.encoding) |enc| self.bufRange(enc) else null,
                        .standalone = self.scanner.token_data.xml_declaration.standalone,
                    } };
                    if (self.token_data.xml_declaration.encoding) |declared_encoding| {
                        try self.decoder.adaptTo(declared_encoding);
                    }
                    return .xml_declaration;
                },
                .element_start => {
                    self.token_data = .{ .element_start = .{
                        .name = self.bufRange(self.scanner.token_data.element_start.name),
                    } };
                    return .element_start;
                },
                .element_content => {
                    self.token_data = .{ .element_content = .{
                        .content = self.bufContent(self.scanner.token_data.element_content.content),
                    } };
                    return .element_content;
                },
                .element_end => {
                    self.token_data = .{ .element_end = .{
                        .name = self.bufRange(self.scanner.token_data.element_end.name),
                    } };
                    return .element_end;
                },
                .element_end_empty => {
                    self.token_data = .{ .element_end_empty = {} };
                    return .element_end_empty;
                },
                .attribute_start => {
                    self.token_data = .{ .attribute_start = .{
                        .name = self.bufRange(self.scanner.token_data.attribute_start.name),
                    } };
                    return .attribute_start;
                },
                .attribute_content => {
                    self.token_data = .{ .attribute_content = .{
                        .content = self.bufContent(self.scanner.token_data.attribute_content.content),
                        .final = self.scanner.token_data.attribute_content.final,
                    } };
                    return .attribute_content;
                },
                .comment_start => {
                    self.token_data = .{ .comment_start = {} };
                    return .comment_start;
                },
                .comment_content => {
                    self.token_data = .{ .comment_content = .{
                        .content = self.bufRange(self.scanner.token_data.comment_content.content),
                        .final = self.scanner.token_data.comment_content.final,
                    } };
                    return .comment_content;
                },
                .pi_start => {
                    const target = self.bufRange(self.scanner.token_data.pi_start.target);
                    if (std.ascii.eqlIgnoreCase(target, "xml")) {
                        return error.InvalidPiTarget;
                    }
                    self.token_data = .{ .pi_start = .{
                        .target = target,
                    } };
                    return .pi_start;
                },
                .pi_content => {
                    self.token_data = .{ .pi_content = .{
                        .content = self.bufRange(self.scanner.token_data.pi_content.content),
                        .final = self.scanner.token_data.pi_content.final,
                    } };
                    return .pi_content;
                },
            }
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

test "PI target" {
    try testValid(.{}, "<?xml version='1.0'?><root><?some-pi?></root>", &.{
        .{ .xml_declaration = .{ .version = "1.0" } },
        .{ .element_start = .{ .name = "root" } },
        .{ .pi_start = .{ .target = "some-pi" } },
        .{ .pi_content = .{ .content = "", .final = true } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testValid(.{}, "<root><?x 2?></root>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .pi_start = .{ .target = "x" } },
        .{ .pi_content = .{ .content = "2", .final = true } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testValid(.{}, "<root><?xm 2?></root>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .pi_start = .{ .target = "xm" } },
        .{ .pi_content = .{ .content = "2", .final = true } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testValid(.{}, "<root><?xml2 2?></root>", &.{
        .{ .element_start = .{ .name = "root" } },
        .{ .pi_start = .{ .target = "xml2" } },
        .{ .pi_content = .{ .content = "2", .final = true } },
        .{ .element_end = .{ .name = "root" } },
    });
    try testInvalid(.{}, "<root><?xml?></root>", error.InvalidPiTarget);
    try testInvalid(.{}, "<root><?XML?></root>", error.InvalidPiTarget);
    try testInvalid(.{}, "<root><?Xml stuff?></root>", error.InvalidPiTarget);
    try testInvalid(.{}, "<root><?xml version='1.0'?></root>", error.InvalidPiTarget);
}

fn testValid(comptime options: TokenReaderOptions, input: []const u8, expected_tokens: []const Token.Full) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = tokenReader(input_stream.reader(), options);
    var i: usize = 0;
    while (true) : (i += 1) {
        const token = try input_reader.next();
        if (token == .eof) break;
        if (i >= expected_tokens.len) {
            std.debug.print("Unexpected token after end: {}\n", .{token});
            return error.TestFailed;
        }
        testing.expectEqualDeep(expected_tokens[i], input_reader.fullToken(token)) catch |e| {
            std.debug.print("(at index {})\n", .{i});
            return e;
        };
    }
    if (i != expected_tokens.len) {
        std.debug.print("Expected {} tokens, found {}\n", .{ expected_tokens.len, i });
        return error.TestFailed;
    }
}

fn testInvalid(comptime options: TokenReaderOptions, input: []const u8, expected_error: anyerror) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = tokenReader(input_stream.reader(), options);
    while (input_reader.next()) |token| {
        if (token == .eof) return error.TestExpectedError;
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}
