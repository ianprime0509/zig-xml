const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    const xmlconf_exe = b.addExecutable(.{
        .name = "xmlconf",
        .root_source_file = b.path("src/xmlconf.zig"),
        .target = target,
        .optimize = optimize,
    });
    xmlconf_exe.root_module.addImport("xml", xml.module("xml"));
    b.installArtifact(xmlconf_exe);

    const xmlts = b.dependency("xmlts", .{});
    const xmlts_run = b.addRunArtifact(xmlconf_exe);
    // Since we can't process DTDs yet, we need to manually specify the test
    // suite root files individually.
    const suite_paths: []const []const u8 = &.{
        "eduni/errata-2e/errata2e.xml",
        "eduni/errata-3e/errata3e.xml",
        "eduni/errata-4e/errata4e.xml",
        "ibm/ibm_oasis_invalid.xml",
        "ibm/ibm_oasis_not-wf.xml",
        "ibm/ibm_oasis_valid.xml",
        "japanese/japanese.xml",
        "oasis/oasis.xml",
        // The sun test suite files are not structured in a way we can handle
        // without DTD support.
        "xmltest/xmltest.xml",
    };
    for (suite_paths) |path| {
        xmlts_run.addFileArg(xmlts.path(path));
    }

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&xmlts_run.step);
}
