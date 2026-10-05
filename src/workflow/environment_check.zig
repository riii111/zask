const std = @import("std");
const config = @import("../model/config.zig");
const config_check = @import("config_check.zig");
const config_value = @import("../model/config_value.zig");
const configured_path = @import("configured_path.zig");
const docker_client = @import("../platform/docker.zig");
const executable = @import("../platform/executable.zig");
const observations = @import("../model/observations.zig");
const phases = @import("phases.zig");
const process_probe = @import("../platform/process_probe.zig");
const proc_runner = @import("../platform/runner.zig");
const tmux_client = @import("../platform/tmux.zig");

pub const default_probe_timeout = std.Io.Duration.fromSeconds(3);
pub const default_precheck_timeout = std.Io.Duration.fromSeconds(10);

pub const Severity = enum {
    problem,
    warning,
    unverified,
};

pub const Finding = struct {
    severity: Severity,
    subject: []const u8,
    message: []const u8,
    fix: []const u8 = "",
};

pub const PrecheckStatus = enum {
    passed,
    failed,
    timed_out,
    output_too_large,
    not_run,
};

pub const PrecheckResult = struct {
    name: []const u8,
    command: []const u8,
    status: PrecheckStatus,
    severity: Severity,
    detail: []const u8 = "",
    hint: []const u8 = "",
};

pub const Report = struct {
    gpa: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,
    prechecks: std.ArrayList(PrecheckResult) = .empty,
    skipped_prechecks: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Report {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Report) void {
        self.findings.deinit(self.gpa);
        self.prechecks.deinit(self.gpa);
    }

    pub fn count(self: Report, severity: Severity) usize {
        var total: usize = 0;
        for (self.findings.items) |finding| {
            if (finding.severity == severity) total += 1;
        }
        for (self.prechecks.items) |result| {
            if (result.status != .passed and result.severity == severity) total += 1;
        }
        return total;
    }

    fn add(self: *Report, finding: Finding) !void {
        try self.findings.append(self.gpa, finding);
    }
};

pub const Options = struct {
    run_prechecks: bool = false,
    probe_timeout: std.Io.Duration = default_probe_timeout,
    precheck_timeout: std.Io.Duration = default_precheck_timeout,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,
    search_path: ?[]const u8,
};

pub fn collect(ctx: Context, options: Options, report: *Report) !void {
    var bounded = ctx;
    bounded.runner.timeout = options.probe_timeout;
    bounded.tmux.runner = bounded.runner;
    bounded.docker.runner = bounded.runner;

    const project_root = try ctx.cfg.projectRoot(ctx.gpa);
    try checkTmux(bounded, report);
    try checkDocker(bounded, report);
    try checkBash(bounded, report);
    const nc_found = try checkNc(bounded, report);
    try checkServiceCommands(bounded, report);
    if (nc_found) try checkServicePorts(bounded, report);
    if (options.run_prechecks) {
        try runPrechecks(bounded, project_root, options.precheck_timeout, report);
    } else {
        report.skipped_prechecks = ctx.cfg.prechecks().len;
    }
}

fn checkTmux(ctx: Context, report: *Report) !void {
    if (try findTool(ctx, ".", "tmux")) return;
    try report.add(.{
        .severity = .problem,
        .subject = "tmux",
        .message = "not found in PATH; zask runs every service in a tmux session",
        .fix = "install tmux or add it to PATH",
    });
}

fn checkDocker(ctx: Context, report: *Report) !void {
    if (!ctx.cfg.dockerEnabled()) return;
    if (!try findTool(ctx, ".", "docker")) {
        try report.add(.{
            .severity = .problem,
            .subject = "docker",
            .message = "not found in PATH; docker.compose is configured",
            .fix = "install Docker or add it to PATH",
        });
        return;
    }
    switch (try probe(ctx, &.{ "docker", "compose", "version" })) {
        .succeeded => {},
        .failed, .unavailable => {
            try report.add(.{
                .severity = .problem,
                .subject = "docker",
                .message = "'docker compose' is not available",
                .fix = "install the Docker Compose plugin",
            });
            return;
        },
        .timed_out => {
            try report.add(.{ .severity = .unverified, .subject = "docker", .message = "'docker compose version' did not finish in time" });
            return;
        },
    }
    switch (try probe(ctx, &.{ "docker", "info", "--format", "{{.ServerVersion}}" })) {
        .succeeded => {},
        .failed, .unavailable => try report.add(.{
            .severity = .problem,
            .subject = "docker",
            .message = "the Docker daemon is not reachable",
            .fix = "start Docker, then run check again",
        }),
        .timed_out => try report.add(.{ .severity = .unverified, .subject = "docker", .message = "the Docker daemon did not answer in time" }),
    }
}

fn checkBash(ctx: Context, report: *Report) !void {
    var missing_from: ?[]const u8 = null;
    var found_somewhere = false;
    for (try bashRunDirs(ctx)) |dir| {
        if (try configured_path.inspect(ctx.io, dir, .directory) != null) continue;
        if (try findTool(ctx, dir, "bash")) {
            found_somewhere = true;
        } else if (missing_from == null) {
            missing_from = dir;
        }
    }
    const dir = missing_from orelse return;
    try report.add(.{
        .severity = .problem,
        .subject = "bash",
        .message = if (found_somewhere)
            try std.fmt.allocPrint(ctx.gpa, "not found in PATH when run from {s}; prechecks and command steps run with bash", .{dir})
        else
            "not found in PATH; prechecks and command steps run with bash",
        .fix = "install bash or add it to PATH",
    });
}

fn bashRunDirs(ctx: Context) ![]const []const u8 {
    const project_root = try ctx.cfg.projectRoot(ctx.gpa);
    var dirs: std.ArrayList([]const u8) = .empty;
    for (ctx.cfg.prechecks()) |check| try appendRunDir(ctx.gpa, &dirs, project_root, config_value.optionalObjectString(check, "dir", ""));
    for (ctx.cfg.phases()) |phase| {
        if (phase != .object or phases.phaseKind(phase) != .command) continue;
        try appendRunDir(ctx.gpa, &dirs, project_root, config_value.optionalObjectString(phase, "dir", ""));
    }
    return dirs.items;
}

fn appendRunDir(gpa: std.mem.Allocator, dirs: *std.ArrayList([]const u8), project_root: []const u8, dir: []const u8) !void {
    const path = if (dir.len == 0) project_root else try std.fs.path.join(gpa, &.{ project_root, dir });
    for (dirs.items) |existing| {
        if (std.mem.eql(u8, existing, path)) return;
    }
    try dirs.append(gpa, path);
}

fn checkNc(ctx: Context, report: *Report) !bool {
    const needed_by_wait_ports = hasWaitPorts(ctx.cfg);
    if (!needed_by_wait_ports and !try hasServicePort(ctx.cfg)) return true;
    if (try findTool(ctx, ".", "nc")) return true;
    if (needed_by_wait_ports) {
        try report.add(.{
            .severity = .problem,
            .subject = "nc",
            .message = "not found in PATH; startup_order wait_ports use nc",
            .fix = "install netcat or add it to PATH",
        });
    } else {
        try report.add(.{ .severity = .unverified, .subject = "nc", .message = "not found in PATH; service ports were not checked" });
    }
    return false;
}

fn checkServiceCommands(ctx: Context, report: *Report) !void {
    for (try ctx.cfg.services()) |service| {
        const dir = try ctx.cfg.serviceDir(ctx.gpa, service);
        if (try configured_path.inspect(ctx.io, dir, .directory) != null) continue;
        const subject = try std.fmt.allocPrint(ctx.gpa, "{s}.command", .{try config_check.serviceLabel(ctx.gpa, service)});
        const command = try config.Config.serviceStartCommand(ctx.gpa, service);
        switch (classifyCommand(command)) {
            .program => |name| {
                const has_slash = std.mem.indexOfScalar(u8, name, '/') != null;
                if (!has_slash and try envFilesSetPath(ctx, service)) {
                    try report.add(.{ .severity = .unverified, .subject = subject, .message = "env_file sets PATH; command not checked" });
                    continue;
                }
                if (try executable.find(ctx.gpa, ctx.io, .shell, ctx.search_path, dir, name) != null) continue;
                try report.add(try missingProgramFinding(ctx, subject, name, has_slash));
            },
            .compound => try report.add(.{ .severity = .unverified, .subject = subject, .message = "compound shell command; not checked" }),
            .shell_syntax => try report.add(.{ .severity = .unverified, .subject = subject, .message = "command name uses shell syntax; not checked" }),
        }
    }
}

fn missingProgramFinding(ctx: Context, subject: []const u8, name: []const u8, has_slash: bool) !Finding {
    if (!has_slash and isShellBuiltin(name)) return .{
        .severity = .unverified,
        .subject = subject,
        .message = try std.fmt.allocPrint(ctx.gpa, "starts with shell builtin '{s}'; not checked", .{name}),
    };
    return .{
        .severity = .problem,
        .subject = subject,
        .message = try std.fmt.allocPrint(ctx.gpa, "'{s}' not found {s}", .{ name, if (has_slash) "as an executable file" else "in PATH" }),
        .fix = "install it, add it to PATH, or fix the command",
    };
}

fn envFilesSetPath(ctx: Context, service: std.json.Value) !bool {
    for (try config.Config.serviceEnvFiles(ctx.gpa, service)) |env_file| {
        const path = try ctx.cfg.serviceEnvFilePath(ctx.gpa, service, env_file);
        if (try configured_path.inspect(ctx.io, path, .file) != null) continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            var line = std.mem.trimEnd(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "export ")) line = line["export ".len..];
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line[0..eq], "PATH")) return true;
        }
    }
    return false;
}

fn checkServicePorts(ctx: Context, report: *Report) !void {
    var session: ?observations.SessionObservation = null;
    for (try ctx.cfg.services()) |service| {
        const port = config.Config.servicePort(service) orelse continue;
        const use = try observePortUse(ctx, port);
        const owner: PortOwner = if (use == .in_use) blk: {
            if (session == null) session = ctx.tmux.observeSession();
            break :blk try observePortOwner(ctx, session.?, try config.Config.serviceName(service), port);
        } else .other;
        const decision = portDecision(use, owner);
        if (decision == .ok) continue;
        const subject = try std.fmt.allocPrint(ctx.gpa, "{s}.port", .{try config_check.serviceLabel(ctx.gpa, service)});
        try report.add(switch (decision) {
            .ok => unreachable,
            .conflict => .{
                .severity = .problem,
                .subject = subject,
                .message = try std.fmt.allocPrint(ctx.gpa, "localhost:{d} is already in use by another process", .{port}),
                .fix = "stop that process or change the port",
            },
            .owner_unknown => .{
                .severity = .unverified,
                .subject = subject,
                .message = try std.fmt.allocPrint(ctx.gpa, "localhost:{d} is in use; could not tell whether this service holds it", .{port}),
            },
            .not_checked => .{
                .severity = .unverified,
                .subject = subject,
                .message = try std.fmt.allocPrint(ctx.gpa, "localhost:{d} could not be checked in time", .{port}),
            },
        });
    }
}

fn runPrechecks(ctx: Context, project_root: []const u8, timeout: std.Io.Duration, report: *Report) !void {
    for (ctx.cfg.prechecks()) |check| {
        const command = try config_value.requiredObjectString(check, "command");
        const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
        var result: PrecheckResult = .{
            .name = config_value.optionalObjectString(check, "name", "precheck"),
            .command = command,
            .status = .passed,
            .severity = if (std.mem.eql(u8, on_fail, "abort")) .problem else .warning,
            .hint = config_value.optionalObjectString(check, "hint", ""),
        };
        const dir = config_value.optionalObjectString(check, "dir", "");
        const cwd = if (dir.len == 0) project_root else try std.fs.path.join(ctx.gpa, &.{ project_root, dir });
        if (try configured_path.inspect(ctx.io, cwd, .directory) != null) {
            result.status = .not_run;
            result.detail = "directory not found";
        } else {
            try runPrecheck(ctx, command, cwd, timeout, &result);
        }
        try report.prechecks.append(ctx.gpa, result);
    }
}

fn runPrecheck(ctx: Context, command: []const u8, cwd: []const u8, timeout: std.Io.Duration, result: *PrecheckResult) !void {
    const output = proc_runner.captured(ctx.runner.run(&.{ "bash", "-c", command }, .{ .cwd = cwd, .timeout = timeout }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Timeout => {
            result.status = .timed_out;
            result.detail = try std.fmt.allocPrint(ctx.gpa, "no result within {d}s", .{timeout.toSeconds()});
            return;
        },
        error.OutputTooLarge => {
            result.status = .output_too_large;
            result.detail = "output exceeded the capture limit";
            return;
        },
        else => {
            result.status = .not_run;
            result.detail = try std.fmt.allocPrint(ctx.gpa, "could not start bash: {s}", .{@errorName(err)});
            return;
        },
    });
    defer ctx.runner.gpa.free(output.stdout);
    defer ctx.runner.gpa.free(output.stderr);
    if (output.term == .exited and output.term.exited == 0) return;
    result.status = .failed;
    const last_line = lastNonEmptyLine(output.stderr) orelse lastNonEmptyLine(output.stdout);
    result.detail = switch (output.term) {
        .exited => |code| if (last_line) |line|
            try std.fmt.allocPrint(ctx.gpa, "exit code {d}: {f}", .{ code, displayText(line) })
        else
            try std.fmt.allocPrint(ctx.gpa, "exit code {d}", .{code}),
        else => "terminated without an exit code",
    };
}

// -----------------------------------------------------------------------------
// Observation and decision
// -----------------------------------------------------------------------------

const ProbeOutcome = enum { succeeded, failed, timed_out, unavailable };

fn probe(ctx: Context, argv: []const []const u8) !ProbeOutcome {
    const output = proc_runner.captured(ctx.runner.run(argv, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Timeout => return .timed_out,
        else => return .unavailable,
    });
    defer ctx.runner.gpa.free(output.stdout);
    defer ctx.runner.gpa.free(output.stderr);
    if (output.term == .exited and output.term.exited == 0) return .succeeded;
    return .failed;
}

const PortUse = enum { free, in_use, unknown };

fn observePortUse(ctx: Context, port: i64) !PortUse {
    const port_text = try std.fmt.allocPrint(ctx.gpa, "{d}", .{port});
    return switch (try probe(ctx, &.{ "nc", "-z", "localhost", port_text })) {
        .succeeded => .in_use,
        .failed => .free,
        .timed_out, .unavailable => .unknown,
    };
}

const PortOwner = enum { own_service, other, unknown };

fn observePortOwner(ctx: Context, session: observations.SessionObservation, service: []const u8, port: i64) !PortOwner {
    switch (session) {
        .active => {},
        .missing => return .other,
        .unavailable => return .unknown,
    }
    const info = ctx.tmux.paneInfo(service) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.WindowMissing => return .other,
        else => return .unknown,
    };
    defer info.deinit(ctx.gpa);
    if (info.dead) return .other;
    const listening = try process_probe.observeDescendantListenPorts(ctx.gpa, ctx.runner, std.mem.trim(u8, info.pid, " \t\r\n"));
    defer listening.deinit(ctx.gpa);
    return switch (listening.state) {
        .ports => if (listening.contains(port)) .own_service else .other,
        .none => .other,
        .unavailable => .unknown,
    };
}

const PortDecision = enum { ok, conflict, owner_unknown, not_checked };

fn portDecision(use: PortUse, owner: PortOwner) PortDecision {
    return switch (use) {
        .free => .ok,
        .unknown => .not_checked,
        .in_use => switch (owner) {
            .own_service => .ok,
            .other => .conflict,
            .unknown => .owner_unknown,
        },
    };
}

const CommandShape = union(enum) {
    program: []const u8,
    compound,
    shell_syntax,
};

const shell_builtins = [_][]const u8{
    ".",        ":",         "[",        "[[",        "alias",  "autoload", "bg",      "bind",     "bindkey",
    "break",    "builtin",   "caller",   "case",      "cd",     "command",  "compgen", "complete", "compopt",
    "continue", "coproc",    "declare",  "dirs",      "disown", "do",       "echo",    "emulate",  "enable",
    "eval",     "exec",      "exit",     "export",    "false",  "fc",       "fg",      "for",      "function",
    "getopts",  "hash",      "help",     "history",   "if",     "jobs",     "kill",    "let",      "local",
    "logout",   "mapfile",   "noglob",   "nocorrect", "popd",   "print",    "printf",  "pushd",    "pwd",
    "read",     "readarray", "readonly", "repeat",    "return", "select",   "set",     "setopt",   "shift",
    "shopt",    "source",    "suspend",  "test",      "time",   "times",    "trap",    "true",     "type",
    "typeset",  "ulimit",    "umask",    "unalias",   "unset",  "unsetopt", "until",   "wait",     "whence",
    "where",    "which",     "while",    "zmodload",
};

fn isShellBuiltin(name: []const u8) bool {
    for (shell_builtins) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

fn classifyCommand(command: []const u8) CommandShape {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.indexOfAny(u8, trimmed, ";&|\n`()") != null) return .compound;
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const name = trimmed[0..end];
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "$'\"\\*?[]{}~=!#<>") != null) return .shell_syntax;
    return .{ .program = name };
}

fn findTool(ctx: Context, cwd: []const u8, name: []const u8) !bool {
    return try executable.find(ctx.gpa, ctx.io, .spawn, ctx.search_path, cwd, name) != null;
}

fn hasWaitPorts(cfg: config.Config) bool {
    for (cfg.phases()) |phase| {
        const ports = config_value.optionalObjectArray(phase, "wait_ports") orelse continue;
        if (ports.len > 0) return true;
    }
    return false;
}

fn hasServicePort(cfg: config.Config) !bool {
    for (try cfg.services()) |service| {
        if (config.Config.servicePort(service) != null) return true;
    }
    return false;
}

fn displayText(text: []const u8) DisplayText {
    return .{ .text = text };
}

const DisplayText = struct {
    text: []const u8,

    pub fn format(self: DisplayText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.text) |byte| {
            try writer.writeByte(if ((byte < 0x20 and byte != '\t') or byte == 0x7f) '?' else byte);
        }
    }
};

fn lastNonEmptyLine(output: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestProject = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    bin: []const u8,

    fn init(gpa: std.mem.Allocator, io: std.Io, tools: []const []const u8) !TestProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "bin");
        for (tools) |tool| {
            try tmp.dir.writeFile(io, .{
                .sub_path = try std.fs.path.join(gpa, &.{ "bin", tool }),
                .data = "#!/bin/sh\n",
                .flags = .{ .permissions = .executable_file },
            });
        }
        return .{
            .tmp = tmp,
            .root = try tmp.dir.realPathFileAlloc(io, ".", gpa),
            .bin = try tmp.dir.realPathFileAlloc(io, "bin", gpa),
        };
    }

    fn deinit(self: *TestProject) void {
        self.tmp.cleanup();
    }

    fn context(self: TestProject, gpa: std.mem.Allocator, io: std.Io, recorder: *proc_runner.Recorder, comptime body: []const u8) !Context {
        const json = try std.fmt.allocPrint(gpa, "{{\"project\":{{\"name\":\"demo\",\"root\":\"{s}\"}},{s}}}", .{ self.root, body });
        const cfg = try config.Config.parse(gpa, json, "/home/me");
        const run: proc_runner.Runner = .{ .gpa = gpa, .io = io, .recorder = recorder };
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .runner = run,
            .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
            .docker = .{ .gpa = gpa, .runner = run, .dir = self.root, .file = "compose.yml" },
            .search_path = self.bin,
        };
    }
};

fn testExpectFindings(expected: []const Finding, actual: []const Finding) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.severity, got.severity);
        try std.testing.expectEqualStrings(want.subject, got.subject);
        try std.testing.expectEqualStrings(want.message, got.message);
    }
}

fn testExpectNoWorkspaceChanges(recorder: *const proc_runner.Recorder) !void {
    const forbidden = [_][]const u8{ "new-session", "new-window", "respawn-pane", "send-keys", "kill-session", "kill-server", "up", "down", "stop", "start" };
    for (recorder.commands.items) |command| {
        for (command.argv[1..]) |arg| {
            for (forbidden) |word| try std.testing.expect(!std.mem.eql(u8, arg, word));
        }
    }
}

test "environment_check.collect: reports missing tools without starting anything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{"serve"});
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    const ctx = try project.context(gpa, io, &recorder,
        \\"docker":{"compose":"compose.yml"},
        \\"prechecks":[{"command":"true"}],
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}],
        \\"startup_order":[{"docker":true},{"group":"be","wait_ports":[5432]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "tmux", .message = "not found in PATH; zask runs every service in a tmux session" },
        .{ .severity = .problem, .subject = "docker", .message = "not found in PATH; docker.compose is configured" },
        .{ .severity = .problem, .subject = "bash", .message = "not found in PATH; prechecks and command steps run with bash" },
        .{ .severity = .problem, .subject = "nc", .message = "not found in PATH; startup_order wait_ports use nc" },
    }, report.findings.items);
    try std.testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), report.skipped_prechecks);
}

test "environment_check.collect: reports an unreachable Docker daemon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "docker", "serve" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueue("Docker Compose version v2\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "Cannot connect to the Docker daemon\n", .{ .exited = 1 });
    const ctx = try project.context(gpa, io, &recorder,
        \\"docker":{"compose":"compose.yml"},
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "docker", .message = "the Docker daemon is not reachable" },
    }, report.findings.items);
    try proc_runner.expectCommandArgv(recorder.commands.items[0], &.{ "docker", "compose", "version" });
    try proc_runner.expectCommandArgvStartsWith(recorder.commands.items[1], &.{ "docker", "info" });
    for (recorder.commands.items) |command| try std.testing.expectEqual(@as(?std.Io.Duration, default_probe_timeout), command.timeout);
    try testExpectNoWorkspaceChanges(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "environment_check.collect: reports a Docker probe timeout as unverified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "docker", "serve" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueueError(error.Timeout);
    const ctx = try project.context(gpa, io, &recorder,
        \\"docker":{"compose":"compose.yml"},
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .unverified, .subject = "docker", .message = "the Docker daemon did not answer in time" },
    }, report.findings.items);
    try std.testing.expectEqual(@as(usize, 0), report.count(.problem));
}

test "environment_check.collect: checks service commands without running them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "npm" });
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, "web/bin");
    try project.tmp.dir.writeFile(io, .{ .sub_path = "web/bin/dev", .data = "", .flags = .{ .permissions = .executable_file } });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "web/.env", .data = "# venv\nexport PATH=/opt/venv/bin\n" });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "web/.env.app", .data = "PATHS=x\n" });
    var recorder = proc_runner.Recorder.init(gpa);
    const ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[
        \\  {"name":"api","command":"serve --port 3000"},
        \\  {"name":"web","dir":"web","runtime":"npm","command":"run dev"},
        \\  {"name":"local","dir":"web","command":"./bin/dev"},
        \\  {"name":"tool","dir":"web","command":"./bin/missing"},
        \\  {"name":"chain","command":"make build && ./server"},
        \\  {"name":"envvar","command":"PORT=3000 serve"},
        \\  {"name":"exec","command":"exec serve"},
        \\  {"name":"reader","command":"read -r line"},
        \\  {"name":"venv","dir":"web","env_file":".env","command":"uvicorn app"},
        \\  {"name":"venv_npm","dir":"web","env_file":".env","command":"npm start"},
        \\  {"name":"app","dir":"web","env_file":".env.app","command":"uvicorn app"},
        \\  {"name":"gone","dir":"absent","command":"missing-in-absent-dir"}
        \\]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "groups[be].services[api].command", .message = "'serve' not found in PATH" },
        .{ .severity = .problem, .subject = "groups[be].services[tool].command", .message = "'./bin/missing' not found as an executable file" },
        .{ .severity = .unverified, .subject = "groups[be].services[chain].command", .message = "compound shell command; not checked" },
        .{ .severity = .unverified, .subject = "groups[be].services[envvar].command", .message = "command name uses shell syntax; not checked" },
        .{ .severity = .unverified, .subject = "groups[be].services[exec].command", .message = "starts with shell builtin 'exec'; not checked" },
        .{ .severity = .unverified, .subject = "groups[be].services[reader].command", .message = "starts with shell builtin 'read'; not checked" },
        .{ .severity = .unverified, .subject = "groups[be].services[venv].command", .message = "env_file sets PATH; command not checked" },
        .{ .severity = .unverified, .subject = "groups[be].services[venv_npm].command", .message = "env_file sets PATH; command not checked" },
        .{ .severity = .problem, .subject = "groups[be].services[app].command", .message = "'uvicorn' not found in PATH" },
    }, report.findings.items);
    try std.testing.expectEqual(@as(usize, 0), recorder.commands.items.len);
}

test "environment_check.collect: reports a port held by another process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "nc", "serve" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "can't find session: demo\n", .{ .exited = 1 });
    const ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[
        \\  {"name":"free","command":"serve","port":3000},
        \\  {"name":"api","command":"serve","port":5432}
        \\]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "groups[be].services[api].port", .message = "localhost:5432 is already in use by another process" },
    }, report.findings.items);
    try proc_runner.expectCommandArgv(recorder.commands.items[0], &.{ "nc", "-z", "localhost", "3000" });
    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "nc", "-z", "localhost", "5432" });
    try testExpectNoWorkspaceChanges(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "environment_check.collect: accepts a port held by the running service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "nc", "serve" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||100|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue(
        \\COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        \\node    100 me  7u IPv4 0x123      0t0  TCP *:5432 (LISTEN)
        \\
    , "", .{ .exited = 0 });
    const ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve","port":5432}]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
    try testExpectNoWorkspaceChanges(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "environment_check.collect: reports a port probe timeout as unverified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "nc", "serve" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueueError(error.Timeout);
    const ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve","port":5432}]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .unverified, .subject = "groups[be].services[api].port", .message = "localhost:5432 could not be checked in time" },
    }, report.findings.items);
}

test "environment_check.collect: runs prechecks only when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "bash" });
    defer project.deinit();
    var recorder = proc_runner.Recorder.init(gpa);
    try recorder.enqueue("v20\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "no response\x1b[2J\n", .{ .exited = 2 });
    try recorder.enqueueError(error.Timeout);
    const ctx = try project.context(gpa, io, &recorder,
        \\"prechecks":[
        \\  {"name":"node","command":"node -v"},
        \\  {"name":"db","command":"pg_isready","on_fail":"abort","hint":"start db"},
        \\  {"name":"slow","command":"sleep 60"},
        \\  {"name":"lint","command":"lint","dir":"tools"}
        \\],
        \\"groups":[]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{ .run_prechecks = true, .precheck_timeout = .fromSeconds(7) }, &report);

    const results = report.prechecks.items;
    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqual(PrecheckStatus.passed, results[0].status);
    try std.testing.expectEqual(PrecheckStatus.failed, results[1].status);
    try std.testing.expectEqual(Severity.problem, results[1].severity);
    try std.testing.expectEqualStrings("exit code 2: no response?[2J", results[1].detail);
    try std.testing.expectEqual(PrecheckStatus.timed_out, results[2].status);
    try std.testing.expectEqual(Severity.warning, results[2].severity);
    try std.testing.expectEqualStrings("no result within 7s", results[2].detail);
    try std.testing.expectEqual(PrecheckStatus.not_run, results[3].status);
    try std.testing.expectEqual(@as(usize, 1), report.count(.problem));
    try std.testing.expectEqual(@as(usize, 2), report.count(.warning));
    try std.testing.expectEqual(@as(usize, 3), recorder.commands.items.len);
    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "bash", "-c", "pg_isready" });
    try proc_runner.expectCommandCwd(recorder.commands.items[1], project.root);
    try std.testing.expectEqual(@as(?std.Io.Duration, .fromSeconds(7)), recorder.commands.items[1].timeout);
}

test "environment_check.portDecision: maps port observations" {
    const cases = [_]struct { use: PortUse, owner: PortOwner, expected: PortDecision }{
        .{ .use = .free, .owner = .other, .expected = .ok },
        .{ .use = .unknown, .owner = .other, .expected = .not_checked },
        .{ .use = .in_use, .owner = .own_service, .expected = .ok },
        .{ .use = .in_use, .owner = .other, .expected = .conflict },
        .{ .use = .in_use, .owner = .unknown, .expected = .owner_unknown },
    };

    for (cases) |case| try std.testing.expectEqual(case.expected, portDecision(case.use, case.owner));
}

test "environment_check.classifyCommand: separates plain programs from shell syntax" {
    const cases = [_]struct { command: []const u8, expected: CommandShape }{
        .{ .command = "serve --port 3000", .expected = .{ .program = "serve" } },
        .{ .command = "  ./bin/dev", .expected = .{ .program = "./bin/dev" } },
        .{ .command = "npm run dev -- --host=0.0.0.0", .expected = .{ .program = "npm" } },
        .{ .command = "make && ./server", .expected = .compound },
        .{ .command = "serve | tee log", .expected = .compound },
        .{ .command = "echo $(date)", .expected = .compound },
        .{ .command = "PORT=3000 serve", .expected = .shell_syntax },
        .{ .command = "$HOME/bin/serve", .expected = .shell_syntax },
        .{ .command = "'my tool' run", .expected = .shell_syntax },
        .{ .command = "cd api", .expected = .{ .program = "cd" } },
    };

    for (cases) |case| try std.testing.expectEqualDeep(case.expected, classifyCommand(case.command));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "environment_check.collect: skips a FIFO env file without reading it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{"tmux"});
    defer project.deinit();
    const fifo = try std.fmt.allocPrintSentinel(gpa, "{s}/.env", .{project.root}, 0);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o644));
    var recorder = proc_runner.Recorder.init(gpa);
    const ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[{"name":"api","env_file":".env","command":"serve"}]}]
    );
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "groups[be].services[api].command", .message = "'serve' not found in PATH" },
    }, report.findings.items);
}

test "environment_check.collect: resolves relative PATH tools from the working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{ "tmux", "serve" });
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, "project");
    const previous = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    try std.process.setCurrentPath(io, project.root);
    defer std.process.setCurrentPath(io, previous) catch unreachable;
    var recorder = proc_runner.Recorder.init(gpa);
    var ctx = try project.context(gpa, io, &recorder,
        \\"groups":[{"name":"be","services":[{"name":"api","command":"/bin/sh"}]}]
    );
    ctx.cfg = try config.Config.parse(gpa, try std.fmt.allocPrint(gpa,
        \\{{"project":{{"name":"demo","root":"{s}/project"}},"groups":[{{"name":"be","services":[{{"name":"api","command":"/bin/sh"}}]}}]}}
    , .{project.root}), "/home/me");
    ctx.search_path = "bin";
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try std.testing.expectEqual(@as(usize, 0), report.findings.items.len);
}

test "environment_check.collect: looks up bash from each run directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{"bash"});
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, "tools");
    try project.tmp.dir.createDirPath(io, "sys");
    try project.tmp.dir.writeFile(io, .{ .sub_path = "sys/tmux", .data = "", .flags = .{ .permissions = .executable_file } });
    var recorder = proc_runner.Recorder.init(gpa);
    var ctx = try project.context(gpa, io, &recorder,
        \\"prechecks":[{"command":"true"},{"command":"lint","dir":"tools"}],
        \\"groups":[]
    );
    ctx.search_path = try std.fmt.allocPrint(gpa, ":bin:{s}/sys", .{project.root});
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "bash", .message = try std.fmt.allocPrint(gpa, "not found in PATH when run from {s}/tools; prechecks and command steps run with bash", .{project.root}) },
    }, report.findings.items);
}

test "environment_check.collect: skips empty PATH entries for spawned tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io, &.{"tmux"});
    defer project.deinit();
    try project.tmp.dir.writeFile(io, .{ .sub_path = "bash", .data = "", .flags = .{ .permissions = .executable_file } });
    var recorder = proc_runner.Recorder.init(gpa);
    var ctx = try project.context(gpa, io, &recorder,
        \\"prechecks":[{"command":"true"}],
        \\"groups":[]
    );
    ctx.search_path = try std.fmt.allocPrint(gpa, ":{s}", .{project.bin});
    var report = Report.init(gpa);

    try collect(ctx, .{}, &report);

    try testExpectFindings(&.{
        .{ .severity = .problem, .subject = "bash", .message = "not found in PATH; prechecks and command steps run with bash" },
    }, report.findings.items);
}
