const std = @import("std");
const afl = @import("zig-afl-kit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = .Debug,
    });

    const afl_obj = b.addObject(.{
        .name = "fuzz-xml",
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = .Debug,
    });
    afl_obj.root_module.stack_check = false;
    afl_obj.root_module.link_libc = true;
    afl_obj.root_module.fuzz = true;
    afl_obj.root_module.addImport("xml", xml.module("xml"));

    // TODO: ABI issues on my system
    // const afl_exe = afl.addInstrumentedExe(b, target, .Debug, afl_obj);
    const afl_exe = afl_exe: {
        const run_afl_cc = b.addSystemCommand(&.{ "afl-cc", "-O3", "-o" });
        const afl_exe = run_afl_cc.addOutputFileArg(afl_obj.name);
        run_afl_cc.addFileArg(b.dependency("zig-afl-kit", .{}).path("afl.c"));
        run_afl_cc.addFileArg(afl_obj.getEmittedLlvmBc());
        break :afl_exe afl_exe;
    };
    const afl_exe_install = b.addInstallBinFile(afl_exe, "fuzz-xml");
    b.getInstallStep().dependOn(&afl_exe_install.step);
}
