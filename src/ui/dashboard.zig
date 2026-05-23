const std = @import("std");
const config = @import("../config.zig");
const docker_client = @import("../infra/docker.zig");
const env = @import("../infra/env.zig");
const proc_runner = @import("../infra/runner.zig");
const tmux_client = @import("../infra/tmux.zig");
const tmux_options = @import("../tmux_options.zig");

pub fn runLauncher(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map, cfg: config.Config, writer: *std.Io.Writer) !void {
    const run: proc_runner.Runner = .{ .gpa = gpa, .io = io };
    const ctx: Context = .{ .gpa = gpa, .cfg = cfg, .runner = run, .tmux = .{ .gpa = gpa, .runner = run, .session = try cfg.sessionName() } };
    try writer.writeAll(clearScreen);
    try renderLauncher(ctx, writer);
    try writer.flush();
    const shell = env.get(environ, "SHELL") orelse "sh";
    _ = try ctx.runner.runInteractive(&.{shell});
}

pub fn runMonitor(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, writer: *std.Io.Writer) !void {
    var previous: []u8 = &.{};
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        const frame_gpa = frame_arena.allocator();
        const run: proc_runner.Runner = .{ .gpa = frame_gpa, .io = io };
        const ctx: Context = .{ .gpa = frame_gpa, .cfg = cfg, .runner = run, .tmux = .{ .gpa = frame_gpa, .runner = run, .session = try cfg.sessionName() } };
        var frame: std.Io.Writer.Allocating = .init(frame_gpa);
        try renderMonitor(ctx, &frame.writer);
        const output = frame.writer.buffered();
        if (!std.mem.eql(u8, previous, output)) {
            try writer.writeAll(clearScreen);
            try writer.writeAll(output);
            try writer.flush();
            if (previous.len > 0) gpa.free(previous);
            previous = try gpa.dupe(u8, output);
        }
        const outer_runner: proc_runner.Runner = .{ .gpa = gpa, .io = io };
        outer_runner.runDiscard(&.{ "sleep", "1" }) catch {};
    }
}

const clearScreen = "\x1b[2J\x1b[H";
const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const red = "\x1b[31m";
const green = "\x1b[32m";
const yellow = "\x1b[33m";
const blue = "\x1b[34m";
const cyan = "\x1b[36m";
const launcher_width = 46;
const service_name_width = 15;
const service_port_width = 6;
const monitor_name_width = 12;
const monitor_port_width = 6;
const monitor_status_width = 8;
const monitor_log_width = 35;
const Context = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
};

const MonitorStatus = enum {
    live,
    ready,
    degraded,
    stop,
    dead,
    unknown,

    fn icon(self: MonitorStatus) []const u8 {
        return switch (self) {
            .live => "●",
            .ready => "◐",
            .degraded => "▲",
            .stop => "○",
            .dead => "✗",
            .unknown => "?",
        };
    }

    fn color(self: MonitorStatus) []const u8 {
        return switch (self) {
            .live => green,
            .ready => cyan,
            .degraded => yellow,
            .stop => dim,
            .dead => red,
            .unknown => dim,
        };
    }

    fn summary(self: MonitorStatus, exit_code: []const u8) []const u8 {
        return switch (self) {
            .live => "live",
            .ready => "ready",
            .degraded => "degraded",
            .stop => "stop",
            .dead => exit_code,
            .unknown => "?",
        };
    }
};

const MonitorRow = struct {
    name: []const u8,
    status: MonitorStatus,
    exit_code: []const u8,
    command: []const u8,
    port: []const u8,
};

fn renderLauncher(ctx: Context, writer: *std.Io.Writer) !void {
    try writer.writeAll("\n");
    const title = try std.fmt.allocPrint(ctx.gpa, "{s} - Development TUI", .{try ctx.cfg.projectName()});
    try writer.print("{s}{s}", .{ bold, cyan });
    try writeRule(writer, "╔", "═", "╗", launcher_width);
    try writer.print("{s}\n", .{reset});
    try writer.print("{s}{s}║", .{ bold, cyan });
    try writeCentered(writer, title, launcher_width);
    try writer.print("║{s}\n", .{reset});
    try writer.print("{s}{s}", .{ bold, cyan });
    try writeRule(writer, "╚", "═", "╝", launcher_width);
    try writer.print("{s}\n\n", .{reset});

    try writer.print("{s}Navigate: {s}{s}Ctrl+q w{s}{s} (list) {s}{s}Ctrl+q '{s}{s} (number) {s}{s}Ctrl+q m{s}{s} (toggle){s}\n\n", .{ dim, reset, bold, reset, dim, reset, bold, reset, dim, reset, bold, reset, dim, reset });

    if (ctx.cfg.dockerEnabled()) {
        try writer.print("{s}{s}[docker]{s}\n", .{ bold, blue, reset });
        try writer.print("  {s}", .{green});
        try writePadded(writer, "docker", service_name_width);
        try writer.print("{s} {s}", .{ reset, dim });
        try writePadded(writer, "compose", 7);
        try writer.print("{s}  docker compose up\n\n", .{reset});
    }

    const groups = try serviceGroups(ctx);
    defer ctx.gpa.free(groups);
    for (groups) |group| {
        try writer.print("{s}{s}[{s}]{s}\n", .{ bold, yellow, group, reset });
        for (try ctx.cfg.services()) |service| {
            if (!std.mem.eql(u8, config.Config.serviceGroup(service), group)) continue;
            const name = try config.Config.serviceName(service);
            const port = config.Config.servicePort(service);
            const command = try config.Config.serviceStartCommand(ctx.gpa, service);
            try writer.print("  {s}", .{green});
            try writePadded(writer, name, service_name_width);
            try writer.print("{s} {s}", .{ reset, dim });
            if (port) |p| {
                const port_text = try std.fmt.allocPrint(ctx.gpa, ":{d}", .{p});
                try writePadded(writer, port_text, service_port_width);
            } else {
                try writePadded(writer, ":N/A", service_port_width);
            }
            try writer.print("{s}  {s}\n", .{ reset, command });
        }
        try writer.writeAll("\n");
    }

    try writer.print("{s}", .{dim});
    try writeRule(writer, "", "─", "", launcher_width + 2);
    try writer.print("{s}\n", .{reset});
    try writer.print("{s}Commands:{s}\n", .{ bold, reset });
    const project = try ctx.cfg.projectName();
    try writeCommandHelp(writer, project);
    try writer.writeByte('\n');
}

const LauncherCommand = struct {
    usage: []const u8,
    description: []const u8,
};

const launcher_commands = [_]LauncherCommand{
    .{ .usage = "hello", .description = "Start all + attach" },
    .{ .usage = "hello --<profile>", .description = "Start configured profile" },
    .{ .usage = "hello --docker", .description = "Start docker only" },
    .{ .usage = "bye", .description = "Graceful shutdown" },
    .{ .usage = "re", .description = "Restart session" },
    .{ .usage = "status", .description = "Show all status" },
    .{ .usage = "up <svc|group>", .description = "Start a service or group" },
    .{ .usage = "stop <svc|group>", .description = "Stop a service or group" },
    .{ .usage = "restart <svc|group>", .description = "Restart a service or group" },
    .{ .usage = "logs <svc>", .description = "Jump to window" },
    .{ .usage = "follow <svc>", .description = "Tail log in nvim" },
};

fn writeCommandHelp(writer: *std.Io.Writer, project: []const u8) !void {
    const usage_width = launcherCommandWidth(project);
    for (launcher_commands) |command| {
        try writer.print("  {s}{s} {s}{s}", .{ green, project, command.usage, reset });
        try writeSpaces(writer, usage_width - project.len - 1 - command.usage.len + 2);
        try writer.print("{s}\n", .{command.description});
    }
}

fn launcherCommandWidth(project: []const u8) usize {
    var width: usize = 0;
    for (launcher_commands) |command| {
        width = @max(width, project.len + 1 + command.usage.len);
    }
    return width;
}

fn renderMonitor(ctx: Context, writer: *std.Io.Writer) !void {
    const mode = try dashboardMode(ctx);
    var live_count: usize = 0;
    var warn_count: usize = 0;
    var dead_count: usize = 0;
    var rows: std.ArrayList(MonitorRow) = .empty;
    defer rows.deinit(ctx.gpa);

    if (ctx.cfg.dockerEnabled()) {
        const row = try dockerMonitorRow(ctx);
        try rows.append(ctx.gpa, row);
        countMonitorRow(row, &live_count, &warn_count, &dead_count);
    }

    for (try ctx.cfg.services()) |service| {
        const row = try serviceMonitorRow(ctx, service);
        try rows.append(ctx.gpa, row);
        countMonitorRow(row, &live_count, &warn_count, &dead_count);
    }

    try writer.print("{s}[zask-monitor]{s} {s}LIVE:{d}{s} {s}WARN:{d}{s} {s}DEAD:{d}{s}  {s}[{s}]{s}  {s}Ctrl+q m: toggle{s}\n\n", .{ bold, reset, green, live_count, reset, yellow, warn_count, reset, red, dead_count, reset, dim, mode, reset, dim, reset });
    for (rows.items) |row| {
        if (std.mem.eql(u8, mode, "bad") and row.status == .live) continue;
        try writeMonitorRow(ctx, writer, row, !std.mem.eql(u8, mode, "all") or row.status != .live);
        try writer.writeAll("\n");
    }
    try writer.print("\n{s}───────────────────────────────────────────────────────────────{s}\n", .{ dim, reset });
    try writer.print("{s}{s} status | {s} logs <service>{s}", .{ dim, try ctx.cfg.projectName(), try ctx.cfg.projectName(), reset });
}

fn serviceGroups(ctx: Context) ![][]const u8 {
    var groups: std.ArrayList([]const u8) = .empty;
    errdefer groups.deinit(ctx.gpa);
    for (try ctx.cfg.services()) |service| {
        const group = config.Config.serviceGroup(service);
        var seen = false;
        for (groups.items) |item| {
            if (std.mem.eql(u8, item, group)) {
                seen = true;
                break;
            }
        }
        if (!seen) try groups.append(ctx.gpa, group);
    }
    return groups.toOwnedSlice(ctx.gpa);
}

fn dashboardMode(ctx: Context) ![]const u8 {
    return try ctx.tmux.showOption(tmux_options.dash_mode) orelse "all";
}

fn serviceMonitorRow(ctx: Context, service: std.json.Value) !MonitorRow {
    const name = try config.Config.serviceName(service);
    const pane = try ctx.tmux.paneInfo(name);
    const state = if (pane.dead)
        MonitorStatus.dead
    else if (tmux_client.isShellCommand(pane.command))
        MonitorStatus.stop
    else
        try healthStatus(ctx, service);
    return .{
        .name = name,
        .status = state,
        .exit_code = pane.exit_code,
        .command = pane.command,
        .port = if (config.Config.servicePort(service)) |p| try std.fmt.allocPrint(ctx.gpa, ":{d}", .{p}) else "  -",
    };
}

fn dockerMonitorRow(ctx: Context) !MonitorRow {
    const pane = try ctx.tmux.paneInfo("docker");
    const state = if (pane.dead)
        MonitorStatus.dead
    else if (tmux_client.isShellCommand(pane.command))
        MonitorStatus.stop
    else if (try dockerRunning(ctx))
        MonitorStatus.live
    else
        MonitorStatus.ready;
    return .{ .name = "docker", .status = state, .exit_code = pane.exit_code, .command = pane.command, .port = "compose" };
}

fn healthStatus(ctx: Context, service: std.json.Value) !MonitorStatus {
    const port = config.Config.servicePort(service) orelse return .live;
    const result = ctx.runner.run(&.{ "nc", "-z", "localhost", try std.fmt.allocPrint(ctx.gpa, "{d}", .{port}) }) catch return .ready;
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return .ready;
    if (!std.mem.eql(u8, config.Config.serviceHealthcheckType(service), "http")) return .live;

    const url = try std.fmt.allocPrint(ctx.gpa, "http://localhost:{d}{s}", .{ port, config.Config.serviceHealthcheckPath(service) });
    const http = ctx.runner.run(&.{ "curl", "-sf", "--max-time", "1", url }) catch return .degraded;
    defer ctx.gpa.free(http.stdout);
    defer ctx.gpa.free(http.stderr);
    return if (http.term == .exited and http.term.exited == 0) .live else .degraded;
}

fn dockerRunning(ctx: Context) !bool {
    return (docker_client.Compose{
        .gpa = ctx.gpa,
        .runner = ctx.runner,
        .dir = try ctx.cfg.dockerDir(ctx.gpa),
        .file = ctx.cfg.dockerComposeFile(),
    }).running();
}

fn writeMonitorRow(ctx: Context, writer: *std.Io.Writer, row: MonitorRow, show_log: bool) !void {
    const color = row.status.color();
    try writer.print("{s}{s}{s} ", .{ color, row.status.icon(), reset });
    try writePadded(writer, truncate(row.name, monitor_name_width), monitor_name_width);
    try writer.print(" {s}", .{dim});
    try writePadded(writer, row.port, monitor_port_width);
    try writer.print("{s} {s}", .{ reset, color });
    try writePadded(writer, row.status.summary(row.exit_code), monitor_status_width);
    try writer.print("{s}", .{reset});
    if (show_log and row.status != .live) {
        const log = try lastLogLine(ctx, row.name);
        if (log.len > 0) try writer.print(" {s}│{s} {s}", .{ dim, reset, truncate(log, monitor_log_width) });
    }
}

fn lastLogLine(ctx: Context, window: []const u8) ![]const u8 {
    const pane = try ctx.tmux.capturePane(window);
    var lines = std.mem.splitScalar(u8, pane, '\n');
    var latest: []const u8 = "";
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n\x00");
        if (trimmed.len > 0) latest = trimmed;
    }
    return latest;
}

fn countMonitorRow(row: MonitorRow, live_count: *usize, warn_count: *usize, dead_count: *usize) void {
    switch (row.status) {
        .live => live_count.* += 1,
        .dead => dead_count.* += 1,
        else => warn_count.* += 1,
    }
}

fn writeCentered(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const text_width = text.len;
    if (text_width >= width) {
        try writer.writeAll(text);
        return;
    }
    const left = (width - text_width) / 2;
    const right = width - text_width - left;
    try writeSpaces(writer, left);
    try writer.writeAll(text);
    try writeSpaces(writer, right);
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writeSpaces(writer, width - text.len);
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
}

fn writeRule(writer: *std.Io.Writer, left: []const u8, fill: []const u8, right: []const u8, width: usize) !void {
    try writer.writeAll(left);
    var i: usize = 0;
    while (i < width) : (i += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
}

fn truncate(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[0..width];
}

test "renders launcher frame with grouped services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": [
        \\    {"name":"api","dir":"backend","command":"serve","group":"backend","port":18080},
        \\    {"name":"web","dir":"frontend","runtime":"npm","command":"run dev","group":"frontend"}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: Context = .{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = .{ .gpa = arena.allocator(), .io = std.Io.null },
        .tmux = .{ .gpa = arena.allocator(), .runner = .{ .gpa = arena.allocator(), .io = std.Io.null }, .session = "demo" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try renderLauncher(ctx, &out.writer);
    const body = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, body, "demo - Development TUI") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[docker]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[backend]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ":18080") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "npm run dev") != null);
}
