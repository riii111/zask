const std = @import("std");

const config = @import("../model/config.zig");
const config_value = @import("../model/config_value.zig");
const lifecycle_mod = @import("lifecycle.zig");
const pathing = @import("pathing.zig");
const proc_runner = @import("../platform/runner.zig");
const progress_mod = @import("progress.zig");
const shell = @import("../platform/shell.zig");
const validate = @import("../model/validate.zig");
const waits = @import("waits.zig");

const port_wait_timeout_seconds = 30;

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
    var progress = progress_mod.Line.init(writer);
    try runCommandPhaseWithProgress(ctx, phase, profile, &progress);
}

pub fn runCommandPhaseWithProgress(ctx: anytype, phase: std.json.Value, profile: []const u8, progress: anytype) !void {
    const command = try config.Config.commandPhaseCommand(phase, profile);
    const dir = config_value.optionalObjectString(phase, "dir", "");
    const cwd = try phaseCwd(ctx, dir);
    try progress.beforeInteractive();
    _ = ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .interactive = true, .check = true }) catch |err| switch (err) {
        error.CommandFailed => {
            if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
            try progress.warn("Warning: command phase failed\n", .{});
            return;
        },
        else => return err,
    };
}

pub fn runServicePhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer, mode: lifecycle_mod.StartMode) !void {
    var progress = progress_mod.Line.init(writer);
    try runServicePhaseWithProgress(ctx, phase, profile, &progress, mode);
}

pub fn runServicePhaseWithProgress(ctx: anytype, phase: std.json.Value, profile: []const u8, progress: anytype, mode: lifecycle_mod.StartMode) !void {
    if (phase.object.get("groups")) |groups| if (groups == .array) {
        for (groups.array.items) |group_value| {
            if (group_value != .string) continue;
            const group = ctx.cfg.resolvePhaseGroup(profile, group_value.string);
            const svcs = try ctx.cfg.resolveGroup(ctx.gpa, group);
            defer ctx.gpa.free(svcs);
            for (svcs) |svc| try ctx.startServiceWithProgress(svc, progress, mode);
        }
    };
    if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
        for (ports.array.items) |port_value| if (port_value == .integer) {
            const service = try serviceForPort(ctx, phase, profile, port_value.integer);
            try writePortWait(ctx, port_value.integer, service, progress);
            waits.waitForPortWithProgress(ctx, port_value.integer, port_wait_timeout_seconds, service, progress) catch |err| switch (err) {
                error.PortNotReady => {
                    try writePortFailure(ctx, phase, profile, port_value.integer, port_wait_timeout_seconds, progress);
                    return error.StartupFailed;
                },
                else => return err,
            };
        };
    };
}

fn phaseCwd(ctx: anytype, dir: []const u8) ![]const u8 {
    if (dir.len == 0) return pathing.absolute(ctx.gpa, ctx.runner.io, try ctx.cfg.projectRoot(ctx.gpa));
    try validate.relativeSubPath(dir);
    return pathing.absolute(ctx.gpa, ctx.runner.io, try std.fs.path.join(ctx.gpa, &.{ try ctx.cfg.projectRoot(ctx.gpa), dir }));
}

fn writePortWait(ctx: anytype, port: i64, service: ?[]const u8, progress: anytype) !void {
    if (service) |name| {
        const value = try ctx.cfg.findService(name);
        const command = try config.Config.serviceStartCommand(ctx.gpa, value);
        try progress.focus("Starting {s}...\n", .{name});
        try progress.command("{s}\n", .{command});
        try progress.status("Waiting for {s} on localhost:{d}...\n", .{ name, port });
    } else {
        try progress.step("Checking localhost:{d}\n", .{port});
        try progress.status("Waiting for localhost:{d}...\n", .{port});
    }
}

fn writePortFailure(ctx: anytype, phase: std.json.Value, profile: []const u8, port: i64, timeout: i64, progress: anytype) !void {
    try progress.failContext();
    const writer = progress.raw();
    const service = try serviceForPort(ctx, phase, profile, port);
    const phase_label = phaseLabel(ctx, phase, profile);
    try writer.writeByte('\n');
    if (service) |name| {
        try writer.print("Error: {s} did not become ready\n", .{name});
    } else {
        try writer.print("Error: port {d} did not become ready\n", .{port});
    }
    try writer.print("  phase: {s}\n", .{phase_label});
    try writer.print("  expected: localhost:{d}\n", .{port});
    try writer.print("  waited: {d}s\n", .{timeout});
    if (service) |name| try writeLastLog(ctx, name, writer);
    if (service) |name| try writeNextLogsHint(ctx, name, writer);
    try writer.flush();
}

fn serviceForPort(ctx: anytype, phase: std.json.Value, profile: []const u8, port: i64) !?[]const u8 {
    var matched: ?[]const u8 = null;
    if (phase.object.get("groups")) |groups| if (groups == .array) {
        for (groups.array.items) |group_value| {
            if (group_value != .string) continue;
            const group = ctx.cfg.resolvePhaseGroup(profile, group_value.string);
            const svcs = try ctx.cfg.resolveGroup(ctx.gpa, group);
            defer ctx.gpa.free(svcs);
            for (svcs) |svc| {
                const service = try ctx.cfg.findService(svc);
                if (config.Config.servicePort(service) != port) continue;
                if (matched != null) return null;
                matched = svc;
            }
        }
    };
    return matched;
}

fn phaseLabel(ctx: anytype, phase: std.json.Value, profile: []const u8) []const u8 {
    const name = config_value.optionalObjectString(phase, "name", "");
    if (name.len > 0) return name;
    if (phase.object.get("groups")) |groups| if (groups == .array and groups.array.items.len == 1) {
        const group = groups.array.items[0];
        if (group == .string) return ctx.cfg.resolvePhaseGroup(profile, group.string);
    };
    return "startup";
}

fn writeLastLog(ctx: anytype, window: []const u8, writer: *std.Io.Writer) !void {
    const line = try ctx.tmux.captureLastLine(window);
    defer ctx.gpa.free(line);
    if (line.len > 0) try writer.print("  last log: {s}\n", .{line});
}

fn writeNextLogsHint(ctx: anytype, service: []const u8, writer: *std.Io.Writer) !void {
    const config_path = try shell.quote(ctx.gpa, ctx.config_path);
    defer ctx.gpa.free(config_path);
    try writer.writeAll("\nNext:\n");
    try writer.print("  zask --config {s} logs {s}\n", .{ config_path, service });
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn parseTestConfig(gpa: std.mem.Allocator, json: []const u8) !config.Config {
    return config.Config.parse(gpa, json, "/home/me");
}

fn testLifecycle(gpa: std.mem.Allocator, run: proc_runner.Runner, cfg: config.Config) lifecycle_mod.Lifecycle {
    return .{
        .gpa = gpa,
        .cfg = cfg,
        .config_path = "config.json",
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
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "missing", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
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
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);
    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[1], "all", &writer));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: command phase failed") != null);
    const warn_command = proc_runner.findCommandContaining(&recorder, "warn setup") orelse return error.CommandNotFound;
    const abort_command = proc_runner.findCommandContaining(&recorder, "abort setup") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(warn_command, 2, "warn setup");
    try proc_runner.expectCommandArg(abort_command, 2, "abort setup");
    try proc_runner.expectNoRemainingResponses(&recorder);
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
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WindowNotReady, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "window for api not ready") != null);
}

test "phases.runServicePhase: honors wait_ports as a declared dependency" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve","port":5432}]}],
        \\  "startup_order": [{"name":"backend","group":"backend","wait_ports":[5432]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe);

    const port_check = proc_runner.findCommandContaining(&recorder, "nc") orelse return error.PortCheckMissing;
    try proc_runner.expectCommandArg(port_check, 3, "5432");
    try proc_runner.expectCommandOrder(&recorder, "serve", "nc");
    try proc_runner.expectCommandOrder(&recorder, "capture-pane", "nc");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "phases.runServicePhase: reports port readiness failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve","port":5432}]}],
        \\  "startup_order": [{"name":"backend","group":"backend","wait_ports":[5432]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    recorder.stdout = "Error: address already in use\n";
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.StartupFailed, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe));

    try std.testing.expectEqualStrings(
        \\Starting api...
        \\Waiting for api on localhost:5432...
        \\
        \\Error: api did not become ready
        \\  phase: backend
        \\  expected: localhost:5432
        \\  waited: 30s
        \\  last log: Error: address already in use
        \\
        \\Next:
        \\  zask --config 'config.json' logs api
        \\
    , writer.buffered());
}

test "phases.runServicePhase: reports unmatched port without service hints" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve","port":3000}]}],
        \\  "startup_order": [{"group":"backend","wait_ports":[5432]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.StartupFailed, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe));

    try std.testing.expectEqualStrings(
        \\Starting api...
        \\Checking localhost:5432
        \\Waiting for localhost:5432...
        \\
        \\Error: port 5432 did not become ready
        \\  phase: backend
        \\  expected: localhost:5432
        \\  waited: 30s
        \\
    , writer.buffered());
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
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);

    try std.testing.expectError(error.InvalidPath, phaseCwd(lifecycle, "../escape"));
}
