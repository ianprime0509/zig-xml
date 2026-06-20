const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.InvalidArguments;
    const data = try Io.Dir.cwd().readFileAllocOptions(io, args[1], arena, .unlimited, .of(u8), 0);

    try @import("root").runBench(data);
}
