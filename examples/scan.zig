const std = @import("std");
const xml = @import("xml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        return error.InvalidArguments;
    }
    const input_path = args[1];

    const stdout_raw = std.io.getStdOut().writer();
    var stdout_buffered_writer = std.io.bufferedWriter(stdout_raw);
    const stdout = stdout_buffered_writer.writer();
    const stderr = std.io.getStdErr().writer();

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();
    var input_buffered_reader = std.io.bufferedReader(input_file.reader());
    var input_reader = input_buffered_reader.reader();
    var scanner = xml.Scanner{};
    var decoder = xml.encoding.DefaultDecoder{};

    var line: usize = 1;
    var column: usize = 1;
    while (true) {
        var buf: [4]u8 = undefined;
        const c = try decoder.readCodepoint(input_reader, &buf);
        if (!c.present) break;
        const token = scanner.next(c.codepoint, c.byte_length) catch |e| {
            try stdout_buffered_writer.flush();
            try stderr.print("error: {} ({}:{}): {}\n", .{ scanner.pos, line, column, e });
            return;
        };
        if (token != .ok) {
            try stdout.print("{} ({}:{}): {}\n", .{ scanner.pos, line, column, token });
        }
        if (c.codepoint == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    try stdout_buffered_writer.flush();
    scanner.endInput() catch |e| {
        try stderr.print("error: {} ({}:{}): {}\n", .{ scanner.pos, line, column, e });
    };
}
