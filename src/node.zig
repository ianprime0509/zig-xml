const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
const QName = @import("reader.zig").QName;

pub fn OwnedValue(comptime T: type) type {
    return struct {
        value: T,
        arena: ArenaAllocator,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const Node = union(enum) {
    document: Document,
    element: Element,
    attribute: Attribute,
    comment: Comment,
    pi: Pi,
    text: Text,

    pub const Document = struct {
        version: []const u8 = "1.0",
        encoding: ?[]const u8 = null,
        standalone: ?bool = null,
        children: []const Node,
    };

    pub const Element = struct {
        name: QName,
        children: []const Node = &.{},
    };

    pub const Attribute = struct {
        name: QName,
        value: []const u8,
    };

    pub const Comment = struct {
        content: []const u8,
    };

    pub const Pi = struct {
        target: []const u8,
        content: []const u8,
    };

    pub const Text = struct {
        content: []const u8,
    };
};
