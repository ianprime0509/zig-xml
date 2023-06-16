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
/// Whether we are inside the doctype.
in_doctype: bool = false,
/// Whether the doctype has been seen already (or it is known to be absent).
seen_doctype: bool = false,
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
    /// Doctype start.
    doctype_start: DoctypeStart,
    /// Parameter entity in doctype.
    parameter_entity: ParameterEntity,
    /// Element declaration in doctype.
    element_declaration: ElementDeclaration,
    /// Start of attribute list declaration in doctype.
    attlist_declaration_start: AttlistDeclarationStart,
    /// Definition in attribute list declaration in doctype.
    attlist_declaration_definition: AttlistDeclarationDefinition,
    /// General entity declaration in doctype.
    general_entity_declaration: GeneralEntityDeclaration,
    /// Parameter entity declaration in doctype.
    parameter_entity_declaration: ParameterEntityDeclaration,
    /// Notation declaration in doctype.
    notation_declaration: NotationDeclaration,
    /// Doctype end.
    doctype_end,
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

    pub const DoctypeStart = struct {
        root_name: Range,
        public_id: ?Range = null,
        system_id: ?Range = null,
    };

    pub const ParameterEntity = struct {
        name: Range,
    };

    pub const ElementDeclaration = struct {
        name: Range,
        content_spec: ContentSpec,

        pub const ContentSpec = union(enum) {
            empty,
            any,
            mixed: struct { options: Range },
            children: struct { definition: Range },
        };
    };

    pub const AttlistDeclarationStart = struct {
        element_name: Range,
    };

    pub const AttlistDeclarationDefinition = struct {
        name: Range,
        type: AttributeType,
        default: Default,

        pub const AttributeType = union(enum) {
            cdata,
            id,
            idref,
            idrefs,
            entity,
            entities,
            nmtoken,
            nmtokens,
            notation: struct { options: Range },
            enumeration: struct { options: Range },
        };

        pub const Default = union(enum) {
            required,
            implied,
            fixed: struct { value: Range },
        };
    };

    pub const GeneralEntityDeclaration = struct {
        name: Range,
        value: Value,

        pub const Value = union(enum) {
            internal: struct { value: Range },
            external: struct {
                public_id: ?Range = null,
                system_id: Range,
                ndata: ?Range = null,
            },
        };
    };

    pub const ParameterEntityDeclaration = struct {
        name: Range,
        value: Value,

        pub const Value = union(enum) {
            internal: struct { value: Range },
            external: struct {
                public_id: ?Range = null,
                system_id: Range,
            },
        };
    };

    pub const NotationDeclaration = struct {
        name: Range,
        public_id: ?Range = null,
        system_id: ?Range = null,
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
pub const State = union(enum) {
    // Note: due to the extremely large number of states in the state machine,
    // they are organized roughly in the order one would expect to encounter
    // them in a document, to make it slightly easier to follow.

    /// Start of document.
    start,
    /// Start of document after BOM.
    start_after_bom,

    /// Same as unknown_start, but also allows the xml and doctype declarations.
    unknown_document_start,
    /// Start of a PI or XML declaration after '<?'.
    pi_or_xml_decl_start: struct { start: usize, xml_seen: TokenMatcher("xml") = .{} },

    /// XML declaration after '<?xml '.
    xml_decl,
    /// XML declaration within 'version'.
    xml_decl_version_name: struct { left: []const u8 },
    /// XML declaration after 'version'.
    xml_decl_after_version_name,
    /// XML declaration after '=' in version info.
    xml_decl_after_version_equals,
    /// XML version value with some part of '1.' consumed.
    xml_decl_version_value_start: struct { start: usize, quote: u8, left: []const u8 },
    /// XML declaration version value after '1.'.
    xml_decl_version_value: struct { start: usize, quote: u8 },
    /// XML declaration after version info.
    xml_decl_after_version: struct { version: Range },
    /// XML declaration within 'encoding'.
    xml_decl_encoding_name: struct { version: Range, left: []const u8 },
    /// XML declaration after 'encoding'.
    xml_decl_after_encoding_name: struct { version: Range },
    /// XML declaration after '=' in encoding declaration.
    xml_decl_after_encoding_equals: struct { version: Range },
    /// XML declaration encoding declaration value start (after opening quote).
    xml_decl_encoding_value_start: struct { version: Range, start: usize, quote: u8 },
    /// XML declaration encoding declaration value (after first character).
    xml_decl_encoding_value: struct { version: Range, start: usize, quote: u8 },
    /// XML declaration after encoding declaration.
    xml_decl_after_encoding: struct { version: Range, encoding: ?Range },
    /// XML declaration within 'standalone'.
    xml_decl_standalone_name: struct { version: Range, encoding: ?Range, left: []const u8 },
    /// XML declaration after 'standalone'.
    xml_decl_after_standalone_name: struct { version: Range, encoding: ?Range },
    /// XML declaration after '=' in standalone declaration.
    xml_decl_after_standalone_equals: struct { version: Range, encoding: ?Range },
    /// XML declaration standalone declaration value start (after opening quote).
    xml_decl_standalone_value_start: struct { version: Range, encoding: ?Range, quote: u8 },
    /// XML declaration standalone declaration value after some part of 'yes' or 'no'.
    xml_decl_standalone_value: struct { quote: u8, left: []const u8 },
    /// XML declaration standalone declaration value after full 'yes' or 'no'.
    xml_decl_standalone_value_end: struct { quote: u8 },
    /// XML declaration after standalone declaration.
    xml_decl_after_standalone,
    /// End of XML declaration after '?'.
    xml_decl_end,
    /// Start of document after XML declaration.
    start_after_xml_decl,

    // Doctype parsing follows.
    // Abandon hope all ye who enter here.

    /// A '<!' (and some part of 'DOCTYPE ' after it) has been encountered.
    doctype_start: struct { left: []const u8 },
    /// After '<!DOCTYPE '.
    doctype_after_start,
    /// In root element name.
    doctype_root_name: struct { start: usize },
    /// After root element name.
    doctype_after_root_name: struct { root_name: Range },
    /// After some part of 'PUBLIC ' in doctype start.
    doctype_public_start: struct { root_name: Range, left: []const u8 },
    /// After some part of 'SYSTEM ' in doctype start.
    doctype_system_start: struct { root_name: Range, left: []const u8 },
    /// After 'PUBLIC' but before public ID.
    doctype_before_public_id: struct { root_name: Range },
    /// In public ID.
    doctype_public_id: struct { root_name: Range, start: usize, quote: u8 },
    /// After public ID or 'SYSTEM' but before system ID.
    doctype_before_system_id: struct { root_name: Range, public_id: ?Range },
    /// In system ID.
    doctype_system_id: struct { root_name: Range, public_id: ?Range, start: usize, quote: u8 },
    /// After external ID.
    doctype_after_external_id,

    /// In internal subset.
    doctype_internal_subset,

    /// After '%'.
    doctype_pe_ref_start,
    /// In PE reference name.
    doctype_pe_ref_name: struct { start: usize },

    /// After '<' in doctype.
    doctype_unknown_start,
    /// After '<!' in doctype.
    doctype_unknown_start_bang,
    /// After '<!E' in doctype.
    doctype_unknown_start_e,

    // <!ELEMENT ...>
    /// After some part of '<!ELEMENT '.
    doctype_element_decl_start: struct { left: []const u8 },
    /// After '<!ELEMENT '.
    doctype_element_decl_after_start,
    /// In element name.
    doctype_element_decl_name: struct { start: usize },
    /// After element name.
    doctype_element_decl_after_name: struct { name: Range },
    /// After some part of 'EMPTY'.
    doctype_element_decl_empty: struct { name: Range, left: []const u8 },
    /// After some part of 'ANY'.
    doctype_element_decl_any: struct { name: Range, left: []const u8 },
    /// After '('.
    doctype_element_decl_after_paren: struct { name: Range },
    /// After some part of '#PCDATA'.
    doctype_element_decl_pcdata: struct { name: Range, left: []const u8 },
    /// After '#PCDATA' or mixed child name.
    doctype_element_decl_mixed: struct { name: Range, start: usize },
    /// After '|'.
    doctype_element_decl_mixed_before_name: struct { name: Range, start: usize },
    /// In mixed child name.
    doctype_element_decl_mixed_name: struct { name: Range, start: usize },
    // TODO: element declaration "children" spec.
    // This will require more advanced techniques than used elsewhere here.
    /// Before final '>'.
    doctype_element_decl_before_end,

    // <!ATTLIST ...>
    /// After some part of '<!ATTLIST '.
    doctype_attlist_decl_start: struct { left: []const u8 },
    /// After '<!ATTLIST '.
    doctype_attlist_decl_after_start,
    /// In element name.
    doctype_attlist_decl_name: struct { start: usize },
    /// Before attribute name.
    doctype_attlist_decl_def,
    /// In attribute name.
    doctype_attlist_decl_def_name: struct { start: usize },
    /// After attribute name.
    doctype_attlist_decl_def_after_name: struct { name: Range },
    // TODO: I'm sure this sort of "literal options" state can be condensed
    /// After some part of 'CDATA'.
    doctype_attlist_decl_def_cdata: struct { name: Range, left: []const u8 },
    /// After some part of 'ID'.
    doctype_attlist_decl_def_id: struct { name: Range, left: []const u8 },
    /// After 'ID'.
    doctype_attlist_decl_def_after_id: struct { name: Range },
    /// After some part of 'IDREF'.
    doctype_attlist_decl_def_idref: struct { name: Range, left: []const u8 },
    /// After 'IDREF'.
    doctype_attlist_decl_def_after_idref: struct { name: Range },
    /// After some part of 'ENTIT'.
    doctype_attlist_decl_def_entit: struct { name: Range, left: []const u8 },
    /// After 'ENTIT'.
    doctype_attlist_decl_def_after_entit: struct { name: Range },
    /// After some part of 'ENTITIES'.
    doctype_attlist_decl_def_entities: struct { name: Range, left: []const u8 },
    /// After 'N'.
    doctype_attlist_decl_def_after_n: struct { name: Range },
    /// After some part of 'NMTOKEN'.
    doctype_attlist_decl_def_nmtoken: struct { name: Range, left: []const u8 },
    /// After 'NMTOKEN'.
    doctype_attlist_decl_def_after_nmtoken: struct { name: Range, left: []const u8 },
    /// After some part of 'NOTATION '.
    doctype_attlist_decl_def_notation: struct { name: Range, left: []const u8 },
    /// After 'NOTATION '.
    doctype_attlist_decl_def_after_notation: struct { name: Range },
    /// Before option in 'NOTATION'.
    doctype_attlist_decl_def_notation_before_option: struct { name: Range, start: usize },
    /// In 'NOTATION' option name.
    doctype_attlist_decl_def_notation_option: struct { name: Range, start: usize },
    /// After 'NOTATION' option name.
    doctype_attlist_decl_def_notation_after_option: struct { name: Range, start: usize },
    /// Before option in enumeration.
    doctype_attlist_decl_def_enumeration_before_option: struct { name: Range, start: usize },
    /// In option in enumeration.
    doctype_attlist_decl_def_enumeration_option: struct { name: Range, start: usize },
    /// After option in enumeration.
    doctype_attlist_decl_def_enumeration_after_option: struct { name: Range, start: usize },
    /// After type but before mandatory space.
    doctype_attlist_decl_def_after_type: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType },
    /// Before default.
    doctype_attlist_decl_def_before_default: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType },
    /// After '#'.
    doctype_attlist_decl_def_default: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType },
    /// After some part of '#REQUIRED'.
    doctype_attlist_decl_def_required: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType, left: []const u8 },
    /// After some part of '#IMPLIED'.
    doctype_attlist_decl_def_implied: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType, left: []const u8 },
    /// After some part of '#FIXED '.
    doctype_attlist_decl_def_fixed: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType, left: []const u8 },
    /// After '#FIXED '.
    doctype_attlist_decl_def_after_fixed: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType },
    // TODO: validate references in fixed attribute value
    /// In fixed attribute value.
    doctype_attlist_decl_def_fixed_value: struct { name: Range, type: Token.AttlistDeclarationDefinition.AttributeType, start: usize, quote: u8 },
    /// After attribute definition.
    doctype_attlist_decl_after_def,

    // <!ENTITY ...>
    /// After some part of '<!ENTITY '.
    doctype_entity_decl_start: struct { left: []const u8 },
    /// After '<!ENTITY '.
    doctype_entity_decl_after_start,

    // <!NOTATION ...>
    /// After some part of '<!NOTATION '.
    doctype_notation_decl_start: struct { left: []const u8 },
    /// After '<!NOTATION '.
    doctype_notation_decl_after_start,

    /// After internal subset.
    doctype_after_internal_subset,

    // End of doctype parsing.
    // You may retrieve your hope at the door.

    /// A '<' has been encountered, but we don't know if it's an element, comment, etc.
    unknown_start,
    /// A '<!' has been encountered.
    unknown_start_bang,

    /// A '<!-' has been encountered.
    comment_before_start,
    /// Comment.
    comment: struct { start: usize },
    /// Comment after consuming one '-'.
    comment_maybe_before_end: struct { start: usize, end: usize },
    /// Comment after consuming '--'.
    comment_before_end,

    /// PI after '<?'.
    pi,
    /// In PI target name.
    pi_target: struct { start: usize, xml_seen: TokenMatcher("xml") = .{} },
    /// After PI target.
    pi_after_target,
    /// In PI content after target name.
    pi_content: struct { start: usize },
    /// Possible end of PI after '?'.
    pi_maybe_end: struct { start: usize, end: usize },

    /// A '<![' (and possibly some part of 'CDATA[' after it) has been encountered.
    cdata_before_start: struct { left: []const u8 },
    /// CDATA.
    cdata: struct { start: usize },
    /// In CDATA content after some part of ']]>'.
    cdata_maybe_end: struct { start: usize, end: usize, left: []const u8 },

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
    /// Attribute value within a character reference.
    attribute_content_char_ref: struct { hex: bool, value: u21, quote: u8 },

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
    /// Element content within a character reference.
    content_char_ref: struct { hex: bool, value: u21 },

    /// A syntax error has been encountered.
    ///
    /// This is for safety, since the parser has no error recovery: to avoid
    /// invalid tokens being emitted, the parser is put in this state after any
    /// syntax error, and will always emit a syntax error in this state.
    @"error",
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
pub inline fn next(self: *Scanner, c: u21, len: usize) error{SyntaxError}!Token {
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
    // Note: none of the switch cases below capture by pointer, because it is
    // too easy to accidentally clobber some state that needs to be returned in
    // a token.
    // Similarly, there is no blanket 'return error.SyntaxError' at the end of
    // this function to avoid duplication across cases because it is too easy
    // to miss a 'return .ok'.
    // These decisions may be revisited later if they somehow manage to impact
    // performance.
    switch (self.state) {
        .start => if (c == 0xFEFF or syntax.isSpace(c)) {
            self.state = .start_after_bom;
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_document_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .start_after_bom => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '<') {
            self.state = .unknown_document_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_document_start => if (syntax.isNameStartChar(c)) {
            if (self.depth == 0) {
                self.seen_doctype = true;
            }
            self.state = .{ .element_start_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_or_xml_decl_start = .{ .start = self.pos + len } };
            return .ok;
        } else if (c == '!') {
            self.state = .unknown_start_bang;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_or_xml_decl_start => |state| if (syntax.isNameStartChar(c) or (syntax.isNameChar(c) and self.pos > state.start)) {
            const xml_seen = state.xml_seen.accept(c);
            if (xml_seen.mightMatch()) {
                self.state = .{ .pi_or_xml_decl_start = .{ .start = state.start, .xml_seen = xml_seen } };
            } else {
                self.state = .{ .pi_target = .{ .start = state.start, .xml_seen = xml_seen } };
            }
            return .ok;
        } else if (syntax.isSpace(c) and self.pos > state.start) {
            if (state.xml_seen.matches()) {
                self.state = .xml_decl;
                return .ok;
            } else {
                self.state = .pi_after_target;
                return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
            }
        } else if (c == '?' and self.pos > state.start) {
            if (state.xml_seen.matches()) {
                // Can't have an XML declaration without a version
                return error.SyntaxError;
            } else {
                self.state = .{ .pi_maybe_end = .{ .start = self.pos, .end = self.pos } };
                return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
            }
        } else {
            return error.SyntaxError;
        },

        .xml_decl => if (syntax.isSpace(c)) {
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
            self.state = .{ .xml_decl_version_value_start = .{ .start = self.pos + len, .quote = @intCast(u8, c), .left = "1." } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_value_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .xml_decl_version_value = .{ .start = state.start, .quote = state.quote } };
            } else {
                self.state = .{ .xml_decl_version_value_start = .{ .start = state.start, .quote = state.quote, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_version_value => |state| if (c == state.quote and self.pos > state.start + "1.".len) {
            self.state = .{ .xml_decl_after_version = .{ .version = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (syntax.isDigit(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_version => |state| if (syntax.isSpace(c)) {
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

        .xml_decl_after_encoding_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .{ .xml_decl_after_encoding_equals = .{ .version = state.version } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding_equals => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .xml_decl_encoding_value_start = .{ .version = state.version, .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_value_start => |state| if (syntax.isEncodingStartChar(c)) {
            self.state = .{ .xml_decl_encoding_value = .{ .version = state.version, .start = state.start, .quote = state.quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_encoding_value => |state| if (c == state.quote) {
            self.state = .{ .xml_decl_after_encoding = .{ .version = state.version, .encoding = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (syntax.isEncodingChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_encoding => |state| if (syntax.isSpace(c)) {
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

        .xml_decl_after_standalone_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '=') {
            self.state = .{ .xml_decl_after_standalone_equals = .{ .version = state.version, .encoding = state.encoding } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_after_standalone_equals => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .xml_decl_standalone_value_start = .{ .version = state.version, .encoding = state.encoding, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value_start => |state| if (c == 'y') {
            self.state = .{ .xml_decl_standalone_value = .{ .quote = state.quote, .left = "es" } };
            return .{ .xml_declaration = .{ .version = state.version, .encoding = state.encoding, .standalone = true } };
        } else if (c == 'n') {
            self.state = .{ .xml_decl_standalone_value = .{ .quote = state.quote, .left = "o" } };
            return .{ .xml_declaration = .{ .version = state.version, .encoding = state.encoding, .standalone = false } };
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .xml_decl_standalone_value_end = .{ .quote = state.quote } };
            } else {
                self.state = .{ .xml_decl_standalone_value = .{ .quote = state.quote, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .xml_decl_standalone_value_end => |state| if (c == state.quote) {
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

        .doctype_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_after_start;
            } else {
                self.state = .{ .doctype_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_after_start => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_root_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_root_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_after_root_name = .{ .root_name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .doctype_after_root_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 'P') {
            self.state = .{ .doctype_public_start = .{ .root_name = state.root_name, .left = "UBLIC " } };
            return .ok;
        } else if (c == 'S') {
            self.state = .{ .doctype_system_start = .{ .root_name = state.root_name, .left = "YSTEM " } };
            return .ok;
        } else if (c == '[') {
            self.state = .doctype_internal_subset;
            return .{ .doctype_start = .{ .root_name = state.root_name } };
        } else {
            return error.SyntaxError;
        },

        .doctype_public_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_before_public_id = .{ .root_name = state.root_name } };
            } else {
                self.state = .{ .doctype_public_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_system_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_before_system_id = .{ .root_name = state.root_name, .public_id = null } };
            } else {
                self.state = .{ .doctype_system_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_before_public_id => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .doctype_public_id = .{ .root_name = state.root_name, .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_public_id => |state| if (c == state.quote) {
            self.state = .{ .doctype_before_system_id = .{ .root_name = state.root_name, .public_id = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else if (syntax.isPubidChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_before_system_id => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .doctype_system_id = .{ .root_name = state.root_name, .public_id = state.public_id, .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_system_id => |state| if (c == state.quote) {
            self.state = .doctype_after_external_id;
            return .{ .doctype_start = .{ .root_name = state.root_name, .public_id = state.public_id, .system_id = state.system_id } };
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_after_external_id => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '[') {
            self.state = .doctype_internal_subset;
        } else if (c == '>') {
            self.in_doctype = false;
            self.seen_doctype = true;
            self.state = .start_after_xml_decl;
            return .doctype_end;
        } else {
            return error.SyntaxError;
        },

        .doctype_internal_subset => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '%') {
            self.state = .doctype_pe_ref_start;
            return .ok;
        } else if (c == '<') {
            self.state = .doctype_unknown_start;
            return .ok;
        } else if (c == ']') {
            self.state = .doctype_after_internal_subset;
            return .doctype_end;
        } else {
            return error.SyntaxError;
        },

        .doctype_pe_ref_start => if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_pe_ref_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_pe_ref_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .doctype_internal_subset;
            return .{ .parameter_entity = .{ .start = state.start, .end = self.pos } };
        } else {
            return error.SyntaxError;
        },

        .doctype_unknown_start => if (c == '!') {
            self.state = .doctype_unknown_start_bang;
            return .ok;
        } else if (c == '?') {
            self.state = .pi;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_unknown_start_bang => if (c == '-') {
            self.state = .comment_before_start;
            return .ok;
        } else if (c == 'E') {
            self.state = .doctype_unknown_start_e;
            return .ok;
        } else if (c == 'A') {
            self.state = .{ .doctype_attlist_decl_start = .{ .left = "TTLIST " } };
            return .ok;
        } else if (c == 'N') {
            self.state = .{ .doctype_notation_decl_start = .{ .left = "OTATION " } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_unknown_start_e => if (c == 'L') {
            self.state = .{ .doctype_element_decl_start = .{ .left = "EMENT " } };
            return .ok;
        } else if (c == 'N') {
            self.state = .{ .doctype_entity_decl_start = .{ .left = "TITY " } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_element_decl_after_start;
            } else {
                self.state = .{ .doctype_element_decl_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_after_start => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_element_decl_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_element_decl_after_name = .{ .name = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_after_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 'E') {
            self.state = .{ .doctype_element_decl_empty = .{ .name = state.name, .left = "MPTY" } };
            return .ok;
        } else if (c == 'A') {
            self.state = .{ .doctype_element_decl_any = .{ .name = state.name, .left = "NY" } };
            return .ok;
        } else if (c == '(') {
            self.state = .{ .doctype_element_decl_after_paren = .{ .name = state.name } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_empty => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_element_decl_before_end;
                return .{ .element_declaration = .{ .name = state.name, .content_spec = .empty } };
            } else {
                self.state = .{ .doctype_element_decl_empty = .{ .name = state.name, .left = state.left[1..] } };
                return .ok;
            }
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_any => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_element_decl_before_end;
                return .{ .element_declaration = .{ .name = state.name, .content_spec = .any } };
            } else {
                self.state = .{ .doctype_element_decl_any = .{ .name = state.name, .left = state.left[1..] } };
                return .ok;
            }
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_after_paren => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '#') {
            self.state = .{ .doctype_element_decl_pcdata = .{ .name = state.name, .left = "PCDATA" } };
            return .ok;
        } else if (c == '(') {
            // TODO: children spec parsing goes here
            return error.SyntaxError;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_pcdata => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_element_decl_mixed = .{ .name = state.name, .start = self.pos + len } };
            } else {
                self.state = .{ .doctype_eement_decl_pcdata = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_mixed => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_element_decl_mixed_before_name = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .doctype_element_decl_before_end;
            return .{ .element_declaration = .{ .name = state.name, .content_spec = .{ .mixed = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_mixed_before_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStart(c)) {
            self.state = .{ .doctype_element_decl_mixed_name = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_element_decl_mixed_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_element_decl_mixed = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_element_decl_mixed_before_name = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .doctype_element_decl_before_end;
            return .{ .element_declaration = .{ .name = state.name, .content_spec = .{ .mixed = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
        },

        .doctype_element_decl_before_end => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '>') {
            self.state = .doctype_internal_subset;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_attlist_decl_after_start;
            } else {
                self.state = .{ .doctype_attlist_decl_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_after_start => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_attlist_decl_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .doctype_attlist_decl_def;
            return .{ .attlist_declaration_start = .{ .element_name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_attlist_decl_def_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '>') {
            self.state = .doctype_internal_subset;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_def_after_name = .{ .name = .{ .start = state.start, .end = self.pos } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_name => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == 'C') {
            self.state = .{ .doctype_attlist_decl_def_cdata = .{ .name = state.name, .left = "DATA" } };
            return .ok;
        } else if (c == 'I') {
            self.state = .{ .doctype_attlist_decl_def_id = .{ .name = state.name, .left = "D" } };
            return .ok;
        } else if (c == 'E') {
            self.state = .{ .doctype_attlist_decl_def_entit = .{ .name = state.name, .left = "NTIT" } };
            return .ok;
        } else if (c == 'N') {
            self.state = .{ .doctype_attlist_decl_def_after_n = .{ .name = state.name } };
            return .ok;
        } else if (c == '(') {
            self.state = .{ .doctype_attlist_decl_enumeration_before_option = .{ .name = state.name, .start = self.pos + len } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_cdata => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_after_type = .{ .name = state.name, .type = .cdata } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_cdata = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_id => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_id = .{ .name = state.name } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_id = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_id => |state| if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_before_default = .{ .name = state.name, .type = .id } };
            return .ok;
        } else if (c == 'R') {
            self.state = .{ .doctype_attlist_decl_idref = .{ .name = state.name, .left = "EF" } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_idref => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_idref = .{ .name = state.name } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_idref = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_idref => |state| if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_before_default = .{ .name = state.name, .type = .idref } };
            return .ok;
        } else if (c == 'S') {
            self.state = .{ .doctype_attlist_decl_after_type = .{ .name = state.name, .type = .idrefs } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_entit => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_entit = .{ .name = state.name } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_entit = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_entit => |state| if (c == 'Y') {
            self.state = .{ .doctype_attlist_decl_after_type = .{ .name = state.name, .type = .entity } };
            return .ok;
        } else if (c == 'I') {
            self.state = .{ .doctype_attlist_decl_def_entities = .{ .name = state.name, .left = "ES" } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_entities => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_after_type = .{ .name = state.name, .type = .entities } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_entities = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_n => |state| if (c == 'M') {
            self.state = .{ .doctype_attlist_decl_def_nmtoken = .{ .name = state.name, .left = "TOKEN" } };
            return .ok;
        } else if (c == 'O') {
            self.state = .{ .doctype_attlist_decl_notation = .{ .name = state.name, .left = "TATION " } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_nmtoken => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_nmtoken = .{ .name = state.name } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_nmtoken = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_nmtoken => |state| if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_def_before_default = .{ .name = state.name, .type = .nmtoken } };
            return .ok;
        } else if (c == 'S') {
            self.state = .{ .doctype_attlist_decl_def_after_type = .{ .name = state.name, .type = .nmtokens } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_notation => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_notation = .{ .name = state.name } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_notation = .{ .name = state.name, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_notation => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '(') {
            self.state = .{ .doctype_attlist_decl_def_notation_before_option = .{ .name = state.name, .start = self.pos + len } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_notation_before_option => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_attlist_decl_def_notation_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_notation_option => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_def_notation_after_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_attlist_decl_def_notation_before_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .{ .doctype_attlist_decl_def_after_type = .{ .name = state.name, .type = .{ .notation = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_notation_after_option => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_attlist_decl_def_notation_before_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .{ .doctype_attlist_decl_def_after_type = .{ .name = state.name, .type = .{ .notation = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_enumeration_before_option => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .doctype_attlist_decl_def_enumeration_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_enumeration_option => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_def_enumeration_after_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_attlist_decl_def_enumeration_before_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .{ .doctype_attlist_decl_def_after_type = .{ .name = state.name, .type = .{ .enumeration = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_enumeration_after_option => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '|') {
            self.state = .{ .doctype_attlist_decl_def_enumeration_before_option = .{ .name = state.name, .start = state.start } };
            return .ok;
        } else if (c == ')') {
            self.state = .{ .doctype_attlist_decl_def_after_type = .{ .name = state.name, .type = .{ .enumeration = .{ .options = .{ .start = state.start, .end = self.pos } } } } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_type => |state| if (syntax.isSpace(c)) {
            self.state = .{ .doctype_attlist_decl_def_before_default = .{ .name = state.name, .type = state.type } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_before_default => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '#') {
            self.state = .{ .doctype_attlist_decl_def_default = .{ .name = state.name, .type = state.type } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_default => |state| if (c == 'R') {
            self.state = .{ .doctype_attlist_decl_def_required = .{ .name = state.name, .type = state.type, .left = "EQUIRED" } };
            return .ok;
        } else if (c == 'I') {
            self.state = .{ .doctype_attlist_decl_def_implied = .{ .name = state.name, .type = state.type, .left = "MPLIED" } };
            return .ok;
        } else if (c == 'F') {
            self.state = .{ .doctype_attlist_decl_def_fixed = .{ .name = state.name, .type = state.type, .left = "IXED " } };
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .doctype_attlist_decl_def_fixed_value = .{ .name = state.name, .type = state.type, .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_required => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_attlist_decl_after_def;
                return .{ .attlist_declaration_definition = .{ .name = state.name, .type = state.type, .default = .required } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_required = .{ .name = state.name, .type = state.type, .left = state.left[1..] } };
                return .ok;
            }
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_implied => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_attlist_decl_after_def;
                return .{ .attlist_declaration_definition = .{ .name = state.name, .type = state.type, .default = .implied } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_implied = .{ .name = state.name, .type = state.type, .left = state.left[1..] } };
                return .ok;
            }
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_fixed => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .doctype_attlist_decl_def_after_fixed = .{ .name = state.name, .type = state.type } };
            } else {
                self.state = .{ .doctype_attlist_decl_def_fixed = .{ .name = state.name, .type = state.type, .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_after_fixed => |state| if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '"' or c == '\'') {
            self.state = .{ .doctype_attlist_decl_def_fixed_value = .{ .name = state.name, .type = state.type, .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_def_fixed_value => |state| if (c == state.quote) {
            self.state = .doctype_attlist_decl_after_def;
            return .{ .attlist_declaration_definition = .{ .name = state.name, .type = state.type, .default = .{ .fixed = .{ .value = .{ .start = state.start, .end = self.pos } } } } };
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_attlist_decl_after_def => if (syntax.isSpace(c)) {
            self.state = .doctype_attlist_decl_def;
            return .ok;
        } else if (c == '>') {
            self.state = .doctype_internal_subset;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_entity_decl_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_entity_decl_after_start;
            } else {
                self.state = .{ .doctype_entity_decl_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_notation_decl_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .doctype_notation_decl_after_start;
            } else {
                self.state = .{ .doctype_notation_decl_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .doctype_after_internal_subset => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '>') {
            self.in_doctype = false;
            self.seen_doctype = true;
            self.state = .start_after_xml_decl;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .unknown_start => if (syntax.isNameStartChar(c) and !self.seen_root_element) {
            if (self.depth == 0) {
                self.seen_doctype = true;
            }
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
        } else if (!self.seen_doctype and c == 'D') {
            self.in_doctype = true;
            self.state = .{ .doctype_start = .{ .left = "OCTYPE " } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_start => if (c == '-') {
            self.state = .{ .comment = .{ .start = self.pos + len } };
            return .comment_start;
        } else {
            return error.SyntaxError;
        },

        .comment => |state| if (c == '-') {
            self.state = .{ .comment_maybe_before_end = .{ .start = state.start, .end = self.pos } };
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_maybe_before_end => |state| if (c == '-') {
            self.state = .comment_before_end;
            return .{ .comment_content = .{ .content = .{ .start = state.start, .end = state.end }, .final = true } };
        } else if (syntax.isChar(c)) {
            self.state = .{ .comment = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .comment_before_end => if (c == '>') {
            if (self.in_doctype) {
                self.state = .doctype_internal_subset;
            } else {
                self.state = .{ .content = .{ .start = self.pos + len } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi => if (syntax.isNameStartChar(c)) {
            self.state = .{ .pi_target = .{ .start = self.pos, .xml_seen = (TokenMatcher("xml"){}).accept(c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_target => |state| if (syntax.isNameChar(c)) {
            self.state = .{ .pi_target = .{ .start = state.start, .xml_seen = state.xml_seen.accept(c) } };
            return .ok;
        } else if (syntax.isSpace(c)) {
            if (state.xml_seen.matches()) {
                // PI named 'xml' is not allowed
                return error.SyntaxError;
            } else {
                self.state = .pi_after_target;
                return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
            }
        } else if (c == '?') {
            if (state.xml_seen.matches()) {
                return error.SyntaxError;
            } else {
                self.state = .{ .pi_maybe_end = .{ .start = self.pos, .end = self.pos } };
                return .{ .pi_start = .{ .target = .{ .start = state.start, .end = self.pos } } };
            }
        } else {
            return error.SyntaxError;
        },

        .pi_after_target => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isChar(c)) {
            self.state = .{ .pi_content = .{ .start = self.pos } };
            return .ok;
        } else if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .start = self.pos, .end = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_content => |state| if (c == '?') {
            self.state = .{ .pi_maybe_end = .{ .start = state.start, .end = self.pos } };
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .pi_maybe_end => |state| if (c == '>') {
            if (self.in_doctype) {
                self.state = .doctype_internal_subset;
            } else {
                self.state = .{ .content = .{ .start = self.pos + len } };
            }
            return .{ .pi_content = .{ .content = .{ .start = state.start, .end = state.end }, .final = true } };
        } else if (syntax.isChar(c)) {
            self.state = .{ .pi_content = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_before_start => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .cdata = .{ .start = self.pos + len } };
            } else {
                self.state = .{ .cdata_before_start = .{ .left = state.left[1..] } };
            }
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata => |state| if (c == ']') {
            self.state = .{ .cdata_maybe_end = .{ .start = state.start, .end = self.pos, .left = "]>" } };
            return .ok;
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .cdata_maybe_end => |state| if (c == state.left[0]) {
            if (state.left.len == 1) {
                self.state = .{ .content = .{ .start = self.pos + len } };
                return .{ .element_content = .{ .content = .{ .text = .{ .start = state.start, .end = state.end } } } };
            } else {
                self.state = .{ .cdata_maybe_end = .{ .start = state.start, .end = state.end, .left = state.left[1..] } };
                return .ok;
            }
        } else if (syntax.isChar(c)) {
            self.state = .{ .cdata = .{ .start = state.start } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .element_start_after_name;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '/') {
            const name = Range{ .start = state.start, .end = self.pos };
            self.state = .element_start_empty;
            return .{ .element_start = .{ .name = name } };
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .{ .element_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .element_start_after_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (syntax.isNameStartChar(c)) {
            self.state = .{ .attribute_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '/') {
            self.state = .element_start_empty;
            return .ok;
        } else if (c == '>') {
            self.depth += 1;
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_start_empty => if (c == '>') {
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .element_end_empty;
        } else {
            return error.SyntaxError;
        },

        .attribute_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .attribute_after_name;
            return .{ .attribute_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '=') {
            self.state = .attribute_after_equals;
            return .{ .attribute_start = .{ .name = .{ .start = state.start, .end = self.pos } } };
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
            self.state = .{ .attribute_content = .{ .start = self.pos + len, .quote = @intCast(u8, c) } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content => |state| if (c == state.quote) {
            self.state = .element_start_after_name;
            return .{ .attribute_content = .{ .content = .{ .text = .{ .start = state.start, .end = self.pos } }, .final = true } };
        } else if (c == '&') {
            const range = Range{ .start = state.start, .end = self.pos };
            self.state = .{ .attribute_content_ref_start = .{ .quote = state.quote } };
            if (range.isEmpty()) {
                // We do not want to emit an empty text content token between entities
                return .ok;
            } else {
                return .{ .attribute_content = .{ .content = .{ .text = range } } };
            }
        } else if (syntax.isChar(c)) {
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_ref_start => |state| if (syntax.isNameStartChar(c)) {
            self.state = .{ .attribute_content_entity_ref_name = .{ .start = self.pos, .quote = state.quote } };
            return .ok;
        } else if (c == '#') {
            self.state = .{ .attribute_content_char_ref_start = .{ .quote = state.quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_entity_ref_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .attribute_content = .{ .start = self.pos + len, .quote = state.quote } };
            return .{ .attribute_content = .{ .content = .{ .entity = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref_start => |state| if (syntax.isDigit(c)) {
            self.state = .{ .attribute_content_char_ref = .{ .hex = false, .value = syntax.digitValue(c), .quote = state.quote } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .attribute_content_char_ref = .{ .hex = true, .value = 0, .quote = state.quote } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .attribute_content_char_ref => |state| if (!state.hex and syntax.isDigit(c)) {
            const value = 10 * @as(u32, state.value) + syntax.digitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            } else {
                self.state = .{ .attribute_content_char_ref = .{ .hex = false, .value = @intCast(u21, value), .quote = state.quote } };
                return .ok;
            }
        } else if (state.hex and syntax.isHexDigit(c)) {
            const value = 16 * @as(u32, state.value) + syntax.hexDigitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            } else {
                self.state = .{ .attribute_content_char_ref = .{ .hex = true, .value = @intCast(u21, value), .quote = state.quote } };
                return .ok;
            }
        } else if (c == ';' and syntax.isChar(state.value)) {
            self.state = .{ .attribute_content = .{ .start = self.pos + len, .quote = state.quote } };
            return .{ .attribute_content = .{ .content = .{ .codepoint = state.value } } };
        } else {
            return error.SyntaxError;
        },

        .element_end => if (syntax.isNameStartChar(c)) {
            self.state = .{ .element_end_name = .{ .start = self.pos } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .element_end_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (syntax.isSpace(c)) {
            self.state = .element_end_after_name;
            return .{ .element_end = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .{ .element_end = .{ .name = .{ .start = state.start, .end = self.pos } } };
        } else {
            return error.SyntaxError;
        },

        .element_end_after_name => if (syntax.isSpace(c)) {
            return .ok;
        } else if (c == '>') {
            self.depth -= 1;
            if (self.depth == 0) {
                self.seen_root_element = true;
            }
            self.state = .{ .content = .{ .start = self.pos + len } };
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
        } else if (self.depth > 0 and syntax.isChar(c)) {
            // Textual content is not allowed outside the root element.
            return .ok;
        } else if (syntax.isSpace(c)) {
            // Spaces are allowed outside the root element. Another check in
            // this state will prevent a text token from being emitted at the
            // end of the whitespace.
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_ref_start => if (syntax.isNameStartChar(c)) {
            self.state = .{ .content_entity_ref_name = .{ .start = self.pos } };
            return .ok;
        } else if (c == '#') {
            self.state = .content_char_ref_start;
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_entity_ref_name => |state| if (syntax.isNameChar(c)) {
            return .ok;
        } else if (c == ';') {
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .{ .element_content = .{ .content = .{ .entity = .{ .start = state.start, .end = self.pos } } } };
        } else {
            return error.SyntaxError;
        },

        .content_char_ref_start => if (syntax.isDigit(c)) {
            self.state = .{ .content_char_ref = .{ .hex = false, .value = syntax.digitValue(c) } };
            return .ok;
        } else if (c == 'x') {
            self.state = .{ .content_char_ref = .{ .hex = true, .value = 0 } };
            return .ok;
        } else {
            return error.SyntaxError;
        },

        .content_char_ref => |state| if (!state.hex and syntax.isDigit(c)) {
            const value = 10 * @as(u32, state.value) + syntax.digitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            } else {
                self.state = .{ .content_char_ref = .{ .hex = false, .value = @intCast(u21, value) } };
                return .ok;
            }
        } else if (state.hex and syntax.isHexDigit(c)) {
            const value = 16 * @as(u32, state.value) + syntax.hexDigitValue(c);
            if (value > std.math.maxInt(u21)) {
                return error.SyntaxError;
            } else {
                self.state = .{ .content_char_ref = .{ .hex = true, .value = @intCast(u21, value) } };
                return .ok;
            }
        } else if (c == ';' and syntax.isChar(c)) {
            self.state = .{ .content = .{ .start = self.pos + len } };
            return .{ .element_content = .{ .content = .{ .codepoint = state.value } } };
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

        .unknown_document_start,

        .xml_decl,
        .xml_decl_version_name,
        .xml_decl_after_version_name,
        .xml_decl_after_version_equals,
        .xml_decl_standalone_value,
        .xml_decl_standalone_value_end,
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
