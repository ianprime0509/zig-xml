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
};

/// A single XML token.
pub const Token = union(enum) {
    /// Continue processing: no new token to report yet.
    ok,
    /// XML declaration.
    xml_declaration: struct { version: Range, encoding: ?Range = null, standalone: ?Range = null },
    /// Element start tag. Emitted after parsing the start tag name but before any attributes.
    element_start: struct { name: Range },
    /// Element attribute.
    attribute: struct { name: Range, value: Range },
    /// Element end tag. Emitted after parsing the end of the tag.
    element_end: struct { name: Range },
    /// Comment.
    comment: struct { content: Range },
    /// Processing instruction (PI).
    pi: struct { target: Range, content: Range },
    /// CDATA.
    cdata: struct { content: Range },
    /// Text content.
    text: struct { content: Range },
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
    xml_decl_after_standalone: struct { version: Range, encoding: ?Range, standalone: ?Range },
    /// End of XML declaration after '?'.
    xml_decl_end: struct { version: Range, encoding: ?Range, standalone: ?Range },
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
    comment_before_end: struct { content: Range },

    /// PI after '<?'.
    pi,
    /// In PI target name.
    pi_target: struct { start: usize },
    /// After PI target.
    pi_after_target: struct { target: Range },
    /// In PI content after target name.
    pi_content: struct { target: Range, start: usize },
    /// Possible end of PI after '?'.
    pi_maybe_end: struct { target: Range, content_start: usize },

    /// A '<![' (and possibly some part of 'CDATA[' after it) has been encountered.
    cdata_before_start: struct { left: []const u8 },
    /// CDATA.
    cdata: struct { start: usize },
    /// In CDATA content after some part of ']]>'.
    cdata_maybe_end: struct { content_start: usize, left: []const u8 },

    /// Name of element start tag.
    element_start_name: struct { start: usize },
    /// In element start tag after name (and possibly after one or more attributes).
    element_start_after_name: struct { name: Range },
    /// In element start tag after encountering '/' (indicating an empty element).
    element_start_empty: struct { name: Range },

    /// Attribute name.
    ///
    /// Note that attribute states must store the range corresponding to the
    /// element name, because we could be in an empty element and will need the
    /// element name to emit the `element_end` token (we will not get the name
    /// again at this point).
    attribute_name: struct { element_name: Range, start: usize },
    /// After attribute name but before '='.
    attribute_after_name: struct { element_name: Range, name: Range },
    /// After attribute '='.
    attribute_after_equals: struct { element_name: Range, name: Range },
    /// Attribute value.
    ///
    /// The `quote` field is intended to avoid duplication of states into
    /// single-quote and double-quote variants.
    attribute_value: struct { element_name: Range, name: Range, start: usize, quote: u8 },
    /// Attribute value after encountering '&'.
    attribute_value_ref_start: struct { element_name: Range, name: Range, value_start: usize, value_quote: u8 },
    /// Attribute value within an entity reference name.
    attribute_value_entity_ref_name: struct { element_name: Range, name: Range, value_start: usize, value_quote: u8 },
    /// Attribute value after encountering '&#'.
    attribute_value_char_ref_start: struct { element_name: Range, name: Range, value_start: usize, value_quote: u8 },
    /// Attribute value within a decimal character reference.
    attribute_value_char_ref_decimal: struct { element_name: Range, name: Range, value_start: usize, value_quote: u8 },
    /// Attribute value within a hex character reference.
    attribute_value_char_ref_hex: struct { element_name: Range, name: Range, value_start: usize, value_quote: u8 },

    /// Element end tag after consuming '</'.
    element_end,
    /// Name of element end tag.
    element_end_name: struct { start: usize },
    /// In element end tag after name.
    element_end_after_name: struct { name: Range },

    /// Element content (character data and markup).
    content: struct { start: usize },
    /// Element content after encountering '&'.
    content_ref_start: struct { content_start: usize },
    /// Element content within an entity reference name.
    content_entity_ref_name: struct { content_start: usize },
    /// Element content after encountering '&#'.
    content_char_ref_start: struct { content_start: usize },
    /// Element content within a decimal character reference.
    content_char_ref_decimal: struct { content_start: usize },
    /// Element content within a hex character reference.
    content_char_ref_hex: struct { content_start: usize },
};

/// Accepts a single byte of input, returning the token found or an error.
pub inline fn next(self: *Scanner, c: u8) error{SyntaxError}!Token {
    const token = try self.nextNoAdvance(c);
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
            self.state = .{ .pi_after_target = .{ .target = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (c == '?' and self.pos > state.start) {
            self.state = .{ .pi_maybe_end = .{ .target = .{ .start = state.start, .end = self.pos }, .content_start = self.pos } };
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
            self.state = .{ .xml_decl_end = .{ .version = state.version, .encoding = null, .standalone = null } };
            return .ok;
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
            self.state = .{ .xml_decl_end = .{ .version = state.version, .encoding = state.encoding, .standalone = null } };
            return .ok;
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
            self.state = .{ .xml_decl_after_standalone = .{ .version = state.version, .encoding = state.encoding, .standalone = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '?') {
            self.state = .{ .xml_decl_end = .{ .version = state.version, .encoding = state.encoding, .standalone = state.standalone } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_end => |state| if (c == '>') {
            self.state = .start_after_xml_decl;
            return .{ .xml_declaration = .{ .version = state.version, .encoding = state.encoding, .standalone = state.standalone } };
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
            return .ok;
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
            self.state = .{ .comment_before_end = .{ .content = .{ .start = state.start, .end = self.pos - 1 } } };
            return .ok;
        } else if (isValidChar(c)) {
            self.state = .{ .comment = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_end => |state| if (c == '>') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .comment = .{ .content = state.content } };
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
            self.state = .{ .pi_after_target = .{ .target = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .target = .{ .start = state.start, .end = self.pos }, .content_start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_after_target => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (isValidChar(c)) {
            self.state = .{ .pi_content = .{ .target = state.target, .start = self.pos } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .target = state.target, .content_start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_content => |state| if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .target = state.target, .content_start = state.start } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_maybe_end => |state| if (c == '>') {
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .pi = .{ .target = state.target, .content = .{ .start = state.content_start, .end = self.pos - 1 } } };
        } else if (isValidChar(c)) {
            self.state = .{ .pi_content = .{ .target = state.target, .start = state.content_start } };
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
            self.state = .{ .cdata_maybe_end = .{ .content_start = state.start, .left = "]>" } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_maybe_end => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .content = .{ .start = self.pos + 1 } };
                return .{ .cdata = .{ .content = .{ .start = state.content_start, .end = self.pos - "]]".len } } };
            } else {
                self.state = .{ .cdata_maybe_end = .{ .content_start = state.content_start, .left = state.left[1..] } };
                return .ok;
            }
        } else if (isValidChar(c)) {
            self.state = .{ .cdata = .{ .start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .{ .element_start_after_name = .{ .name = name } };
            return .{ .element_start = .{ .name = name } };
        } else if (c == '/') {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .{ .element_start_empty = .{ .name = name } };
            return .{ .element_start = .{ .name = name } };
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .element_start_after_name => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (isNameStartChar(c)) {
            self.state = .{ .attribute_name = .{ .element_name = state.name, .start = self.pos } };
            return .ok;
        } else if (c == '/') {
            self.state = .{ .element_start_empty = .{ .name = state.name } };
            return .ok;
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_empty => |state| if (c == '>') {
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_end = .{ .name = state.name } };
        } else {
            return error.SyntaxError;
        },

        .attribute_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (isSpaceChar(c)) {
            self.state = .{ .attribute_after_name = .{ .element_name = state.element_name, .name = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (c == '=') {
            self.state = .{ .attribute_after_equals = .{ .element_name = state.element_name, .name = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_after_name => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .{ .attribute_after_equals = .{ .element_name = state.element_name, .name = state.name } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_after_equals => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .attribute_value = .{ .element_name = state.element_name, .name = state.name, .start = self.pos + 1, .quote = c } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value => |state| if (c == state.quote) {
            self.state = .{ .element_start_after_name = .{ .name = state.element_name } };
            return .{ .attribute = .{ .name = state.name, .value = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '&') {
            self.state = .{ .attribute_value_ref_start = .{ .element_name = state.element_name, .name = state.name, .value_start = state.start, .value_quote = state.quote } };
            return .ok;
        } else if (isValidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value_ref_start => |state| if (isNameStartChar(c)) {
            self.state = .{ .attribute_value_entity_ref_name = .{ .element_name = state.element_name, .name = state.name, .value_start = state.value_start, .value_quote = state.value_quote } };
            return .ok;
        } else if (c == '#') {
            self.state = .{ .attribute_value_char_ref_start = .{ .element_name = state.element_name, .name = state.name, .value_start = state.value_start, .value_quote = state.value_quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value_entity_ref_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_value = .{ .element_name = state.element_name, .name = state.name, .start = state.value_start, .quote = state.value_quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value_char_ref_start => |state| if (isDigitChar(c)) {
            self.state = .{ .attribute_value_char_ref_decimal = .{ .element_name = state.element_name, .name = state.name, .value_start = state.value_start, .value_quote = state.value_quote } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .attribute_value_char_ref_hex = .{ .element_name = state.element_name, .name = state.name, .value_start = state.value_start, .value_quote = state.value_quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value_char_ref_decimal => |state| if (isDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_value = .{ .element_name = state.element_name, .name = state.name, .start = state.value_start, .quote = state.value_quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_value_char_ref_hex => |state| if (isHexDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_value = .{ .element_name = state.element_name, .name = state.name, .start = state.value_start, .quote = state.value_quote } };
            return .ok;
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
            self.state = .{ .element_end_after_name = .{ .name = .{ .start = state.start, .end = self.pos } } };
            return .ok;
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

        .element_end_after_name => |state| if (isSpaceChar(c)) {
            return .ok;
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + 1 } };
            return .{ .element_end = .{ .name = state.name } };
        } else {
            return error.SyntaxError;
        },

        .content => |state| if (c == '<') {
            self.state = .unknown_start;
            const content = Range{ .start = state.start, .end = self.pos };
            if (self.depth == 0 or content.isEmpty()) {
                // Do not report empty text content between elements, e.g.
                // <e1></e1><e2></e2> (there is no text content between or
                // within e1 and e2). Also do not report text content outside
                // the root element (which will just be whitespace).
                return .ok;
            } else {
                return .{ .text = .{ .content = content } };
            }
        } else if (self.depth > 0 and c == '&') {
            self.state = .{ .content_ref_start = .{ .content_start = state.start } };
            return .ok;
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

        .content_ref_start => |state| if (isNameStartChar(c)) {
            self.state = .{ .content_entity_ref_name = .{ .content_start = state.content_start } };
            return .ok;
        } else if (c == '#') {
            self.state = .{ .content_char_ref_start = .{ .content_start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_entity_ref_name => |state| if (isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_start => |state| if (isDigitChar(c)) {
            self.state = .{ .content_char_ref_decimal = .{ .content_start = state.content_start } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .content_char_ref_hex = .{ .content_start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_decimal => |state| if (isDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_hex => |state| if (isHexDigitChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = state.content_start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },
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
        .{ .element_end = .{ .name = .{ .start = 1, .end = 8 } } },
    });
    try testValid("<element />", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .element_end = .{ .name = .{ .start = 1, .end = 8 } } },
    });
}

test "root element with no content" {
    try testValid("<element></element>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .element_end = .{ .name = .{ .start = 11, .end = 18 } } },
    });
}

test "text content" {
    try testValid("<message>Hello, world!</message>", &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .text = .{ .content = .{ .start = 9, .end = 22 } } },
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
        .{ .element_end = .{ .name = .{ .start = 23, .end = 27 } } },
    });
    try testValid(
        \\<?xml version = "1.0"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 } } },
        .{ .element_start = .{ .name = .{ .start = 25, .end = 29 } } },
        .{ .element_end = .{ .name = .{ .start = 25, .end = 29 } } },
    });
    try testValid(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .{ .element_end = .{ .name = .{ .start = 40, .end = 44 } } },
    });
    try testValid(
        \\<?xml version = "1.0" encoding = "UTF-8"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .encoding = .{ .start = 34, .end = 39 } } },
        .{ .element_start = .{ .name = .{ .start = 44, .end = 48 } } },
        .{ .element_end = .{ .name = .{ .start = 44, .end = 48 } } },
    });
    try testValid(
        \\<?xml version="1.0" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .standalone = .{ .start = 32, .end = 35 } } },
        .{ .element_start = .{ .name = .{ .start = 40, .end = 44 } } },
        .{ .element_end = .{ .name = .{ .start = 40, .end = 44 } } },
    });
    try testValid(
        \\<?xml version = "1.0" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .standalone = .{ .start = 36, .end = 39 } } },
        .{ .element_start = .{ .name = .{ .start = 44, .end = 48 } } },
        .{ .element_end = .{ .name = .{ .start = 44, .end = 48 } } },
    });
    try testValid(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 15, .end = 18 }, .encoding = .{ .start = 30, .end = 35 }, .standalone = .{ .start = 49, .end = 52 } } },
        .{ .element_start = .{ .name = .{ .start = 57, .end = 61 } } },
        .{ .element_end = .{ .name = .{ .start = 57, .end = 61 } } },
    });
    try testValid(
        \\<?xml version = "1.0" encoding = "UTF-8" standalone = "yes"?>
        \\<root/>
    , &.{
        .{ .xml_declaration = .{ .version = .{ .start = 17, .end = 20 }, .encoding = .{ .start = 34, .end = 39 }, .standalone = .{ .start = 55, .end = 58 } } },
        .{ .element_start = .{ .name = .{ .start = 63, .end = 67 } } },
        .{ .element_end = .{ .name = .{ .start = 63, .end = 67 } } },
    });
}

test "references" {
    try testValid(
        \\<element attribute="Hello&#x2C;&#32;world &amp; friends!">&lt;Hi&#33;&#x21;&gt;</element>
    , &.{
        .{ .element_start = .{ .name = .{ .start = 1, .end = 8 } } },
        .{ .attribute = .{ .name = .{ .start = 9, .end = 18 }, .value = .{ .start = 20, .end = 56 } } },
        .{ .text = .{ .content = .{ .start = 58, .end = 79 } } },
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
        \\  <p>Hello, <![CDATA[world!]]></p>
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
        .{ .pi = .{ .target = .{ .start = 24, .end = 31 }, .content = .{ .start = 31, .end = 31 } } }, // some-pi
        .{ .comment = .{ .content = .{ .start = 38, .end = 85 } } },
        .{ .pi = .{ .target = .{ .start = 91, .end = 111 }, .content = .{ .start = 112, .end = 119 } } }, // some-pi-with-content
        .{ .element_start = .{ .name = .{ .start = 123, .end = 127 } } }, // root
        .{ .text = .{ .content = .{ .start = 128, .end = 131 } } },
        .{ .element_start = .{ .name = .{ .start = 132, .end = 133 } } }, // p
        .{ .text = .{ .content = .{ .start = 134, .end = 141 } } },
        .{ .cdata = .{ .content = .{ .start = 150, .end = 156 } } },
        .{ .element_end = .{ .name = .{ .start = 161, .end = 162 } } }, // /p
        .{ .text = .{ .content = .{ .start = 163, .end = 166 } } },
        .{ .element_start = .{ .name = .{ .start = 167, .end = 171 } } }, // line
        .{ .element_end = .{ .name = .{ .start = 167, .end = 171 } } }, // /line
        .{ .text = .{ .content = .{ .start = 174, .end = 177 } } },
        .{ .pi = .{ .target = .{ .start = 179, .end = 189 }, .content = .{ .start = 189, .end = 189 } } }, // another-pi
        .{ .text = .{ .content = .{ .start = 191, .end = 220 } } },
        .{ .element_start = .{ .name = .{ .start = 221, .end = 224 } } }, // div
        .{ .element_start = .{ .name = .{ .start = 226, .end = 227 } } }, // p
        .{ .text = .{ .content = .{ .start = 228, .end = 233 } } },
        .{ .element_end = .{ .name = .{ .start = 235, .end = 236 } } }, // /p
        .{ .element_end = .{ .name = .{ .start = 239, .end = 242 } } }, // /div
        .{ .text = .{ .content = .{ .start = 243, .end = 244 } } },
        .{ .element_end = .{ .name = .{ .start = 246, .end = 250 } } }, // /root
        .{ .comment = .{ .content = .{ .start = 256, .end = 312 } } },
        .{ .pi = .{ .target = .{ .start = 319, .end = 326 }, .content = .{ .start = 327, .end = 338 } } }, // comment
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
