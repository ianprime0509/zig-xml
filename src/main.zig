const std = @import("std");
const testing = std.testing;

pub const Scanner = @import("Scanner.zig");
const read = @import("reader.zig");
pub const Event = read.Event;
pub const reader = read.reader;
pub const Reader = read.Reader;

test {
    testing.refAllDecls(@This());
}
