//! A simple, low-level streaming XML parser.
//!
//! The design of the parser is strongly inspired by
//! [Yxml](https://dev.yorhel.nl/yxml). Bytes are fed to the parser one by one
//! using the `next` function, then the `endInput` function should be used to
//! check that the parser is in a valid state for the end of input (e.g. not in
//! the middle of parsing an element). The tokens returned by the parser
//! reference the input data using byte positions.
//!
//! Intentional (permanent) limitations (which can be addressed by
//! higher-level APIs):
//!
//! - Only supports ASCII-compatible encodings, and does not validate
//!   correctness of byte values >= 128 (for example, any byte value >= 128 is
//!   considered valid in names and text content, and is not validated to be
//!   valid UTF-8 or any other encoding).
//! - Does not validate that corresponding open and close tags match.
//! - Does not validate that attribute names are not duplicated.
//! - Does not do any special handling of namespaces.
//! - Does not perform any sort of processing on text content or attribute
//!   values (including normalization, expansion of entities, etc.).
//!   - However, note that entity and character references in text content and
//!     attribute values _are_ validated for correct syntax, although their
//!     content is not (they may reference non-existent entities or
//!     out-of-bounds characters).
//! - Does not process DTDs in any way besides parsing them (TODO: see below).
//!
//! Unintentional (temporary) limitations (which will be removed over time):
//!
//! - Does not support `DOCTYPE` at all (using one will result in an error).
//! - Need to evaluate to what extent XML 1.1 can be supported within the
//!   constraints of this design (e.g. non-ASCII whitespace will definitely not
//!   be supported, but other stuff might work).
//! - Entity references in text content and attribute values are not validated
//!   (while this parser will never expand such references, they should be
//!   validated and represented in the state machine).
//! - Some validations (e.g. of XML declaration contents) are not as strict as
//!   they reasonably could/should be within the constraints of this design
//!   (e.g. the version number is not validated to match `1.[0-9]+`).
//! - Not extensively tested/fuzzed.

/// The current state of the scanner.
state: State = .start,
/// The current byte position in the input.
///
/// This is not necessarily the byte position relative to the start of the
/// document: see the `resetPos` function and the documentation of `Token`.
pos: usize = 0,
/// The current element nesting depth.
depth: usize = 0,
/// Whether the root element has been seen already.
seen_root_element: bool = false,

const std = @import("std");
const testing = std.testing;

const Scanner = @This();

/// A range of byte positions in the input.
pub const Range = struct {
    /// The start of the range (inclusive).
    start: usize,
    /// The end of the range (exclusive).
    end: usize,

    pub fn isEmpty(self: Range) bool {
        return self.start == self.end;
    }

    pub fn format(self: Range, _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}..{}", .{ self.start, self.end });
    }
};

/// A bit of content of an element or attribute.
pub const Content = union(enum) {
    /// Raw text content (does not contain any entities).
    text: Range,
    /// An entity reference, such as `&amp;`. The range covers the name (`amp`).
    entity_ref: Range,
    /// A decimal character reference, such as `&#32;`. The range covers the number (`32`).
    char_ref_dec: Range,
    /// A hexadecimal character reference, such as `&#x20`. The range covers the number (`20`).
    char_ref_hex: Range,
};

/// A single XML token.
///
/// The choice of tokens is designed to allow the buffer position to be reset as
/// often as reasonably possible ("forgetting" any range information before the
/// reset), supported by the following design decisions:
///
/// - Tokens contain only the immediately necessary context: for example, the
///   `attribute_content` token does not store any information about the
///   attribute name, since it may have been processed many resets ago (if the
///   attribute content is very long).
/// - Multiple `content` tokens may be returned for a single enclosing context
///   (e.g. element or attribute) if the buffer is reset in the middle of
///   content or there are other necessary intervening factors, such as CDATA
///   in the middle of normal (non-CDATA) element content.
///
/// Note also that there are no explicit `end` tokens except for elements,
/// since other constructs cannot nest, so the structure is never unclear (and
/// because otherwise the `next` function would sometimes need to return more
/// than one token, which it can't).
pub const Token = union(enum) {
    /// Continue processing: no new token to report yet.
    ok,
    /// XML declaration.
    xml_declaration: struct { version: Range, encoding: ?Range = null, standalone: ?Range = null },
    /// Element start tag.
    element_start: struct { name: Range },
    /// Element content.
    element_content: struct { content: Content },
    /// Element end tag.
    element_end: struct { name: Range },
    /// End of an empty element.
    element_end_empty,
    /// Attribute start.
    attribute_start: struct { name: Range },
    /// Attribute value content.
    attribute_content: struct { content: Content },
    /// Comment start.
    comment_start,
    /// Comment content.
    comment_content: struct { content: Range },
    /// Processing instruction (PI) start.
    pi_start: struct { target: Range },
    /// PI content.
    pi_content: struct { content: Range },
};

/// The possible states of the parser.
///
/// The parser is designed as a state machine. A state may need to hold
/// associated data to allow the necessary information to be included in a
/// future token. One shortcut used to avoid creating many unnecessary
/// additional states is to store a `left` byte slice tracking expected bytes
/// remaining in a state (the slice is always pointing to static strings, so
/// there are no lifetime considerations): for example, the word "version" in
/// an XML declaration is parsed in the xml_decl_version_name state, and
/// successive bytes are validated using the `left` slice (e.g. after parsing
/// "v", left is "ersion", so that when we handle the next character, we can
/// fail parsing if it is not "e", and then set `left` to "rsion", and so on).
const State = union(enum) {
    /// Start of document.
    start,

    /// Same as unknown_start, but also allows the xml and doctype declarations.
    unknown_document_start,
    /// Start of a PI or XML declaration after '<?'.
    pi_or_xml_decl_start: struct { start: usize, xml_left: []const u8 },

    /// XML declaration after '<?xml '.
    xml_decl,
    /// XML declaration within 'version'.
    xml_decl_version_name: struct { left: []const u8 },
    /// XML declaration after 'version'.
    xml_decl_after_version_name,
    /// XML declaration after '=' in version info.
    xml_decl_after_version_equals,
    /// XML declaration version value.
    xml_decl_version_value: struct { start: usize, quote: u8 },
    /// XML declaration after version info.
    xml_decl_after_version: struct { version: Range },
    /// XML declaration within 'encoding'.
    xml_decl_encoding_name: struct { version: Range, left: []const u8 },
    /// XML declaration after 'encoding'.
    xml_decl_after_encoding_name: struct { version: Range },
    /// XML declaration after '=' in encoding declaration.
    xml_decl_after_encoding_equals: struct { version: Range },
    /// XML declaration encoding declaration value.
    xml_decl_encoding_value: struct { version: Range, start: usize, quote: u8 },
    /// XML declaration after encoding declaration.
    xml_decl_after_encoding: struct { version: Range, encoding: ?Range },
    /// XML declaration within 'standalone'.
    xml_decl_standalone_name: struct { version: Range, encoding: ?Range, left: []const u8 },
    /// XML declaration after 'standalone'.
    xml_decl_after_standalone_name: struct { version: Range, encoding: ?Range },
    /// XML declaration after '=' in standalone declaration.
    xml_decl_after_standalone_equals: struct { version: Range, encoding: ?Range },
    /// XML declaration standalone declaration value.
    xml_decl_standalone_value: struct { version: Range, encoding: ?Range, start: usize, quote: u8 },
    /// XML declaration after standalone declaration.
    xml_decl_after_standalone,
    /// End of XML declaration after '?'.
    xml_decl_end,
    /// Start of document after XML declaration.
    start_after_xml_decl,

    /// A '<' has been encountered, but we don't know if it's an element, comment, etc.
    unknown_start,
    /// A '<!' has been encountered.
    unknown_start_bang,

    /// A '<!-' has been encountered.
    comment_before_start,
    /// Comment.
    comment: struct { start: usize },
    /// Comment after consuming one '-'.
    comment_maybe_before_end: struct { start: usize },
    /// Comment after consuming '--'.
    comment_before_end,

    /// PI after '<?'.
    pi,
    /// In PI target name.
    pi_target: struct { start: usize },
    /// After PI target.
    pi_after_target,
    /// In PI content after target name.
    pi_content: struct { start: usize },
    /// Possible end of PI after '?'.
    pi_maybe_end: struct { start: usize },

    /// A '<![' (and possibly some part of 'CDATA[' after it) has been encountered.
    cdata_before_start: struct { left: []const u8 },
    /// CDATA.
    cdata: struct { start: usize },
    /// In CDATA content after some part of ']]>'.
    cdata_maybe_end: struct { start: usize, left: []const u8 },

    /// Name of element start tag.
    element_start_name: struct { start: usize },
    /// In element start tag after name (and possibly after one or more attributes).
    element_start_after_name,
    /// In element start tag after encountering '/' (indicating an empty element).
    element_start_empty,

    /// Attribute name.
    attribute_name: struct { start: usize },
    /// After attribute name but before '='.
    attribute_after_name,
    /// After attribute '='.
    attribute_after_equals,
    /// Attribute value.
    ///
    /// The `quote` field is intended to avoid duplication of states into
    /// single-quote and double-quote variants.
    attribute_content: struct { start: usize, quote: u8 },
    /// Attribute value after encountering '&'.
    attribute_content_ref_start: struct { quote: u8 },
    /// Attribute value within an entity reference name.
    attribute_content_entity_ref_name: struct { start: usize, quote: u8 },
    /// Attribute value after encountering '&#'.
    attribute_content_char_ref_start: struct { quote: u8 },
    /// Attribute value within a decimal character reference.
    attribute_content_char_ref_dec: struct { start: usize, quote: u8 },
    /// Attribute value within a hex character reference.
    attribute_content_char_ref_hex: struct { start: usize, quote: u8 },

    /// Element end tag after consuming '</'.
    element_end,
    /// Name of element end tag.
    element_end_name: struct { start: usize },
    /// In element end tag after name.
    element_end_after_name,

    /// Element content (text).
    content: struct { start: usize },
    /// Element content after encountering '&'.
    content_ref_start,
    /// Element content within an entity reference name.
    content_entity_ref_name: struct { start: usize },
    /// Element content after encountering '&#'.
    content_char_ref_start,
    /// Element content within a decimal character reference.
    content_char_ref_dec: struct { start: usize },
    /// Element content within a hex character reference.
    content_char_ref_hex: struct { start: usize },

    /// A syntax error has been encountered.
    ///
    /// This is for safety, since the parser has no error recovery: to avoid
    /// invalid tokens being emitted, the parser is put in this state after any
    /// syntax error, and will always emit a syntax error in this state.
    @"error",
};

/// Accepts a single byte of input, returning the token found or an error.
pub inline fn next(self: *Scanner, c: u8) error{SyntaxError}!Token {
    const token = self.nextNoAdvance(c) catch |e| {
        self.state = .@"error";
        return e;
    };
    self.pos += 1;
    return token;
}

/// Returns the next token (or an error) without advancing the internal
/// position (which should only be advanced in case of success: basically this
/// function is needed because Zig has no "successdefer" to advance `pos` only
/// in case of success).
fn nextNoAdvance(self: *Scanner, c: u8) error{SyntaxError}!Token {
    switch (self.state) {
        .start => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_document_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_document_start => if (isNameStartChar(c)) {
            self.state = .{ .element_start_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_or_xml_decl_start = .{ .start = self.pos + 1, .xml_left = "xml " } };
            return .ok;
        } else if (c == '!') {
            // TODO: doctype
            self.state = .unknown_start_bang;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_or_xml_decl_start => |state| if (c == state.xml_left[0]) {
            if (state.xml_left.len == 1) {
                self.state = .xml_decl;
            } else {
                self.state = .{ .pi_or_xml_decl_start = .{ .start = state.start, .xml_left = state.xml_left[1..] } };
            }
            return .ok;
        } else if (isNameStartChar(c) or (isNameChar(c) and self.pos > state.start)) {
            self.state = .{ .pi_target = .{ .start = state.start } };
            return .ok;
        } else if (isSpaceChar(c) and self.pos > state.start) {
            self.state = .pi_after_target;
            return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '?' and self.pos > state.start) {
            self.state = .{ .pi_maybe_end = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == 'v') {
            self.state = .{ .xml_decl_version_name = .{ .left = "ersion" } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_name => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .xml_decl_after_version_name;
            } else {
                self.state = .{ .xml_decl_version_name = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version_name => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .xml_decl_after_version_equals;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version_equals => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .xml_decl_version_value = .{ .start = self.pos + 1, .quote = c } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_value => |state| if (c == state.quote) {
            self.state = .{ .xml_decl_after_version = .{ .version = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == 'e') {
            self.state = .{ .xml_decl_encoding_name = .{ .version = state.version, .left = "ncoding" } };
            return .ok;
        } else if (c == 's') {
            self.state = .{ .xml_decl_standalone_name = .{ .version = state.version, .encoding = null, .left = "tandalone" } };
            return .ok;
        } else if (c == '?') {
            self.state = .xml_decl_end;
            return .{ .xml_declaration = .{ .version = state.version, .encoding = null, .standalone = null } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_name => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .xml_decl_after_encoding_name = .{ .version = state.version } };
            } else {
                self.state = .{ .xml_decl_encoding_name = .{ .version = state.version, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding_name => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .{ .xml_decl_after_encoding_equals = .{ .version = state.version } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding_equals => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .xml_decl_encoding_value = .{ .version = state.version, .start = self.pos + 1, .quote = c } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_value => |state| if (c == state.quote) {
            self.state = .{ .xml_decl_after_encoding = .{ .version = state.version, .encoding = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == 's') {
            self.state = .{ .xml_decl_standalone_name = .{ .version = state.version, .encoding = state.encoding, .left = "tandalone" } };
            return .ok;
        } else if (c == '?') {
            self.state = .xml_decl_end;
            return .{ .xml_declaration = .{ .version = state.version, .encoding = state.encoding, .standalone = null } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_name => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .xml_decl_after_standalone_name = .{ .version = state.version, .encoding = state.encoding } };
            } else {
                self.state = .{ .xml_decl_standalone_name = .{ .version = state.version, .encoding = state.encoding, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone_name => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .{ .xml_decl_after_standalone_equals = .{ .version = state.version, .encoding = state.encoding } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone_equals => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .xml_decl_standalone_value = .{ .version = state.version, .encoding = state.encoding, .start = self.pos + 1, .quote = c } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value => |state| if (c == state.quote) {
            self.state = .xml_decl_after_standalone;
            return .{ .xml_declaration = .{ .version = state.version, .encoding = state.encoding, .standalone = .{ .start = state.start, .end = self.pos } } };
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '?') {
            self.state = .xml_decl_end;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_end => if (c == '>') {
            self.state = .start_after_xml_decl;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .start_after_xml_decl => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_start => if (isNameStartChar(c) and !self.seen_root_element) {
            self.state = .{ .element_start_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '/' and self.depth > 0) {
            self.state = .element_end;
            return .ok;
        } else if (c == '!') {
            self.state = .unknown_start_bang;
            return .ok;
        } else if (c == '?') {
            self.state = .pi;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_start_bang => if (c == '-') {
            self.state = .comment_before_start;
            return .ok;
        } else if (self.depth > 0 and c == '[') {
            // Textual content is not allowed outside the root element.
            self.state = .{ .cdata_before_start = .{ .left = "CDATA[" } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_start => if (c == '-') {
            self.state = .{ .comment = .{ .start = self.pos + 1 } };
            return .comment_start;
        } else {
            return error.SyntaxError;
        },

        .comment => |state| if (c == '-') {
            self.state = .{ .comment_maybe_before_end = .{ .start = state.start } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_maybe_before_end => |state| if (c == '-') {
            const range = Range{ .start = state.start, .end = self.pos - 1 };
            self.state = .comment_before_end;
            if (range.isEmpty()) {
                return .ok;
            } else {
                return .{ .comment_content = .{ .content = .{ .start = state.start, .end = self.pos - 1 } } };
            }
        } else if (isValidChar(c)) {
            self.state = .{ .comment = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_end => if (c == '>') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi => if (isNameStartChar(c)) {
            self.state = .{ .pi_target = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_target => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            self.state = .pi_after_target;
            return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .start = self.pos } };
            return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .pi_after_target => if (isSpaceChar(c)) {
            return .ok;
        } else if (isValidChar(c)) {
            self.state = .{ .pi_content = .{ .start = self.pos } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_content => |state| if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .start = state.start } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_maybe_end => |state| if (c == '>') {
            const range = Range{ .start = state.start, .end = self.pos - 1 };
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            if (range.isEmpty()) {
                return .ok;
            } else {
                return .{ .pi_content = .{ .content = range } };
            }
        } else if (isValidChar(c)) {
            self.state = .{ .pi_content = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_before_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .cdata = .{ .start = self.pos + 1 } };
            } else {
                self.state = .{ .cdata_before_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata => |state| if (c == ']') {
            self.state = .{ .cdata_maybe_end = .{ .start = state.start, .left = "]>" } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_maybe_end => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .content = .{ .start = self.pos + 1 } };
                return .{ .element_content = .{ .content = .{ .text = .{ .start = state.start, .end = self.pos - "]]".len } } } };
            } else {
                self.state = .{ .cdata_maybe_end = .{ .start = state.start, .left = state.left[1..] } };
                return .ok;
            }
        } else if (isValidChar(c)) {
            self.state = .{ .cdata = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .element_start_after_name;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '/') {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .element_start_empty;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .element_start_after_name => if (isSpaceChar(c)) {
            return .ok;
        } else if (isNameStartChar(c)) {
            self.state = .{ .attribute_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '/') {
            self.state = .element_start_empty;
            return .ok;
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_empty => if (c == '>') {
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .element_end_empty;
        } else {
            return error.SyntaxError;
        },

        .attribute_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            self.state = .attribute_after_name;
            return .{ .attribute_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '=') {
            self.state = .attribute_after_equals;
            return .{ .attribute_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .attribute_after_name => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .attribute_after_equals;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_after_equals => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .attribute_content = .{ .start = self.pos + 1, .quote = c } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content => |state| if (c == state.quote) {
            const range = Range{ .start = state.start, .end = self.pos };
            self.state = .element_start_after_name;
            if (range.isEmpty()) {
                return .ok;
            } else {
                return .{ .attribute_content = .{ .content = .{ .text = range } } };
            }
        } else if (c == '&') {
            const range = Range{ .start = state.start, .end = self.pos };
            self.state = .{ .attribute_content_ref_start = .{ .quote = state.quote } };
            if (range.isEmpty()) {
                return .ok;
            } else {
                return .{ .attribute_content = .{ .content = .{ .text = range } } };
            }
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_ref_start => |state| if (isNameStartChar(c)) {
            self.state = .{ .attribute_content_entity_ref_name = .{ .start = self.pos, .quote = state.quote } };
            return .ok;
        } else if (c == '#') {
            self.state = .{ .attribute_content_char_ref_start = .{ .quote = state.quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_entity_ref_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_content = .{ .start = self.pos + 1, .quote = state.quote } };
            return .{ .attribute_content = .{ .content = .{ .entity_ref = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref_start => |state| if (isDigitChar(c)) {
            self.state = .{ .attribute_content_char_ref_dec = .{ .start = self.pos, .quote = state.quote } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .attribute_content_char_ref_hex = .{ .start = self.pos + 1, .quote = state.quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref_dec => |state| if (isDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_content = .{ .start = self.pos + 1, .quote = state.quote } };
            return .{ .attribute_content = .{ .content = .{ .char_ref_dec = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref_hex => |state| if (isHexDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_content = .{ .start = self.pos + 1, .quote = state.quote } };
            return .{ .attribute_content = .{ .content = .{ .char_ref_hex = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .element_end => if (isNameStartChar(c)) {
            self.state = .{ .element_end_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_end_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            self.state = .element_end_after_name;
            return .{ .element_end = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_end = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .element_end_after_name => if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content => |state| if (c == '<') {
            self.state = .unknown_start;
            const range = Range{ .start = state.start, .end = self.pos };
            if (self.depth == 0 or range.isEmpty()) {
                // Do not report empty text content between elements, e.g.
                // <e1></e1><e2></e2> (there is no text content between or
                // within e1 and e2). Also do not report text content outside
                // the root element (which will just be whitespace).
                return .ok;
            } else {
                return .{ .element_content = .{ .content = .{ .text = range } } };
            }
        } else if (self.depth > 0 and c == '&') {
            const range = Range{ .start = state.start, .end = self.pos };
            self.state = .content_ref_start;
            if (range.isEmpty()) {
                return .ok;
            } else {
                return .{ .element_content = .{ .content = .{ .text = range } } };
            }
        } else if (self.depth > 0 and isValidChar(c)) {
            // Textual content is not allowed outside the root element.
            return .ok;
        } else if (isSpaceChar(c)) {
            // Spaces are allowed outside the root element. Another check in
            // this state will prevent a text token from being emitted at the
            // end of the whitespace.
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_ref_start => if (isNameStartChar(c)) {
            self.state = .{ .content_entity_ref_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '#') {
            self.state = .content_char_ref_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_entity_ref_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_content = .{ .content = .{ .entity_ref = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_start => if (isDigitChar(c)) {
            self.state = .{ .content_char_ref_dec = .{ .start = self.pos } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .content_char_ref_hex = .{ .start = self.pos + 1 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_dec => |state| if (isDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_content = .{ .content = .{ .char_ref_dec = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_hex => |state| if (isHexDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_content = .{ .content = .{ .char_ref_hex = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .@"error" => return error.SyntaxError,
    }
}

/// Signals that there is no further input to scan, and returns an error if
/// the scanner is not in a valid state to handle this (for example, if this
/// is called while in the middle of element content).
pub fn endInput(self: *Scanner) error{UnexpectedEndOfInput}!void {
    if (self.state != .content or self.depth != 0 or !self.seen_root_element) {
        return error.UnexpectedEndOfInput;
    }
}

inline fn isValidChar(c: u8) bool {
    return switch (c) {
        '\t', '\r', '\n', ' '...255 => true,
        else => false,
    };
}

inline fn isSpaceChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

inline fn isDigitChar(c: u8) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

inline fn isHexDigitChar(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

inline fn isNameStartChar(c: u8) bool {
    return switch (c) {
        ':', 'A'...'Z', '_', 'a'...'z', 128...255 => true,
        else => false,
    };
}

inline fn isNameChar(c: u8) bool {
    return if (isNameStartChar(c)) true else switch (c) {
        '-', '.', '0'...'9' => true,
        else => false,
    };
}

test "empty root element" {
    try testValid("<element/>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .element_end_empty,
    });
    try testValid("<element />", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .element_end_empty,
    });
}

test "root element with no content" {
    try testValid("<element></element>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .element_end = .{ .name = .{ .start = 11, .end = 18 } } },
    });
}

test "element content" {
    try testValid("<message>Hello, world!</message>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 9, .end = 22 } } } },
        .{ .element_end = .{ .name = .{ .start = 24, .end = 31 } } },
    });
}

test "XML declaration" {
    try testValid(
        \\<?xml version="1.0"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 } } },
        .{ .element_start = .{ .name = .{ .start = 23, .end = 27 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 } } },
        .{ .element_start = .{ .name = .{ .start = 25, .end = 29 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0" encoding = "UTF-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .encoding = .{ .start = 34, .end = 39 } } },
        .{ .element_start = .{ .name = .{ .start = 44, .end = 48 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .standalone = .{ .start = 32, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .standalone = .{ .start = 36, .end = 39 } } },
        .{ .element_start = .{ .name = .{ .start = 44, .end = 48 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 }, .standalone = .{ .start = 49, .end = 52 } } },
        .{ .element_start = .{ .name = .{ .start = 57, .end = 61 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0" encoding = "UTF-8" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .encoding = .{ .start = 34, .end = 39 }, .standalone = .{ .start = 55, .end = 58 } } },
        .{ .element_start = .{ .name = .{ .start = 63, .end = 67 } } },
        .element_end_empty,
    });
}

test "references" {
    try testValid(
        \\<element attribute="Hello&#x2C;&#32;world &amp; friends!">&lt;Hi&#33;&#x21;&gt;</element>
    , &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .attribute_start = .{ .name = .{ .start = 9, .end = 18 } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 20, .end = 25 } } } },
        .{ .attribute_content = .{ .content = .{ .char_ref_hex = .{ .start = 28, .end = 30 } } } },
        .{ .attribute_content = .{ .content = .{ .char_ref_dec = .{ .start = 33, .end = 35 } } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 36, .end = 42 } } } },
        .{ .attribute_content = .{ .content = .{ .entity_ref = .{ .start = 43, .end = 46 } } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 47, .end = 56 } } } },
        .{ .element_content = .{ .content = .{ .entity_ref = .{ .start = 59, .end = 61 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 62, .end = 64 } } } },
        .{ .element_content = .{ .content = .{ .char_ref_dec = .{ .start = 66, .end = 68 } } } },
        .{ .element_content = .{ .content = .{ .char_ref_hex = .{ .start = 72, .end = 74 } } } },
        .{ .element_content = .{ .content = .{ .entity_ref = .{ .start = 76, .end = 78 } } } },
        .{ .element_end = .{ .name = .{ .start = 81, .end = 88 } } },
    });
}

test "complex document" {
    try testValid(
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
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 } } },
        .{ .pi_start = .{ .target = .{ .start = 24, .end = 31 } } }, // some-pi
        .comment_start,
        .{ .comment_content = .{ .content = .{ .start = 38, .end = 85 } } },
        .{ .pi_start = .{ .target = .{ .start = 91, .end = 111 } } }, // some-pi-with-content
        .{ .pi_content = .{ .content = .{ .start = 112, .end = 119 } } },
        .{ .element_start = .{ .name = .{ .start = 123, .end = 127 } } }, // root
        .{ .element_content = .{ .content = .{ .text = .{ .start = 128, .end = 131 } } } },
        .{ .element_start = .{ .name = .{ .start = 132, .end = 133 } } }, // p
        .{ .attribute_start = .{ .name = .{ .start = 134, .end = 139 } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 141, .end = 145 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 147, .end = 154 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 163, .end = 169 } } } },
        .{ .element_end = .{ .name = .{ .start = 174, .end = 175 } } }, // /p
        .{ .element_content = .{ .content = .{ .text = .{ .start = 176, .end = 179 } } } },
        .{ .element_start = .{ .name = .{ .start = 180, .end = 184 } } }, // line
        .element_end_empty,
        .{ .element_content = .{ .content = .{ .text = .{ .start = 187, .end = 190 } } } },
        .{ .pi_start = .{ .target = .{ .start = 192, .end = 202 } } }, // another-pi
        .{ .element_content = .{ .content = .{ .text = .{ .start = 204, .end = 233 } } } },
        .{ .element_start = .{ .name = .{ .start = 234, .end = 237 } } }, // div
        .{ .element_start = .{ .name = .{ .start = 239, .end = 240 } } }, // p
        .{ .element_content = .{ .content = .{ .entity_ref = .{ .start = 242, .end = 245 } } } },
        .{ .element_end = .{ .name = .{ .start = 248, .end = 249 } } }, // /p
        .{ .element_end = .{ .name = .{ .start = 252, .end = 255 } } }, // /div
        .{ .element_content = .{ .content = .{ .text = .{ .start = 256, .end = 257 } } } },
        .{ .element_end = .{ .name = .{ .start = 259, .end = 263 } } }, // /root
        .comment_start,
        .{ .comment_content = .{ .content = .{ .start = 269, .end = 325 } } },
        .{ .pi_start = .{ .target = .{ .start = 332, .end = 339 } } }, // comment
        .{ .pi_content = .{ .content = .{ .start = 340, .end = 351 } } },
    });
}

test "invalid top-level text" {
    try testInvalid("Hello, world!", 0);
    try testInvalid(
        \\<?xml version="1.0"?>
        \\Hello, world!
    , 22);
    try testInvalid(
        \\<root />
        \\Hello, world!
    , 9);
}

test "invalid XML declaration" {
    // TODO: be stricter about not allowing xml as a PI target so this will fail:
    // try testInvalid("<?xml?>", 5);
    try testInvalid("<? xml version='1.0' ?>", 2);
    try testInvalid("<?xml version='1.0' standalone='yes' encoding='UTF-8'?>", 37);
}

test "invalid references" {
    try testInvalid("<element>&</element>", 10);
    try testInvalid("<element>&amp</element>", 13);
    try testInvalid("<element>&#ABC;</element>", 11);
    try testInvalid("<element>&#12C;</element>", 13);
    try testInvalid("<element>&#xxx;</element>", 12);
    try testInvalid("<element attr='&' />", 16);
    try testInvalid("<element attr='&amp' />", 19);
    try testInvalid("<element attr='&#ABC' />", 17);
    try testInvalid("<element attr='&#12C' />", 19);
    try testInvalid("<element attr='&#xxx' />", 18);
}

test "missing root element" {
    try testIncomplete("");
    try testIncomplete("<?xml version=\"1.0\"?>");
}

test "incomplete document" {
    try testIncomplete("<");
    try testIncomplete("<root");
    try testIncomplete("<root>");
    try testIncomplete("<root/");
    try testIncomplete("<root></root");
}

fn testValid(input: []const u8, expected_tokens: []const Token) !void {
    var scanner = Scanner{};
    var tokens = std.ArrayListUnmanaged(Token){};
    defer tokens.deinit(testing.allocator);
    for (input) |c| {
        const token = scanner.next(c) catch |e| switch (e) {
            error.SyntaxError => {
                std.debug.print("syntax error at char '{}' position {}\n", .{ std.fmt.fmtSliceEscapeLower(&.{c}), scanner.pos });
                return e;
            },
        };
        if (token != .ok) {
            try tokens.append(testing.allocator, token);
        }
    }
    try scanner.endInput();
    try testing.expectEqualSlices(Token, expected_tokens, tokens.items);
}

fn testInvalid(input: []const u8, expected_error_pos: usize) !void {
    var scanner = Scanner{};
    for (input) |c| {
        _ = scanner.next(c) catch |e| switch (e) {
            error.SyntaxError => {
                try testing.expectEqual(expected_error_pos, scanner.pos);
                return;
            },
        };
    }
    return error.TextExpectedError;
}

fn testIncomplete(input: []const u8) !void {
    var scanner = Scanner{};
    for (input) |c| {
        _ = try scanner.next(c);
    }
    try testing.expectError(error.UnexpectedEndOfInput, scanner.endInput());
}

/// Attempts to reset the `pos` of the scanner to 0.
///
/// This may require a token to be emitted with range information which will be
/// lost after resetting `pos`: for example, calling this function in the
/// middle of text content (of an element, attribute, etc.) will return a token
/// consisting of the text content encountered so far. This token will use a
/// range corresponding to `pos` _before the reset_, so the buffer backing the
/// underlying data cannot be cleared until the token is processed. If no token
/// needs to be emitted, `Token.ok` is returned.
pub fn resetPos(self: *Scanner) error{CannotReset}!Token {
    const token: Token = switch (self.state) {
        // States which contain no positional information can be reset at any
        // time with no additional token
        .start,

        .unknown_document_start,

        .xml_decl,
        .xml_decl_version_name,
        .xml_decl_after_version_name,
        .xml_decl_after_version_equals,
        .xml_decl_after_standalone,
        .xml_decl_end,
        .start_after_xml_decl,

        .unknown_start,
        .unknown_start_bang,

        .comment_before_start,
        .comment_before_end,

        .pi,
        .pi_after_target,

        .cdata_before_start,

        .element_start_after_name,
        .element_start_empty,

        .attribute_after_name,
        .attribute_after_equals,
        .attribute_content_ref_start,
        .attribute_content_char_ref_start,

        .element_end,
        .element_end_after_name,

        .content_ref_start,
        .content_char_ref_start,

        .@"error",
        => .ok,

        // States which contain positional information but cannot immediately
        // be emitted as a token cannot be reset
        .pi_or_xml_decl_start,

        .xml_decl_version_value,
        .xml_decl_after_version,
        .xml_decl_encoding_name,
        .xml_decl_after_encoding_name,
        .xml_decl_after_encoding_equals,
        .xml_decl_encoding_value,
        .xml_decl_after_encoding,
        .xml_decl_standalone_name,
        .xml_decl_after_standalone_name,
        .xml_decl_after_standalone_equals,
        .xml_decl_standalone_value,

        // None of the "maybe_end" states can be reset because we don't know if
        // the resulting content token should include the possible ending
        // characters until we read further to unambiguously determine whether
        // the state is ending.
        .comment_maybe_before_end,

        .pi_target,
        .pi_maybe_end,

        .cdata_maybe_end,

        .element_start_name,

        .attribute_name,
        .attribute_content_entity_ref_name,
        .attribute_content_char_ref_dec,
        .attribute_content_char_ref_hex,

        .element_end_name,

        .content_entity_ref_name,
        .content_char_ref_dec,
        .content_char_ref_hex,
        => return error.CannotReset,

        // Some states (specifically, content states) can be reset by emitting
        // a token with the content seen so far
        .comment => |*state| token: {
            const range = Range{ .start = state.start, .end = self.pos };
            state.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .comment_content = .{ .content = range } };
            }
        },

        .pi_content => |*state| token: {
            const range = Range{ .start = state.start, .end = self.pos };
            state.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .pi_content = .{ .content = range } };
            }
        },

        .cdata => |*state| token: {
            const range = Range{ .start = state.start, .end = self.pos };
            state.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .element_content = .{ .content = .{ .text = range } } };
            }
        },

        .attribute_content => |*state| token: {
            const range = Range{ .start = state.start, .end = self.pos };
            state.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .attribute_content = .{ .content = .{ .text = range } } };
            }
        },

        .content => |*state| token: {
            const range = Range{ .start = state.start, .end = self.pos };
            state.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .element_content = .{ .content = .{ .text = range } } };
            }
        },
    };
    self.pos = 0;
    return token;
}

test "resetPos inside element content" {
    var scanner = Scanner{};
    var tokens = std.ArrayListUnmanaged(Token){};
    defer tokens.deinit(testing.allocator);

    for ("<element>Hello,") |c| {
        switch (try scanner.next(c)) {
            .ok => {},
            else => |token| try tokens.append(testing.allocator, token),
        }
    }
    try tokens.append(testing.allocator, try scanner.resetPos());
    for (" world!</element>") |c| {
        switch (try scanner.next(c)) {
            .ok => {},
            else => |token| try tokens.append(testing.allocator, token),
        }
    }

    try testing.expectEqualSlices(Token, &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 9, .end = 15 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 0, .end = 7 } } } },
        .{ .element_end = .{ .name = .{ .start = 9, .end = 16 } } },
    }, tokens.items);
}

test "resetPos inside element reference name" {
    var scanner = Scanner{};

    for ("<element>Hello, world &am") |c| {
        _ = try scanner.next(c);
    }
    try testing.expectError(error.CannotReset, scanner.resetPos());
}
