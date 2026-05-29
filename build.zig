const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const run_step = b.step("run", "Run zask");
    const test_step = b.step("test", "Run unit, recorder, and render smoke tests");
    const e2e_step = b.step("test-e2e", "Run subprocess CLI E2E tests");
    const tmux_integration_step = b.step("test-tmux", "Run tmux integration tests");
    const test_all_step = b.step("test-all", "Run all test suites");

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = zask_mod,
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const tmux_integration_options = b.addOptions();
    tmux_integration_options.addOption([]const u8, "tmux_path", b.findProgram(&.{"tmux"}, &.{}) catch "tmux");
    const tmux_integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/tmux_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zask", .module = zask_mod },
        },
    });
    tmux_integration_mod.addOptions("tmux_integration_options", tmux_integration_options);
    const tmux_integration_tests = b.addTest(.{
        .root_module = tmux_integration_mod,
        .filters = test_filters,
    });
    tmux_integration_step.dependOn(&b.addRunArtifact(tmux_integration_tests).step);

    const e2e_options = b.addOptions();
    e2e_options.addOption([]const u8, "zask_path", b.getInstallPath(.bin, "zask"));
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("e2e_options", e2e_options);
    const e2e_tests = b.addTest(.{
        .root_module = e2e_mod,
        .filters = test_filters,
    });
    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.step.dependOn(b.getInstallStep());

    e2e_step.dependOn(&run_e2e_tests.step);
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(e2e_step);
    test_all_step.dependOn(tmux_integration_step);
}
