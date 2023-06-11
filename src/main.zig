const std = @import("std");
const testing = std.testing;

pub const Scanner = @import("Scanner.zig");

pub const encoding = @import("encoding.zig");

const read = @import("reader.zig");
pub const Event = read.Event;
pub const reader = read.reader;
pub const Reader = read.Reader;
pub const NamespaceContext = read.NamespaceContext;
pub const QName = read.QName;

const node = @import("node.zig");
pub const Node = node.Node;
pub const OwnedNode = node.OwnedNode;

test {
    testing.refAllDecls(@This());
}
