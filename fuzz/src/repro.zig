const std = @import("std");
const assert = std.debug.assert;
const fuzz = @import("fuzz.zig").fuzz;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer assert(gpa_state.deinit() == .ok);
    const gpa = gpa_state.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(input);
    try fuzz(gpa, input);
}
