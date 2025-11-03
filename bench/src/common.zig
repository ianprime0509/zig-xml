const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        return error.InvalidArguments;
    }
    const data = try readFileAllocOptions(std.fs.cwd(), args[1], allocator, .unlimited, .of(u8), 0);
    defer allocator.free(data);

    try @import("root").runBench(data);
}

fn readFileAllocOptions(
    dir: std.fs.Dir,
    sub_path: []const u8,
    gpa: std.mem.Allocator,
    limit: std.Io.Limit,
    comptime alignment: std.mem.Alignment,
    comptime sentinel: ?u8,
) !(if (sentinel) |s| [:s]align(alignment.toByteUnits()) u8 else []align(alignment.toByteUnits()) u8) {
    if (@import("builtin").zig_version.minor == 15) {
        return dir.readFileAllocOptions(gpa, sub_path, @intFromEnum(limit), null, alignment, sentinel);
    } else {
        return dir.readFileAllocOptions(sub_path, gpa, limit, alignment, sentinel);
    }
}
