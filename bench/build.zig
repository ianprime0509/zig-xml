const std = @import("std");
const libxml2 = @import("lib/zig-libxml2/libxml2.zig");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) !void {
    const xml = b.addModule("xml", .{ .source_file = .{ .path = "../src/xml.zig" } });

    const bench_scanner = addBench(b, "scanner");
    bench_scanner.addModule("xml", xml);

    const bench_token_reader = addBench(b, "token_reader");
    bench_token_reader.addModule("xml", xml);

    const bench_reader = addBench(b, "reader");
    bench_reader.addModule("xml", xml);

    const libxml2_lib = try libxml2.create(b, .{}, .ReleaseFast, .{
        .iconv = false,
        .lzma = false,
        .zlib = false,
    });
    const bench_libxml2 = addBench(b, "libxml2");
    libxml2_lib.link(bench_libxml2);

    const bench_yxml = addBench(b, "yxml");
    bench_yxml.linkLibC();
    bench_yxml.addCSourceFile("lib/yxml/yxml.c", &.{});
    bench_yxml.addIncludePath("lib/yxml");
}

fn addBench(b: *Build, name: []const u8) *Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = .{ .path = b.fmt("src/{s}.zig", .{name}) },
        .optimize = .ReleaseFast,
    });
    b.installArtifact(exe);
    return exe;
}
