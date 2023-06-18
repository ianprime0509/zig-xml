const std = @import("std");
const testing = std.testing;

pub const encoding = @import("encoding.zig");

pub const Scanner = @import("Scanner.zig");

pub const tokenReader = @import("token_reader.zig").tokenReader;
pub const TokenReader = @import("token_reader.zig").TokenReader;
pub const Token = @import("token_reader.zig").Token;

pub const reader = @import("reader.zig").reader;
pub const readDocument = @import("reader.zig").readDocument;
pub const Reader = @import("reader.zig").Reader;
pub const QName = @import("reader.zig").QName;
pub const Event = @import("reader.zig").Event;

pub const Node = @import("node.zig").Node;
pub const OwnedValue = @import("node.zig").OwnedValue;

test {
    testing.refAllDecls(@This());
}
