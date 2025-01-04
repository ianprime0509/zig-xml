const std = @import("std");

context: *const anyopaque,
guessFn: *const fn (context: *const anyopaque, text: []const u8) void,
checkEncodingFn: *const fn (context: *const anyopaque, xml_encoding: []const u8) bool,
transcodeFn: *const fn (context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult,

const Encoding = @This();

pub const TranscodeResult = struct {
    dest_written: usize,
    src_read: usize,
};

pub fn guess(encoding: Encoding, text: []const u8) void {
    encoding.guessFn(encoding.context, text);
}

pub fn checkEncoding(encoding: Encoding, xml_encoding: []const u8) bool {
    return encoding.checkEncodingFn(encoding.context, xml_encoding);
}

pub fn transcode(encoding: Encoding, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
    return encoding.transcodeFn(encoding.context, dest, src);
}

pub const utf8: Encoding = .{
    .context = undefined,
    .guessFn = &utf8Guess,
    .checkEncodingFn = &utf8CheckEncoding,
    .transcodeFn = &utf8Transcode,
};

fn utf8Guess(context: *const anyopaque, text: []const u8) void {
    _ = context;
    _ = text;
}

fn utf8CheckEncoding(context: *const anyopaque, encoding: []const u8) bool {
    _ = context;
    return std.ascii.eqlIgnoreCase(encoding, "UTF-8");
}

fn utf8Transcode(context: *const anyopaque, noalias dest: []u8, noalias src: []const u8) TranscodeResult {
    _ = context;
    var dest_written: usize = 0;
    var src_read: usize = 0;
    while (src_read < src.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(src[src_read]) catch break;
        if (src_read + cp_len > src.len or dest_written + cp_len > dest.len) break;
        switch (cp_len) {
            1 => {
                dest[dest_written] = src[src_read];
                dest_written += 1;
                src_read += 1;
            },
            2, 3, 4 => {
                const slice = src[src_read..][0..cp_len];
                if (!std.unicode.utf8ValidateSlice(slice)) break;
                @memcpy(dest[dest_written..][0..cp_len], slice);
                dest_written += cp_len;
                src_read += cp_len;
            },
            else => unreachable,
        }
    }
    return .{
        .dest_written = dest_written,
        .src_read = src_read,
    };
}
