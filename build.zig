const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dependency = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dependency.artifact("raylib");

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_module.addImport("raylib", raylib_dependency.module("raylib"));
    app_module.linkLibrary(raylib);

    const executable = b.addExecutable(.{
        .name = "kanjo-night",
        .root_module = app_module,
    });
    b.installArtifact(executable);

    const run_artifact = b.addRunArtifact(executable);
    run_artifact.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_artifact.addArgs(args);

    const run_step = b.step("run", "Run the Kanjo Night driving prototype");
    run_step.dependOn(&run_artifact.step);
}
