const std = @import("std");
const Build = std.Build;
const Step = Build.Step;

pub fn build(b: *Build) !void {
    const xml = b.dependency("xml", .{}).module("xml");

    const bench_reader = addBench(b, "reader");
    bench_reader.root_module.addImport("xml", xml);
    bench_reader.root_module.link_libc = true;

    const bench_streaming_reader = addBench(b, "streaming_reader");
    bench_streaming_reader.root_module.addImport("xml", xml);
    bench_streaming_reader.root_module.link_libc = true;

    const libxml2 = b.dependency("libxml2", .{
        .optimize = .ReleaseFast,
    });
    const bench_libxml2 = addBench(b, "libxml2");
    bench_libxml2.root_module.linkLibrary(libxml2.artifact("xml2"));

    const yxml = b.dependency("yxml", .{});
    const bench_yxml = addBench(b, "yxml");
    bench_yxml.root_module.link_libc = true;
    bench_yxml.root_module.addCSourceFile(.{ .file = yxml.path("yxml.c"), .flags = &.{} });
    bench_yxml.root_module.addIncludePath(yxml.path("."));

    const mxml = b.dependency("mxml", .{});
    const bench_mxml = addBench(b, "mxml");
    bench_mxml.root_module.link_libc = true;
    bench_mxml.root_module.addCSourceFiles(.{
        .root = mxml.path("."),
        .files = &.{
            "mxml-attr.c",
            "mxml-entity.c",
            "mxml-file.c",
            "mxml-get.c",
            "mxml-index.c",
            "mxml-node.c",
            "mxml-private.c",
            "mxml-search.c",
            "mxml-set.c",
            "mxml-string.c",
        },
    });
    bench_mxml.root_module.addIncludePath(mxml.path("."));
    const mxml_config = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = mxml.path("config.h.in") },
    }, .{
        .HAVE_LONG_LONG_INT = 1,
        .HAVE_SNPRINTF = 1,
        .HAVE_VASPRINTF = null,
        .HAVE_VSNPRINTF = null,
        .HAVE_STRDUP = null,
        .HAVE_STRLCAT = null,
        .HAVE_STRLCPY = null,
        .HAVE_PTHREAD_H = null,
    });
    bench_mxml.root_module.addConfigHeader(mxml_config);
}

fn addBench(b: *Build, name: []const u8) *Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);
    return exe;
}
