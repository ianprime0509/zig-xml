const std = @import("std");
const libxml2 = @import("lib/zig-libxml2/libxml2.zig");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) !void {
    const xml = b.addModule("xml", .{ .source_file = .{ .path = "../src/xml.zig" } });

    const bench_scanner = addBench(b, "scanner");
    bench_scanner.addModule("xml", xml);
    bench_scanner.linkLibC();

    const bench_token_reader = addBench(b, "token_reader");
    bench_token_reader.addModule("xml", xml);
    bench_token_reader.linkLibC();

    const bench_reader = addBench(b, "reader");
    bench_reader.addModule("xml", xml);
    bench_reader.linkLibC();

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

    const bench_mxml = addBench(b, "mxml");
    bench_mxml.linkLibC();
    bench_mxml.addCSourceFiles(&.{
        "lib/mxml/mxml-attr.c",
        "lib/mxml/mxml-entity.c",
        "lib/mxml/mxml-file.c",
        "lib/mxml/mxml-get.c",
        "lib/mxml/mxml-index.c",
        "lib/mxml/mxml-node.c",
        "lib/mxml/mxml-private.c",
        "lib/mxml/mxml-search.c",
        "lib/mxml/mxml-set.c",
        "lib/mxml/mxml-string.c",
    }, &.{});
    bench_mxml.addIncludePath("lib/mxml");
    bench_mxml.addIncludePath("lib/mxml-config");
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
