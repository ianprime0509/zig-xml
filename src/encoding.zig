//! Various encoding-related utilities.
//!
//! The central "interface" of this file is `Decoder`, which decodes XML
//! content into Unicode codepoints for further processing. It consists
//! of an error type `Error` and two functions:
//!
//! - `fn next(self: *Decoder, b: u8) Error!?u21` - accepts a single byte of
//!   input, returning an error if the byte is invalid in the current state of
//!   the decoder, a valid Unicode codepoint, or `null` if the byte is valid
//!   but there is not yet a full codepoint to return.
//! - `fn adaptTo(self: *Decoder, encoding: []const u8) error{InvalidEncoding}!void` -
//!   accepts a UTF-8-encoded encoding name and returns an error if the desired
//!   encoding cannot be handled by the decoder. This is intended to support
//!   `Decoder` implementations which adapt to the encoding declared by an XML
//!   document.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BoundedArray = std.BoundedArray;

/// A decoder which handles UTF-8 or UTF-16, using a BOM to detect UTF-16
/// endianness.
///
/// This is the bare minimum encoding support required of a standard-compliant
/// XML parser.
pub const DefaultDecoder = struct {
    state: union(enum) {
        start,
        utf16_be_bom,
        utf16_le_bom,
        utf8: Utf8Decoder,
        utf16_le: Utf16Decoder(.little),
        utf16_be: Utf16Decoder(.big),
    } = .start,

    pub const Error = error{ InvalidUtf8, InvalidUtf16 };

    pub fn next(self: *DefaultDecoder, b: u8) Error!?u21 {
        switch (self.state) {
            .start => if (b == 0xFE) {
                self.state = .utf16_be_bom;
                return null;
            } else if (b == 0xFF) {
                self.state = .utf16_le_bom;
                return null;
            } else {
                self.state = .{ .utf8 = .{} };
                return try self.state.utf8.next(b);
            },
            .utf16_be_bom => if (b == 0xFF) {
                self.state = .{ .utf16_be = .{} };
                return 0xFEFF;
            } else {
                self.state = .{ .utf8 = .{} };
                return error.InvalidUtf8;
            },
            .utf16_le_bom => if (b == 0xFE) {
                self.state = .{ .utf16_le = .{} };
                return 0xFEFF;
            } else {
                self.state = .{ .utf8 = .{} };
                return error.InvalidUtf8;
            },
            inline else => |*decoder| return try decoder.next(b),
        }
    }

    pub fn adaptTo(self: *DefaultDecoder, encoding: []const u8) error{InvalidEncoding}!void {
        switch (self.state) {
            .start, .utf16_be_bom, .utf16_le_bom => {},
            inline else => |*decoder| try decoder.adaptTo(encoding),
        }
    }
};

test DefaultDecoder {
    // UTF-8 no BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xC3));
        try testing.expectEqual(@as(?u21, 'ü'), try decoder.next(0xBC));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xE6));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x97));
        try testing.expectEqual(@as(?u21, '日'), try decoder.next(0xA5));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xF0));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x9F));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x98));
        try testing.expectEqual(@as(?u21, '😀'), try decoder.next(0x80));
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-8 BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xEF));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xBB));
        try testing.expectEqual(@as(?u21, 0xFEFF), try decoder.next(0xBF));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xC3));
        try testing.expectEqual(@as(?u21, 'ü'), try decoder.next(0xBC));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xE6));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x97));
        try testing.expectEqual(@as(?u21, '日'), try decoder.next(0xA5));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xF0));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x9F));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x98));
        try testing.expectEqual(@as(?u21, '😀'), try decoder.next(0x80));
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // Invalid UTF-8 BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xEF));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x00));
        try testing.expectError(error.InvalidUtf8, decoder.next(0x00));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-16BE BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xFE));
        try testing.expectEqual(@as(?u21, 0xFEFF), try decoder.next(0xFF));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x00));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x00));
        try testing.expectEqual(@as(?u21, 'ü'), try decoder.next(0xFC));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x65));
        try testing.expectEqual(@as(?u21, '日'), try decoder.next(0xE5));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xD8));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x3D));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xDE));
        try testing.expectEqual(@as(?u21, '😀'), try decoder.next(0x00));
        try decoder.adaptTo("utf-16");
        try decoder.adaptTo("UTF-16");
        try decoder.adaptTo("utf-16be");
        try decoder.adaptTo("UTF-16BE");
    }

    // Invalid UTF-16BE BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xFE));
        try testing.expectError(error.InvalidUtf8, decoder.next(0x00));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-16LE BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xFF));
        try testing.expectEqual(@as(?u21, 0xFEFF), try decoder.next(0xFE));
        try testing.expectEqual(@as(?u21, null), try decoder.next('H'));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next(0x00));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xFC));
        try testing.expectEqual(@as(?u21, 'ü'), try decoder.next(0x00));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xE5));
        try testing.expectEqual(@as(?u21, '日'), try decoder.next(0x65));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x3D));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xD8));
        try testing.expectEqual(@as(?u21, null), try decoder.next(0x00));
        try testing.expectEqual(@as(?u21, '😀'), try decoder.next(0xDE));
        try decoder.adaptTo("utf-16");
        try decoder.adaptTo("UTF-16");
        try decoder.adaptTo("utf-16le");
        try decoder.adaptTo("UTF-16LE");
    }

    // Invalid UTF-16LE BOM
    {
        var decoder = DefaultDecoder{};
        try testing.expectEqual(@as(?u21, null), try decoder.next(0xFF));
        try testing.expectError(error.InvalidUtf8, decoder.next(0xFF));
        try testing.expectEqual(@as(?u21, 'H'), try decoder.next('H'));
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }
}

/// A decoder which handles only UTF-8.
pub const Utf8Decoder = struct {
    buffer: BoundedArray(u8, 4) = .{},
    expecting: u3 = 0,

    pub const Error = error{InvalidUtf8};

    pub fn next(self: *Utf8Decoder, b: u8) Error!?u21 {
        if (self.expecting == 0) {
            const len = unicode.utf8ByteSequenceLength(b) catch return error.InvalidUtf8;
            if (len == 1) {
                return b;
            }
            self.expecting = len;
            self.buffer.appendAssumeCapacity(b);
            return null;
        } else {
            self.buffer.appendAssumeCapacity(b);
            if (self.buffer.len == self.expecting) {
                const codepoint_or_error = unicode.utf8Decode(self.buffer.slice());
                self.expecting = 0;
                self.buffer.len = 0;
                return codepoint_or_error catch error.InvalidUtf8;
            } else {
                return null;
            }
        }
    }

    pub fn adaptTo(_: *Utf8Decoder, encoding: []const u8) error{InvalidEncoding}!void {
        if (!ascii.eqlIgnoreCase(encoding, "utf-8")) {
            return error.InvalidEncoding;
        }
    }
};

pub const Utf16Endianness = enum {
    big,
    little,
};

/// A decoder which handles only UTF-16 of a given endianness.
pub fn Utf16Decoder(comptime endianness: Utf16Endianness) type {
    return struct {
        buffer: BoundedArray(u8, 2) = .{},
        high_unit: u16 = 0,

        const Self = @This();

        pub const Error = error{InvalidUtf16};

        pub fn next(self: *Self, b: u8) Error!?u21 {
            self.buffer.appendAssumeCapacity(b);
            if (self.buffer.len == 1) {
                return null;
            }
            const u = self.takeCodeUnit();
            if (self.high_unit != 0) {
                const high_unit = self.high_unit;
                self.high_unit = 0;
                if (!isLowSurrogate(u)) {
                    return error.InvalidUtf16;
                }
                return 0x10000 + ((@as(u21, high_unit) << 10) | surrogateValue(u));
            } else if (isHighSurrogate(u)) {
                self.high_unit = surrogateValue(u);
                return null;
            } else if (isLowSurrogate(u)) {
                return error.InvalidUtf16;
            } else {
                return u;
            }
        }

        inline fn takeCodeUnit(self: *Self) u16 {
            const b1 = self.buffer.buffer[0];
            const b2 = self.buffer.buffer[1];
            self.buffer.len = 0;
            return if (endianness == .big) (@as(u16, b1) << 8) + b2 else (@as(u16, b2) << 8) + b1;
        }

        inline fn isHighSurrogate(u: u16) bool {
            return u & ~@as(u16, 0x3FF) == 0xD800;
        }

        inline fn isLowSurrogate(u: u16) bool {
            return u & ~@as(u16, 0x3FF) == 0xDC00;
        }

        inline fn surrogateValue(u: u16) u10 {
            return @intCast(u10, u & 0x3FF);
        }

        pub fn adaptTo(_: *Self, encoding: []const u8) error{InvalidEncoding}!void {
            if (!(ascii.eqlIgnoreCase(encoding, "utf-16") or
                (endianness == .big and ascii.eqlIgnoreCase(encoding, "utf-16be")) or
                (endianness == .little and ascii.eqlIgnoreCase(encoding, "utf-16le"))))
            {
                return error.InvalidEncoding;
            }
        }
    };
}
