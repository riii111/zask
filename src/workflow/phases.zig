const std = @import("std");

const config = @import("../model/config.zig");
const config_value = @import("../model/config_value.zig");
const lifecycle_mod = @import("lifecycle.zig");
const pathing = @import("pathing.zig");
const runner_mod = @import("../platform/runner.zig");
const validate = @import("../model/validate.zig");
const waits = @import("waits.zig");

pub const PhaseKind = enum {
    docker,
    command,
    services,
};

pub fn phaseKind(phase: std.json.Value) PhaseKind {
    const value = config_value.optionalObjectString(phase, "type", "");
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "command")) return .command;
    return .services;
}

pub fn runPrechecks(ctx: anytype, writer: *std.Io.Writer) !void {
    for (ctx.cfg.prechecks()) |check| {
        const name = config_value.optionalObjectString(check, "name", "precheck");
        const command = try config_value.requiredObjectString(check, "command");
        const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
        const hint = config_value.optionalObjectString(check, "hint", "");
        const dir = config_value.optionalObjectString(check, "dir", "");
        const cwd = try phaseCwd(ctx, dir);
        const result = ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .check = true }) catch |err| switch (err) {
            error.CommandFailed => {
                if (hint.len > 0) try writer.print("Hint: {s}\n", .{hint});
                if (std.mem.eql(u8, on_fail, "abort")) return error.PrecheckFailed;
                try writer.print("Warning: {s} check failed\n", .{name});
                continue;
            },
            else => return err,
        };
        const captured = result.captured;
        ctx.gpa.free(captured.stdout);
        ctx.gpa.free(captured.stderr);
    }
}

pub fn runCommandPhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
    const command = try config.Config.commandPhaseCommand(phase, profile);
    const dir = config_value.optionalObjectString(phase, "dir", "");
    const cwd = try phaseCwd(ctx, dir);
    _ = ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .interactive = true, .check = true }) catch |err| switch (err) {
        error.CommandFailed => {
            if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
            try writer.writeAll("Warning: command phase failed\n");
            return;
        },
        else => return err,
    };
}

pub fn runServicePhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer, opts: lifecycle_mod.StartOptions) !void {
    if (phase.object.get("groups")) |groups| if (groups == .array) {
        for (groups.array.items) |group_value| {
            if (group_value != .string) continue;
            const group = ctx.cfg.resolvePhaseGroup(profile, group_value.string);
            const svcs = try ctx.cfg.resolveGroup(ctx.gpa, group);
            defer ctx.gpa.free(svcs);
            for (svcs) |svc| try ctx.startService(svc, writer, opts.mode);
        }
    };
    if (opts.wait_ready) if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
        for (ports.array.items) |port_value| if (port_value == .integer) try waits.waitForPort(ctx, port_value.integer, 120, writer);
    };
}

fn phaseCwd(ctx: anytype, dir: []const u8) ![]const u8 {
    if (dir.len == 0) return pathing.absolute(ctx.gpa, ctx.runner.io, try ctx.cfg.projectRoot(ctx.gpa));
    try validate.relativeSubPath(dir);
    return pathing.absolute(ctx.gpa, ctx.runner.io, try std.fs.path.join(ctx.gpa, &.{ try ctx.cfg.projectRoot(ctx.gpa), dir }));
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn parseTestConfig(gpa: std.mem.Allocator, json: []const u8) !config.Config {
    return config.Config.parse(gpa, json, "/home/me");
}

fn testLifecycle(gpa: std.mem.Allocator, run: runner_mod.Runner, cfg: config.Config) lifecycle_mod.Lifecycle {
    return .{
        .gpa = gpa,
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
        .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
}

test "phases.phaseKind: classifies lifecycle phase kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct {
        json: []const u8,
        expected: PhaseKind,
    }{
        .{ .json = "{\"type\":\"docker\"}", .expected = .docker },
        .{ .json = "{\"type\":\"command\"}", .expected = .command },
        .{ .json = "{\"groups\":[\"api\"]}", .expected = .services },
    };

    for (cases) |case| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), case.json, .{});
        try std.testing.expectEqual(case.expected, phaseKind(parsed));
    }
}

test "phases.runPrechecks: failure prints hint and preserves abort semantics" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "prechecks": [{"name":"tool","command":"missing-tool","on_fail":"abort","hint":"install tool"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "missing", .{ .exited = 1 });
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.PrecheckFailed, runPrechecks(lifecycle, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Hint: install tool") != null);
}

test "phases.runCommandPhase: warn continues and abort fails startup" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "startup_order": [
        \\    {"command":"warn setup","on_fail":"warn"},
        \\    {"command":"abort setup","on_fail":"abort"}
        \\  ],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);
    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[1], "all", &writer));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: command phase failed") != null);
    const warn_command = runner_mod.findCommandContaining(&recorder, "warn setup") orelse return error.CommandNotFound;
    const abort_command = runner_mod.findCommandContaining(&recorder, "abort setup") orelse return error.CommandNotFound;
    try runner_mod.expectCommandArg(warn_command, 2, "warn setup");
    try runner_mod.expectCommandArg(abort_command, 2, "abort setup");
    try runner_mod.expectNoRemainingResponses(&recorder);
}

test "phases.runServicePhase: propagates window-not-ready as startup failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}],
        \\  "startup_order": [{"group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WindowNotReady, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .{}));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "window for api not ready") != null);
}

test "phases.phaseCwd: rejects path traversal" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);

    try std.testing.expectError(error.InvalidPath, phaseCwd(lifecycle, "../escape"));
}
