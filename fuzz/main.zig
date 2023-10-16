const std = @import("std");
const xml = @import("xml");

fn cMain() callconv(.C) void {
    main();
}

comptime {
    @export(cMain, .{ .name = "main" });
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdin_buf = std.io.bufferedReader(std.io.getStdIn().reader());
    var reader = xml.reader(allocator, stdin_buf.reader(), .{});
    defer reader.deinit();

    var stdout_buf = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = stdout_buf.writer();
    const stderr = std.io.getStdErr().writer();
    while (reader.next() catch |e| {
        stderr.print("Error at {}: {}\n", .{ reader.token_reader.scanner.pos, e }) catch {};
        return;
    }) |event| {
        stdout.print("{} {}\n", .{ reader.token_reader.scanner.pos, event }) catch {};
    }
}
