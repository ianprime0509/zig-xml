const std = @import("std");
const Build = std.Build;
const Mode = std.builtin.Mode;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.addModule("xml", .{
        .root_source_file = b.path("src/xml.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the tests");
    const xml_test = b.addTest(.{
        .root_module = xml,
    });
    const xml_test_run = b.addRunArtifact(xml_test);
    test_step.dependOn(&xml_test_run.step);

    const docs_step = b.step("docs", "Build the documentation");
    const xml_docs = b.addObject(.{
        .name = "xml",
        .root_module = xml,
    });
    const xml_docs_copy = b.addInstallDirectory(.{
        .source_dir = xml_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&xml_docs_copy.step);

    const install_examples_step = b.step("install-examples", "Build and install the example programs");

    const example_reader_mod = b.createModule(.{
        .root_source_file = b.path("examples/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_reader_mod.addImport("xml", xml);
    const example_reader_exe = b.addExecutable(.{
        .name = "reader",
        .root_module = example_reader_mod,
    });
    const example_reader_install = b.addInstallArtifact(example_reader_exe, .{});
    install_examples_step.dependOn(&example_reader_install.step);

    const example_canonicalize_mod = b.createModule(.{
        .root_source_file = b.path("examples/canonicalize.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_canonicalize_mod.addImport("xml", xml);
    const example_canonicalize_exe = b.addExecutable(.{
        .name = "canonicalize",
        .root_module = example_canonicalize_mod,
    });
    const example_canonicalize_install = b.addInstallArtifact(example_canonicalize_exe, .{});
    install_examples_step.dependOn(&example_canonicalize_install.step);
}
