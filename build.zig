const std = @import("std");

/// Homebrew's MuPDF ships no pkg-config file, so its paths are spelled out.
const mupdf_prefix = "/opt/homebrew/opt/mupdf";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Nix builds turn this off: Zig then finds Nix's MuPDF through
    // NIX_CFLAGS_COMPILE and NIX_LDFLAGS, without Homebrew headers mixed in.
    const homebrew = b.option(bool, "homebrew", "Use MuPDF from " ++ mupdf_prefix ++ " (default: true)") orelse true;

    const shim = b.addTranslateC(.{
        .root_source_file = b.path("src/shim.h"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "shim", .module = shim.createModule() }},
    });
    if (homebrew) {
        module.addIncludePath(.{ .cwd_relative = mupdf_prefix ++ "/include" });
        module.addLibraryPath(.{ .cwd_relative = mupdf_prefix ++ "/lib" });
    }
    module.addCSourceFile(.{
        .file = b.path("src/shim.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    // Homebrew's libmupdf-third.dylib is a symlink to libmupdf.dylib. Linking
    // both records one install name twice, and dyld then refuses to start the
    // binary ("duplicate linked dylib").
    module.linkSystemLibrary("mupdf", .{});

    const exe = b.addExecutable(.{ .name = "rdr", .root_module = module });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
