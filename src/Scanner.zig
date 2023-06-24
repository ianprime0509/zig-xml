//! A simple, low-level streaming XML parser.
//!
//! The design of the parser is strongly inspired by
//! [Yxml](https://dev.yorhel.nl/yxml). Codepoints are fed to the parser one by one
//! using the `next` function, then the `endInput` function should be used to
//! check that the parser is in a valid state for the end of input (e.g. not in
//! the middle of parsing an element). The tokens returned by the parser
//! reference the input data using `pos` ranges (the meaning of `pos` depends
//! on the meaning of the `len` passed to `next`).
//!
//! A higher-level parser which wants to do anything useful with the returned
//! tokens will need to store the input text fed to the `next` function in some
//! sort of buffer. If the document is stored entirely in memory, this buffer
//! could be the document content itself. If the document is being read in a
//! streaming manner, however, then an auxiliary buffer will be needed. To
//! avoid requiring such higher-level APIs to maintain an unbounded input
//! buffer, the `resetPos` function exists to reset `pos` to 0, if possible.
//! The approach taken by `TokenReader` is to call `resetPos` after every
//! token, and after reaching a state where space for a further codepoint is
//! not guaranteed. With this approach, the length of the buffer bounds the
//! maximum size of "unsplittable" content, such as element and attribute
//! names, but not "splittable" content such as element text content and
//! attribute values.
//!
//! Intentional (permanent) limitations (which can be addressed by
//! higher-level APIs, such as `Reader`):
//!
//! - Does not validate that corresponding open and close tags match.
//! - Does not validate that attribute names are not duplicated.
//! - Does not do any special handling of namespaces.
//! - Does not perform any sort of processing on text content or attribute
//!   values (including normalization, expansion of entities, etc.).
//!   - However, note that entity and character references in text content and
//!     attribute values _are_ validated for correct syntax, although their
//!     content is not (they may reference non-existent entities).
//! - Does not process DTDs in any way besides parsing them (TODO: see below).
//!
//! Unintentional (temporary) limitations (which will be removed over time):
//!
//! - Does not support `DOCTYPE` at all (using one will result in an error).
//! - Not extensively tested/fuzzed.

/// The current state of the scanner.
state: State = .start,
/// Data associated with the current state of the scanner.
state_data: State.Data = undefined,
/// The current position in the input.
///
/// The meaning of this position is determined by the meaning of the `len`
/// value passed to `next`, which is determined by the user. For example, a
/// user with a byte slice or reader would probably want to pass `len` as the
/// number of bytes making up the codepoint, which would make `pos` a byte
/// offset.
pos: usize = 0,
/// The current element nesting depth.
depth: usize = 0,
/// Whether the root element has been seen already.
seen_root_element: bool = false,

const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;
const syntax = @import("syntax.zig");

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
pub const Token = union(enum) {
    /// Continue processing: no new token to report yet.
    ok,
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
        version: Range,
        encoding: ?Range = null,
        standalone: ?bool = null,
    };

    pub const ElementStart = struct {
        name: Range,
    };

    pub const ElementContent = struct {
        content: Content,
    };

    pub const ElementEnd = struct {
        name: Range,
    };

    pub const AttributeStart = struct {
        name: Range,
    };

    pub const AttributeContent = struct {
        content: Content,
        final: bool = false,
    };

    pub const CommentContent = struct {
        content: Range,
        final: bool = false,
    };

    pub const PiStart = struct {
        target: Range,
    };

    pub const PiContent = struct {
        content: Range,
        final: bool = false,
    };

    /// A bit of content of an element or attribute.
    pub const Content = union(enum) {
        /// Raw text content (does not contain any entities).
        text: Range,
        /// A Unicode codepoint.
        codepoint: u21,
        /// An entity reference, such as `&amp;`. The range covers the name (`amp`).
        entity: Range,
    };
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
pub const State = enum {
    /// Start of document.
    start,
    /// Start of document after BOM.
    start_after_bom,

    /// Same as unknown_start, but also allows the XML declaration.
    start_unknown_start,
    /// Start of a PI or XML declaration after '<?'.
    ///
    /// Uses `start`, `xml_seen`.
    pi_or_xml_decl_start,

    /// XML declaration after '<?xml '.
    xml_decl,
    /// XML declaration within 'version'.
    ///
    /// Uses `left`.
    xml_decl_version_name,
    /// XML declaration after 'version'.
    xml_decl_after_version_name,
    /// XML declaration after '=' in version info.
    xml_decl_after_version_equals,
    /// XML version value with some part of '1.' consumed.
    ///
    /// Uses `start`, `quote`, `left`.
    xml_decl_version_value_start,
    /// XML declaration version value after '1.'.
    ///
    /// Uses `start`, `quote`.
    xml_decl_version_value,
    /// XML declaration after version info.
    ///
    /// Uses `version`.
    xml_decl_after_version,
    /// XML declaration within 'encoding'.
    ///
    /// Uses `version`, `left`.
    xml_decl_encoding_name,
    /// XML declaration after 'encoding'.
    ///
    /// Uses `version`.
    xml_decl_after_encoding_name,
    /// XML declaration after '=' in encoding declaration.
    ///
    /// Uses `version`.
    xml_decl_after_encoding_equals,
    /// XML declaration encoding declaration value start (after opening quote).
    ///
    /// Uses `version`, `start`, `quote`.
    xml_decl_encoding_value_start,
    /// XML declaration encoding declaration value (after first character).
    ///
    /// Uses `version`, `start`, `quote`.
    xml_decl_encoding_value,
    /// XML declaration after encoding declaration.
    ///
    /// Uses `version`, `encoding`.
    xml_decl_after_encoding,
    /// XML declaration within 'standalone'.
    ///
    /// Uses `version`, `encoding`, `left`.
    xml_decl_standalone_name,
    /// XML declaration after 'standalone'.
    ///
    /// Uses `version`, `encoding`.
    xml_decl_after_standalone_name,
    /// XML declaration after '=' in standalone declaration.
    ///
    /// Uses `version`, `encoding`.
    xml_decl_after_standalone_equals,
    /// XML declaration standalone declaration value start (after opening quote).
    ///
    /// Uses `version`, `encoding`, `quote`.
    xml_decl_standalone_value_start,
    /// XML declaration standalone declaration value after some part of 'yes' or 'no'.
    ///
    /// Uses `quote`, `left`.
    xml_decl_standalone_value,
    /// XML declaration standalone declaration value after full 'yes' or 'no'.
    ///
    /// Uses `quote`.
    xml_decl_standalone_value_end,
    /// XML declaration after standalone declaration.
    xml_decl_after_standalone,
    /// End of XML declaration after '?'.
    xml_decl_end,
    /// Start of document after XML declaration.
    start_after_xml_decl,

    /// Top-level document content (outside the root element).
    document_content,
    /// A '<' has been encountered, but we don't know if it's an element, comment, etc.
    unknown_start,
    /// A '<!' has been encountered.
    unknown_start_bang,

    /// A '<!-' has been encountered.
    comment_before_start,
    /// Comment.
    ///
    /// Uses `start`.
    comment,
    /// Comment after consuming one '-'.
    ///
    /// Uses `start`, `end`.
    comment_maybe_before_end,
    /// Comment after consuming '--'.
    comment_before_end,

    /// PI after '<?'.
    pi,
    /// In PI target name.
    ///
    /// Uses `start`, `xml_seen`.
    pi_target,
    /// After PI target.
    pi_after_target,
    /// In PI content after target name.
    ///
    /// Uses `start`.
    pi_content,
    /// Possible end of PI after '?'.
    ///
    /// Uses `start`, `end`.
    pi_maybe_end,

    /// A '<![' (and possibly some part of 'CDATA[' after it) has been encountered.
    ///
    /// Uses `left`.
    cdata_before_start,
    /// CDATA.
    ///
    /// Uses `start`.
    cdata,
    /// In CDATA content after some part of ']]>'.
    ///
    /// Uses `start`, `end`, `left`.
    cdata_maybe_end,

    /// Name of element start tag.
    ///
    /// Uses `start`.
    element_start_name,
    /// In element start tag after name (and possibly after one or more attributes).
    element_start_after_name,
    /// In element start tag after encountering '/' (indicating an empty element).
    element_start_empty,

    /// Attribute name.
    ///
    /// Uses `start`.
    attribute_name,
    /// After attribute name but before '='.
    attribute_after_name,
    /// After attribute '='.
    attribute_after_equals,
    /// Attribute value.
    ///
    /// Uses `start`, `quote`.
    attribute_content,
    /// Attribute value after encountering '&'.
    ///
    /// Uses `quote`.
    attribute_content_ref_start,
    /// Attribute value within an entity reference name.
    ///
    /// Uses `start`, `quote`.
    attribute_content_entity_ref_name,
    /// Attribute value after encountering '&#'.
    ///
    /// Uses `quote`.
    attribute_content_char_ref_start,
    /// Attribute value within a character reference.
    ///
    /// Uses `hex`, `value`, `quote`.
    attribute_content_char_ref,

    /// Element end tag after consuming '</'.
    element_end,
    /// Name of element end tag.
    ///
    /// Uses `start`.
    element_end_name,
    /// In element end tag after name.
    element_end_after_name,

    /// Element content (text).
    ///
    /// Uses `start`.
    content,
    /// Element content after encountering '&'.
    content_ref_start,
    /// Element content within an entity reference name.
    ///
    /// Uses `start`.
    content_entity_ref_name,
    /// Element content after encountering '&#'.
    content_char_ref_start,
    /// Element content within a character reference.
    ///
    /// Uses `hex`, `value`.
    content_char_ref,

    /// A syntax error has been encountered.
    ///
    /// This is for safety, since the parser has no error recovery: to avoid
    /// invalid tokens being emitted, the parser is put in this state after any
    /// syntax error, and will always emit a syntax error in this state.
    @"error",

    /// Data associated with the scanner state.
    ///
    /// A more idiomatic pattern for Zig would be to make `State` a tagged
    /// union and have this data contained within the states that use it.
    /// However, the tagged union pattern turns out to be worse for
    /// performance due to the extra copying required, especially since many
    /// states preserve similar data values across transitions (for example,
    /// all attribute value states maintain the `quote` field).
    pub const Data = struct {
        start: usize,
        end: usize,
        left: []const u8,
        // Attribute value
        quote: u8,
        // PI or XML declaration
        xml_seen: TokenMatcher("xml"),
        // Character reference
        hex: bool,
        value: u21,
        // XML declaration
        version: Range,
        encoding: ?Range,
    };
};

/// A matcher which keeps track of whether the input does/might match a fixed
/// ASCII token.
fn TokenMatcher(comptime token: []const u8) type {
    const invalid = token ++ "\x00";

    return struct {
        seen: []const u8 = "",

        const Self = @This();

        pub fn accept(self: Self, c: u21) Self {
            if (self.seen.len < token.len and c == token[self.seen.len]) {
                return .{ .seen = token[0 .. self.seen.len + 1] };
            } else {
                return .{ .seen = invalid };
            }
        }

        pub fn matches(self: Self) bool {
            return self.seen.len == token.len;
        }

        pub fn mightMatch(self: Self) bool {
            return self.seen.len <= token.len;
        }
    };
}

/// Accepts a single codepoint of input, returning the token found or an error.
///
/// The `len` argument determines how `pos` (and hence any ranges in the
/// returned tokens) behaves. A byte-oriented user will probably want to pass
/// the number of bytes making up the codepoint so that all ranges are byte
/// ranges, but it is also valid to use other interpretations (e.g. the user
/// could always pass 1 if the input is already parsed into codepoints).
pub fn next(self: *Scanner, c: u21, len: usize) error{SyntaxError}!Token {
    const token = self.nextNoAdvance(c, len) catch |e| {
        self.state = .@"error";
        return e;
    };
    self.pos += len;
    return token;
}

/// Returns the next token (or an error) without advancing the internal
/// position (which should only be advanced in case of success: basically this
/// function is needed because Zig has no "successdefer" to advance `pos` only
/// in case of success).
fn nextNoAdvance(self: *Scanner, c: u21, len: usize) error{SyntaxError}!Token {
    switch (self.state) {
        .start => if (c == 0xFEFF or syntax.isSpace(c)) {
            self.state = .start_after_bom;
            return .ok;
        } else if (c == '<') {
            self.state = .start_unknown_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .start_after_bom => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .start_unknown_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .start_unknown_start => if (syntax.isNameStartChar(c)) {
            self.state = .element_start_name;
            self.state_data.start = self.pos;
            return .ok;
        } else if (c == '?') {
            self.state = .pi_or_xml_decl_start;
            self.state_data.start = self.pos + len;
            self.state_data.xml_seen = .{};
            return .ok;
        } else if (c == '!') {
            // TODO: doctype
            self.state = .unknown_start_bang;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_or_xml_decl_start => if (syntax.isNameStartChar(c) or (syntax.isNameChar(c) and self.pos > self.state_data.start)) {
            const xml_seen = self.state_data.xml_seen.accept(c);
            if (xml_seen.mightMatch()) {
                self.state_data.xml_seen = xml_seen;
            } else {
                self.state = .pi_target;
                // self.state_data.start = self.state_data.start;
                self.state_data.xml_seen = xml_seen;
            }
            return .ok;
        } else if (syntax.isSpace(c) and self.pos > self.state_data.start) {
            if (self.state_data.xml_seen.matches()) {
                self.state = .xml_decl;
                return .ok;
            } else {
                const target = Range{ .start = self.state_data.start, .end = self.pos };
                self.state = .pi_after_target;
                return .{ .pi_start = .{ .target = target } };
            }
        } else if (c == '?' and self.pos > self.state_data.start) {
            if (self.state_data.xml_seen.matches()) {
                // Can't have an XML declaration without a version
                return error.SyntaxError;
            } else {
                const target = Range{ .start = self.state_data.start, .end = self.pos };
                self.state = .pi_maybe_end;
                self.state_data.start = self.pos;
                self.state_data.end = self.pos;
                return .{ .pi_start = .{ .target = target } };
            }
        } else {
            return error.SyntaxError;
        },

        .xml_decl => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 'v') {
            self.state = .xml_decl_version_name;
            self.state_data.left = "ersion";
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_name => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .xml_decl_after_version_name;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .xml_decl_after_version_equals;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version_equals => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .xml_decl_version_value_start;
            self.state_data.start = self.pos + len;
            self.state_data.quote = @intCast(u8, c);
            self.state_data.left = "1.";
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_value_start => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .xml_decl_version_value;
                // self.state_data.start = self.state_data.start;
                // self.state_data.quote = self.state_data.quote;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_value => if (c == self.state_data.quote and self.pos > self.state_data.start + "1.".len) {
            self.state = .xml_decl_after_version;
            self.state_data.version = .{ .start = self.state_data.start, .end = self.pos };
            return .ok;
        } else if (syntax.isDigit(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 'e') {
            self.state = .xml_decl_encoding_name;
            // self.state_data.version = self.state_data.version;
            self.state_data.left = "ncoding";
            return .ok;
        } else if (c == 's') {
            self.state = .xml_decl_standalone_name;
            // self.state_data.version = self.state_data.version;
            self.state_data.encoding = null;
            self.state_data.left = "tandalone";
            return .ok;
        } else if (c == '?') {
            const version = self.state_data.version;
            self.state = .xml_decl_end;
            return .{ .xml_declaration = .{ .version = version, .encoding = null, .standalone = null } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_name => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .xml_decl_after_encoding_name;
                // self.state_data.version = self.state_data.version;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .xml_decl_after_encoding_equals;
            // self.state_data.version = self.state_data.version;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding_equals => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .xml_decl_encoding_value_start;
            // self.state_data.version = self.state_data.version;
            self.state_data.start = self.pos + len;
            self.state_data.quote = @intCast(u8, c);
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_value_start => if (syntax.isEncodingStartChar(c)) {
            self.state = .xml_decl_encoding_value;
            // self.state_data.version = self.state_data.version;
            // self.state_data.start = self.state_data.start;
            // self.state_data.quote = self.state_data.quote;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_value => if (c == self.state_data.quote) {
            self.state = .xml_decl_after_encoding;
            // self.state_data.version = self.state_data.version;
            self.state_data.encoding = .{ .start = self.state_data.start, .end = self.pos };
            return .ok;
        } else if (syntax.isEncodingChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 's') {
            self.state = .xml_decl_standalone_name;
            // self.state_data.version = self.state_data.version;
            // self.state_data.encoding = self.state_data.encoding;
            self.state_data.left = "tandalone";
            return .ok;
        } else if (c == '?') {
            const version = self.state_data.version;
            const encoding = self.state_data.encoding;
            self.state = .xml_decl_end;
            return .{ .xml_declaration = .{ .version = version, .encoding = encoding, .standalone = null } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_name => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .xml_decl_after_standalone_name;
                // self.state_data.version = self.state_data.version;
                // self.state_data.encoding = self.state_data.encoding;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .xml_decl_after_standalone_equals;
            // self.state_data.version = self.state_data.version;
            // self.state_data.encoding = self.state_data.encoding;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone_equals => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .xml_decl_standalone_value_start;
            // self.state_data.version = self.state_data.version;
            // self.state_data.encoding = self.state_data.encoding;
            self.state_data.quote = @intCast(u8, c);
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value_start => if (c == 'y') {
            const version = self.state_data.version;
            const encoding = self.state_data.encoding;
            self.state = .xml_decl_standalone_value;
            // self.state_data.quote = self.state_data.quote;
            self.state_data.left = "es";
            return .{ .xml_declaration = .{ .version = version, .encoding = encoding, .standalone = true } };
        } else if (c == 'n') {
            const version = self.state_data.version;
            const encoding = self.state_data.encoding;
            self.state = .xml_decl_standalone_value;
            // self.state_data.quote = self.state_data.quote;
            self.state_data.left = "o";
            return .{ .xml_declaration = .{ .version = version, .encoding = encoding, .standalone = false } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .xml_decl_standalone_value_end;
                // self.state_data.quote = self.state_data.quote;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value_end => if (c == self.state_data.quote) {
            self.state = .xml_decl_after_standalone;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone => if (syntax.isSpace(c)) {
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

        .start_after_xml_decl => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .document_content => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_start => if (syntax.isNameStartChar(c) and !self.seen_root_element) {
            self.state = .element_start_name;
            self.state_data.start = self.pos;
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
            self.state = .cdata_before_start;
            self.state_data.left = "CDATA[";
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_start => if (c == '-') {
            self.state = .comment;
            self.state_data.start = self.pos + len;
            return .comment_start;
        } else {
            return error.SyntaxError;
        },

        .comment => if (c == '-') {
            self.state = .comment_maybe_before_end;
            // self.state_data.start = self.state_data.start;
            self.state_data.end = self.pos;
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_maybe_before_end => if (c == '-') {
            const content = Range{ .start = self.state_data.start, .end = self.state_data.end };
            self.state = .comment_before_end;
            return .{ .comment_content = .{ .content = content, .final = true } };
        } else if (syntax.isChar(c)) {
            self.state = .comment;
            // self.state_data.start = self.state_data.start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_end => if (c == '>') {
            if (self.depth == 0) {
                self.state = .document_content;
            } else {
                self.state = .content;
                self.state_data.start = self.pos + len;
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi => if (syntax.isNameStartChar(c)) {
            self.state = .pi_target;
            self.state_data.start = self.pos;
            self.state_data.xml_seen = (TokenMatcher("xml"){}).accept(c);
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_target => if (syntax.isNameChar(c)) {
            self.state_data.xml_seen = self.state_data.xml_seen.accept(c);
            return .ok;
        } else if (syntax.isSpace(c)) {
            if (self.state_data.xml_seen.matches()) {
                // PI named 'xml' is not allowed
                return error.SyntaxError;
            } else {
                const target = Range{ .start = self.state_data.start, .end = self.pos };
                self.state = .pi_after_target;
                return .{ .pi_start = .{ .target = target } };
            }
        } else if (c == '?') {
            if (self.state_data.xml_seen.matches()) {
                return error.SyntaxError;
            } else {
                const target = Range{ .start = self.state_data.start, .end = self.pos };
                self.state = .pi_maybe_end;
                self.state_data.start = self.pos;
                self.state_data.end = self.pos;
                return .{ .pi_start = .{ .target = target } };
            }
        } else {
            return error.SyntaxError;
        },

        .pi_after_target => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isChar(c)) {
            self.state = .pi_content;
            self.state_data.start = self.pos;
            return .ok;
        } else if (c == '?') {
            self.state = .pi_maybe_end;
            self.state_data.start = self.pos;
            self.state_data.end = self.pos;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_content => if (c == '?') {
            self.state = .pi_maybe_end;
            // self.state_data.start = self.state_data.start;
            self.state_data.end = self.pos;
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_maybe_end => if (c == '>') {
            const content = Range{ .start = self.state_data.start, .end = self.state_data.end };
            if (self.depth == 0) {
                self.state = .document_content;
            } else {
                self.state = .content;
                self.state_data.start = self.pos + len;
            }
            return .{ .pi_content = .{ .content = content, .final = true } };
        } else if (syntax.isChar(c)) {
            self.state = .pi_content;
            // self.state_data.start = self.state_data.start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_before_start => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                self.state = .cdata;
                self.state_data.start = self.pos + len;
            } else {
                self.state_data.left = self.state_data.left[1..];
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata => if (c == ']') {
            self.state = .cdata_maybe_end;
            // self.state_data.start = self.state_data.start;
            self.state_data.end = self.pos;
            self.state_data.left = "]>";
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_maybe_end => if (c == self.state_data.left[0]) {
            if (self.state_data.left.len == 1) {
                const text = Range{ .start = self.state_data.start, .end = self.state_data.end };
                self.state = .content;
                self.state_data.start = self.pos + len;
                return .{ .element_content = .{ .content = .{ .text = text } } };
            } else {
                self.state_data.left = self.state_data.left[1..];
                return .ok;
            }
        } else if (syntax.isChar(c)) {
            self.state = .cdata;
            // self.state_data.start = self.state_data.start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_name => if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.depth += 1;
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .element_start_after_name;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '/') {
            self.depth += 1;
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .element_start_empty;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '>') {
            self.depth += 1;
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .content;
            self.state_data.start = self.pos + len;
            return .{ .element_start = .{ .name = name } };
        } else {
            return error.SyntaxError;
        },

        .element_start_after_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .attribute_name;
            self.state_data.start = self.pos;
            return .ok;
        } else if (c == '/') {
            self.state = .element_start_empty;
            return .ok;
        } else if (c == '>') {
            self.state = .content;
            self.state_data.start = self.pos + len;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_empty => if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            if (self.depth == 0) {
                self.state = .document_content;
            } else {
                self.state = .content;
                self.state_data.start = self.pos + len;
            }
            return .element_end_empty;
        } else {
            return error.SyntaxError;
        },

        .attribute_name => if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .attribute_after_name;
            return .{ .attribute_start = .{ .name = name } };
        } else if (c == '=') {
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .attribute_after_equals;
            return .{ .attribute_start = .{ .name = name } };
        } else {
            return error.SyntaxError;
        },

        .attribute_after_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .attribute_after_equals;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_after_equals => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .attribute_content;
            self.state_data.start = self.pos + len;
            self.state_data.quote = @intCast(u8, c);
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content => if (c == self.state_data.quote) {
            const text = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .element_start_after_name;
            return .{ .attribute_content = .{ .content = .{ .text = text }, .final = true } };
        } else if (c == '&') {
            const text = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .attribute_content_ref_start;
            // self.state_data.quote = self.state_data.quote;
            if (text.isEmpty()) {
                // We do not want to emit an empty text content token between entities
                return .ok;
            } else {
                return .{ .attribute_content = .{ .content = .{ .text = text } } };
            }
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_ref_start => if (syntax.isNameStartChar(c)) {
            self.state = .attribute_content_entity_ref_name;
            self.state_data.start = self.pos;
            // self.state_data.quote = self.state_data.quote;
            return .ok;
        } else if (c == '#') {
            self.state = .attribute_content_char_ref_start;
            // self.state_data.quote = self.state_data.quote;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_entity_ref_name => if (syntax.isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            const entity = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .attribute_content;
            self.state_data.start = self.pos + len;
            // self.state_data.quote = self.state_data.quote;
            return .{ .attribute_content = .{ .content = .{ .entity = entity } } };
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref_start => if (syntax.isDigit(c)) {
            self.state = .attribute_content_char_ref;
            self.state_data.hex = false;
            self.state_data.value = syntax.digitValue(c);
            // self.state_data.quote = self.state_data.quote;
            return .ok;
        } else if (c == 'x') {
            self.state = .attribute_content_char_ref;
            self.state_data.hex = true;
            self.state_data.value = 0;
            // self.state_data.quote = self.state_data.quote;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref => if (!self.state_data.hex and syntax.isDigit(c)) {
            const value = 10 * @as(u32, self.state_data.value) + syntax.digitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            }
            self.state_data.value = @intCast(u21, value);
            return .ok;
        } else if (self.state_data.hex and syntax.isHexDigit(c)) {
            const value = 16 * @as(u32, self.state_data.value) + syntax.hexDigitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            }
            self.state_data.value = @intCast(u21, value);
            return .ok;
        } else if (c == ';' and syntax.isChar(self.state_data.value)) {
            const codepoint = self.state_data.value;
            self.state = .attribute_content;
            self.state_data.start = self.pos + len;
            // self.state_data.quote = self.state_data.quote;
            return .{ .attribute_content = .{ .content = .{ .codepoint = codepoint } } };
        } else {
            return error.SyntaxError;
        },

        .element_end => if (syntax.isNameStartChar(c)) {
            self.state = .element_end_name;
            self.state_data.start = self.pos;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_end_name => if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.depth -= 1;
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .element_end_after_name;
            return .{ .element_end = .{ .name = name } };
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            const name = Range{ .start = self.state_data.start, .end = self.pos };
            if (self.depth == 0) {
                self.state = .document_content;
            } else {
                self.state = .content;
                self.state_data.start = self.pos + len;
            }
            return .{ .element_end = .{ .name = name } };
        } else {
            return error.SyntaxError;
        },

        .element_end_after_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '>') {
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            if (self.depth == 0) {
                self.state = .document_content;
            } else {
                self.state = .content;
                self.state_data.start = self.pos + len;
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content => if (c == '<') {
            const text = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .unknown_start;
            if (text.isEmpty()) {
                // Do not report empty text content between elements, e.g.
                // <e1></e1><e2></e2> (there is no text content between or
                // within e1 and e2).
                return .ok;
            } else {
                return .{ .element_content = .{ .content = .{ .text = text } } };
            }
        } else if (c == '&') {
            const text = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .content_ref_start;
            if (text.isEmpty()) {
                return .ok;
            } else {
                return .{ .element_content = .{ .content = .{ .text = text } } };
            }
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_ref_start => if (syntax.isNameStartChar(c)) {
            self.state = .content_entity_ref_name;
            self.state_data.start = self.pos;
            return .ok;
        } else if (c == '#') {
            self.state = .content_char_ref_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_entity_ref_name => if (syntax.isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            const entity = Range{ .start = self.state_data.start, .end = self.pos };
            self.state = .content;
            self.state_data.start = self.pos + len;
            return .{ .element_content = .{ .content = .{ .entity = entity } } };
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_start => if (syntax.isDigit(c)) {
            self.state = .content_char_ref;
            self.state_data.hex = false;
            self.state_data.value = syntax.digitValue(c);
            return .ok;
        } else if (c == 'x') {
            self.state = .content_char_ref;
            self.state_data.hex = true;
            self.state_data.value = 0;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref => if (!self.state_data.hex and syntax.isDigit(c)) {
            const value = 10 * @as(u32, self.state_data.value) + syntax.digitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            }
            self.state_data.value = @intCast(u21, value);
            return .ok;
        } else if (self.state_data.hex and syntax.isHexDigit(c)) {
            const value = 16 * @as(u32, self.state_data.value) + syntax.hexDigitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            }
            self.state_data.value = @intCast(u21, value);
            return .ok;
        } else if (c == ';' and syntax.isChar(self.state_data.value)) {
            const codepoint = self.state_data.value;
            self.state = .content;
            self.state_data.start = self.pos + len;
            return .{ .element_content = .{ .content = .{ .codepoint = codepoint } } };
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
    if (self.state != .document_content or !self.seen_root_element) {
        return error.UnexpectedEndOfInput;
    }
}

test Scanner {
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
        .{ .pi_content = .{ .content = .{ .start = 31, .end = 31 }, .final = true } },
        .comment_start,
        .{ .comment_content = .{ .content = .{ .start = 38, .end = 85 }, .final = true } },
        .{ .pi_start = .{ .target = .{ .start = 91, .end = 111 } } }, // some-pi-with-content
        .{ .pi_content = .{ .content = .{ .start = 112, .end = 119 }, .final = true } },
        .{ .element_start = .{ .name = .{ .start = 123, .end = 127 } } }, // root
        .{ .element_content = .{ .content = .{ .text = .{ .start = 128, .end = 131 } } } },
        .{ .element_start = .{ .name = .{ .start = 132, .end = 133 } } }, // p
        .{ .attribute_start = .{ .name = .{ .start = 134, .end = 139 } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 141, .end = 145 } }, .final = true } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 147, .end = 154 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 163, .end = 169 } } } },
        .{ .element_end = .{ .name = .{ .start = 174, .end = 175 } } }, // /p
        .{ .element_content = .{ .content = .{ .text = .{ .start = 176, .end = 179 } } } },
        .{ .element_start = .{ .name = .{ .start = 180, .end = 184 } } }, // line
        .element_end_empty,
        .{ .element_content = .{ .content = .{ .text = .{ .start = 187, .end = 190 } } } },
        .{ .pi_start = .{ .target = .{ .start = 192, .end = 202 } } }, // another-pi
        .{ .pi_content = .{ .content = .{ .start = 202, .end = 202 }, .final = true } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 204, .end = 233 } } } },
        .{ .element_start = .{ .name = .{ .start = 234, .end = 237 } } }, // div
        .{ .element_start = .{ .name = .{ .start = 239, .end = 240 } } }, // p
        .{ .element_content = .{ .content = .{ .entity = .{ .start = 242, .end = 245 } } } },
        .{ .element_end = .{ .name = .{ .start = 248, .end = 249 } } }, // /p
        .{ .element_end = .{ .name = .{ .start = 252, .end = 255 } } }, // /div
        .{ .element_content = .{ .content = .{ .text = .{ .start = 256, .end = 257 } } } },
        .{ .element_end = .{ .name = .{ .start = 259, .end = 263 } } }, // /root
        .comment_start,
        .{ .comment_content = .{ .content = .{ .start = 269, .end = 325 }, .final = true } },
        .{ .pi_start = .{ .target = .{ .start = 332, .end = 339 } } }, // comment
        .{ .pi_content = .{ .content = .{ .start = 340, .end = 351 }, .final = true } },
    });
}

test "BOM" {
    try testValid("\u{FEFF}<element/>", &.{
        .{ .element_start = .{ .name = .{ .start = 4, .end = 11 } } },
        .element_end_empty,
    });
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

test "element nesting" {
    try testValid("<root><sub><inner/></sub></root>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 5 } } },
        .{ .element_start = .{ .name = .{ .start = 7, .end = 10 } } },
        .{ .element_start = .{ .name = .{ .start = 12, .end = 17 } } },
        .element_end_empty,
        .{ .element_end = .{ .name = .{ .start = 21, .end = 24 } } },
        .{ .element_end = .{ .name = .{ .start = 27, .end = 31 } } },
    });
    try testValid("<root   ><sub\t><inner\n/></sub ></root\r  >", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 5 } } },
        .{ .element_start = .{ .name = .{ .start = 10, .end = 13 } } },
        .{ .element_start = .{ .name = .{ .start = 16, .end = 21 } } },
        .element_end_empty,
        .{ .element_end = .{ .name = .{ .start = 26, .end = 29 } } },
        .{ .element_end = .{ .name = .{ .start = 33, .end = 37 } } },
    });
    try testInvalid("<root></root></outer>", 14);
    try testInvalid("<root ></root\n></outer\r>", 16);
    try testIncomplete("<root><sub><inner/></sub>");
    try testIncomplete("<root   ><sub\t><inner\n/></sub >");
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
        \\<?xml version="1.1"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 } } },
        .{ .element_start = .{ .name = .{ .start = 23, .end = 27 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.999"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 20 } } },
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
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" encoding="Utf-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" encoding="ASCII"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .standalone = true } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" standalone="no"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .standalone = false } },
        .{ .element_start = .{ .name = .{ .start = 39, .end = 43 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .standalone = true } },
        .{ .element_start = .{ .name = .{ .start = 44, .end = 48 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 }, .standalone = true } },
        .{ .element_start = .{ .name = .{ .start = 57, .end = 61 } } },
        .element_end_empty,
    });
    try testValid(
        \\<?xml version = "1.0" encoding = "UTF-8" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .encoding = .{ .start = 34, .end = 39 }, .standalone = true } },
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
        .{ .attribute_content = .{ .content = .{ .codepoint = 0x2C } } },
        .{ .attribute_content = .{ .content = .{ .codepoint = 32 } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 36, .end = 42 } } } },
        .{ .attribute_content = .{ .content = .{ .entity = .{ .start = 43, .end = 46 } } } },
        .{ .attribute_content = .{ .content = .{ .text = .{ .start = 47, .end = 56 } }, .final = true } },
        .{ .element_content = .{ .content = .{ .entity = .{ .start = 59, .end = 61 } } } },
        .{ .element_content = .{ .content = .{ .text = .{ .start = 62, .end = 64 } } } },
        .{ .element_content = .{ .content = .{ .codepoint = 33 } } },
        .{ .element_content = .{ .content = .{ .codepoint = 0x21 } } },
        .{ .element_content = .{ .content = .{ .entity = .{ .start = 76, .end = 78 } } } },
        .{ .element_end = .{ .name = .{ .start = 81, .end = 88 } } },
    });
}

test "PI at document start" {
    try testValid("<?some-pi?><root/>", &.{
        .{ .pi_start = .{ .target = .{ .start = 2, .end = 9 } } },
        .{ .pi_content = .{ .content = .{ .start = 9, .end = 9 }, .final = true } },
        .{ .element_start = .{ .name = .{ .start = 12, .end = 16 } } },
        .element_end_empty,
    });
    try testValid("<?xm?><root/>", &.{
        .{ .pi_start = .{ .target = .{ .start = 2, .end = 4 } } },
        .{ .pi_content = .{ .content = .{ .start = 4, .end = 4 }, .final = true } },
        .{ .element_start = .{ .name = .{ .start = 7, .end = 11 } } },
        .element_end_empty,
    });
    try testValid("<?xmlm?><root/>", &.{
        .{ .pi_start = .{ .target = .{ .start = 2, .end = 6 } } },
        .{ .pi_content = .{ .content = .{ .start = 6, .end = 6 }, .final = true } },
        .{ .element_start = .{ .name = .{ .start = 9, .end = 13 } } },
        .element_end_empty,
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
    try testInvalid("<?xml?>", 5);
    try testInvalid("<? xml version='1.0' ?>", 2);
    try testInvalid("<?xml version='1.0' standalone='yes' encoding='UTF-8'?>", 37);
    try testInvalid("<?xml version=\"2.0\"?>", 15);
    try testInvalid("<?xml version=\"1.\"?>", 17);
    try testInvalid("<?xml version='1'?>", 16);
    try testInvalid("<?xml version=''?>", 15);
    try testInvalid("<?xml version='1.0' encoding=''?>", 30);
    try testInvalid("<?xml version='1.0' encoding=\"?\"?>", 30);
    try testInvalid("<?xml version='1.0' encoding=\"UTF-?\"?>", 34);
    try testInvalid("<?xml version='1.0' standalone='yno'?>", 33);
    try testInvalid("<?xml version=\"1.0\" standalone=\"\"", 32);
}

test "invalid PI" {
    try testInvalid("<?xml version='1.0'?><?xml version='1.0'?>", 26);
}

test "invalid reference" {
    try testInvalid("<element>&</element>", 10);
    try testInvalid("<element>&amp</element>", 13);
    try testInvalid("<element>&#ABC;</element>", 11);
    try testInvalid("<element>&#12C;</element>", 13);
    try testInvalid("<element>&#xxx;</element>", 12);
    try testInvalid("<element>&#0;</element>", 12);
    try testInvalid("<element>&#x1f0000;</element>", 18);
    try testInvalid("<element attr='&' />", 16);
    try testInvalid("<element attr='&amp' />", 19);
    try testInvalid("<element attr='&#ABC' />", 17);
    try testInvalid("<element attr='&#12C' />", 19);
    try testInvalid("<element attr='&#xxx' />", 18);
    try testInvalid("<element attr='&#0;' />", 18);
    try testInvalid("<element attr='&#x1f0000;' />", 24);
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
    var input_codepoints = (try unicode.Utf8View.init(input)).iterator();
    while (input_codepoints.nextCodepointSlice()) |c_bytes| {
        const c = unicode.utf8Decode(c_bytes) catch unreachable;
        const token = scanner.next(c, c_bytes.len) catch |e| switch (e) {
            error.SyntaxError => {
                std.debug.print("syntax error at char '{u}' position {}\n", .{ c, scanner.pos });
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
    var input_codepoints = (try unicode.Utf8View.init(input)).iterator();
    while (input_codepoints.nextCodepointSlice()) |c_bytes| {
        const c = unicode.utf8Decode(c_bytes) catch unreachable;
        _ = scanner.next(c, c_bytes.len) catch |e| switch (e) {
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
    var input_codepoints = (try unicode.Utf8View.init(input)).iterator();
    while (input_codepoints.nextCodepointSlice()) |c_bytes| {
        const c = unicode.utf8Decode(c_bytes) catch unreachable;
        _ = try scanner.next(c, c_bytes.len);
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
        .start_after_bom,

        .start_unknown_start,

        .xml_decl,
        .xml_decl_version_name,
        .xml_decl_after_version_name,
        .xml_decl_after_version_equals,
        .xml_decl_standalone_value,
        .xml_decl_standalone_value_end,
        .xml_decl_after_standalone,
        .xml_decl_end,
        .start_after_xml_decl,

        .document_content,
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
        .attribute_content_char_ref,

        .element_end,
        .element_end_after_name,

        .content_ref_start,
        .content_char_ref_start,
        .content_char_ref,

        .@"error",
        => .ok,

        // States which contain positional information but cannot immediately
        // be emitted as a token cannot be reset
        .pi_or_xml_decl_start,

        .xml_decl_version_value_start,
        .xml_decl_version_value,
        .xml_decl_after_version,
        .xml_decl_encoding_name,
        .xml_decl_after_encoding_name,
        .xml_decl_after_encoding_equals,
        .xml_decl_encoding_value_start,
        .xml_decl_encoding_value,
        .xml_decl_after_encoding,
        .xml_decl_standalone_name,
        .xml_decl_after_standalone_name,
        .xml_decl_after_standalone_equals,
        .xml_decl_standalone_value_start,

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

        .element_end_name,

        .content_entity_ref_name,
        => return error.CannotReset,

        // Some states (specifically, content states) can be reset by emitting
        // a token with the content seen so far
        .comment => token: {
            const range = Range{ .start = self.state_data.start, .end = self.pos };
            self.state_data.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .comment_content = .{ .content = range } };
            }
        },

        .pi_content => token: {
            const range = Range{ .start = self.state_data.start, .end = self.pos };
            self.state_data.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .pi_content = .{ .content = range } };
            }
        },

        .cdata => token: {
            const range = Range{ .start = self.state_data.start, .end = self.pos };
            self.state_data.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .element_content = .{ .content = .{ .text = range } } };
            }
        },

        .attribute_content => token: {
            const range = Range{ .start = self.state_data.start, .end = self.pos };
            self.state_data.start = 0;
            if (range.isEmpty()) {
                break :token .ok;
            } else {
                break :token .{ .attribute_content = .{ .content = .{ .text = range } } };
            }
        },

        .content => token: {
            const range = Range{ .start = self.state_data.start, .end = self.pos };
            self.state_data.start = 0;
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

test resetPos {
    var scanner = Scanner{};
    var tokens = std.ArrayListUnmanaged(Token){};
    defer tokens.deinit(testing.allocator);

    for ("<element>Hello,") |c| {
        switch (try scanner.next(c, 1)) {
            .ok => {},
            else => |token| try tokens.append(testing.allocator, token),
        }
    }
    try tokens.append(testing.allocator, try scanner.resetPos());
    for (" world!</element>") |c| {
        switch (try scanner.next(c, 1)) {
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
        _ = try scanner.next(c, 1);
    }
    try testing.expectError(error.CannotReset, scanner.resetPos());
}
