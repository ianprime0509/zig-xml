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
//!   accepts an encoding name (which itself is a slice of bytes already
//!   validated by the decoder _but not transcoded in any way_) and returns an
//!   error if the desired encoding cannot be handled by the decoder. This is
//!   intended to support `Decoder` implementations which adapt to the encoding
//!   declared by an XML document.

const std = @import("std");
const unicode = std.unicode;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const BoundedArray = std.BoundedArray;

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
        if (!std.ascii.eqlIgnoreCase(encoding, "utf-8")) {
            return error.InvalidEncoding;
        }
    }
};
