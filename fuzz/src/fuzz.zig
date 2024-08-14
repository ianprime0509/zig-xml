const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const xml = @import("xml");

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();
    fuzz(gpa, buf[0..@intCast(len)]) catch @panic("OOM");
}

fn fuzz(gpa: Allocator, input: []const u8) !void {
    var doc = xml.StaticDocument.init(input);
    var reader = doc.reader(gpa, .{});
    defer reader.deinit();
    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => break,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (node == .eof) break;
    }
}
