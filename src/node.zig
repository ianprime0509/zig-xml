const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
const QName = @import("reader.zig").QName;

pub const OwnedNode = struct {
    node: Node,
    arena: ArenaAllocator,

    pub fn deinit(self: *OwnedNode) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Node = union(enum) {
    element: Element,
    attribute: Attribute,
    comment: Comment,
    pi: Pi,
    text: Text,

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
