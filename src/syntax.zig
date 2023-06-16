const std = @import("std");
const unicode = std.unicode;

pub inline fn isChar(c: u21) bool {
    return switch (c) {
        '\t', '\r', '\n', ' '...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF => true,
        else => false,
    };
}

pub inline fn isSpace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

pub inline fn isDigit(c: u21) bool {
    return switch (c) {
        '0'...'9' => true,
        else => false,
    };
}

/// Note: only valid if `isDigit` returns true.
pub inline fn digitValue(c: u21) u4 {
    return @intCast(u4, c - '0');
}

pub inline fn isHexDigit(c: u21) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

/// Note: only valid if `isHexDigit` returns true.
pub inline fn hexDigitValue(c: u21) u4 {
    return switch (c) {
        'a'...'f' => @intCast(u4, c - 'a' + 10),
        'A'...'F' => @intCast(u4, c - 'A' + 10),
        else => @intCast(u4, c - '0'),
    };
}

/// Checks if `s` matches `NCName` from the namespaces spec.
///
/// Note: only valid if `s` is valid UTF-8.
pub fn isNcName(s: []const u8) bool {
    var view = unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    const first_c = iter.nextCodepoint() orelse return false;
    if (first_c == ':' or !isNameStartChar(first_c)) {
        return false;
    }
    while (iter.nextCodepoint()) |c| {
        if (c == ':' or !isNameChar(c)) {
            return false;
        }
    }
    return true;
}

pub inline fn isNameStartChar(c: u21) bool {
    return switch (c) {
        ':',
        'A'...'Z',
        '_',
        'a'...'z',
        0xC0...0xD6,
        0xD8...0xF6,
        0xF8...0x2FF,
        0x370...0x37D,
        0x37F...0x1FFF,
        0x200C...0x200D,
        0x2070...0x218F,
        0x2C00...0x2FEF,
        0x3001...0xD7FF,
        0xF900...0xFDCF,
        0xFDF0...0xFFFD,
        0x10000...0xEFFFF,
        => true,
        else => false,
    };
}

pub inline fn isNameChar(c: u21) bool {
    return if (isNameStartChar(c)) true else switch (c) {
        '-', '.', '0'...'9', 0xB7, 0x0300...0x036F, 0x203F...0x2040 => true,
        else => false,
    };
}

pub inline fn isEncodingStartChar(c: u21) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

pub inline fn isEncodingChar(c: u21) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => true,
        else => false,
    };
}

pub inline fn isPubidChar(c: u21) bool {
    return switch (c) {
        ' ',
        '\r',
        '\n',
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '-',
        '\'',
        '(',
        ')',
        '+',
        ',',
        '.',
        '/',
        ':',
        '=',
        '?',
        ';',
        '!',
        '*',
        '#',
        '@',
        '$',
        '_',
        '%',
        => true,
        else => false,
    };
}
