const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        return error.InvalidArguments;
    }
    const data = try std.fs.cwd().readFileAllocOptions(allocator, args[1], std.math.maxInt(usize), null, @alignOf(u8), 0);
    defer allocator.free(data);

    try @import("root").runBench(data);
}
