const std = @import("std");
const ansi = @import("ansi.zig");
const config = @import("../../model/config.zig");
const observations = @import("../../model/observations.zig");
const proc_runner = @import("../../platform/runner.zig");
const service_observation = @import("../../workflow/service_observation.zig");
const tmux_options = @import("../../model/tmux_options.zig");
const RenderContext = @import("context.zig").RenderContext;

const monitor_name_width = 12;
const monitor_port_width = 8;
const monitor_status_width = 8;
const monitor_log_width = 35;

pub fn run(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, writer: *std.Io.Writer) !void {
    var previous: []u8 = &.{};
    defer if (previous.len > 0) gpa.free(previous);
    while (true) {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        const frame_gpa = frame_arena.allocator();
        const runner: proc_runner.Runner = .{ .gpa = frame_gpa, .io = io };
        const ctx: RenderContext = .{ .gpa = frame_gpa, .cfg = cfg, .runner = runner, .tmux = .{ .gpa = frame_gpa, .runner = runner, .session = try cfg.projectName() } };
        var frame: std.Io.Writer.Allocating = .init(frame_gpa);
        try render(ctx, &frame.writer);
        const output = frame.writer.buffered();
        if (!std.mem.eql(u8, previous, output)) {
            try writer.writeAll(ansi.clear_screen);
            try writer.writeAll(output);
            try writer.flush();
            if (previous.len > 0) gpa.free(previous);
            previous = try gpa.dupe(u8, output);
        }
        std.Io.sleep(io, .fromSeconds(1), .awake) catch {};
    }
}

const MonitorStatus = enum {
    live,
    waiting,
    degraded,
    stop,
    dead,
    unknown,

    fn icon(self: MonitorStatus) []const u8 {
        return switch (self) {
            .live => "●",
            .waiting => "◐",
            .degraded => "▲",
            .stop => "○",
            .dead => "✗",
            .unknown => "?",
        };
    }

    fn color(self: MonitorStatus) []const u8 {
        return switch (self) {
            .live => ansi.green,
            .waiting => ansi.cyan,
            .degraded => ansi.yellow,
            .stop => ansi.dim,
            .dead => ansi.red,
            .unknown => ansi.dim,
        };
    }

    fn summary(self: MonitorStatus, exit_code: []const u8) []const u8 {
        return switch (self) {
            .live => "live",
            .waiting => "waiting",
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

fn render(ctx: RenderContext, writer: *std.Io.Writer) !void {
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

    try writer.print("{s}[zask-monitor]{s} {s}LIVE:{d}{s} {s}WARN:{d}{s} {s}DEAD:{d}{s}  {s}[{s}]{s}  {s}Ctrl+q m: toggle{s}\n\n", .{ ansi.bold, ansi.reset, ansi.green, live_count, ansi.reset, ansi.yellow, warn_count, ansi.reset, ansi.red, dead_count, ansi.reset, ansi.dim, mode, ansi.reset, ansi.dim, ansi.reset });
    for (rows.items) |row| {
        if (std.mem.eql(u8, mode, tmux_options.dash_mode_bad) and row.status == .live) continue;
        try writeMonitorRow(ctx, writer, row, !std.mem.eql(u8, mode, tmux_options.dash_mode_all) or row.status != .live);
        try writer.writeAll("\n");
    }
    try writer.print("\n{s}───────────────────────────────────────────────────────────────{s}\n", .{ ansi.dim, ansi.reset });
    try writer.print("{s}zask status | zask logs <service> | zask {s} <command>{s}", .{ ansi.dim, try ctx.cfg.projectName(), ansi.reset });
}

fn dashboardMode(ctx: RenderContext) ![]const u8 {
    return try ctx.tmux.showOption(tmux_options.dash_mode) orelse tmux_options.dash_mode_all;
}

fn serviceMonitorRow(ctx: RenderContext, service: std.json.Value) !MonitorRow {
    const observation = try observer(ctx).observeService(service);
    return .{
        .name = try config.Config.serviceName(service),
        .status = serviceMonitorStatus(observation),
        .exit_code = observation.pane.exit_code,
        .command = observation.pane.command,
        .port = if (observation.port) |p| try std.fmt.allocPrint(ctx.gpa, ":{d}", .{p}) else "no check",
    };
}

fn dockerMonitorRow(ctx: RenderContext) !MonitorRow {
    const observation = observer(ctx).observeDocker();
    defer observation.compose.deinit(ctx.gpa);
    return .{ .name = "docker", .status = dockerMonitorStatus(observation), .exit_code = observation.pane.exit_code, .command = observation.pane.command, .port = "compose" };
}

fn observer(ctx: RenderContext) service_observation.Observer {
    return .{
        .gpa = ctx.gpa,
        .runner = ctx.runner,
        .tmux = ctx.tmux,
        .docker = .{
            .gpa = ctx.gpa,
            .runner = ctx.runner,
            // The monitor runs from the project root, so the compose dir is the subdir
            // under root; dockerDir would prepend root again and double the path.
            .dir = ctx.cfg.dockerSubdir(),
            .file = ctx.cfg.dockerComposeFile(),
        },
    };
}

fn serviceMonitorStatus(observation: observations.ServiceObservation) MonitorStatus {
    return switch (observation.health()) {
        .not_running => if (observation.pane.state == .dead) .dead else .stop,
        .no_check, .ready => .live,
        .waiting => .waiting,
        .degraded => .degraded,
        .unavailable => .unknown,
    };
}

fn dockerMonitorStatus(observation: observations.DockerObservation) MonitorStatus {
    return switch (observation.pane.state) {
        .dead => .dead,
        .idle, .window_missing => .stop,
        .tmux_unavailable => .unknown,
        .busy => switch (observation.compose.state) {
            .running => .live,
            .empty => .waiting,
            .unavailable => .unknown,
        },
    };
}

fn writeMonitorRow(ctx: RenderContext, writer: *std.Io.Writer, row: MonitorRow, show_log: bool) !void {
    const color = row.status.color();
    try writer.print("{s}{s}{s} ", .{ color, row.status.icon(), ansi.reset });
    try ansi.writePadded(writer, ansi.truncate(row.name, monitor_name_width), monitor_name_width);
    try writer.print(" {s}", .{ansi.dim});
    try ansi.writePadded(writer, row.port, monitor_port_width);
    try writer.print("{s} {s}", .{ ansi.reset, color });
    try ansi.writePadded(writer, row.status.summary(row.exit_code), monitor_status_width);
    try writer.print("{s}", .{ansi.reset});
    if (show_log and row.status != .live) {
        const log = try lastLogLine(ctx, row.name);
        if (log.len > 0) try writer.print(" {s}│{s} {s}", .{ ansi.dim, ansi.reset, ansi.truncate(log, monitor_log_width) });
    }
}

fn lastLogLine(ctx: RenderContext, window: []const u8) ![]const u8 {
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

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn recordedCommandCount(recorder: *const proc_runner.Recorder, name: []const u8) usize {
    var count: usize = 0;
    for (recorder.commands.items) |command| {
        if (command.argv.len > 0 and std.mem.eql(u8, command.argv[0], name)) count += 1;
    }
    return count;
}

test "monitor.render: shows local and named command forms" {
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
    try recorder.enqueue("all\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try render(ctx, &out.writer);
    const body = out.writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, body, "zask status") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zask logs <service>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "zask demo <command>") != null);
}

test "monitor.service: skips health checks unless pane is busy" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","port":3000}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.stop, row.status);
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "nc"));
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "curl"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.service: shows no check for services without port" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.live, row.status);
    try std.testing.expectEqualStrings("no check", row.port);
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "nc"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.service: checks health for busy shell panes" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","port":3000}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.live, row.status);
    try std.testing.expectEqual(@as(usize, 1), recordedCommandCount(&recorder, "nc"));
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "curl"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.service: shows waiting while port is not ready" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","port":3000}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.waiting, row.status);
    try std.testing.expectEqualStrings(":3000", row.port);
    try std.testing.expectEqualStrings("waiting", row.status.summary(row.exit_code));
    try std.testing.expectEqual(@as(usize, 1), recordedCommandCount(&recorder, "nc"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.docker: skips compose observation unless pane is busy" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try dockerMonitorRow(ctx);

    try std.testing.expectEqual(MonitorStatus.stop, row.status);
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "docker"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.docker: checks compose for busy shell panes" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try dockerMonitorRow(ctx);

    try std.testing.expectEqual(MonitorStatus.live, row.status);
    try std.testing.expectEqual(@as(usize, 1), recordedCommandCount(&recorder, "docker"));
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.docker: runs compose from the root-relative subdir, not a doubled path" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"work/demo"},
        \\  "docker": {"compose": "infra/compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try dockerMonitorRow(ctx);

    const compose = proc_runner.findCommandContaining(&recorder, "compose") orelse return error.MissingComposeCommand;
    try proc_runner.expectCommandCwd(compose, "infra");
    try std.testing.expectEqual(MonitorStatus.live, row.status);
}

test "monitor.service: shows unknown when the port probe cannot run" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","port":3000}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0||12345|node|\n", "", .{ .exited = 0 });
    try recorder.enqueueError(error.FileNotFound);
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.unknown, row.status);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.service: shows exit code of an exited service" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","port":3000}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("1|2|12345|node|\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

    try std.testing.expectEqual(MonitorStatus.dead, row.status);
    try std.testing.expectEqualStrings("2", row.status.summary(row.exit_code));
    try std.testing.expectEqual(@as(usize, 0), recordedCommandCount(&recorder, "nc"));
}
