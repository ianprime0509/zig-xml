const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ComptimeStringMap = std.ComptimeStringMap;
const StringArrayHashMapUnmanaged = std.StringArrayHashMapUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const encoding = @import("encoding.zig");
const syntax = @import("syntax.zig");
const Node = @import("node.zig").Node;
const OwnedValue = @import("node.zig").OwnedValue;
const Scanner = @import("Scanner.zig");
const Token = @import("token_reader.zig").Token;
const TokenReader = @import("token_reader.zig").TokenReader;

const max_encoded_codepoint_len = 4;

/// A qualified name.
pub const QName = struct {
    prefix: ?[]const u8 = null,
    ns: ?[]const u8 = null,
    local: []const u8,

    /// Returns whether this name has the given namespace and local name.
    pub fn is(self: QName, ns: ?[]const u8, local: []const u8) bool {
        if (self.ns) |self_ns| {
            if (!mem.eql(u8, self_ns, ns orelse return false)) {
                return false;
            }
        } else if (ns != null) {
            return false;
        }
        return mem.eql(u8, self.local, local);
    }

    test is {
        try testing.expect((QName{ .local = "abc" }).is(null, "abc"));
        try testing.expect((QName{ .ns = "http://example.com/ns/", .local = "abc" }).is("http://example.com/ns/", "abc"));
        try testing.expect(!(QName{ .local = "abc" }).is(null, "def"));
        try testing.expect(!(QName{ .local = "abc" }).is("http://example.com/ns/", "abc"));
        try testing.expect(!(QName{ .ns = "http://example.com/ns/", .local = "abc" }).is(null, "abc"));
        try testing.expect(!(QName{ .ns = "http://example.com/ns/", .local = "abc" }).is("http://example.com/ns2/", "abc"));
        try testing.expect(!(QName{ .ns = "http://example.com/ns/", .local = "abc" }).is("http://example.com/ns/", "def"));
        try testing.expect(!(QName{ .ns = "http://example.com/ns/", .local = "abc" }).is("http://example.com/ns2/", "def"));
    }

    fn clone(self: QName, allocator: Allocator) !QName {
        const prefix = if (self.prefix) |prefix| try allocator.dupe(u8, prefix) else null;
        errdefer if (prefix) |p| allocator.free(p);
        const ns = if (self.ns) |ns| try allocator.dupe(u8, ns) else null;
        errdefer if (ns) |n| allocator.free(n);
        const local = try allocator.dupe(u8, self.local);
        return .{ .prefix = prefix, .ns = ns, .local = local };
    }

    /// Duplicates the `ns` value, if any.
    ///
    /// This is to allow the `QName` to outlive the closure of its containing
    /// scope.
    inline fn dupNs(self: *QName, allocator: Allocator) !void {
        if (self.ns) |*ns| {
            ns.* = try allocator.dupe(u8, ns.*);
        }
    }
};

/// An event emitted by a reader.
pub const Event = union(enum) {
    xml_declaration: XmlDeclaration,
    element_start: ElementStart,
    element_content: ElementContent,
    element_end: ElementEnd,
    comment: Comment,
    pi: Pi,

    pub const XmlDeclaration = struct {
        version: []const u8,
        encoding: ?[]const u8 = null,
        standalone: ?bool = null,
    };

    pub const ElementStart = struct {
        name: QName,
        attributes: []const Attribute = &.{},
    };

    pub const Attribute = struct {
        name: QName,
        value: []const u8,
    };

    pub const ElementContent = struct {
        content: []const u8,
    };

    pub const ElementEnd = struct {
        name: QName,
    };

    pub const Comment = struct {
        content: []const u8,
    };

    pub const Pi = struct {
        target: []const u8,
        content: []const u8,
    };
};

/// A map of predefined XML entities to their replacement text.
///
/// Until DTDs are understood and parsed, these are the only named entities
/// supported by this parser.
const entities = ComptimeStringMap([]const u8, .{
    .{ "amp", "&" },
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "apos", "'" },
    .{ "quot", "\"" },
});

const xml_ns = "http://www.w3.org/XML/1998/namespace";
const xmlns_ns = "http://www.w3.org/2000/xmlns/";

const predefined_ns_prefixes = ComptimeStringMap([]const u8, .{
    .{ "xml", xml_ns },
    .{ "xmlns", xmlns_ns },
});

/// A context for namespace information in a document.
///
/// The context maintains a hierarchy of namespace scopes. Initially, there is
/// no active scope (corresponding to the beginning of a document, before the
/// start of the root element).
const NamespaceContext = struct {
    scopes: ArrayListUnmanaged(StringHashMapUnmanaged([]const u8)) = .{},

    pub fn deinit(self: *NamespaceContext, allocator: Allocator) void {
        while (self.scopes.items.len > 0) {
            self.endScope(allocator);
        }
        self.scopes.deinit(allocator);
        self.* = undefined;
    }

    /// Starts a new scope.
    pub fn startScope(self: *NamespaceContext, allocator: Allocator) !void {
        try self.scopes.append(allocator, .{});
    }

    /// Ends the current scope.
    ///
    /// Only valid if there is a current scope.
    pub fn endScope(self: *NamespaceContext, allocator: Allocator) void {
        var bindings = self.scopes.pop();
        var iter = bindings.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        bindings.deinit(allocator);
    }

    /// Binds the default namespace in the current scope.
    ///
    /// Only valid if there is a current scope.
    pub inline fn bindDefault(self: *NamespaceContext, allocator: Allocator, uri: []const u8) !void {
        try self.bindInner(allocator, "", uri);
    }

    /// Binds a prefix in the current scope.
    ///
    /// Only valid if there is a current scope.
    pub inline fn bindPrefix(self: *NamespaceContext, allocator: Allocator, prefix: []const u8, uri: []const u8) !void {
        if (!syntax.isNcName(prefix)) {
            return error.InvalidNsPrefix;
        }
        try self.bindInner(allocator, prefix, uri);
    }

    fn bindInner(self: *NamespaceContext, allocator: Allocator, prefix: []const u8, uri: []const u8) !void {
        // TODO: validate that uri is a valid URI reference
        if (prefix.len != 0 and uri.len == 0) {
            return error.CannotUndeclareNsPrefix;
        }
        var bindings = &self.scopes.items[self.scopes.items.len - 1];
        const key = try allocator.dupe(u8, prefix);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, uri);
        errdefer allocator.free(value);
        // We cannot clobber an existing prefix in this scope because that
        // would imply a duplicate attribute name, which is validated earlier.
        try bindings.putNoClobber(allocator, key, value);
    }

    /// Returns the URI, if any, bound to the given prefix.
    pub fn getUri(self: NamespaceContext, prefix: []const u8) ?[]const u8 {
        if (predefined_ns_prefixes.get(prefix)) |uri| {
            return uri;
        }
        return for (0..self.scopes.items.len) |i| {
            if (self.scopes.items[self.scopes.items.len - i - 1].get(prefix)) |uri| {
                break if (uri.len > 0) uri else null;
            }
        } else null;
    }

    /// Parses a possibly prefixed name and returns the corresponding `QName`.
    ///
    /// `use_default_ns` specifies if the default namespace (if any) should be
    /// implied for the given name if it is unprefixed. This is appropriate for
    /// element names but not attribute names, per the namespaces spec.
    pub fn parseName(self: NamespaceContext, name: []const u8, use_default_ns: bool) !QName {
        if (mem.indexOfScalar(u8, name, ':')) |sep_pos| {
            const prefix = name[0..sep_pos];
            const local = name[sep_pos + 1 ..];
            if (!syntax.isNcName(prefix) or !syntax.isNcName(local)) {
                return error.InvalidQName;
            }
            const ns = self.getUri(prefix) orelse return error.UndeclaredNsPrefix;
            return .{ .prefix = prefix, .ns = ns, .local = local };
        } else if (use_default_ns) {
            return .{ .ns = self.getUri(""), .local = name };
        } else {
            return .{ .local = name };
        }
    }
};

/// A drop-in replacement for `NamespaceContext` which doesn't actually do any
/// namespace processing.
const UnawareNamespaceContext = struct {
    pub inline fn deinit(_: *UnawareNamespaceContext, _: Allocator) void {}

    pub inline fn startScope(_: *UnawareNamespaceContext, _: Allocator) !void {}

    pub inline fn endScope(_: *UnawareNamespaceContext, _: Allocator) void {}

    pub inline fn bindDefault(_: *UnawareNamespaceContext, _: Allocator, _: []const u8) !void {}

    pub inline fn bindPrefix(_: *UnawareNamespaceContext, _: Allocator, _: []const u8, _: []const u8) !void {}

    pub inline fn getUri(_: UnawareNamespaceContext, _: []const u8) ?[]const u8 {
        return null;
    }

    pub inline fn parseName(_: UnawareNamespaceContext, name: []const u8, _: bool) !QName {
        return .{ .local = name };
    }
};

/// Returns a `Reader` wrapping a `std.io.Reader`.
pub fn reader(
    allocator: Allocator,
    r: anytype,
    decoder: anytype,
    comptime options: ReaderOptions,
) Reader(@TypeOf(r), @TypeOf(decoder), options) {
    return Reader(@TypeOf(r), @TypeOf(decoder), options).init(allocator, r, decoder);
}

/// Reads a full XML document from a `std.io.Reader`.
pub fn readDocument(
    allocator: Allocator,
    r: anytype,
    decoder: anytype,
    comptime options: ReaderOptions,
) !OwnedValue(Node.Document) {
    var arena = ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const node_allocator = arena.allocator();

    var decl_version: []const u8 = "1.0";
    var decl_encoding: ?[]const u8 = null;
    var decl_standalone: ?bool = null;
    var children = ArrayListUnmanaged(Node){};

    var xml_reader = reader(allocator, r, decoder, options);
    defer xml_reader.deinit();
    while (try xml_reader.next()) |event| {
        switch (event) {
            .xml_declaration => |xml_declaration| {
                decl_version = try node_allocator.dupe(u8, xml_declaration.version);
                if (xml_declaration.encoding) |e| {
                    decl_encoding = try node_allocator.dupe(u8, e);
                }
                decl_standalone = xml_declaration.standalone;
            },
            .element_start => |element_start| try children.append(node_allocator, .{
                .element = try xml_reader.nextElementNode(node_allocator, element_start),
            }),
            .comment => |comment| try children.append(node_allocator, .{ .comment = .{
                .content = try node_allocator.dupe(u8, comment.content),
            } }),
            .pi => |pi| try children.append(node_allocator, .{ .pi = .{
                .target = try node_allocator.dupe(u8, pi.target),
                .content = try node_allocator.dupe(u8, pi.content),
            } }),
            else => unreachable,
        }
    }

    return .{
        .value = .{
            .version = decl_version,
            .encoding = decl_encoding,
            .standalone = decl_standalone,
            .children = children.items,
        },
        .arena = arena,
    };
}

/// Options for a `Reader`.
pub const ReaderOptions = struct {
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
    /// the line ending sequence `\r\n` will appear as-is in returned events
    /// rather than the normalized `\n`.
    enable_normalization: bool = true,
    /// Whether namespace information should be processed.
    ///
    /// If this is false, then `QName`s in the returned events will have only
    /// their `local` field populated, containing the full name of the element
    /// or attribute.
    namespace_aware: bool = true,
};

/// A streaming, pull-based XML parser wrapping a `std.io.Reader`.
///
/// This parser behaves similarly to Go's `encoding/xml` package. It is a
/// higher-level abstraction over a `TokenReader` which uses an internal
/// allocator to keep track of additional context. It performs additional
/// well-formedness checks which the lower-level parsers cannot perform due to
/// their design, such as ensuring element start and end tags match and
/// attribute names are not duplicated. It is also able to process namespace
/// information.
///
/// Since this parser wraps a `TokenReader`, the caveats on the `buffer_size`
/// bounding the length of "non-splittable" content which are outlined in its
/// documentation apply here as well.
pub fn Reader(
    comptime ReaderType: type,
    comptime DecoderType: type,
    comptime options: ReaderOptions,
) type {
    return struct {
        token_reader: TokenReaderType,
        /// A stack of element names enclosing the current context.
        element_names: ArrayListUnmanaged([]u8) = .{},
        /// The namespace context of the reader.
        namespace_context: if (options.namespace_aware) NamespaceContext else UnawareNamespaceContext = .{},
        /// A pending token which has been read but has not yet been handled as
        /// part of an event.
        pending_token: ?Token = null,
        /// A buffer for storing encoded Unicode codepoint data.
        codepoint_buf: [max_encoded_codepoint_len]u8 = undefined,
        /// A "buffer" for handling the contents of the next pending event.
        pending_event: union(enum) {
            none,
            element_start: struct {
                name: []const u8,
                attributes: StringArrayHashMapUnmanaged(ArrayListUnmanaged(u8)) = .{},
            },
            comment: struct { content: ArrayListUnmanaged(u8) = .{} },
            pi: struct { target: []const u8, content: ArrayListUnmanaged(u8) = .{} },
        } = .none,
        /// An arena to store memory for `pending_event` (and the event after
        /// it's returned).
        event_arena: ArenaAllocator,
        allocator: Allocator,

        const Self = @This();
        const TokenReaderType = TokenReader(ReaderType, DecoderType, .{
            .buffer_size = options.buffer_size,
            .enable_normalization = options.enable_normalization,
        });

        pub const Error = error{
            CannotUndeclareNsPrefix,
            DuplicateAttribute,
            InvalidNsPrefix,
            InvalidQName,
            MismatchedEndTag,
            UndeclaredEntityReference,
            UndeclaredNsPrefix,
        } || Allocator.Error || TokenReaderType.Error;

        pub fn init(allocator: Allocator, r: ReaderType, decoder: DecoderType) Self {
            return .{
                .token_reader = TokenReaderType.init(r, decoder),
                .event_arena = ArenaAllocator.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.element_names.items) |name| {
                self.allocator.free(name);
            }
            self.element_names.deinit(self.allocator);
            self.namespace_context.deinit(self.allocator);
            self.event_arena.deinit();
            self.* = undefined;
        }

        /// Returns the next event from the input.
        ///
        /// The returned event is only valid until the next reader operation.
        pub fn next(self: *Self) Error!?Event {
            _ = self.event_arena.reset(.retain_capacity);
            const event_allocator = self.event_arena.allocator();
            while (true) {
                const token = (try self.nextToken()) orelse return null;
                switch (token) {
                    .xml_declaration => |xml_declaration| return .{ .xml_declaration = .{
                        .version = xml_declaration.version,
                        .encoding = xml_declaration.encoding,
                        .standalone = xml_declaration.standalone,
                    } },
                    .element_start => |element_start| {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        const name = try self.allocator.dupe(u8, element_start.name);
                        errdefer self.allocator.free(name);
                        try self.element_names.append(self.allocator, name);
                        errdefer _ = self.element_names.pop();
                        try self.namespace_context.startScope(self.allocator);
                        self.pending_event = .{ .element_start = .{ .name = name } };
                    },
                    .element_content => |element_content| {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        return .{ .element_content = .{ .content = try self.contentText(element_content.content) } };
                    },
                    .element_end => |element_end| {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        const expected_name = self.element_names.pop();
                        defer self.allocator.free(expected_name);
                        if (!mem.eql(u8, expected_name, element_end.name)) {
                            return error.MismatchedEndTag;
                        }
                        var qname = try self.namespace_context.parseName(element_end.name, true);
                        try qname.dupNs(event_allocator);
                        self.namespace_context.endScope(self.allocator);
                        return .{ .element_end = .{ .name = qname } };
                    },
                    .element_end_empty => {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        const name = self.element_names.pop();
                        defer self.allocator.free(name);
                        const dup_name = try event_allocator.dupe(u8, name);
                        var qname = try self.namespace_context.parseName(dup_name, true);
                        try qname.dupNs(event_allocator);
                        self.namespace_context.endScope(self.allocator);
                        return .{ .element_end = .{ .name = qname } };
                    },
                    .attribute_start => |attribute_start| {
                        var attr_entry = try self.pending_event.element_start.attributes.getOrPut(event_allocator, attribute_start.name);
                        if (attr_entry.found_existing) {
                            return error.DuplicateAttribute;
                        }
                        // The attribute name will be invalidated after we get
                        // the next token, so we have to duplicate it here.
                        // This doesn't change the hash of the key, so it's
                        // safe to do this.
                        attr_entry.key_ptr.* = try event_allocator.dupe(u8, attribute_start.name);
                        attr_entry.value_ptr.* = .{};
                    },
                    .attribute_content => |attribute_content| {
                        const attributes = self.pending_event.element_start.attributes.values();
                        try attributes[attributes.len - 1].appendSlice(event_allocator, try self.contentText(attribute_content.content));
                    },
                    .comment_start => {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        self.pending_event = .{ .comment = .{} };
                    },
                    .comment_content => |comment_content| {
                        try self.pending_event.comment.content.appendSlice(event_allocator, comment_content.content);
                        if (comment_content.final) {
                            const event = Event{ .comment = .{ .content = self.pending_event.comment.content.items } };
                            self.pending_event = .none;
                            return event;
                        }
                    },
                    .pi_start => |pi_start| {
                        if (try self.finalizePendingEvent()) |event| {
                            self.pending_token = token;
                            return event;
                        }
                        self.pending_event = .{ .pi = .{ .target = try event_allocator.dupe(u8, pi_start.target) } };
                    },
                    .pi_content => |pi_content| {
                        try self.pending_event.pi.content.appendSlice(event_allocator, pi_content.content);
                        if (pi_content.final) {
                            const event = Event{ .pi = .{ .target = self.pending_event.pi.target, .content = self.pending_event.pi.content.items } };
                            self.pending_event = .none;
                            return event;
                        }
                    },
                }
            }
        }

        fn nextToken(self: *Self) !?Token {
            if (self.pending_token) |token| {
                self.pending_token = null;
                return token;
            }
            return try self.token_reader.next();
        }

        fn finalizePendingEvent(self: *Self) !?Event {
            const event_allocator = self.event_arena.allocator();
            switch (self.pending_event) {
                .none => return null,
                .element_start => |element_start| {
                    // Bind all xmlns declarations in the current element
                    for (element_start.attributes.keys(), element_start.attributes.values()) |attr_name, attr_value| {
                        if (mem.eql(u8, attr_name, "xmlns")) {
                            try self.namespace_context.bindDefault(self.allocator, attr_value.items);
                        } else if (mem.startsWith(u8, attr_name, "xmlns:")) {
                            try self.namespace_context.bindPrefix(self.allocator, attr_name["xmlns:".len..], attr_value.items);
                        }
                    }

                    // Convert the element and attribute names to QNames
                    const qname = try self.namespace_context.parseName(element_start.name, true);
                    var attributes = ArrayListUnmanaged(Event.Attribute){};
                    try attributes.ensureTotalCapacity(event_allocator, element_start.attributes.count());
                    for (element_start.attributes.keys(), element_start.attributes.values()) |attr_name, attr_value| {
                        attributes.appendAssumeCapacity(.{
                            .name = try self.namespace_context.parseName(attr_name, false),
                            .value = attr_value.items,
                        });
                    }

                    self.pending_event = .none;
                    return .{ .element_start = .{ .name = qname, .attributes = attributes.items } };
                },
                // Other pending events will have already been handled by
                // looking at the 'final' content event
                else => unreachable,
            }
        }

        fn contentText(self: *Self, content: Token.Content) ![]const u8 {
            return switch (content) {
                .text => |text| text,
                .codepoint => |codepoint| text: {
                    const len = unicode.utf8Encode(codepoint, &self.codepoint_buf) catch unreachable;
                    break :text self.codepoint_buf[0..len];
                },
                .entity => |entity| entities.get(entity) orelse return error.UndeclaredEntityReference,
            };
        }

        pub fn nextNode(self: *Self, allocator: Allocator, element_start: Event.ElementStart) Error!OwnedValue(Node.Element) {
            var arena = ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            return .{
                .value = try self.nextElementNode(arena.allocator(), element_start),
                .arena = arena,
            };
        }

        fn nextElementNode(self: *Self, allocator: Allocator, element_start: Event.ElementStart) Error!Node.Element {
            const name = try element_start.name.clone(allocator);
            var element_children = ArrayListUnmanaged(Node){};
            try element_children.ensureTotalCapacity(allocator, element_start.attributes.len);
            for (element_start.attributes) |attr| {
                element_children.appendAssumeCapacity(.{ .attribute = .{
                    .name = try attr.name.clone(allocator),
                    .value = try allocator.dupe(u8, attr.value),
                } });
            }
            var current_content = ArrayListUnmanaged(u8){};
            while (try self.next()) |event| {
                if (event != .element_content and current_content.items.len > 0) {
                    try element_children.append(allocator, .{ .text = .{ .content = current_content.items } });
                    current_content = .{};
                }
                switch (event) {
                    .xml_declaration => unreachable,
                    .element_start => |sub_element_start| try element_children.append(allocator, .{
                        .element = try self.nextElementNode(allocator, sub_element_start),
                    }),
                    .element_content => |element_content| try current_content.appendSlice(allocator, element_content.content),
                    .element_end => return .{ .name = name, .children = element_children.items },
                    .comment => |comment| try element_children.append(allocator, .{ .comment = .{
                        .content = try allocator.dupe(u8, comment.content),
                    } }),
                    .pi => |pi| try element_children.append(allocator, .{ .pi = .{
                        .target = try allocator.dupe(u8, pi.target),
                        .content = try allocator.dupe(u8, pi.content),
                    } }),
                }
            }
            unreachable;
        }

        /// Returns an iterator over the remaining children of the current
        /// element.
        ///
        /// Note that, since the returned iterator's `next` function calls the
        /// `next` function of this reader internally, such calls will
        /// invalidate any event returned prior to calling this function.
        pub fn children(self: *Self) Children(Self) {
            return .{ .reader = self, .start_depth = self.element_names.items.len };
        }
    };
}

fn Children(comptime ReaderType: type) type {
    return struct {
        reader: *ReaderType,
        start_depth: usize,

        const Self = @This();

        /// Returns the next event.
        ///
        /// This function must not be called after it initially returns null.
        pub fn next(self: Self) ReaderType.Error!?Event {
            return switch (try self.reader.next() orelse return null) {
                .element_end => |element_end| if (self.reader.element_names.items.len >= self.start_depth) .{ .element_end = element_end } else null,
                else => |event| event,
            };
        }

        /// Returns an iterator over the remaining children of the current
        /// element.
        ///
        /// This may not be used after `next` returns null.
        pub fn children(self: Self) Self {
            return self.reader.children();
        }

        /// Skips the remaining children.
        ///
        /// `next` and `children` must not be used after this.
        pub fn skip(self: Self) ReaderType.Error!void {
            while (try self.next()) |_| {}
        }
    };
}

test Reader {
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
        .{ .pi = .{ .target = "some-pi", .content = "" } },
        .{ .comment = .{ .content = " A processing instruction with content follows " } },
        .{ .pi = .{ .target = "some-pi-with-content", .content = "content" } },
        .{ .element_start = .{ .name = .{ .local = "root" } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_start = .{ .name = .{ .local = "p" }, .attributes = &.{
            .{ .name = .{ .local = "class" }, .value = "test" },
        } } },
        .{ .element_content = .{ .content = "Hello, " } },
        .{ .element_content = .{ .content = "world!" } },
        .{ .element_end = .{ .name = .{ .local = "p" } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_start = .{ .name = .{ .local = "line" } } },
        .{ .element_end = .{ .name = .{ .local = "line" } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .pi = .{ .target = "another-pi", .content = "" } },
        .{ .element_content = .{ .content = "\n  Text content goes here.\n  " } },
        .{ .element_start = .{ .name = .{ .local = "div" } } },
        .{ .element_start = .{ .name = .{ .local = "p" } } },
        .{ .element_content = .{ .content = "&" } },
        .{ .element_end = .{ .name = .{ .local = "p" } } },
        .{ .element_end = .{ .name = .{ .local = "div" } } },
        .{ .element_content = .{ .content = "\n" } },
        .{ .element_end = .{ .name = .{ .local = "root" } } },
        .{ .comment = .{ .content = " Comments are allowed after the end of the root element " } },
        .{ .pi = .{ .target = "comment", .content = "So are PIs " } },
    });
}

test "namespace handling" {
    try testValid(.{},
        \\<a:root xmlns:a="urn:1">
        \\  <child xmlns="urn:2" xmlns:b="urn:3" attr="value">
        \\    <b:child xmlns:a="urn:4" b:attr="value">
        \\      <a:child />
        \\    </b:child>
        \\  </child>
        \\</a:root>
    , &.{
        .{ .element_start = .{ .name = .{ .prefix = "a", .ns = "urn:1", .local = "root" }, .attributes = &.{
            .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "a" }, .value = "urn:1" },
        } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_start = .{ .name = .{ .ns = "urn:2", .local = "child" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns" }, .value = "urn:2" },
            .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "b" }, .value = "urn:3" },
            .{ .name = .{ .local = "attr" }, .value = "value" },
        } } },
        .{ .element_content = .{ .content = "\n    " } },
        .{ .element_start = .{ .name = .{ .prefix = "b", .ns = "urn:3", .local = "child" }, .attributes = &.{
            .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "a" }, .value = "urn:4" },
            .{ .name = .{ .prefix = "b", .ns = "urn:3", .local = "attr" }, .value = "value" },
        } } },
        .{ .element_content = .{ .content = "\n      " } },
        .{ .element_start = .{ .name = .{ .prefix = "a", .ns = "urn:4", .local = "child" } } },
        .{ .element_end = .{ .name = .{ .prefix = "a", .ns = "urn:4", .local = "child" } } },
        .{ .element_content = .{ .content = "\n    " } },
        .{ .element_end = .{ .name = .{ .prefix = "b", .ns = "urn:3", .local = "child" } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_end = .{ .name = .{ .ns = "urn:2", .local = "child" } } },
        .{ .element_content = .{ .content = "\n" } },
        .{ .element_end = .{ .name = .{ .prefix = "a", .ns = "urn:1", .local = "root" } } },
    });
    try testInvalid(.{}, "<a:root />", error.UndeclaredNsPrefix);
    try testInvalid(.{}, "<: />", error.InvalidQName);
    try testInvalid(.{}, "<a: />", error.InvalidQName);
    try testInvalid(.{}, "<:a />", error.InvalidQName);
    try testInvalid(.{}, "<root xmlns:='urn:1' />", error.InvalidNsPrefix);
    try testInvalid(.{}, "<root xmlns::='urn:1' />", error.InvalidNsPrefix);
    try testInvalid(.{}, "<root xmlns:a:b='urn:1' />", error.InvalidNsPrefix);
    try testInvalid(.{}, "<root xmlns='urn:1' xmlns='urn:2' />", error.DuplicateAttribute);
    try testInvalid(.{}, "<root xmlns:abc='urn:1' xmlns:abc='urn:2' />", error.DuplicateAttribute);

    try testValid(.{ .namespace_aware = false },
        \\<a:root xmlns:a="urn:1">
        \\  <child xmlns="urn:2" xmlns:b="urn:3" attr="value">
        \\    <b:child xmlns:a="urn:4" b:attr="value">
        \\      <a:child />
        \\    </b:child>
        \\  </child>
        \\</a:root>
    , &.{
        .{ .element_start = .{ .name = .{ .local = "a:root" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns:a" }, .value = "urn:1" },
        } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_start = .{ .name = .{ .local = "child" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns" }, .value = "urn:2" },
            .{ .name = .{ .local = "xmlns:b" }, .value = "urn:3" },
            .{ .name = .{ .local = "attr" }, .value = "value" },
        } } },
        .{ .element_content = .{ .content = "\n    " } },
        .{ .element_start = .{ .name = .{ .local = "b:child" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns:a" }, .value = "urn:4" },
            .{ .name = .{ .local = "b:attr" }, .value = "value" },
        } } },
        .{ .element_content = .{ .content = "\n      " } },
        .{ .element_start = .{ .name = .{ .local = "a:child" } } },
        .{ .element_end = .{ .name = .{ .local = "a:child" } } },
        .{ .element_content = .{ .content = "\n    " } },
        .{ .element_end = .{ .name = .{ .local = "b:child" } } },
        .{ .element_content = .{ .content = "\n  " } },
        .{ .element_end = .{ .name = .{ .local = "child" } } },
        .{ .element_content = .{ .content = "\n" } },
        .{ .element_end = .{ .name = .{ .local = "a:root" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<a:root />", &.{
        .{ .element_start = .{ .name = .{ .local = "a:root" } } },
        .{ .element_end = .{ .name = .{ .local = "a:root" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<: />", &.{
        .{ .element_start = .{ .name = .{ .local = ":" } } },
        .{ .element_end = .{ .name = .{ .local = ":" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<a: />", &.{
        .{ .element_start = .{ .name = .{ .local = "a:" } } },
        .{ .element_end = .{ .name = .{ .local = "a:" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<:a />", &.{
        .{ .element_start = .{ .name = .{ .local = ":a" } } },
        .{ .element_end = .{ .name = .{ .local = ":a" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<root xmlns:='urn:1' />", &.{
        .{ .element_start = .{ .name = .{ .local = "root" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns:" }, .value = "urn:1" },
        } } },
        .{ .element_end = .{ .name = .{ .local = "root" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<root xmlns::='urn:1' />", &.{
        .{ .element_start = .{ .name = .{ .local = "root" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns::" }, .value = "urn:1" },
        } } },
        .{ .element_end = .{ .name = .{ .local = "root" } } },
    });
    try testValid(.{ .namespace_aware = false }, "<root xmlns:a:b='urn:1' />", &.{
        .{ .element_start = .{ .name = .{ .local = "root" }, .attributes = &.{
            .{ .name = .{ .local = "xmlns:a:b" }, .value = "urn:1" },
        } } },
        .{ .element_end = .{ .name = .{ .local = "root" } } },
    });
    try testInvalid(.{ .namespace_aware = false }, "<root xmlns='urn:1' xmlns='urn:2' />", error.DuplicateAttribute);
    try testInvalid(.{ .namespace_aware = false }, "<root xmlns:abc='urn:1' xmlns:abc='urn:2' />", error.DuplicateAttribute);
}

fn testValid(comptime options: ReaderOptions, input: []const u8, expected_events: []const Event) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, options);
    defer input_reader.deinit();
    var i: usize = 0;
    while (try input_reader.next()) |event| : (i += 1) {
        if (i >= expected_events.len) {
            std.debug.print("Unexpected event after end: {}\n", .{event});
            return error.TestFailed;
        }
        testing.expectEqualDeep(expected_events[i], event) catch |e| {
            std.debug.print("(at index {})\n", .{i});
            return e;
        };
    }
    if (i != expected_events.len) {
        std.debug.print("Expected {} events, found {}\n", .{ expected_events.len, i });
        return error.TestFailed;
    }
}

fn testInvalid(comptime options: ReaderOptions, input: []const u8, expected_error: anyerror) !void {
    var input_stream = std.io.fixedBufferStream(input);
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, options);
    defer input_reader.deinit();
    while (input_reader.next()) |_| {} else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "nextNode" {
    // See https://github.com/ziglang/zig/pull/14981
    if (true) return error.SkipZigTest;

    var input_stream = std.io.fixedBufferStream(
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
    );
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, .{});
    defer input_reader.deinit();

    try testing.expectEqualDeep(@as(?Event, .{ .xml_declaration = .{ .version = "1.0" } }), try input_reader.next());
    try testing.expectEqualDeep(@as(?Event, .{ .pi = .{ .target = "some-pi", .content = "" } }), try input_reader.next());
    try testing.expectEqualDeep(@as(?Event, .{ .comment = .{ .content = " A processing instruction with content follows " } }), try input_reader.next());
    try testing.expectEqualDeep(@as(?Event, .{ .pi = .{ .target = "some-pi-with-content", .content = "content" } }), try input_reader.next());

    const root_start = try input_reader.next();
    try testing.expect(root_start != null and root_start.? == .element_start);
    var root_node = try input_reader.nextNode(testing.allocator, root_start.?.element_start);
    defer root_node.deinit();
    try testing.expectEqualDeep(Node.Element{ .name = .{ .local = "root" }, .children = &.{
        .{ .text = .{ .content = "\n  " } },
        .{ .element = .{ .name = .{ .local = "p" }, .children = &.{
            .{ .attribute = .{ .name = .{ .local = "class" }, .value = "test" } },
            .{ .text = .{ .content = "Hello, world!" } },
        } } },
        .{ .text = .{ .content = "\n  " } },
        .{ .element = .{ .name = .{ .local = "line" }, .children = &.{} } },
        .{ .text = .{ .content = "\n  " } },
        .{ .pi = .{ .target = "another-pi", .content = "" } },
        .{ .text = .{ .content = "\n  Text content goes here.\n  " } },
        .{ .element = .{ .name = .{ .local = "div" }, .children = &.{
            .{ .element = .{ .name = .{ .local = "p" }, .children = &.{
                .{ .text = .{ .content = "&" } },
            } } },
        } } },
        .{ .text = .{ .content = "\n" } },
    } }, root_node.value);

    try testing.expectEqualDeep(@as(?Event, .{ .comment = .{ .content = " Comments are allowed after the end of the root element " } }), try input_reader.next());
    try testing.expectEqualDeep(@as(?Event, .{ .pi = .{ .target = "comment", .content = "So are PIs " } }), try input_reader.next());
    try testing.expect(try input_reader.next() == null);
}

test "nextNode namespace handling" {
    // See https://github.com/ziglang/zig/pull/14981
    if (true) return error.SkipZigTest;

    var input_stream = std.io.fixedBufferStream(
        \\<a:root xmlns:a="urn:1">
        \\  <child xmlns="urn:2" xmlns:b="urn:3" attr="value">
        \\    <b:child xmlns:a="urn:4" b:attr="value">
        \\      <a:child />
        \\    </b:child>
        \\  </child>
        \\</a:root>
    );
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, .{});
    defer input_reader.deinit();

    var root_start = try input_reader.next();
    try testing.expect(root_start != null and root_start.? == .element_start);
    var root_node = try input_reader.nextNode(testing.allocator, root_start.?.element_start);
    defer root_node.deinit();
    try testing.expectEqualDeep(Node.Element{ .name = .{ .prefix = "a", .ns = "urn:1", .local = "root" }, .children = &.{
        .{ .attribute = .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "a" }, .value = "urn:1" } },
        .{ .text = .{ .content = "\n  " } },
        .{ .element = .{ .name = .{ .ns = "urn:2", .local = "child" }, .children = &.{
            .{ .attribute = .{ .name = .{ .local = "xmlns" }, .value = "urn:2" } },
            .{ .attribute = .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "b" }, .value = "urn:3" } },
            .{ .attribute = .{ .name = .{ .local = "attr" }, .value = "value" } },
            .{ .text = .{ .content = "\n    " } },
            .{ .element = .{ .name = .{ .prefix = "b", .ns = "urn:3", .local = "child" }, .children = &.{
                .{ .attribute = .{ .name = .{ .prefix = "xmlns", .ns = xmlns_ns, .local = "a" }, .value = "urn:4" } },
                .{ .attribute = .{ .name = .{ .prefix = "b", .ns = "urn:3", .local = "attr" }, .value = "value" } },
                .{ .text = .{ .content = "\n      " } },
                .{ .element = .{ .name = .{ .prefix = "a", .ns = "urn:4", .local = "child" } } },
                .{ .text = .{ .content = "\n    " } },
            } } },
            .{ .text = .{ .content = "\n  " } },
        } } },
        .{ .text = .{ .content = "\n" } },
    } }, root_node.value);
}

test readDocument {
    // See https://github.com/ziglang/zig/pull/14981
    if (true) return error.SkipZigTest;

    var input_stream = std.io.fixedBufferStream(
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
    );
    var document_node = try readDocument(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, .{});
    defer document_node.deinit();

    try testing.expectEqualDeep(Node.Document{ .version = "1.0", .children = &.{
        .{ .pi = .{ .target = "some-pi", .content = "" } },
        .{ .comment = .{ .content = " A processing instruction with content follows " } },
        .{ .pi = .{ .target = "some-pi-with-content", .content = "content" } },
        .{ .element = .{ .name = .{ .local = "root" }, .children = &.{
            .{ .text = .{ .content = "\n  " } },
            .{ .element = .{ .name = .{ .local = "p" }, .children = &.{
                .{ .attribute = .{ .name = .{ .local = "class" }, .value = "test" } },
                .{ .text = .{ .content = "Hello, world!" } },
            } } },
            .{ .text = .{ .content = "\n  " } },
            .{ .element = .{ .name = .{ .local = "line" }, .children = &.{} } },
            .{ .text = .{ .content = "\n  " } },
            .{ .pi = .{ .target = "another-pi", .content = "" } },
            .{ .text = .{ .content = "\n  Text content goes here.\n  " } },
            .{ .element = .{ .name = .{ .local = "div" }, .children = &.{
                .{ .element = .{ .name = .{ .local = "p" }, .children = &.{
                    .{ .text = .{ .content = "&" } },
                } } },
            } } },
            .{ .text = .{ .content = "\n" } },
        } } },
        .{ .comment = .{ .content = " Comments are allowed after the end of the root element " } },
        .{ .pi = .{ .target = "comment", .content = "So are PIs " } },
    } }, document_node.value);
}

test Children {
    var input_stream = std.io.fixedBufferStream(
        \\<root>
        \\  Hello, world!
        \\  <child1 attr="value">Some content.</child1>
        \\  <child2><!-- Comment --><child3/></child2>
        \\</root>
    );
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, .{});
    defer input_reader.deinit();

    try testing.expectEqualDeep(@as(?Event, .{ .element_start = .{ .name = .{ .local = "root" } } }), try input_reader.next());
    const root_children = input_reader.children();
    try testing.expectEqualDeep(@as(?Event, .{ .element_content = .{ .content = "\n  Hello, world!\n  " } }), try root_children.next());
    try testing.expectEqualDeep(@as(?Event, .{ .element_start = .{ .name = .{ .local = "child1" }, .attributes = &.{
        .{ .name = .{ .local = "attr" }, .value = "value" },
    } } }), try root_children.next());
    const child1_children = root_children.children();
    try testing.expectEqualDeep(@as(?Event, .{ .element_content = .{ .content = "Some content." } }), try child1_children.next());
    try testing.expectEqual(@as(?Event, null), try child1_children.next());
    try testing.expectEqualDeep(@as(?Event, .{ .element_content = .{ .content = "\n  " } }), try root_children.next());
    try testing.expectEqualDeep(@as(?Event, .{ .element_start = .{ .name = .{ .local = "child2" } } }), try root_children.next());
    const child2_children = root_children.children();
    try testing.expectEqualDeep(@as(?Event, .{ .comment = .{ .content = " Comment " } }), try child2_children.next());
    try testing.expectEqualDeep(@as(?Event, .{ .element_start = .{ .name = .{ .local = "child3" } } }), try child2_children.next());
    const child3_children = child2_children.children();
    try testing.expectEqual(@as(?Event, null), try child3_children.next());
    try testing.expectEqual(@as(?Event, null), try child2_children.next());
    try testing.expectEqualDeep(@as(?Event, .{ .element_content = .{ .content = "\n" } }), try root_children.next());
    try testing.expectEqual(@as(?Event, null), try root_children.next());
}

test "skip children" {
    var input_stream = std.io.fixedBufferStream(
        \\<root>
        \\  Hello, world!
        \\  <child1 attr="value">Some content.</child1>
        \\  <child2><!-- Comment --><child3/></child2>
        \\</root>
    );
    var input_reader = reader(testing.allocator, input_stream.reader(), encoding.Utf8Decoder{}, .{});
    defer input_reader.deinit();

    try testing.expectEqualDeep(@as(?Event, .{ .element_start = .{ .name = .{ .local = "root" } } }), try input_reader.next());
    const root_children = input_reader.children();
    try root_children.skip();
    try testing.expectEqual(@as(?Event, null), try input_reader.next());
}
