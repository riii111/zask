const std = @import("std");

const config = @import("../model/config.zig");
const config_value = @import("../model/config_value.zig");
const configured_path = @import("configured_path.zig");
const lifecycle_mod = @import("lifecycle.zig");
const pathing = @import("pathing.zig");
const proc_runner = @import("../platform/runner.zig");
const progress_mod = @import("progress.zig");
const validate = @import("../model/validate.zig");
const waits = @import("waits.zig");
const zask_command = @import("zask_command.zig");

const default_port_wait_timeout_seconds = 180;
const diagnostic_tail_lines = 6;

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
        const result = proc_runner.captured(ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd }) catch |err| switch (err) {
            error.OutputTooLarge => {
                if (std.mem.eql(u8, on_fail, "abort")) {
                    try writePrecheckOutputTooLargeError(progress, name, command, cwd, hint);
                    return error.PrecheckFailed;
                }
                try writePrecheckOutputTooLargeWarning(progress, name, command, cwd, hint);
                continue;
            },
            else => return err,
        });
        defer ctx.gpa.free(result.stdout);
        defer ctx.gpa.free(result.stderr);
        if (commandSucceeded(result.term)) continue;

        if (std.mem.eql(u8, on_fail, "abort")) {
            try writePrecheckError(progress, name, command, cwd, result, hint);
            return error.PrecheckFailed;
        }
        try writePrecheckWarning(progress, name, command, cwd, result, hint);
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
    try progress.step("Running {s}...\n", .{phase_label});
    try progress.command("{s}\n", .{command});

    const on_fail = config_value.optionalObjectString(phase, "on_fail", "abort");
    const result = proc_runner.captured(ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd }) catch |err| switch (err) {
        error.OutputTooLarge => {
            if (std.mem.eql(u8, on_fail, "abort")) {
                try writeCommandOutputTooLargeError(progress, phase_label, command, cwd);
                return error.CommandPhaseFailed;
            }
            try writeCommandOutputTooLargeWarning(progress, phase_label, command, cwd);
            return;
        },
        else => return err,
    });
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (commandSucceeded(result.term)) return;

    if (std.mem.eql(u8, on_fail, "abort")) {
        try writeCommandError(progress, phase_label, command, cwd, result);
        return error.CommandPhaseFailed;
    }
    try writeCommandWarning(progress, phase_label, command, cwd, result);
}

pub fn runServicePhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer, mode: lifecycle_mod.StartMode) !void {
    var progress = progress_mod.Line.init(writer);
    try runServicePhaseWithProgress(ctx, phase, profile, &progress, mode);
}

/// Caller owns the returned slice and must free it with the same allocator.
pub fn resolvedServicePhaseServices(gpa: std.mem.Allocator, cfg: config.Config, profile: []const u8) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    const phase_list = cfg.phases();
    if (phase_list.len == 0) {
        for (try cfg.services()) |service| try appendUniqueService(gpa, &names, try config.Config.serviceName(service));
        return names.toOwnedSlice(gpa);
    }
    for (phase_list) |phase| {
        if (phase != .object or phaseKind(phase) != .services) continue;
        if (phase.object.get("groups")) |groups| if (groups == .array) {
            for (groups.array.items) |group_value| {
                if (group_value != .string) continue;
                const group = cfg.resolvePhaseGroup(profile, group_value.string);
                const services = try cfg.resolveGroup(gpa, group);
                defer gpa.free(services);
                for (services) |service| try appendUniqueService(gpa, &names, service);
            }
        };
    }
    return names.toOwnedSlice(gpa);
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
        const port_wait_timeout_seconds = config.Config.phasePortWaitTimeout(phase, default_port_wait_timeout_seconds);
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
                .configured = try ctx.cfg.configuredProjectRoot(),
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
    var observed = ListenPorts.empty(.unavailable);
    defer observed.deinit(ctx.gpa);
    if (service) |name| {
        observed = try observeListenPorts(ctx, name);
        try writeListenPortObservation(writer, observed);
        const last_log = try writeLastLog(ctx, name, writer);
        defer ctx.gpa.free(last_log);
        try writeStartupFailureHints(writer, name, port, observed, last_log);
        try writeNextLogsHint(ctx, name, writer);
    }
    try writer.flush();
}

const ListenPortState = enum {
    ports,
    none,
    unavailable,
};

const ListenPorts = struct {
    state: ListenPortState,
    ports: []const i64 = &.{},

    fn empty(state: ListenPortState) ListenPorts {
        return .{ .state = state };
    }

    fn fromOwned(ports: []const i64) ListenPorts {
        return .{ .state = .ports, .ports = ports };
    }

    fn deinit(self: ListenPorts, gpa: std.mem.Allocator) void {
        gpa.free(self.ports);
    }

    fn contains(self: ListenPorts, port: i64) bool {
        for (self.ports) |item| {
            if (item == port) return true;
        }
        return false;
    }
};

fn observeListenPorts(ctx: anytype, service: []const u8) !ListenPorts {
    const info = ctx.tmux.paneInfo(service) catch return ListenPorts.empty(.unavailable);
    defer info.deinit(ctx.gpa);
    const pid = std.mem.trim(u8, info.pid, " \t\r\n");
    if (pid.len == 0 or std.mem.eql(u8, pid, "0")) return ListenPorts.empty(.unavailable);

    const pid_arg = try listenPortPidArg(ctx, pid);
    defer ctx.gpa.free(pid_arg);
    const result = proc_runner.captured(ctx.runner.run(&.{ "lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pid_arg }, .{}) catch return ListenPorts.empty(.unavailable));
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (result.term != .exited) return ListenPorts.empty(.unavailable);

    const ports = try parseListenPorts(ctx.gpa, result.stdout);
    if (ports.len == 0) {
        ctx.gpa.free(ports);
        return ListenPorts.empty(.none);
    }
    return ListenPorts.fromOwned(ports);
}

fn listenPortPidArg(ctx: anytype, pid: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    errdefer out.deinit();
    try out.writer.writeAll(pid);

    const children = proc_runner.captured(ctx.runner.run(&.{ "pgrep", "-P", pid }, .{}) catch return out.toOwnedSlice());
    defer ctx.gpa.free(children.stdout);
    defer ctx.gpa.free(children.stderr);
    if (children.term != .exited or children.term.exited != 0) return out.toOwnedSlice();
    var lines = std.mem.splitScalar(u8, children.stdout, '\n');
    while (lines.next()) |line| {
        const child = std.mem.trim(u8, line, " \t\r\n");
        if (child.len == 0) continue;
        try out.writer.writeByte(',');
        try out.writer.writeAll(child);
    }
    return out.toOwnedSlice();
}

fn parseListenPorts(gpa: std.mem.Allocator, output: []const u8) ![]i64 {
    var ports: std.ArrayList(i64) = .empty;
    errdefer ports.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "(LISTEN)") == null) continue;
        const marker = std.mem.indexOf(u8, line, " (LISTEN)") orelse line.len;
        const endpoint = std.mem.trim(u8, line[0..marker], " \t\r\n");
        const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse continue;
        const port_text = endpoint[colon + 1 ..];
        const parsed = std.fmt.parseInt(i64, port_text, 10) catch continue;
        if (!containsPort(ports.items, parsed)) try ports.append(gpa, parsed);
    }
    return ports.toOwnedSlice(gpa);
}

fn containsPort(ports: []const i64, port: i64) bool {
    for (ports) |item| {
        if (item == port) return true;
    }
    return false;
}

fn writeListenPortObservation(writer: *std.Io.Writer, observed: ListenPorts) !void {
    switch (observed.state) {
        .unavailable => try writer.writeAll("  observed: unavailable\n"),
        .none => try writer.writeAll("  observed: no listen port from service process\n"),
        .ports => {
            try writer.writeAll("  observed: ");
            for (observed.ports, 0..) |port, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("localhost:{d}", .{port});
            }
            try writer.writeByte('\n');
        },
    }
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

fn appendUniqueService(gpa: std.mem.Allocator, names: *std.ArrayList([]const u8), service: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, service)) return;
    }
    try names.append(gpa, service);
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

fn writePrecheckError(progress: anytype, name: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult, hint: []const u8) !void {
    try progress.failContext();
    try writePrecheckDiagnostic(progress.raw(), "Error", name, command, cwd, result, hint);
}

fn writePrecheckOutputTooLargeError(progress: anytype, name: []const u8, command: []const u8, cwd: []const u8, hint: []const u8) !void {
    try progress.failContext();
    try writePrecheckOutputTooLargeDiagnostic(progress.raw(), "Error", name, command, cwd, hint);
}

fn writePrecheckWarning(progress: anytype, name: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult, hint: []const u8) !void {
    try progress.warnContext();
    try writePrecheckDiagnostic(progress.raw(), "Warning", name, command, cwd, result, hint);
}

fn writePrecheckOutputTooLargeWarning(progress: anytype, name: []const u8, command: []const u8, cwd: []const u8, hint: []const u8) !void {
    try progress.warnContext();
    try writePrecheckOutputTooLargeDiagnostic(progress.raw(), "Warning", name, command, cwd, hint);
}

fn writePrecheckDiagnostic(writer: *std.Io.Writer, label: []const u8, name: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult, hint: []const u8) !void {
    try writer.writeByte('\n');
    try writer.print("{s}: {s} check failed\n", .{ label, name });
    try writer.print("  command: {s}\n", .{command});
    try writer.print("  cwd: {s}\n", .{cwd});
    switch (result.term) {
        .exited => |code| try writer.print("  exit code: {d}\n", .{code}),
        else => try writer.writeAll("  exit code: unavailable\n"),
    }
    try writeOutputTail(writer, "stderr tail", result.stderr);
    try writeOutputTail(writer, "stdout tail", result.stdout);
    if (hint.len > 0) try writer.print("Hint: {s}\n", .{hint});
    try writer.flush();
}

fn writePrecheckOutputTooLargeDiagnostic(writer: *std.Io.Writer, label: []const u8, name: []const u8, command: []const u8, cwd: []const u8, hint: []const u8) !void {
    try writer.writeByte('\n');
    try writer.print("{s}: {s} check failed\n", .{ label, name });
    try writer.print("  command: {s}\n", .{command});
    try writer.print("  cwd: {s}\n", .{cwd});
    try writer.writeAll("  exit code: unavailable\n");
    try writeCaptureLimitExceeded(writer);
    if (hint.len > 0) try writer.print("Hint: {s}\n", .{hint});
    try writer.writeAll("Next: run the command directly for full logs\n");
    try writer.flush();
}

fn writeCommandError(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult) !void {
    try progress.failContext();
    try writeCommandDiagnostic(progress.raw(), "Error", phase_label, command, cwd, result);
}

fn writeCommandOutputTooLargeError(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8) !void {
    try progress.failContext();
    try writeCommandOutputTooLargeDiagnostic(progress.raw(), "Error", phase_label, command, cwd);
}

fn writeCommandWarning(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult) !void {
    try progress.warnContext();
    try writeCommandDiagnostic(progress.raw(), "Warning", phase_label, command, cwd, result);
}

fn writeCommandOutputTooLargeWarning(progress: anytype, phase_label: []const u8, command: []const u8, cwd: []const u8) !void {
    try progress.warnContext();
    try writeCommandOutputTooLargeDiagnostic(progress.raw(), "Warning", phase_label, command, cwd);
}

fn writeCommandDiagnostic(writer: *std.Io.Writer, label: []const u8, phase_label: []const u8, command: []const u8, cwd: []const u8, result: std.process.RunResult) !void {
    try writer.writeByte('\n');
    try writer.print("{s}: command phase failed\n", .{label});
    try writer.print("  phase: {s}\n", .{phase_label});
    try writer.print("  command: {s}\n", .{command});
    try writer.print("  cwd: {s}\n", .{cwd});
    switch (result.term) {
        .exited => |code| try writer.print("  exit code: {d}\n", .{code}),
        else => try writer.writeAll("  exit code: unavailable\n"),
    }
    try writeOutputTail(writer, "stderr tail", result.stderr);
    try writeOutputTail(writer, "stdout tail", result.stdout);
    try writer.flush();
}

fn writeCommandOutputTooLargeDiagnostic(writer: *std.Io.Writer, label: []const u8, phase_label: []const u8, command: []const u8, cwd: []const u8) !void {
    try writer.writeByte('\n');
    try writer.print("{s}: command phase failed\n", .{label});
    try writer.print("  phase: {s}\n", .{phase_label});
    try writer.print("  command: {s}\n", .{command});
    try writer.print("  cwd: {s}\n", .{cwd});
    try writer.writeAll("  exit code: unavailable\n");
    try writeCaptureLimitExceeded(writer);
    try writer.writeAll("Next: run the command directly for full logs\n");
    try writer.flush();
}

fn writeCaptureLimitExceeded(writer: *std.Io.Writer) !void {
    if (proc_runner.captured_output_limit == 1024 * 1024) {
        try writer.writeAll("  output: 1 MiB capture limit exceeded\n");
        return;
    }
    try writer.print("  output: {d} byte capture limit exceeded\n", .{proc_runner.captured_output_limit});
}

fn writeOutputTail(writer: *std.Io.Writer, label: []const u8, output: []const u8) !void {
    var tail: [diagnostic_tail_lines][]const u8 = undefined;
    var count: usize = 0;
    var next: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = trimLineRight(raw_line);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (count < diagnostic_tail_lines) {
            tail[count] = line;
            count += 1;
        } else {
            tail[next] = line;
            next = (next + 1) % diagnostic_tail_lines;
        }
    }
    if (count == 0) return;

    try writer.print("  {s}:\n", .{label});
    const start = if (count == diagnostic_tail_lines) next else 0;
    for (0..count) |offset| {
        const line = tail[(start + offset) % diagnostic_tail_lines];
        try writer.writeAll("    ");
        try writeDisplayLine(writer, line);
        try writer.writeByte('\n');
    }
}

fn trimLineRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0) {
        switch (line[end - 1]) {
            ' ', '\t', '\r' => end -= 1,
            else => break,
        }
    }
    return line[0..end];
}

fn writeDisplayLine(writer: *std.Io.Writer, line: []const u8) !void {
    for (line) |byte| {
        if (byte < 0x20 and byte != '\t') {
            try writer.writeByte('?');
        } else if (byte == 0x7f) {
            try writer.writeByte('?');
        } else {
            try writer.writeByte(byte);
        }
    }
}

fn writeLastLog(ctx: anytype, window: []const u8, writer: *std.Io.Writer) ![]const u8 {
    const line = try ctx.tmux.captureLastLine(window);
    if (line.len > 0) try writer.print("  last log: {s}\n", .{line});
    return line;
}

fn writeStartupFailureHints(writer: *std.Io.Writer, service: []const u8, expected_port: i64, observed: ListenPorts, last_log: []const u8) !void {
    if (observed.state == .ports and !observed.contains(expected_port) and observed.ports.len > 0) {
        try writer.print("Hint: {s} is listening on {d}, but config port is {d}.\n", .{ service, observed.ports[0], expected_port });
    }
    if (startupFailureHint(last_log)) |hint| try writer.print("Hint: {s}\n", .{hint});
}

fn startupFailureHint(last_log: []const u8) ?[]const u8 {
    if (last_log.len == 0) return null;
    if (containsIgnoreCase(last_log, "address already in use") or containsIgnoreCase(last_log, "eaddrinuse"))
        return "port is already in use; stop the existing process or change the configured port.";
    if (containsIgnoreCase(last_log, "connection refused"))
        return "a dependency refused the connection; check whether the upstream service is running.";
    if (containsIgnoreCase(last_log, "client_id is required") or
        containsIgnoreCase(last_log, "environment variable") or
        containsIgnoreCase(last_log, "missing required"))
        return "required environment may be missing; check env_file or the service command environment.";
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn writeNextLogsHint(ctx: anytype, service: []const u8, writer: *std.Io.Writer) !void {
    const command_text = try std.fmt.allocPrint(ctx.gpa, "logs {s}", .{service});
    defer ctx.gpa.free(command_text);
    const command = try zask_command.hint(ctx.gpa, ctx.command_hint, command_text);
    defer ctx.gpa.free(command);
    try writer.writeAll("\nNext:\n");
    try writer.print("  {s}\n", .{command});
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
        .runner = run,
        .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
        .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
        .validate_configured_dirs = false,
        .command_hint = .{ .config = "config.json" },
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

test "phases.resolvedServicePhaseServices: resolves service phase targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct {
        name: []const u8,
        json: []const u8,
        profile: []const u8,
        expected: []const []const u8,
    }{
        .{
            .name = "no phases",
            .json =
            \\{
            \\  "project": {"name":"demo","root":"/tmp/demo"},
            \\  "groups": [{"name":"all","services":[
            \\    {"name":"api","dir":"api","command":"serve"},
            \\    {"name":"web","dir":"web","command":"dev"}
            \\  ]}]
            \\}
            ,
            .profile = "all",
            .expected = &.{ "api", "web" },
        },
        .{
            .name = "profile override",
            .json =
            \\{
            \\  "project": {"name":"demo","root":"/tmp/demo"},
            \\  "groups": [
            \\    {"name":"backend","services":[{"name":"api","dir":"api","command":"serve"}]},
            \\    {"name":"worker","services":[{"name":"job","dir":"job","command":"run"}]}
            \\  ],
            \\  "startup_order": [{"group":"backend"}],
            \\  "start_profiles": {
            \\    "jobs": {"profile":"jobs","group_overrides":{"backend":"worker"}}
            \\  }
            \\}
            ,
            .profile = "jobs",
            .expected = &.{"job"},
        },
        .{
            .name = "dedupe",
            .json =
            \\{
            \\  "project": {"name":"demo","root":"/tmp/demo"},
            \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve"}]}],
            \\  "startup_order": [{"group":"backend"}, {"group":"backend"}]
            \\}
            ,
            .profile = "all",
            .expected = &.{"api"},
        },
    };

    for (cases) |case| {
        const cfg = try parseTestConfig(gpa, case.json);
        const services = try resolvedServicePhaseServices(gpa, cfg, case.profile);
        try std.testing.expectEqual(case.expected.len, services.len);
        for (case.expected, services) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
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
    try recorder.enqueue("install log\n", "missing\n", .{ .exited = 1 });
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
        \\  command: missing-tool
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\  stderr tail:
        \\    missing
        \\  stdout tail:
        \\    install log
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
    try recorder.enqueue("install log\n", "missing\n", .{ .exited = 1 });
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
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\  stderr tail:
        \\    missing
        \\  stdout tail:
        \\    install log
        \\Hint: install tool
        \\
    , writer.buffered());
}

test "phases.runPrechecks: reports capture limit with check context" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "prechecks": [{"name":"tool","command":"verbose-check","on_fail":"abort","hint":"reduce output"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.StreamTooLong);
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
        \\  $ verbose-check
        \\
        \\Error: tool check failed
        \\  command: verbose-check
        \\  cwd: /tmp/demo
        \\  exit code: unavailable
        \\  output: 1 MiB capture limit exceeded
        \\Hint: reduce output
        \\Next: run the command directly for full logs
        \\
    , writer.buffered());
}

test "phases.runPrechecks: capture limit warning continues" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "prechecks": [
        \\    {"name":"before","command":"before-check"},
        \\    {"name":"verbose","command":"verbose-check","on_fail":"warn"},
        \\    {"name":"after","command":"after-check"}
        \\  ],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueueError(error.StreamTooLong);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try runPrechecks(lifecycle, &progress);

    try std.testing.expectEqualStrings(
        \\Checking before...
        \\Checking verbose...
        \\
        \\Warning: verbose check failed
        \\  command: verbose-check
        \\  cwd: /tmp/demo
        \\  exit code: unavailable
        \\  output: 1 MiB capture limit exceeded
        \\Next: run the command directly for full logs
        \\Checking after...
        \\
    , writer.buffered());
    try proc_runner.expectCommandContaining(&recorder, "after-check");
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
    try recorder.enqueue("warn out\n", "warn err\n", .{ .exited = 1 });
    try recorder.enqueue("abort out\n", "abort err\n", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);
    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[1], "all", &writer));

    try std.testing.expectEqualStrings(
        \\Running command...
        \\
        \\Warning: command phase failed
        \\  phase: command
        \\  command: warn setup
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\  stderr tail:
        \\    warn err
        \\  stdout tail:
        \\    warn out
        \\Running command...
        \\
        \\Error: command phase failed
        \\  phase: command
        \\  command: abort setup
        \\  cwd: /tmp/demo
        \\  exit code: 1
        \\  stderr tail:
        \\    abort err
        \\  stdout tail:
        \\    abort out
        \\
    , writer.buffered());
    const warn_command = proc_runner.findCommandContaining(&recorder, "warn setup") orelse return error.CommandNotFound;
    const abort_command = proc_runner.findCommandContaining(&recorder, "abort setup") orelse return error.CommandNotFound;
    try std.testing.expect(!warn_command.interactive);
    try std.testing.expect(!abort_command.interactive);
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
    try recorder.enqueue("one\n  two\nthree\nfour\nfive\nsix\nseven\n", "bad\x1b[2J\n", .{ .exited = 42 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[0], "release", &writer));

    try std.testing.expectEqualStrings(
        \\Running prepare...
        \\
        \\Error: command phase failed
        \\  phase: prepare
        \\  command: zig build -Drelease
        \\  cwd: /tmp/demo
        \\  exit code: 42
        \\  stderr tail:
        \\    bad?[2J
        \\  stdout tail:
        \\      two
        \\    three
        \\    four
        \\    five
        \\    six
        \\    seven
        \\
    , writer.buffered());
    const command = proc_runner.findCommandContaining(&recorder, "zig build -Drelease") orelse return error.CommandNotFound;
    try std.testing.expect(!command.interactive);
    try proc_runner.expectCommandArg(command, 2, "zig build -Drelease");
}

test "phases.runCommandPhase: reports capture limit with phase context" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "startup_order": [{"name":"prepare","command":"gradle build"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.StreamTooLong);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CommandPhaseFailed, runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer));

    try std.testing.expectEqualStrings(
        \\Running prepare...
        \\
        \\Error: command phase failed
        \\  phase: prepare
        \\  command: gradle build
        \\  cwd: /tmp/demo
        \\  exit code: unavailable
        \\  output: 1 MiB capture limit exceeded
        \\Next: run the command directly for full logs
        \\
    , writer.buffered());
}

test "phases.runCommandPhase: capture limit warning continues" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "startup_order": [{"name":"prepare","command":"gradle build","on_fail":"warn"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.StreamTooLong);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runCommandPhase(lifecycle, cfg.phases()[0], "all", &writer);

    try std.testing.expectEqualStrings(
        \\Running prepare...
        \\
        \\Warning: command phase failed
        \\  phase: prepare
        \\  command: gradle build
        \\  cwd: /tmp/demo
        \\  exit code: unavailable
        \\  output: 1 MiB capture limit exceeded
        \\Next: run the command directly for full logs
        \\
    , writer.buffered());
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
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WindowNotReady, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe));
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Error: api window is not ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "window: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zask --config 'config.json' open") != null);
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
        \\  "startup_order": [{"name":"backend","group":"backend","wait_ports":[5432],"port_wait_timeout_seconds":5}]
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
        \\  waited: 5s
        \\  observed: unavailable
        \\  last log: Error: address already in use
        \\Hint: port is already in use; stop the existing process or change the configured port.
        \\
        \\Next:
        \\  zask --config 'config.json' logs api
        \\
    , writer.buffered());
}

test "phases.runServicePhase: reports mismatched observed listen port" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve","port":5432}]}],
        \\  "startup_order": [{"name":"backend","group":"backend","wait_ports":[5432],"port_wait_timeout_seconds":1}]
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
    try recorder.enqueue("Listening on 15432\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue(
        \\COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        \\node    12346 me     7u  IPv4 0x123      0t0  TCP *:15432 (LISTEN)
        \\
    , "", .{ .exited = 0 });
    try recorder.enqueue("Listening on 15432\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [768]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.StartupFailed, runServicePhase(lifecycle, cfg.phases()[0], "all", &writer, .observe));

    try std.testing.expectEqualStrings(
        \\Starting api...
        \\Waiting for api on localhost:5432...
        \\
        \\Error: api did not become ready
        \\  phase: backend
        \\  expected: localhost:5432
        \\  waited: 1s
        \\  observed: localhost:15432
        \\  last log: Listening on 15432
        \\Hint: api is listening on 15432, but config port is 5432.
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
        \\  waited: 180s
        \\
    , writer.buffered());
}

test "phases.startupFailureHint: maps common startup failures" {
    try std.testing.expectEqualStrings(
        "required environment may be missing; check env_file or the service command environment.",
        startupFailureHint("[ERROR] TypeError: client_id is required").?,
    );
    try std.testing.expectEqualStrings(
        "a dependency refused the connection; check whether the upstream service is running.",
        startupFailureHint("Connection refused while calling upstream").?,
    );
    try std.testing.expectEqualStrings(
        "port is already in use; stop the existing process or change the configured port.",
        startupFailureHint("listen EADDRINUSE 127.0.0.1:3000").?,
    );
    try std.testing.expect(startupFailureHint("server exited") == null);
}

test "phases.parseListenPorts: parses unique lsof listen ports" {
    const output =
        \\COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        \\node    12345 me     7u  IPv4 0x123      0t0  TCP *:15432 (LISTEN)
        \\node    12346 me     8u  IPv6 0x456      0t0  TCP [::1]:3000 (LISTEN)
        \\node    12346 me     9u  IPv6 0x456      0t0  TCP [::1]:3000 (LISTEN)
        \\
    ;
    const ports = try parseListenPorts(std.testing.allocator, output);
    defer std.testing.allocator.free(ports);

    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqual(@as(i64, 15432), ports[0]);
    try std.testing.expectEqual(@as(i64, 3000), ports[1]);
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
