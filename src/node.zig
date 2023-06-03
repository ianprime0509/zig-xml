const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;

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
        name: []const u8,
        children: []const Node,

        pub fn attribute(self: Element, name: []const u8) ?Attribute {
            for (self.children) |child| {
                switch (child) {
                    .attribute => |attr| if (mem.eql(u8, attr.name, name)) {
                        return attr;
                    },
                    // There cannot be attributes after non-attribute children
                    else => return null,
                }
            }
            return null;
        }
    };

    pub const Attribute = struct {
        name: []const u8,
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
