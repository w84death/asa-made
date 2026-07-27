const std = @import("std");

// raylib core source files (compiled from vendored 6.0 source).
const raylib_src = [_][]const u8{
    "raudio.c",
    "rcore.c",
    "rglfw.c",
    "rmodels.c",
    "rshapes.c",
    "rtext.c",
    "rtextures.c",
};

const raylib_cflags = [_][]const u8{
    "-std=c99",
    "-DPLATFORM_DESKTOP",
    "-DGRAPHICS_API_OPENGL_33",
    "-D_GNU_SOURCE",
    "-w", // suppress raylib's warnings
};

const raylib_cflags_linux = [_][]const u8{
    "-std=c99",
    "-DPLATFORM_DESKTOP",
    "-DGRAPHICS_API_OPENGL_33",
    "-D_GNU_SOURCE",
    "-D_GLFW_X11",
    "-w", // suppress raylib's warnings
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    // ---- raylib (static, from source) ----
    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    raylib_mod.addIncludePath(b.path("vendor/raylib/src"));
    raylib_mod.addIncludePath(b.path("vendor/raylib/src/external/glfw/include"));
    raylib_mod.addCSourceFiles(.{
        .root = b.path("vendor/raylib/src"),
        .files = &raylib_src,
        .flags = if (os_tag == .linux) &raylib_cflags_linux else &raylib_cflags,
    });
    raylib_mod.link_libc = true;
    // Linux: rglfw.c needs the X11 development headers from the host.
    if (os_tag == .linux) {
        raylib_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    const raylib_lib = b.addLibrary(.{
        .name = "raylib",
        .root_module = raylib_mod,
        .linkage = .static,
    });

    // ---- game ----
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addIncludePath(b.path("vendor/raylib/src"));
    exe_mod.link_libc = true;
    exe_mod.linkLibrary(raylib_lib);

    linkPlatformLibs(exe_mod, os_tag);

    const exe = b.addExecutable(.{
        .name = "bitwars",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ---- run ----
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Bit Wars");
    run_step.dependOn(&run_cmd.step);

    // ---- test ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addIncludePath(b.path("vendor/raylib/src"));
    test_mod.link_libc = true;
    test_mod.linkLibrary(raylib_lib);
    linkPlatformLibs(test_mod, os_tag);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn linkPlatformLibs(mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    switch (os_tag) {
        .windows => {
            mod.linkSystemLibrary("opengl32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("winmm", .{});
            mod.linkSystemLibrary("shell32", .{});
        },
        .linux => {
            mod.linkSystemLibrary("GL", .{});
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
        },
        else => {},
    }
}
