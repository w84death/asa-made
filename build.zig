const std = @import("std");

const raylib_src = [_][]const u8{
    "raudio.c",
    "rcore.c",
    "rglfw.c",
    "rmodels.c",
    "rshapes.c",
    "rtext.c",
    "rtextures.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addExe(b, "asa-made", target, optimize);
    b.installArtifact(exe);
    installAssets(b);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run ASA MADE");
    run_step.dependOn(&run_cmd.step);

    // --- Release build (Linux x86_64) ---
    const release_step = b.step("release", "Build optimized release binary");
    const release_exe = addExe(b, "asa-made", b.graph.host, .ReleaseFast);
    const release_install = b.addInstallArtifact(release_exe, .{});
    release_step.dependOn(&release_install.step);

    const install_assets_rel = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    release_step.dependOn(&install_assets_rel.step);
}

fn addExe(b: *std.Build, exe_name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const os_tag = target.result.os.tag;

    // --- raylib C source (compiled directly, avoiding raylib-zig build system) ---
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_src_dir = raylib_dep.path("src");

    const cflags_base = [_][]const u8{
        "-std=c99",
        "-DPLATFORM_DESKTOP_GLFW",
        "-DGRAPHICS_API_OPENGL_33",
        "-D_GNU_SOURCE",
        "-DGL_SILENCE_DEPRECATION=199309L",
        "-DSUPPORT_MODULE_RSHAPES=1",
        "-DSUPPORT_MODULE_RTEXTURES=1",
        "-DSUPPORT_MODULE_RTEXT=1",
        "-DSUPPORT_MODULE_RMODELS=1",
        "-DSUPPORT_MODULE_RAUDIO=1",
        "-w",
    };

    var cflags: []const []const u8 = &cflags_base;
    var cflags_buf: [16][]const u8 = undefined;
    switch (os_tag) {
        .linux => {
            cflags_buf[0..cflags_base.len].* = cflags_base;
            cflags_buf[cflags_base.len] = "-D_GLFW_X11";
            cflags = cflags_buf[0 .. cflags_base.len + 1];
        },
        .windows => {
            cflags_buf[0..cflags_base.len].* = cflags_base;
            cflags_buf[cflags_base.len] = "-D_GLFW_WIN32";
            cflags = cflags_buf[0 .. cflags_base.len + 1];
        },
        else => {},
    }

    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    raylib_mod.addIncludePath(raylib_src_dir);
    raylib_mod.addIncludePath(raylib_dep.path("src/external/glfw/include"));
    raylib_mod.addCSourceFiles(.{
        .root = raylib_src_dir,
        .files = &raylib_src,
        .flags = cflags,
    });
    raylib_mod.link_libc = true;
    if (os_tag == .linux) {
        raylib_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    }

    const raylib_lib = b.addLibrary(.{
        .name = "raylib",
        .root_module = raylib_mod,
        .linkage = .static,
    });

    // --- raylib-zig bindings (module only, no compiled artifact) ---
    const raylib_zig_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_zig_mod = b.addModule("raylib", .{
        .root_source_file = raylib_zig_dep.path("lib/raylib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Game executable ---
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const embedded_assets_mod = b.createModule(.{
        .root_source_file = b.path("assets/embedded.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("raylib", raylib_zig_mod);
    exe_mod.addImport("embedded_assets", embedded_assets_mod);
    exe_mod.linkLibrary(raylib_lib);
    linkPlatformLibs(exe_mod, os_tag);

    return b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });
}

fn installAssets(b: *std.Build) void {
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("assets"),
        .install_dir = .bin,
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);
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
            mod.linkSystemLibrary("Xrandr", .{});
            mod.linkSystemLibrary("Xinerama", .{});
            mod.linkSystemLibrary("Xi", .{});
            mod.linkSystemLibrary("Xcursor", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("rt", .{});
        },
        else => {},
    }
}
