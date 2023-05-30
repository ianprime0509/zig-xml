const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig-xml",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const module = b.addModule("xml", .{ .source_file = .{ .path = "src/main.zig" } });

    const install_examples_step = b.step("install-examples", "Install examples");

    const scan_exe = b.addExecutable(.{
        .name = "scan",
        .root_source_file = .{ .path = "examples/scan.zig" },
        .target = target,
        .optimize = optimize,
    });
    scan_exe.addModule("xml", module);
    install_examples_step.dependOn(&b.addInstallArtifact(scan_exe).step);

    const run_scan_exe = b.addRunArtifact(scan_exe);
    if (b.args) |args| {
        run_scan_exe.addArgs(args);
    }

    const run_scan_step = b.step("run-example-scan", "Run scan example");
    run_scan_step.dependOn(&run_scan_exe.step);
}
