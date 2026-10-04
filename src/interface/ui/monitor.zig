const std = @import("std");
const ansi = @import("ansi.zig");
const config = @import("../../model/config.zig");
const keys = @import("keys.zig");
const observations = @import("../../model/observations.zig");
const proc_runner = @import("../../platform/runner.zig");
const selection_state = @import("selection.zig");
const service_observation = @import("../../workflow/service_observation.zig");
const terminal = @import("../../platform/terminal.zig");
const tmux_options = @import("../../model/tmux_options.zig");
const tmux_setup = @import("../../workflow/tmux_setup.zig");
const RenderContext = @import("context.zig").RenderContext;
const Selection = selection_state.Selection;

const monitor_name_width = 12;
const monitor_port_width = 8;
const monitor_status_width = 8;
const monitor_log_width = 35;
const refresh_interval_ms = 1000;
// How long a lone ESC waits for the rest of an arrow-key sequence. Only a
// bare ESC is delayed by this, and the monitor binds no action to it.
const escape_timeout_ms = 250;
const key_guide = "j/k ↑↓ select  f filter  q quit";

/// Runs until `q` / Ctrl+C or the terminal closes. Leaving restores the
/// terminal mode and screen; services are only observed, never stopped.
pub fn run(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, writer: *std.Io.Writer) !void {
    const raw_mode = try terminal.RawMode.enter(terminal.stdin);
    defer if (raw_mode) |mode| mode.restore();
    try writer.writeAll(ansi.enter_screen);
    defer {
        writer.writeAll(ansi.leave_screen) catch {};
        writer.flush() catch {};
    }

    var monitor: Monitor = .{ .gpa = gpa, .io = io, .cfg = cfg, .snapshot_arena = .init(gpa) };
    defer monitor.deinit();
    try monitor.loop(writer, raw_mode != null);
}

const Control = enum { keep, quit };

const Action = union(enum) {
    none,
    quit,
    select: selection_state.Direction,
    toggle_filter,
};

fn actionForKey(key: keys.Key) Action {
    return switch (key) {
        .up => .{ .select = .up },
        .down => .{ .select = .down },
        .ctrl_c => .quit,
        .char => |char| switch (char) {
            'k' => .{ .select = .up },
            'j' => .{ .select = .down },
            'f' => .toggle_filter,
            'q' => .quit,
            else => .none,
        },
        .left, .right, .enter, .escape, .unknown => .none,
    };
}

const Monitor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    /// Owns `snapshot`; reset on every refresh.
    snapshot_arena: std.heap.ArenaAllocator,
    snapshot: Snapshot = .{},
    selection: Selection = .{},
    notice: ?[]const u8 = null,
    previous: []u8 = &.{},
    input: keys.Decoder = .{},

    fn deinit(self: *Monitor) void {
        self.selection.deinit(self.gpa);
        self.gpa.free(self.previous);
        self.snapshot_arena.deinit();
    }

    // Keys redraw from the last snapshot without re-observing, so selection
    // stays responsive while health checks run once per refresh interval.
    fn loop(self: *Monitor, writer: *std.Io.Writer, interactive: bool) !void {
        try self.refresh();
        var refreshed_at = std.Io.Clock.awake.now(self.io);
        while (true) {
            try self.draw(writer);
            const elapsed = refreshed_at.untilNow(self.io, .awake).toMilliseconds();
            const remaining: i32 = @intCast(std.math.clamp(refresh_interval_ms - elapsed, 0, refresh_interval_ms));
            if (interactive) {
                const timeout = if (self.input.pending()) @min(remaining, escape_timeout_ms) else remaining;
                switch (try terminal.waitReadable(terminal.stdin, timeout)) {
                    .input => if (try self.readKeys() == .quit) return,
                    .closed => return,
                    .timeout => if (self.input.flush()) |key| {
                        if (try self.handleKey(key) == .quit) return;
                    },
                }
            } else {
                std.Io.sleep(self.io, .fromMilliseconds(remaining), .awake) catch {};
            }
            if (refreshed_at.untilNow(self.io, .awake).toMilliseconds() >= refresh_interval_ms) {
                try self.refresh();
                refreshed_at = std.Io.Clock.awake.now(self.io);
            }
        }
    }

    fn readKeys(self: *Monitor) !Control {
        const len = try terminal.read(terminal.stdin, self.input.space());
        if (len == 0) return .quit;
        self.input.commit(len);
        while (self.input.next()) |key| {
            if (try self.handleKey(key) == .quit) return .quit;
        }
        return .keep;
    }

    fn handleKey(self: *Monitor, key: keys.Key) !Control {
        switch (actionForKey(key)) {
            .none => {},
            .quit => return .quit,
            .select => |direction| {
                const names = try visibleNames(self.gpa, self.snapshot);
                defer self.gpa.free(names);
                try self.selection.move(self.gpa, names, direction);
                self.notice = null;
            },
            .toggle_filter => self.toggleFilter(),
        }
        return .keep;
    }

    fn toggleFilter(self: *Monitor) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const ctx = renderContext(scratch.allocator(), self.io, self.cfg) catch {
            self.notice = "filter toggle failed";
            return;
        };
        self.snapshot.mode = tmux_setup.toggleDashMode(ctx.tmux) catch {
            self.notice = "filter toggle failed: tmux unavailable";
            return;
        };
        self.notice = null;
    }

    fn refresh(self: *Monitor) !void {
        _ = self.snapshot_arena.reset(.retain_capacity);
        self.snapshot = try observeSnapshot(try renderContext(self.snapshot_arena.allocator(), self.io, self.cfg));
    }

    fn draw(self: *Monitor, writer: *std.Io.Writer) !void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const frame_gpa = scratch.allocator();
        try self.selection.track(self.gpa, try visibleNames(frame_gpa, self.snapshot));

        var frame: std.Io.Writer.Allocating = .init(frame_gpa);
        try render(frame_gpa, &frame.writer, self.cfg, self.snapshot, .{
            .selected = self.selection.name,
            .size = terminal.size(terminal.stdout),
            .notice = self.notice,
        });
        const output = frame.writer.buffered();
        if (std.mem.eql(u8, self.previous, output)) return;
        try writer.writeAll(ansi.clear_screen);
        try writer.writeAll(output);
        try writer.flush();
        const copy = try self.gpa.dupe(u8, output);
        self.gpa.free(self.previous);
        self.previous = copy;
    }
};

fn renderContext(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !RenderContext {
    const runner: proc_runner.Runner = .{ .gpa = gpa, .io = io };
    return .{ .gpa = gpa, .cfg = cfg, .runner = runner, .tmux = .{ .gpa = gpa, .runner = runner, .session = try cfg.projectName() } };
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
    /// Last non-empty pane line; only captured for rows that are not live.
    log: []const u8 = "",
};

const Snapshot = struct {
    rows: []const MonitorRow = &.{},
    mode: tmux_options.DashMode = .all,
};

const View = struct {
    selected: ?[]const u8 = null,
    size: ?terminal.Size = null,
    notice: ?[]const u8 = null,
};

fn observeSnapshot(ctx: RenderContext) !Snapshot {
    const mode = tmux_options.DashMode.parse(try ctx.tmux.showOption(tmux_options.dash_mode));
    var rows: std.ArrayList(MonitorRow) = .empty;
    errdefer rows.deinit(ctx.gpa);

    if (ctx.cfg.dockerEnabled()) try rows.append(ctx.gpa, try dockerMonitorRow(ctx));
    for (try ctx.cfg.services()) |service| try rows.append(ctx.gpa, try serviceMonitorRow(ctx, service));
    for (rows.items) |*row| {
        if (row.status != .live) row.log = try lastLogLine(ctx, row.name);
    }
    return .{ .rows = try rows.toOwnedSlice(ctx.gpa), .mode = mode };
}

fn isVisible(row: MonitorRow, mode: tmux_options.DashMode) bool {
    return switch (mode) {
        .all => true,
        .bad => row.status != .live,
    };
}

/// Caller owns the returned slice; the names borrow from `snapshot`.
fn visibleNames(gpa: std.mem.Allocator, snapshot: Snapshot) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (snapshot.rows) |row| {
        if (isVisible(row, snapshot.mode)) try names.append(gpa, row.name);
    }
    return names.toOwnedSlice(gpa);
}

fn render(gpa: std.mem.Allocator, writer: *std.Io.Writer, cfg: config.Config, snapshot: Snapshot, view: View) !void {
    var frame: std.Io.Writer.Allocating = .init(gpa);
    defer frame.deinit();
    try writeFrame(gpa, &frame.writer, cfg, snapshot, view);
    const body = frame.writer.buffered();
    const size = view.size orelse return writer.writeAll(body);
    const clipped = try ansi.clipLines(gpa, body, size.cols);
    defer gpa.free(clipped);
    try writer.writeAll(clipped);
}

fn writeFrame(gpa: std.mem.Allocator, writer: *std.Io.Writer, cfg: config.Config, snapshot: Snapshot, view: View) !void {
    const layout = Layout.fit(if (view.size) |size| size.rows else null, view.notice != null);
    var live_count: usize = 0;
    var warn_count: usize = 0;
    var dead_count: usize = 0;
    for (snapshot.rows) |row| countMonitorRow(row, &live_count, &warn_count, &dead_count);
    var lines: LineWriter = .{ .writer = writer };
    if (layout.title) {
        try lines.begin();
        try writer.print("{s}[zask-monitor]{s} {s}LIVE:{d}{s} {s}WARN:{d}{s} {s}DEAD:{d}{s}  {s}[{s}]{s}  {s}Ctrl+q m: toggle{s}", .{ ansi.bold, ansi.reset, ansi.green, live_count, ansi.reset, ansi.yellow, warn_count, ansi.reset, ansi.red, dead_count, ansi.reset, ansi.dim, snapshot.mode.optionValue(), ansi.reset, ansi.dim, ansi.reset });
    }
    if (layout.title_gap) try lines.begin();

    var visible: std.ArrayList(MonitorRow) = .empty;
    defer visible.deinit(gpa);
    var selected_index: ?usize = null;
    for (snapshot.rows) |row| {
        if (!isVisible(row, snapshot.mode)) continue;
        if (view.selected) |name| {
            if (std.mem.eql(u8, name, row.name)) selected_index = visible.items.len;
        }
        try visible.append(gpa, row);
    }

    if (snapshot.rows.len == 0) {
        try lines.begin();
        try writer.print("  {s}No services configured{s}", .{ ansi.dim, ansi.reset });
    } else if (visible.items.len == 0) {
        try lines.begin();
        try writer.print("  {s}All services live{s}", .{ ansi.green, ansi.reset });
    } else {
        const range = rowWindow(visible.items.len, selected_index, layout.row_capacity);
        for (visible.items[range.start..range.end], range.start..) |row, i| {
            try lines.begin();
            try writeMonitorRow(writer, row, selected_index == i);
        }
    }

    if (layout.notice_line) {
        try lines.begin();
        if (view.notice) |notice| try writer.print("{s}{s}{s}", .{ ansi.yellow, notice, ansi.reset });
    }
    if (layout.rule) {
        try lines.begin();
        try writer.print("{s}───────────────────────────────────────────────────────────────{s}", .{ ansi.dim, ansi.reset });
    }
    if (layout.guide) {
        try lines.begin();
        try writer.print("{s}{s}{s}", .{ ansi.dim, key_guide, ansi.reset });
    }
    if (layout.commands) {
        try lines.begin();
        try writer.print("{s}zask status | zask logs <service> | zask {s} <command>{s}", .{ ansi.dim, try cfg.projectName(), ansi.reset });
    }
}

/// Separates frame lines without a trailing newline, so a frame of exactly
/// the pane height does not scroll the first line away.
const LineWriter = struct {
    writer: *std.Io.Writer,
    started: bool = false,

    fn begin(self: *LineWriter) !void {
        if (self.started) try self.writer.writeAll("\n");
        self.started = true;
    }
};

/// Chooses which fixed lines fit around the service rows. At least one row
/// always stays so the selection is never pushed off screen; fixed lines are
/// dropped from the lowest priority first: blank spacers, command forms,
/// rule, notice, title, key guide.
const Layout = struct {
    title: bool = true,
    title_gap: bool = true,
    notice_line: bool = true,
    rule: bool = true,
    guide: bool = true,
    commands: bool = true,
    row_capacity: usize = std.math.maxInt(usize),

    fn fit(height: ?u16, has_notice: bool) Layout {
        const rows = height orelse return .{};
        var layout: Layout = .{ .title = false, .title_gap = false, .notice_line = false, .rule = false, .guide = false, .commands = false };
        var budget: usize = @as(usize, rows) -| 1;
        const by_priority = [_]*bool{ &layout.guide, &layout.title, &layout.notice_line, &layout.rule, &layout.commands, &layout.title_gap, &layout.notice_line };
        for (by_priority, 0..) |line, rank| {
            // The notice slot ranks high only while it carries a message.
            if (rank == 2 and !has_notice) continue;
            if (line.* or budget == 0) continue;
            line.* = true;
            budget -= 1;
        }
        layout.row_capacity = 1 + budget;
        return layout;
    }
};

const RowRange = struct { start: usize, end: usize };

/// Picks the rows to draw so the selected one stays on screen; without a
/// visible selection the list starts from the top.
fn rowWindow(count: usize, selected: ?usize, capacity: usize) RowRange {
    if (count <= capacity) return .{ .start = 0, .end = count };
    const index = selected orelse 0;
    const start = if (index >= capacity) index + 1 - capacity else 0;
    return .{ .start = start, .end = start + capacity };
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

fn writeMonitorRow(writer: *std.Io.Writer, row: MonitorRow, selected: bool) !void {
    const color = row.status.color();
    if (selected) try writer.print("{s}>{s} ", .{ ansi.bold, ansi.reset }) else try writer.writeAll("  ");
    try writer.print("{s}{s}{s} ", .{ color, row.status.icon(), ansi.reset });
    if (selected) try writer.writeAll(ansi.reverse);
    try ansi.writePadded(writer, ansi.truncate(row.name, monitor_name_width), monitor_name_width);
    if (selected) try writer.writeAll(ansi.reset);
    try writer.print(" {s}", .{ansi.dim});
    try ansi.writePadded(writer, row.port, monitor_port_width);
    try writer.print("{s} {s}", .{ ansi.reset, color });
    try ansi.writePadded(writer, row.status.summary(row.exit_code), monitor_status_width);
    try writer.print("{s}", .{ansi.reset});
    if (row.log.len > 0) try writer.print(" {s}│{s} {s}", .{ ansi.dim, ansi.reset, ansi.truncate(row.log, monitor_log_width) });
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

fn testRow(name: []const u8, status: MonitorStatus) MonitorRow {
    return .{ .name = name, .status = status, .exit_code = "", .command = "", .port = "no check" };
}

fn testConfig(gpa: std.mem.Allocator) !config.Config {
    return config.Config.parse(gpa,
        \\{"project": {"name":"demo","root":"/tmp/demo"}, "groups": []}
    , "/home/me");
}

fn testRender(gpa: std.mem.Allocator, snapshot: Snapshot, view: View) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try render(gpa, &out.writer, try testConfig(gpa), snapshot, view);
    return out.writer.buffered();
}

fn testVisibleColumns(line: []const u8) usize {
    var columns: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            i += 2;
            while (i < line.len and (line[i] < 0x40 or line[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        columns += ansi.displayWidth(line[i..@min(i + len, line.len)]);
        i += len;
    }
    return columns;
}

fn testSelectedLine(body: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, ansi.reverse) != null) return line;
    }
    return null;
}

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

    try render(ctx.gpa, &out.writer, cfg, try observeSnapshot(ctx), .{});
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

test "monitor.actionForKey: maps keys to monitor actions" {
    const cases = [_]struct { key: keys.Key, expected: Action }{
        .{ .key = .{ .char = 'j' }, .expected = .{ .select = .down } },
        .{ .key = .down, .expected = .{ .select = .down } },
        .{ .key = .{ .char = 'k' }, .expected = .{ .select = .up } },
        .{ .key = .up, .expected = .{ .select = .up } },
        .{ .key = .{ .char = 'f' }, .expected = .toggle_filter },
        .{ .key = .{ .char = 'q' }, .expected = .quit },
        .{ .key = .ctrl_c, .expected = .quit },
        .{ .key = .escape, .expected = .none },
        .{ .key = .enter, .expected = .none },
        .{ .key = .{ .char = 'x' }, .expected = .none },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.expected, actionForKey(case.key));
}

test "monitor.rowWindow: keeps the selected row inside the capacity" {
    const cases = [_]struct { count: usize, selected: ?usize, capacity: usize, start: usize, end: usize }{
        .{ .count = 3, .selected = 2, .capacity = 5, .start = 0, .end = 3 },
        .{ .count = 10, .selected = 1, .capacity = 3, .start = 0, .end = 3 },
        .{ .count = 10, .selected = 3, .capacity = 3, .start = 1, .end = 4 },
        .{ .count = 10, .selected = 9, .capacity = 3, .start = 7, .end = 10 },
        .{ .count = 10, .selected = null, .capacity = 3, .start = 0, .end = 3 },
    };
    for (cases) |case| {
        const range = rowWindow(case.count, case.selected, case.capacity);

        try std.testing.expectEqual(case.start, range.start);
        try std.testing.expectEqual(case.end, range.end);
    }
}

test "monitor.render: highlights only the selected row and shows the key guide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{ testRow("api", .live), testRow("web", .dead) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "web" });

    const selected = testSelectedLine(body) orelse return error.MissingSelectedRow;
    try std.testing.expect(std.mem.indexOf(u8, selected, "web") != null);
    try std.testing.expect(std.mem.startsWith(u8, selected, ansi.bold ++ ">"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, ansi.reverse));
    try std.testing.expect(std.mem.indexOf(u8, body, key_guide) != null);
}

test "monitor.render: hidden selection highlights no other row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{ testRow("api", .live), testRow("web", .dead) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows, .mode = .bad }, .{ .selected = "api" });

    try std.testing.expectEqual(@as(?[]const u8, null), testSelectedLine(body));
    try std.testing.expect(std.mem.indexOf(u8, body, "web") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "api") == null);
}

test "monitor.render: explains empty lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const live = [_]MonitorRow{testRow("api", .live)};
    const cases = [_]struct { snapshot: Snapshot, message: []const u8 }{
        .{ .snapshot = .{}, .message = "No services configured" },
        .{ .snapshot = .{ .rows = &live, .mode = .bad }, .message = "All services live" },
    };
    for (cases) |case| {
        const body = try testRender(arena.allocator(), case.snapshot, .{});

        try std.testing.expect(std.mem.indexOf(u8, body, case.message) != null);
        try std.testing.expect(std.mem.indexOf(u8, body, key_guide) != null);
    }
}

test "monitor.render: narrow pane clips every line to its width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var row = testRow("a-very-long-service-name", .dead);
    row.log = "error: something went wrong while starting the service";
    const rows = [_]MonitorRow{ row, testRow("web", .live) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "web", .size = .{ .cols = 20, .rows = 24 } });

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| try std.testing.expect(testVisibleColumns(line) <= 20);
    try std.testing.expect(testSelectedLine(body) != null);
}

test "monitor.render: short pane scrolls rows and keeps the footer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{ testRow("svc-0", .live), testRow("svc-1", .live), testRow("svc-2", .live), testRow("svc-3", .live), testRow("svc-4", .live) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "svc-4", .size = .{ .cols = 80, .rows = 8 } });

    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, body, "\n") + 1);
    try std.testing.expect(std.mem.indexOf(u8, body, "svc-2") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "svc-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(body) orelse return error.MissingSelectedRow, "svc-4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, key_guide) != null);
}

test "monitor.render: shows a notice above the footer rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{testRow("api", .live)};

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .notice = "filter toggle failed" });

    const notice = std.mem.indexOf(u8, body, "filter toggle failed") orelse return error.MissingNotice;
    try std.testing.expect(notice < (std.mem.indexOf(u8, body, "───") orelse return error.MissingRule));
}

test "monitor.observeSnapshot: reads filter mode and captures logs only for rows that are not live" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":"api","command":"serve"},
        \\    {"name":"web","dir":"web","command":"serve"}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("bad\n", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("1|3|12345|node|\n", "", .{ .exited = 0 });
    try recorder.enqueue("booting\npanic: boom\n\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const snapshot = try observeSnapshot(ctx);

    try std.testing.expectEqual(tmux_options.DashMode.bad, snapshot.mode);
    try std.testing.expectEqual(MonitorStatus.live, snapshot.rows[0].status);
    try std.testing.expectEqualStrings("", snapshot.rows[0].log);
    try std.testing.expectEqual(MonitorStatus.dead, snapshot.rows[1].status);
    try std.testing.expectEqualStrings("panic: boom", snapshot.rows[1].log);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.Layout.fit: drops fixed lines before the selected row" {
    const cases = [_]struct { height: ?u16, notice: bool, expected: Layout }{
        .{ .height = null, .notice = false, .expected = .{} },
        .{ .height = 24, .notice = false, .expected = .{ .row_capacity = 18 } },
        .{ .height = 7, .notice = false, .expected = .{ .row_capacity = 1 } },
        .{ .height = 4, .notice = false, .expected = .{ .title_gap = false, .notice_line = false, .commands = false, .row_capacity = 1 } },
        .{ .height = 4, .notice = true, .expected = .{ .title_gap = false, .rule = false, .commands = false, .row_capacity = 1 } },
        .{ .height = 2, .notice = false, .expected = .{ .title = false, .title_gap = false, .notice_line = false, .rule = false, .commands = false, .row_capacity = 1 } },
        .{ .height = 1, .notice = false, .expected = .{ .title = false, .title_gap = false, .notice_line = false, .rule = false, .guide = false, .commands = false, .row_capacity = 1 } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.expected, Layout.fit(case.height, case.notice));
}

test "monitor.render: tiny pane keeps the selected row within its height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{ testRow("api", .live), testRow("web", .live), testRow("worker", .dead) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "worker", .size = .{ .cols = 45, .rows = 4 } });

    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, body, "\n") + 1);
    try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(body) orelse return error.MissingSelectedRow, "worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, key_guide) != null);
}

test "monitor.render: wide log text stays within the pane width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var row = testRow("api", .dead);
    row.log = "ログ日本語日本語日本語日本語日本語日本語";
    const rows = [_]MonitorRow{row};

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "api", .size = .{ .cols = 45, .rows = 10 } });

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| try std.testing.expect(testVisibleColumns(line) <= 45);
}
