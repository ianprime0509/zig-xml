const std = @import("std");
const afl = @import("zig-afl-kit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = .Debug,
    });

    const afl_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = .Debug,
        .stack_check = false,
        .link_libc = true,
        .fuzz = true,
    });
    afl_mod.addImport("xml", xml.module("xml"));
    const afl_obj = b.addObject(.{
        .name = "fuzz-xml",
        .root_module = afl_mod,
    });

    const afl_exe = afl.addInstrumentedExe(
        b,
        target,
        .Debug,
        b.option([]const []const u8, "llvm-config-path", "Path to find llvm-config executable"),
        b.systemIntegrationOption("aflplusplus", .{}),
        afl_obj,
    ) orelse return;
    const afl_exe_install = b.addInstallBinFile(afl_exe, "fuzz-xml");
    b.getInstallStep().dependOn(&afl_exe_install.step);
}
