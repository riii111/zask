const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zask_mod = b.addModule("zask", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    zask_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zask",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zask", .module = zask_mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zask");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = zask_mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const tmux_integration_options = b.addOptions();
    tmux_integration_options.addOption([]const u8, "tmux_path", b.findProgram(&.{"tmux"}, &.{}) catch "tmux");
    const tmux_integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/tmux_session.zig"),
        .target = target,
        .optimize = optimize,
    });
    tmux_integration_mod.addOptions("tmux_integration_options", tmux_integration_options);
    const tmux_integration_tests = b.addTest(.{ .root_module = tmux_integration_mod });
    const tmux_integration_step = b.step("test-tmux", "Run tmux integration tests");
    tmux_integration_step.dependOn(&b.addRunArtifact(tmux_integration_tests).step);
}
