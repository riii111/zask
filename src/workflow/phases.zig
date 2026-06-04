const std = @import("std");

const config = @import("../model/config.zig");
const config_value = @import("../model/config_value.zig");
const configured_path = @import("configured_path.zig");
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

pub fn runPrechecks(ctx: anytype, progress: anytype) !void {
    for (ctx.cfg.prechecks()) |check| {
        const name = config_value.optionalObjectString(check, "name", "precheck");
        const command = try config_value.requiredObjectString(check, "command");
        const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
        const hint = config_value.optionalObjectString(check, "hint", "");
        const dir = config_value.optionalObjectString(check, "dir", "");
        const cwd = try phaseCwd(ctx, dir, "prechecks.dir", progress.raw());
        try progress.step("Checking {s}...\n", .{name});
        try progress.command("{s}\n", .{command});
        const result = ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .check = true }) catch |err| switch (err) {
            error.CommandFailed => {
                if (std.mem.eql(u8, on_fail, "abort")) {
                    try progress.failContext();
                    const writer = progress.raw();
                    try writer.writeByte('\n');
                    try writer.print("Error: {s} check failed\n", .{name});
                    if (hint.len > 0) try writer.print("Hint: {s}\n", .{hint});
                    try writer.flush();
                    return error.PrecheckFailed;
                }
                try writePrecheckWarning(progress, name, command, hint);
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
    const cwd = try phaseCwd(ctx, dir, "startup_order.dir", progress.raw());
    const phase_label = commandPhaseLabel(phase);
    try progress.focus("Running {s}...\n", .{phase_label});
    try progress.command("{s}\n", .{command});
    try progress.beforeInteractive();

    const result = try ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .interactive = true });
    const term = switch (result) {
        .term => |value| value,
        else => unreachable,
    };
    if (commandSucceeded(term)) return;

    if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) {
        try writeCommandError(progress, phase_label, command, cwd, term);
        return error.CommandPhaseFailed;
    }
    try writeCommandWarning(progress, phase_label, command, cwd, term);
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

fn phaseCwd(ctx: anytype, dir: []const u8, field: []const u8, writer: *std.Io.Writer) ![]const u8 {
    const project_root = try ctx.cfg.projectRoot(ctx.gpa);
    if (dir.len == 0) {
        if (ctx.validate_configured_dirs) {
            try configured_path.ensureDir(ctx.gpa, ctx.runner.io, writer, .{
                .field = "project.root",
                .configured = try ctx.cfg.requiredString(&.{ "project", "root" }),
                .path = project_root,
            });
        }
        return pathing.absolute(ctx.gpa, ctx.runner.io, project_root);
    }
    try validate.relativeSubPath(dir);
    const path = try std.fs.path.join(ctx.gpa, &.{ project_root, dir });
    if (ctx.validate_configured_dirs) {
        try configured_path.ensureDir(ctx.gpa, ctx.runner.io, writer, .{
            .field = field,
            .configured = dir,
            .project_root = project_root,
            .path = path,
        });
    }
    return pathing.absolute(ctx.gpa, ctx.runner.io, path);
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

fn commandPhaseLabel(phase: std.json.Value) []const u8 {
    const name = config_value.optionalObjectString(phase, "name", "");
    if (name.len > 0) return name;
    return "command";
}

fn commandSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn writePrecheckWarning(progress: anytype, name: []const u8, command: []const u8, hint: []const u8) !void {
    try progress.warnContext();
    const writer = progress.raw();
    try writer.writeByte('\n');
    try writer.print("Warning: {s} check failed\n", .{name});
    try writer.print("  command: {s}\n", .{command});
    if (hint.len > 0) try writer.print("Hint: {s}\n", .{hint});
    try writer.flush();
}

fn writeCommandError(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8, term: std.process.Child.Term) !void {
    try progress.failContext();
    try writeCommandDiagnostic(progress.raw(), "Error", phase_label, command, cwd, term);
}

fn writeCommandWarning(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8, term: std.process.Child.Term) !void {
    try progress.warnContext();
    try writeCommandDiagnostic(progress.raw(), "Warning", phase_label, command, cwd, term);
}

fn writeCommandDiagnostic(writer: *std.Io.Writer, label: []const u8, phase_label: []const u8, command: []const u8, cwd: []const u8, term: std.process.Child.Term) !void {
    try writer.writeByte('\n');
    try writer.print("{s}: command phase failed\n", .{label});
    try writer.print("  phase: {s}\n", .{phase_label});
    try writer.print("  command: {s}\n", .{command});
    try writer.print("  cwd: {s}\n", .{cwd});
    switch (term) {
        .exited => |code| try writer.print("  exit code: {d}\n", .{code}),
        else => try writer.writeAll("  exit code: unavailable\n"),
    }
    try writer.flush();
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
        .validate_configured_dirs = false,
    };
}

const TestProgress = struct {
    writer: *std.Io.Writer,
    current_step: []const u8 = "",
    current_command: []const u8 = "",

    fn raw(self: *TestProgress) *std.Io.Writer {
        return self.writer;
    }

    fn step(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        self.current_step = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
    }

    fn info(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    fn focus(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        try self.step(fmt, args);
    }

    fn command(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        self.current_command = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
    }

    fn status(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    fn detail(self: *TestProgress, lines: []const []const u8) !void {
        _ = self;
        _ = lines;
    }

    fn warn(self: *TestProgress, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
    }

    fn warnContext(self: *TestProgress) !void {
        try self.failContext();
    }

    fn beforeInteractive(self: *TestProgress) !void {
        _ = self;
    }

    fn failContext(self: *TestProgress) !void {
        if (self.current_step.len > 0) try self.writer.writeAll(self.current_step);
        if (self.current_command.len > 0) try self.writer.print("  $ {s}", .{self.current_command});
    }

    fn finishSuccess(self: *TestProgress) !void {
        _ = self;
    }

    fn finishError(self: *TestProgress) !void {
        try self.failContext();
    }

    fn deinit(self: *TestProgress) void {
        if (self.current_step.len > 0) std.testing.allocator.free(self.current_step);
        if (self.current_command.len > 0) std.testing.allocator.free(self.current_command);
    }
};

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

test "phases.runPrechecks: abort failure replays precheck context" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = TestProgress{ .writer = &writer };
    defer progress.deinit();

    try std.testing.expectError(error.PrecheckFailed, runPrechecks(lifecycle, &progress));

    try std.testing.expectEqualStrings(
        \\Checking tool...
        \\  $ missing-tool
        \\
        \\Error: tool check failed
        \\Hint: install tool
        \\
    , writer.buffered());
}

test "phases.runPrechecks: warn failure prints warning and hint" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "prechecks": [{"name":"tool","command":"missing-tool","on_fail":"warn","hint":"install tool"}],
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
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try runPrechecks(lifecycle, &progress);

    try std.testing.expectEqualStrings(
        \\Checking tool...
        \\
        \\Warning: tool check failed
        \\  command: missing-tool
        \\Hint: install tool
        \\
    , writer.buffered());
}

test "phases.runCommandPhase: warn continues and abort fails startup" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);
    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[1], "all", &writer));

    try std.testing.expectEqualStrings(
        \\
        \\Warning: command phase failed
        \\  phase: command
        \\  command: warn setup
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\
        \\Error: command phase failed
        \\  phase: command
        \\  command: abort setup
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\
    , writer.buffered());
    const warn_command = proc_runner.findCommandContaining(&recorder, "warn setup") orelse return error.CommandNotFound;
    const abort_command = proc_runner.findCommandContaining(&recorder, "abort setup") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(warn_command, 2, "warn setup");
    try proc_runner.expectCommandArg(abort_command, 2, "abort setup");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "phases.runCommandPhase: progress includes phase name and command" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "startup_order": [{"name":"release setup","command":"zig build"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = TestProgress{ .writer = &writer };
    defer progress.deinit();

    try runCommandPhaseWithProgress(lifecycle, cfg.phases()[0], "all", &progress);

    try std.testing.expectEqualStrings("Running release setup...\n", progress.current_step);
    try std.testing.expectEqualStrings("zig build\n", progress.current_command);
}

test "phases.runCommandPhase: reports profile override command failure context" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "startup_order": [{"name":"prepare","command":"default prepare","commands":{"release":"zig build -Drelease"}}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 42 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[0], "release", &writer));

    try std.testing.expectEqualStrings(
        \\
        \\Error: command phase failed
        \\  phase: prepare
        \\  command: zig build -Drelease
        \\  cwd: /tmp/demo
        \\  exit code: 42
        \\
    , writer.buffered());
    const command = proc_runner.findCommandContaining(&recorder, "zig build -Drelease") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(command, 2, "zig build -Drelease");
}

test "phases.runServicePhase: propagates window-not-ready as startup failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidPath, phaseCwd(lifecycle, "../escape", "startup_order.dir", &writer));
}
