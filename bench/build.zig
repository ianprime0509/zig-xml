const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) !void {
    const xml = b.dependency("xml", .{}).module("xml");

    const bench_scanner = addBench(b, "scanner");
    bench_scanner.addModule("xml", xml);
    bench_scanner.linkLibC();

    const bench_token_reader = addBench(b, "token_reader");
    bench_token_reader.addModule("xml", xml);
    bench_token_reader.linkLibC();

    const bench_reader = addBench(b, "reader");
    bench_reader.addModule("xml", xml);
    bench_reader.linkLibC();

    const libxml2 = b.dependency("libxml2", .{
        .optimize = .ReleaseFast,
        .iconv = false,
        .lzma = false,
        .zlib = false,
    }).artifact("xml2");
    const bench_libxml2 = addBench(b, "libxml2");
    bench_libxml2.linkLibrary(libxml2);

    const bench_yxml = addBench(b, "yxml");
    bench_yxml.linkLibC();
    bench_yxml.addCSourceFile(.{ .file = .{ .path = "lib/yxml/yxml.c" }, .flags = &.{} });
    bench_yxml.addIncludePath(.{ .path = "lib/yxml" });

    const bench_mxml = addBench(b, "mxml");
    bench_mxml.linkLibC();
    bench_mxml.addCSourceFiles(.{ .files = &.{
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
    } });
    bench_mxml.addIncludePath(.{ .path = "lib/mxml" });
    bench_mxml.addIncludePath(.{ .path = "lib/mxml-config" });
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
