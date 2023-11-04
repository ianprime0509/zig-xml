//! Various encoding-related utilities.
//!
//! The central "interface" of this file is `Decoder`, which decodes XML
//! content into Unicode codepoints for further processing. It consists
//! of an error type `Error` and several declarations:
//!
//! - `const max_encoded_codepoint_len` - the maximum number of bytes a
//!    single Unicode codepoint may occupy in encoded form.
//! - `fn readCodepoint(self: *Decoder, reader: anytype, buf: []u8) (Error || @TypeOf(reader).Error))!ReadResult` -
//!   reads a single codepoint from a `std.io.GenericReader` and writes its UTF-8
//!   encoding to `buf`. Should return `error.UnexpectedEndOfInput` if a full
//!   codepoint cannot be read, `error.Overflow` if the UTF-8-encoded form cannot
//!   be written to `buf`; other decoder-specific errors can also be used.
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

/// The result of reading a single codepoint successfully.
pub const ReadResult = packed struct(u32) {
    /// The codepoint read.
    codepoint: u21,
    /// The length of the codepoint encoded in UTF-8.
    byte_length: u10,
    /// If https://github.com/ziglang/zig/issues/104 is implemented, a much
    /// better API would be to make `ReadResult` a `packed struct(u31)` instead
    /// and use `?ReadResult` elsewhere. But, for now, this indicates whether
    /// `codepoint` and `byte_length` are present, so that the whole thing fits
    /// in a `u32` rather than unnecessarily taking up 8 bytes.
    present: bool = true,

    pub const none: ReadResult = .{
        .codepoint = 0,
        .byte_length = 0,
        .present = false,
    };
};

/// A decoder which handles UTF-8 or UTF-16, using a BOM to detect UTF-16
/// endianness.
///
/// This is the bare minimum encoding support required of a standard-compliant
/// XML parser.
pub const DefaultDecoder = struct {
    state: union(enum) {
        start,
        utf8: Utf8Decoder,
        utf16_le: Utf16Decoder(.little),
        utf16_be: Utf16Decoder(.big),
    } = .start,

    pub const Error = Utf8Decoder.Error || Utf16Decoder(.little).Error || Utf16Decoder(.big).Error;

    pub const max_encoded_codepoint_len = 4;
    const bom = 0xFEFF;
    const bom_byte_length = unicode.utf8CodepointSequenceLength(bom) catch unreachable;

    pub fn readCodepoint(self: *DefaultDecoder, reader: anytype, buf: []u8) (Error || @TypeOf(reader).Error)!ReadResult {
        switch (self.state) {
            .start => {},
            inline else => |*inner| return inner.readCodepoint(reader, buf),
        }
        // If attempting to match the UTF-16 BOM fails for whatever reason, we
        // will assume we are reading UTF-8.
        self.state = .{ .utf8 = .{} };
        const b = reader.readByte() catch |e| switch (e) {
            error.EndOfStream => return error.UnexpectedEndOfInput,
            else => |other| return other,
        };
        switch (b) {
            0xFE => {
                const b2 = reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => return error.InvalidUtf8,
                    else => |other| return other,
                };
                if (b2 != 0xFF) return error.InvalidUtf8;
                self.state = .{ .utf16_be = .{} };
                if (bom_byte_length > buf.len) return error.Overflow;
                _ = unicode.utf8Encode(bom, buf) catch unreachable;
                return .{ .codepoint = bom, .byte_length = bom_byte_length };
            },
            0xFF => {
                const b2 = reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => return error.InvalidUtf8,
                    else => |other| return other,
                };
                if (b2 != 0xFE) return error.InvalidUtf8;
                self.state = .{ .utf16_le = .{} };
                if (bom_byte_length > buf.len) return error.Overflow;
                _ = unicode.utf8Encode(bom, buf) catch unreachable;
                return .{ .codepoint = bom, .byte_length = bom_byte_length };
            },
            else => {
                // The rest of this branch is copied from Utf8Decoder
                const byte_length = unicode.utf8ByteSequenceLength(b) catch return error.InvalidUtf8;
                if (byte_length > buf.len) return error.Overflow;
                buf[0] = b;
                if (byte_length == 1) return .{ .codepoint = b, .byte_length = 1 };
                reader.readNoEof(buf[1..byte_length]) catch |e| switch (e) {
                    error.EndOfStream => return error.UnexpectedEndOfInput,
                    else => |other| return other,
                };
                const codepoint = switch (byte_length) {
                    2 => unicode.utf8Decode2(buf[0..2]),
                    3 => unicode.utf8Decode3(buf[0..3]),
                    4 => unicode.utf8Decode4(buf[0..4]),
                    else => unreachable,
                } catch return error.InvalidUtf8;
                return .{ .codepoint = codepoint, .byte_length = byte_length };
            },
        }
    }

    pub fn adaptTo(self: *DefaultDecoder, encoding: []const u8) error{InvalidEncoding}!void {
        switch (self.state) {
            .start => {},
            inline else => |*decoder| try decoder.adaptTo(encoding),
        }
    }
};

test DefaultDecoder {
    // UTF-8 no BOM
    {
        const input = "Hü日😀";
        var decoder = try testDecode(DefaultDecoder, input, &.{
            'H',
            'ü',
            '日',
            '😀',
        });
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-8 BOM
    {
        const input = "\u{FEFF}Hü日😀";
        var decoder = try testDecode(DefaultDecoder, input, &.{
            0xFEFF,
            'H',
            'ü',
            '日',
            '😀',
        });
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // Invalid UTF-8 BOM
    {
        const input = "\xEF\x00\x00H";
        var decoder = try testDecode(DefaultDecoder, input, &.{
            error.InvalidUtf8,
            'H',
        });
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-16BE BOM
    {
        const input = "\xFE\xFF" ++ // U+FEFF
            "\x00H" ++
            "\x00\xFC" ++ // ü
            "\x65\xE5" ++ // 日
            "\xD8\x3D\xDE\x00"; // 😀
        var decoder = try testDecode(DefaultDecoder, input, &.{
            0xFEFF,
            'H',
            'ü',
            '日',
            '😀',
        });
        try decoder.adaptTo("utf-16");
        try decoder.adaptTo("UTF-16");
        try decoder.adaptTo("utf-16be");
        try decoder.adaptTo("UTF-16BE");
    }

    // Invalid UTF-16BE BOM
    {
        const input = "\xFE\x00H";
        var decoder = try testDecode(DefaultDecoder, input, &.{
            error.InvalidUtf8,
            'H',
        });
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }

    // UTF-16LE BOM
    {
        const input = "\xFF\xFE" ++ // U+FEFF
            "H\x00" ++
            "\xFC\x00" ++ // ü
            "\xE5\x65" ++ // 日
            "\x3D\xD8\x00\xDE"; // 😀
        var decoder = try testDecode(DefaultDecoder, input, &.{
            0xFEFF,
            'H',
            'ü',
            '日',
            '😀',
        });
        try decoder.adaptTo("utf-16");
        try decoder.adaptTo("UTF-16");
        try decoder.adaptTo("utf-16le");
        try decoder.adaptTo("UTF-16LE");
    }

    // Invalid UTF-16LE BOM
    {
        const input = "\xFF\xFFH";
        var decoder = try testDecode(DefaultDecoder, input, &.{
            error.InvalidUtf8,
            'H',
        });
        try decoder.adaptTo("utf-8");
        try decoder.adaptTo("UTF-8");
    }
}

/// A decoder which handles only UTF-8.
pub const Utf8Decoder = struct {
    pub const max_encoded_codepoint_len = 4;

    pub const Error = error{ InvalidUtf8, Overflow, UnexpectedEndOfInput };

    pub fn readCodepoint(_: *Utf8Decoder, reader: anytype, buf: []u8) (Error || @TypeOf(reader).Error)!ReadResult {
        const b = reader.readByte() catch |e| switch (e) {
            error.EndOfStream => return ReadResult.none,
            else => |other| return other,
        };
        const byte_length = unicode.utf8ByteSequenceLength(b) catch return error.InvalidUtf8;
        if (byte_length > buf.len) return error.Overflow;
        buf[0] = b;
        if (byte_length == 1) return .{ .codepoint = b, .byte_length = 1 };
        reader.readNoEof(buf[1..byte_length]) catch |e| switch (e) {
            error.EndOfStream => return error.UnexpectedEndOfInput,
            else => |other| return other,
        };
        const codepoint = switch (byte_length) {
            2 => unicode.utf8Decode2(buf[0..2]),
            3 => unicode.utf8Decode3(buf[0..3]),
            4 => unicode.utf8Decode4(buf[0..4]),
            else => unreachable,
        } catch return error.InvalidUtf8;
        return .{ .codepoint = codepoint, .byte_length = byte_length };
    }

    pub fn adaptTo(_: *Utf8Decoder, encoding: []const u8) error{InvalidEncoding}!void {
        if (!ascii.eqlIgnoreCase(encoding, "utf-8")) {
            return error.InvalidEncoding;
        }
    }
};

test Utf8Decoder {
    const input =
        // 1-byte encodings
        "\x00\x01 ABC abc 123" ++
        // 2-byte encodings
        "éèçñåβΘ" ++
        // 3-byte encodings
        "日本語ＡＥＳＴＨＥＴＩＣ" ++
        // 4-byte encodings
        "😳😂❤️👩‍👩‍👧‍👧" ++
        // Overlong encodings
        "\xC0\x80\xE0\x80\x80\xF0\x80\x80\x80" ++
        // Out of bounds codepoint
        "\xF7\xBF\xBF\xBF" ++
        // Surrogate halves
        "\xED\xA0\x80\xED\xBF\xBF";
    _ = try testDecode(Utf8Decoder, input, &.{
        '\x00',
        '\x01',
        ' ',
        'A',
        'B',
        'C',
        ' ',
        'a',
        'b',
        'c',
        ' ',
        '1',
        '2',
        '3',
        'é',
        'è',
        'ç',
        'ñ',
        'å',
        'β',
        'Θ',
        '日',
        '本',
        '語',
        'Ａ',
        'Ｅ',
        'Ｓ',
        'Ｔ',
        'Ｈ',
        'Ｅ',
        'Ｔ',
        'Ｉ',
        'Ｃ',
        '😳',
        '😂',
        '❤',
        '\u{FE0F}', // variation selector-16
        '👩',
        '\u{200D}', // zero-width joiner
        '👩',
        '\u{200D}', // zero-width joiner
        '👧',
        '\u{200D}', // zero-width joiner
        '👧',
        error.InvalidUtf8, // 2-byte U+0000
        error.InvalidUtf8, // 3-byte U+0000
        error.InvalidUtf8, // 4-byte U+0000
        error.InvalidUtf8, // attempted U+1FFFFF
        error.InvalidUtf8, // U+D800
        error.InvalidUtf8, // U+DFFF
    });
}

/// A decoder which handles only UTF-16 of a given endianness.
pub fn Utf16Decoder(comptime endian: std.builtin.Endian) type {
    return struct {
        const Self = @This();

        pub const Error = error{ InvalidUtf16, Overflow, UnexpectedEndOfInput };

        pub const max_encoded_codepoint_len = 4;

        pub fn readCodepoint(_: *Self, reader: anytype, buf: []u8) (Error || @TypeOf(reader).Error)!ReadResult {
            var u_buf: [2]u8 = undefined;
            const u_len = try reader.readAll(&u_buf);
            switch (u_len) {
                0 => return ReadResult.none,
                1 => return error.UnexpectedEndOfInput,
                else => {},
            }
            const u = std.mem.readInt(u16, &u_buf, endian);
            const code_unit_length = unicode.utf16CodeUnitSequenceLength(u) catch return error.InvalidUtf16;
            const codepoint = switch (code_unit_length) {
                1 => u,
                2 => codepoint: {
                    const low = reader.readInt(u16, endian) catch |e| switch (e) {
                        error.EndOfStream => return error.UnexpectedEndOfInput,
                        else => |other| return other,
                    };
                    break :codepoint unicode.utf16DecodeSurrogatePair(&.{ u, low }) catch return error.InvalidUtf16;
                },
                else => unreachable,
            };
            const byte_length = unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            if (byte_length > buf.len) return error.Overflow;
            _ = unicode.utf8Encode(codepoint, buf) catch unreachable;
            return .{ .codepoint = codepoint, .byte_length = byte_length };
        }

        pub fn adaptTo(_: *Self, encoding: []const u8) error{InvalidEncoding}!void {
            if (!(ascii.eqlIgnoreCase(encoding, "utf-16") or
                (endian == .big and ascii.eqlIgnoreCase(encoding, "utf-16be")) or
                (endian == .little and ascii.eqlIgnoreCase(encoding, "utf-16le"))))
            {
                return error.InvalidEncoding;
            }
        }
    };
}

test Utf16Decoder {
    // little-endian
    {
        const input = "\x00\x00" ++ // U+0000
            "A\x00" ++ // A
            "b\x00" ++ // b
            "5\x00" ++ // 5
            "\xE5\x65" ++ // 日
            "\x3D\xD8\x33\xDE" ++ // 😳
            "\x00\xD8\x00\x00" ++ // unpaired high surrogate followed by U+0000
            "\xFF\xDF" // unpaired low surrogate
        ;
        _ = try testDecode(Utf16Decoder(.little), input, &.{
            '\x00',
            'A',
            'b',
            '5',
            '日',
            '😳',
            error.InvalidUtf16,
            error.InvalidUtf16,
        });
    }

    // big-endian
    {
        const input = "\x00\x00" ++ // U+0000
            "\x00A" ++ // A
            "\x00b" ++ // b
            "\x005" ++ // 5
            "\x65\xE5" ++ // 日
            "\xD8\x3D\xDE\x33" ++ // 😳
            "\xD8\x00\x00\x00" ++ // unpaired high surrogate followed by U+0000
            "\xDF\xFF" // unpaired low surrogate
        ;
        _ = try testDecode(Utf16Decoder(.big), input, &.{
            '\x00',
            'A',
            'b',
            '5',
            '日',
            '😳',
            error.InvalidUtf16,
            error.InvalidUtf16,
        });
    }
}

fn testDecode(comptime Decoder: type, input: []const u8, expected: []const (Decoder.Error!u21)) !Decoder {
    var decoder: Decoder = .{};
    var decoded = ArrayListUnmanaged(Decoder.Error!u21){};
    defer decoded.deinit(testing.allocator);
    var input_stream = std.io.fixedBufferStream(input);
    var buf: [4]u8 = undefined;
    while (true) {
        if (decoder.readCodepoint(input_stream.reader(), &buf)) |c| {
            if (!c.present) break;
            try decoded.append(testing.allocator, c.codepoint);
        } else |err| {
            try decoded.append(testing.allocator, err);
        }
    }

    try testing.expectEqualDeep(expected, decoded.items);

    return decoder;
}
