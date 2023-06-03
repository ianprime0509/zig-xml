const std = @import("std");
const fmt = std.fmt;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Scanner = @import("Scanner.zig");

/// An event emitted by a reader.
pub const Event = union(enum) {
    element_start: struct { name: []const u8 },
    element_content: struct { element_name: []const u8, content: Content },
    element_end: struct { name: []const u8 },
    attribute_start: struct { element_name: []const u8, name: []const u8 },
    attribute_content: struct { element_name: []const u8, attribute_name: []const u8, content: Content },
    comment_start,
    comment_content: struct { content: []const u8 },
    pi_start: struct { target: []const u8 },
    pi_content: struct { pi_target: []const u8, content: []const u8 },

    pub const Content = union(enum) {
        text: []const u8,
        entity_ref: []const u8,
        char_ref: u21,
    };
};

// Once we understand DTDs, we can include custom entities somehow
const entities = std.ComptimeStringMap([]const u8, .{
    .{ "amp", "&" },
    .{ "lt", "<" },
    .{ "gt", ">" },
    .{ "apos", "'" },
    .{ "quot", "\"" },
});

/// Wraps a `std.io.Reader` in a `Reader` of the default buffer size.
pub fn reader(allocator: Allocator, r: anytype) Reader(4096, @TypeOf(r)) {
    return Reader(4096, @TypeOf(r)).init(allocator, r);
}

/// A streaming XML parser wrapping a `std.io.Reader`.
///
/// This parser is a higher-level wrapper around a `Scanner`, providing an API
/// which vaguely mimics a StAX pull-based XML parser as found in other
/// libraries. It performs the additional well-formedness checks on the input
/// which `Scanner` is unable to perform due to its design, such as verifying
/// that end element tag names match the corresponding start tag names.
pub fn Reader(comptime buffer_size: usize, comptime ReaderType: type) type {
    return struct {
        scanner: Scanner,
        reader: ReaderType,
        buffer: [buffer_size]u8 = undefined,
        /// A stack of element names enclosing the current context.
        element_names: ArrayListUnmanaged([]u8) = .{},
        /// The last element name, if we just encountered the end of an empty element.
        last_element_name: ?[]u8 = null,
        /// The current attribute name we're parsing, if any.
        attribute_name: ?[]u8 = null,
        /// The current PI target we're parsing, if any.
        pi_target: ?[]u8 = null,
        allocator: Allocator,

        const Self = @This();

        pub const Error = error{
            SyntaxError,
            UnexpectedEndOfInput,
            Overflow,
        } || Allocator.Error || ReaderType.Error;

        pub fn init(allocator: Allocator, r: ReaderType) Self {
            return .{
                .scanner = Scanner{},
                .reader = r,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.element_names.items) |name| {
                self.allocator.free(name);
            }
            self.element_names.deinit(self.allocator);

            if (self.last_element_name) |last_element_name| {
                self.allocator.free(last_element_name);
            }

            if (self.attribute_name) |attribute_name| {
                self.allocator.free(attribute_name);
            }

            if (self.pi_target) |pi_target| {
                self.allocator.free(pi_target);
            }

            self.* = undefined;
        }

        pub fn next(self: *Self) Error!?Event {
            if (self.last_element_name) |last_element_name| {
                // last_element_name is only a holding area to return a valid
                // element_end event for an empty element. Since events are
                // invalidated after the next call to next, we no longer need
                // it.
                self.allocator.free(last_element_name);
                self.last_element_name = null;
            }

            if (self.scanner.pos > 0) {
                // If the scanner position is > 0, that means we emitted an event
                // on the last call to next, and should try to reset the
                // position again in an effort to not run out of buffer space
                // (ideally, the scanner should be resettable after every token,
                // but we do not depend on this).
                if (self.scanner.resetPos()) |token| {
                    if (try self.tokenToEvent(token)) |event| {
                        return event;
                    }
                } else |_| {
                    // Failure to reset isn't fatal (yet); we can still try to
                    // complete the token below
                }
            }

            while (true) {
                if (self.scanner.pos == self.buffer.len) {
                    const token = self.scanner.resetPos() catch |e| switch (e) {
                        error.CannotReset => return error.Overflow,
                    };
                    if (try self.tokenToEvent(token)) |event| {
                        return event;
                    }
                }

                const c = self.reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => {
                        try self.scanner.endInput();
                        return null;
                    },
                    else => |other| return other,
                };
                self.buffer[self.scanner.pos] = c;
                if (try self.tokenToEvent(try self.scanner.next(c))) |event| {
                    return event;
                }
            }
        }

        fn tokenToEvent(self: *Self, token: Scanner.Token) !?Event {
            switch (token) {
                .ok => return null,

                // This should eventually be handled, but currently it is not
                // very useful
                .xml_declaration => return null,

                .element_start => |element_start| {
                    const name = try self.bufRangeDupe(element_start.name);
                    errdefer self.allocator.free(name);
                    try self.element_names.append(self.allocator, name);
                    return .{ .element_start = .{ .name = name } };
                },

                .element_content => |element_content| return .{ .element_content = .{
                    .element_name = self.element_names.getLast(),
                    .content = try self.convertContent(element_content.content),
                } },

                .element_end => |element_end| {
                    const name = self.bufRange(element_end.name);
                    const current_element_name = self.element_names.pop();
                    defer self.allocator.free(current_element_name);
                    if (!std.mem.eql(u8, name, current_element_name)) {
                        return error.SyntaxError;
                    }
                    return .{ .element_end = .{ .name = name } };
                },

                .element_end_empty => {
                    const current_element_name = self.element_names.pop();
                    self.last_element_name = current_element_name;
                    return .{ .element_end = .{ .name = current_element_name } };
                },

                .attribute_start => |attribute_start| {
                    if (self.attribute_name) |attribute_name| {
                        self.allocator.free(attribute_name);
                    }
                    const name = try self.bufRangeDupe(attribute_start.name);
                    self.attribute_name = name;
                    return .{ .attribute_start = .{
                        .element_name = self.element_names.getLast(),
                        .name = name,
                    } };
                },

                .attribute_content => |attribute_content| return .{ .attribute_content = .{
                    .element_name = self.element_names.getLast(),
                    .attribute_name = self.attribute_name.?,
                    .content = try self.convertContent(attribute_content.content),
                } },

                .comment_start => return .comment_start,

                .comment_content => |comment_content| return .{ .comment_content = .{
                    .content = self.bufRange(comment_content.content),
                } },

                .pi_start => |pi_start| {
                    if (self.pi_target) |pi_target| {
                        self.allocator.free(pi_target);
                    }
                    const target = try self.bufRangeDupe(pi_start.target);
                    self.pi_target = target;
                    return .{ .pi_start = .{ .target = target } };
                },

                .pi_content => |pi_content| return .{ .pi_content = .{
                    .pi_target = self.pi_target.?,
                    .content = self.bufRange(pi_content.content),
                } },
            }
        }

        fn convertContent(self: *const Self, content: Scanner.Content) !Event.Content {
            return switch (content) {
                .text => |text| .{ .text = self.bufRange(text) },
                .entity_ref => |entity_ref| .{ .entity_ref = self.bufRange(entity_ref) },
                .char_ref_dec => |char_ref| .{ .char_ref = fmt.parseInt(u21, self.bufRange(char_ref), 10) catch return error.SyntaxError },
                .char_ref_hex => |char_ref| .{ .char_ref = fmt.parseInt(u21, self.bufRange(char_ref), 16) catch return error.SyntaxError },
            };
        }

        inline fn bufRange(self: *const Self, range: Scanner.Range) []const u8 {
            return self.buffer[range.start..range.end];
        }

        inline fn bufRangeDupe(self: *const Self, range: Scanner.Range) ![]u8 {
            return try self.allocator.dupe(u8, self.bufRange(range));
        }
    };
}
