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

    const read_exe = b.addExecutable(.{
        .name = "read",
        .root_source_file = .{ .path = "examples/read.zig" },
        .target = target,
        .optimize = optimize,
    });
    read_exe.addModule("xml", module);
    install_examples_step.dependOn(&b.addInstallArtifact(read_exe).step);

    const run_read_exe = b.addRunArtifact(read_exe);
    if (b.args) |args| {
        run_read_exe.addArgs(args);
    }

    const run_read_step = b.step("run-example-read", "Run read example");
    run_read_step.dependOn(&run_read_exe.step);

    // Fuzzing setup
    // Thanks to https://www.ryanliptak.com/blog/fuzzing-zig-code/ for the basis of this!
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz",
        .root_source_file = .{ .path = "fuzz/main.zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addModule("xml", module);

    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o" });
    const fuzz_exe = fuzz_compile.addOutputFileArg("fuzz");
    fuzz_compile.addArtifactArg(fuzz_lib);
    const fuzz_install = b.addInstallBinFile(fuzz_exe, "fuzz");

    const run_fuzz_compile_step = b.step("install-fuzz", "Build executable for fuzz testing using afl-clang-lto");
    run_fuzz_compile_step.dependOn(&fuzz_install.step);

    const run_fuzz = b.addSystemCommand(&.{"afl-fuzz"});
    run_fuzz.addArg("-i");
    if (b.option(bool, "resume", "Resume fuzzing rather than starting a new run") orelse false) {
        run_fuzz.addArg("-");
    } else {
        run_fuzz.addArg(b.pathJoin(&.{ "fuzz", "inputs" }));
    }
    run_fuzz.addArgs(&.{ "-o", b.pathJoin(&.{ "fuzz", "outputs" }) });
    const dictionaries = &[_][]const u8{ "xml.dict", "xml_UTF_16.dict", "xml_UTF_16BE.dict", "xml_UTF_16LE.dict" };
    for (dictionaries) |dictionary| {
        run_fuzz.addArgs(&.{ "-x", b.pathJoin(&.{ "fuzz", "dictionaries", dictionary }) });
    }
    run_fuzz.addFileSourceArg(fuzz_exe);
    const run_fuzz_step = b.step("fuzz", "Execute afl-fuzz with the fuzz testing executable");
    run_fuzz_step.dependOn(&run_fuzz.step);

    const fuzz_reproduce_exe = b.addExecutable(.{
        .name = "fuzz-reproduce",
        .root_source_file = .{ .path = "fuzz/main.zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_reproduce_exe.addModule("xml", module);

    const run_fuzz_reproduce_exe = b.addRunArtifact(fuzz_reproduce_exe);
    if (b.args) |args| {
        run_fuzz_reproduce_exe.addArgs(args);
    }

    const run_fuzz_reproduce_step = b.step("fuzz-reproduce", "Reproduce crash found by fuzzing");
    run_fuzz_reproduce_step.dependOn(&run_fuzz_reproduce_exe.step);
}
