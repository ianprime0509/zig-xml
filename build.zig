const std = @import("std");
const Build = std.Build;
const CrossTarget = std.zig.CrossTarget;
const Mode = std.builtin.Mode;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.addModule("xml", .{ .source_file = .{ .path = "src/xml.zig" } });

    addTests(b, target, optimize, xml);
    addDocs(b, target);
    addExamples(b, target, optimize, xml);
    addFuzz(b, target, xml);
}

fn addTests(b: *Build, target: CrossTarget, optimize: Mode, xml: *Build.Module) void {
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/xml.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const xmlconf_exe = b.addExecutable(.{
        .name = "xmlconf",
        .root_source_file = .{ .path = "test/xmlconf.zig" },
        .target = target,
        .optimize = optimize,
    });
    xmlconf_exe.addModule("xml", xml);

    const install_xmlconf_step = b.step("install-xmlconf", "Install xmlconf test runner");
    install_xmlconf_step.dependOn(&b.addInstallArtifact(xmlconf_exe).step);

    const run_xmlconf_exe = b.addRunArtifact(xmlconf_exe);
    if (b.args) |args| {
        run_xmlconf_exe.addArgs(args);
    }
    // Since we can't yet handle doctypes, the test files need to be specified
    // individually
    run_xmlconf_exe.addArgs(&.{
        "test/xmlconf/eduni/errata-2e/errata2e.xml",
        "test/xmlconf/eduni/errata-3e/errata3e.xml",
        "test/xmlconf/eduni/errata-4e/errata4e.xml",
        "test/xmlconf/eduni/misc/ht-bh.xml",
        "test/xmlconf/eduni/namespaces/1.0/rmt-ns10.xml",
        "test/xmlconf/eduni/namespaces/1.1/rmt-ns11.xml",
        "test/xmlconf/eduni/namespaces/errata-1e/errata1e.xml",
        "test/xmlconf/eduni/xml-1.1/xml11.xml",
        "test/xmlconf/ibm/ibm_oasis_invalid.xml",
        "test/xmlconf/ibm/ibm_oasis_not-wf.xml",
        "test/xmlconf/ibm/ibm_oasis_valid.xml",
        "test/xmlconf/japanese/japanese.xml",
        "test/xmlconf/oasis/oasis.xml",
        // The test case files in the sun directory do not have an enclosing
        // TESTCASES element, and only work when directly substituted as entity
        // content, so they cannot be used at this time.
        "test/xmlconf/xmltest/xmltest.xml",
    });

    const run_xmlconf_step = b.step("run-xmlconf", "Run xmlconf test cases");
    run_xmlconf_step.dependOn(&run_xmlconf_exe.step);
}

fn addDocs(b: *Build, target: CrossTarget) void {
    const lib = b.addStaticLibrary(.{
        .name = "zig-xml",
        .root_source_file = .{ .path = "src/xml.zig" },
        .target = target,
        .optimize = .Debug,
    });
    // We don't actually care about the library itself, but zig build doesn't
    // like it for some reason if we do this (it fails the step):
    // lib.emit_bin = .no_emit;
    lib.emit_docs = .emit;

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&lib.step);
}

fn addExamples(b: *Build, target: CrossTarget, optimize: Mode, xml: *Build.Module) void {
    const install_examples_step = b.step("install-examples", "Install examples");

    const scan_exe = b.addExecutable(.{
        .name = "scan",
        .root_source_file = .{ .path = "examples/scan.zig" },
        .target = target,
        .optimize = optimize,
    });
    scan_exe.addModule("xml", xml);
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
    read_exe.addModule("xml", xml);
    install_examples_step.dependOn(&b.addInstallArtifact(read_exe).step);

    const run_read_exe = b.addRunArtifact(read_exe);
    if (b.args) |args| {
        run_read_exe.addArgs(args);
    }

    const run_read_step = b.step("run-example-read", "Run read example");
    run_read_step.dependOn(&run_read_exe.step);
}

fn addFuzz(b: *Build, target: CrossTarget, xml: *Build.Module) void {
    // Thanks to https://www.ryanliptak.com/blog/fuzzing-zig-code/ for the basis of this!
    const fuzz_lib = b.addStaticLibrary(.{
        .name = "fuzz",
        .root_source_file = .{ .path = "fuzz/main.zig" },
        .target = target,
        .optimize = .Debug,
    });
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addModule("xml", xml);

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
    fuzz_reproduce_exe.addModule("xml", xml);

    const run_fuzz_reproduce_exe = b.addRunArtifact(fuzz_reproduce_exe);
    if (b.args) |args| {
        run_fuzz_reproduce_exe.addArgs(args);
    }

    const run_fuzz_reproduce_step = b.step("fuzz-reproduce", "Reproduce crash found by fuzzing");
    run_fuzz_reproduce_step.dependOn(&run_fuzz_reproduce_exe.step);
}
