const std = @import("std");

const config = @import("config.zig");
const config_value = @import("config_value.zig");
const validate = @import("validate.zig");
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

pub fn runServicePhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
    if (phase.object.get("groups")) |groups| if (groups == .array) {
        for (groups.array.items) |group_value| {
            if (group_value != .string) continue;
            const group = ctx.cfg.resolvePhaseGroup(profile, group_value.string);
            for (try ctx.cfg.resolveGroup(ctx.gpa, group)) |svc| try ctx.startService(svc, writer);
        }
    };
    if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
        for (ports.array.items) |port_value| if (port_value == .integer) try waits.waitForPort(ctx, port_value.integer, 120, writer);
    };
}

fn phaseCwd(ctx: anytype, dir: []const u8) ![]const u8 {
    if (dir.len == 0) return ctx.cfg.projectRoot(ctx.gpa);
    try validate.relativeSubPath(dir);
    return std.fs.path.join(ctx.gpa, &.{ try ctx.cfg.projectRoot(ctx.gpa), dir });
}

test "classifies lifecycle phase kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\[
        \\  {"type":"docker"},
        \\  {"type":"command"},
        \\  {"groups":["api"]}
        \\]
    , .{});

    try std.testing.expectEqual(PhaseKind.docker, phaseKind(parsed.array.items[0]));
    try std.testing.expectEqual(PhaseKind.command, phaseKind(parsed.array.items[1]));
    try std.testing.expectEqual(PhaseKind.services, phaseKind(parsed.array.items[2]));
}

test "precheck failure prints hint and preserves abort semantics" {
    const lifecycle_mod = @import("lifecycle.zig");
    const runner_mod = @import("infra/runner.zig");
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "prechecks": [{"name":"tool","command":"missing-tool","on_fail":"abort","hint":"install tool"}],
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "missing", .{ .exited = 1 });
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = lifecycle_mod.Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.PrecheckFailed, runPrechecks(lifecycle, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Hint: install tool") != null);
}

test "command phase warn continues and abort fails startup" {
    const lifecycle_mod = @import("lifecycle.zig");
    const runner_mod = @import("infra/runner.zig");
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "phases": [
        \\    {"type":"command","command":"warn setup","on_fail":"warn"},
        \\    {"type":"command","command":"abort setup","on_fail":"abort"}
        \\  ],
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = lifecycle_mod.Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);
    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[1], "all", &writer));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: command phase failed") != null);
    try std.testing.expectEqualStrings("warn setup", recorder.commands.items[0].argv[2]);
    try std.testing.expectEqualStrings("abort setup", recorder.commands.items[1].argv[2]);
    try runner_mod.expectNoRemainingResponses(&recorder);
}

test "phase cwd rejects path traversal" {
    const runner_mod = @import("infra/runner.zig");
    const lifecycle_mod = @import("lifecycle.zig");
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = runner_mod.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = runner_mod.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = lifecycle_mod.Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };

    try std.testing.expectError(error.InvalidPath, phaseCwd(lifecycle, "../escape"));
}
