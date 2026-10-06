const std = @import("std");
const ansi = @import("ansi.zig");
const config = @import("../../model/config.zig");
const keys = @import("keys.zig");
const log_popup = @import("../../workflow/log_popup.zig");
const observations = @import("../../model/observations.zig");
const proc_runner = @import("../../platform/runner.zig");
const recovery = @import("../../model/recovery.zig");
const selection_state = @import("selection.zig");
const service_observation = @import("../../workflow/service_observation.zig");
const session_layout = @import("../../workflow/session_layout.zig");
const terminal = @import("../../platform/terminal.zig");
const tmux_options = @import("../../model/tmux_options.zig");
const tmux_setup = @import("../../workflow/tmux_setup.zig");
const RenderContext = @import("context.zig").RenderContext;
const runtime_mod = @import("../../workflow/runtime.zig");
const Runtime = runtime_mod.Runtime;
const Selection = selection_state.Selection;

const monitor_name_width = 12;
const monitor_port_width = 8;
const monitor_status_width = 8;
const monitor_recovery_width = 11;
const monitor_log_width = 35;
const refresh_interval_ms = 1000;
const escape_timeout_ms = 250;
const action_guide = "⏎ go  s start  x stop  r restart  l logs";
const key_guide = "C-n/p C-v/M-v M-</> move  f filter  q quit";

pub fn run(runtime: Runtime, writer: *std.Io.Writer) !void {
    const gpa = runtime.gpa;
    const raw_mode = try terminal.RawMode.enter(terminal.stdin);
    defer if (raw_mode) |mode| mode.restore();
    try writer.writeAll(ansi.enter_screen);
    defer {
        writer.writeAll(ansi.leave_screen) catch {};
        writer.flush() catch {};
    }

    var monitor: Monitor = .{
        .gpa = gpa,
        .io = runtime.io,
        .cfg = runtime.cfg,
        .runtime = runtime,
        .snapshot_arena = .init(gpa),
        .operation_arena = .init(gpa),
    };
    defer monitor.deinit();
    try monitor.loop(writer, raw_mode != null);
}

const Control = enum { keep, quit };

const Action = union(enum) {
    none,
    quit,
    select: selection_state.Motion,
    page: enum { up, down },
    cancel,
    toggle_filter,
    show_logs,
    operate: Operation,
};

const Operation = enum {
    show,
    start,
    stop,
    restart,

    fn running(self: Operation) []const u8 {
        return switch (self) {
            .show => "opening",
            .start => "starting",
            .stop => "stopping",
            .restart => "restarting",
        };
    }

    fn done(self: Operation) []const u8 {
        return switch (self) {
            .show => "opened",
            .start => "started",
            .stop => "stopped",
            .restart => "restarted",
        };
    }

    fn verb(self: Operation) []const u8 {
        return switch (self) {
            .show => "open",
            .start => "start",
            .stop => "stop",
            .restart => "restart",
        };
    }
};

fn actionForKey(key: keys.Key) Action {
    return switch (key) {
        .up => .{ .select = .up },
        .down => .{ .select = .down },
        .enter => .{ .operate = .show },
        .ctrl => |char| switch (char) {
            'n' => .{ .select = .down },
            'p' => .{ .select = .up },
            'v' => .{ .page = .down },
            'g' => .cancel,
            'c' => .quit,
            else => .none,
        },
        .alt => |char| switch (char) {
            'v' => .{ .page = .up },
            '<' => .{ .select = .first },
            '>' => .{ .select = .last },
            else => .none,
        },
        .char => |char| switch (char) {
            'k' => .{ .select = .up },
            'j' => .{ .select = .down },
            's' => .{ .operate = .start },
            'x' => .{ .operate = .stop },
            'r' => .{ .operate = .restart },
            'l' => .show_logs,
            'f' => .toggle_filter,
            'q' => .quit,
            else => .none,
        },
        .left, .right, .escape, .unknown => .none,
    };
}

const Monitor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    runtime: Runtime,
    snapshot_arena: std.heap.ArenaAllocator,
    operation_arena: std.heap.ArenaAllocator,
    snapshot: Snapshot = .{},
    selection: Selection = .{},
    notice: ?[]const u8 = null,
    notice_buffer: [256]u8 = undefined,
    previous: []u8 = &.{},
    input: keys.Decoder = .{},
    pending_since: ?std.Io.Timestamp = null,

    fn deinit(self: *Monitor) void {
        self.selection.deinit(self.gpa);
        self.gpa.free(self.previous);
        self.operation_arena.deinit();
        self.snapshot_arena.deinit();
    }

    fn loop(self: *Monitor, writer: *std.Io.Writer, interactive: bool) !void {
        try self.refresh();
        var refreshed_at = std.Io.Clock.awake.now(self.io);
        while (true) {
            try self.draw(writer);
            const elapsed = refreshed_at.untilNow(self.io, .awake).toMilliseconds();
            const remaining: i32 = @intCast(std.math.clamp(refresh_interval_ms - elapsed, 0, refresh_interval_ms));
            if (interactive) {
                const escape_remaining = self.escapeRemaining();
                const timeout = if (escape_remaining) |left| @min(remaining, left) else remaining;
                switch (try terminal.waitReadable(terminal.stdin, timeout)) {
                    .input => if (try self.readKeys(writer) == .quit) return,
                    .closed => return,
                    .timeout => if (self.escapeRemaining() == 0) {
                        self.pending_since = null;
                        if (self.input.flush()) |key| {
                            if (try self.handleKey(writer, key) == .quit) return;
                        }
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

    fn readKeys(self: *Monitor, writer: *std.Io.Writer) !Control {
        const len = try terminal.read(terminal.stdin, self.input.space());
        if (len == 0) return .quit;
        self.input.commit(len);
        var decoded_any = false;
        while (self.input.next()) |key| {
            decoded_any = true;
            if (try self.handleKey(writer, key) == .quit) return .quit;
        }
        if (!self.input.pending()) {
            self.pending_since = null;
        } else if (decoded_any or self.pending_since == null) {
            self.pending_since = std.Io.Clock.awake.now(self.io);
        }
        return .keep;
    }

    fn escapeRemaining(self: Monitor) ?i32 {
        const since = self.pending_since orelse return null;
        const age = since.untilNow(self.io, .awake).toMilliseconds();
        return @intCast(std.math.clamp(escape_timeout_ms - age, 0, escape_timeout_ms));
    }

    fn handleKey(self: *Monitor, writer: *std.Io.Writer, key: keys.Key) !Control {
        switch (actionForKey(key)) {
            .none => {},
            .quit => return .quit,
            .select => |motion| try self.moveSelection(motion),
            .page => |direction| {
                const rows = pageRows(if (terminal.size(terminal.stdout)) |size| size.rows else null);
                try self.moveSelection(switch (direction) {
                    .up => .{ .page_up = rows },
                    .down => .{ .page_down = rows },
                });
            },
            .cancel => self.notice = null,
            .toggle_filter => self.toggleFilter(),
            .operate => |operation| try self.operate(writer, operation),
            .show_logs => try self.showLogs(),
        }
        return .keep;
    }

    fn moveSelection(self: *Monitor, motion: selection_state.Motion) !void {
        const names = try visibleNames(self.gpa, self.snapshot);
        defer self.gpa.free(names);
        try self.selection.move(self.gpa, names, motion);
        self.notice = null;
    }

    fn operate(self: *Monitor, writer: *std.Io.Writer, operation: Operation) !void {
        const target = selectedTarget(self.snapshot, self.selection) orelse {
            self.notice = "no service selected";
            return;
        };
        self.setNotice("{s} {s}...", .{ operation.running(), target.name });
        try self.draw(writer);

        _ = self.operation_arena.reset(.retain_capacity);
        const scratch = self.operation_arena.allocator();
        var output: std.Io.Writer.Allocating = .init(scratch);
        const printed = &output.writer;
        if (runOperation(self.runtime.withAllocator(scratch), operation, target, printed)) |outcome| switch (outcome) {
            .done => self.setCompletedNotice(operation, target.name, printed.buffered()),
            .incomplete => self.setNotice("{s} {s} incomplete: {s}", .{ operation.verb(), target.name, incompleteReason(operation, printed.buffered()) }),
        } else |err| {
            self.setNotice("{s} {s} failed: {s}", .{ operation.verb(), target.name, lastOutputLine(printed.buffered(), @errorName(err)) });
        }

        terminal.discardInput(terminal.stdin);
        self.input = .{};
        self.pending_since = null;
        try self.refresh();
    }

    fn setCompletedNotice(self: *Monitor, operation: Operation, name: []const u8, output: []const u8) void {
        var notice: std.Io.Writer = .fixed(&self.notice_buffer);
        notice.print("{s} {s}", .{ operation.done(), name }) catch {};
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "Warning:")) notice.print("; {s}", .{trimmed}) catch {};
        }
        self.notice = notice.buffered();
    }

    fn showLogs(self: *Monitor) !void {
        const target = selectedTarget(self.snapshot, self.selection) orelse {
            self.notice = "no service selected";
            return;
        };
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const window = switch (target.kind) {
            .service => target.name,
            .docker => session_layout.docker_window,
        };
        const outcome = self.runtime.withAllocator(scratch.allocator()).showLogPopup(window, target.name) catch |err| {
            self.setNotice("logs {s} failed: {s}", .{ target.name, @errorName(err) });
            return;
        };
        self.notice = null;
        switch (outcome) {
            .shown => {},
            .empty => self.setNotice("{s} has no log output yet", .{target.name}),
            .outside_tmux => self.notice = "log popup unavailable: monitor is not in tmux",
            .no_client => self.notice = "log popup unavailable: no client shows the monitor",
            .window_missing => self.setNotice("logs {s}: window not found", .{target.name}),
            .tmux_unavailable => self.notice = "log popup failed: tmux unavailable",
            .popup_unavailable => self.notice = "log popup unavailable: needs tmux 3.3+",
            .pager_unavailable => self.notice = "log popup unavailable: needs less 582+ or lesskey",
        }

        terminal.discardInput(terminal.stdin);
        self.input = .{};
        self.pending_since = null;
        try self.refresh();
    }

    fn setNotice(self: *Monitor, comptime fmt: []const u8, args: anytype) void {
        var notice: std.Io.Writer = .fixed(&self.notice_buffer);
        notice.print(fmt, args) catch {};
        self.notice = notice.buffered();
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

const RowKind = enum { service, docker };
const docker_selection_key = ":docker";

const MonitorRow = struct {
    name: []const u8,
    kind: RowKind = .service,
    status: MonitorStatus,
    exit_code: []const u8,
    command: []const u8,
    port: []const u8,
    log: []const u8 = "",
    recovery: recovery.View = .not_configured,

    fn selectionKey(self: MonitorRow) []const u8 {
        return if (self.kind == .docker) docker_selection_key else self.name;
    }
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
        if (row.status != .live) {
            row.log = try lastLogLine(ctx, row.name);
        } else if (row.recovery == .restarted) {
            row.log = try restartReason(ctx.gpa, row.recovery.restarted);
        }
    }
    return .{ .rows = try rows.toOwnedSlice(ctx.gpa), .mode = mode };
}

fn isVisible(row: MonitorRow, mode: tmux_options.DashMode) bool {
    return switch (mode) {
        .all => true,
        .bad => row.status != .live,
    };
}

const Target = struct {
    name: []const u8,
    kind: RowKind,
};

fn selectedTarget(snapshot: Snapshot, selection: Selection) ?Target {
    const name = selection.name orelse return null;
    for (snapshot.rows) |row| {
        if (!isVisible(row, snapshot.mode)) continue;
        if (std.mem.eql(u8, row.selectionKey(), name)) return .{ .name = row.name, .kind = row.kind };
    }
    return null;
}

fn runOperation(runtime: Runtime, operation: Operation, target: Target, writer: *std.Io.Writer) !runtime_mod.Outcome {
    switch (target.kind) {
        .service => switch (operation) {
            .show => try runtime.showWindow(target.name),
            .start => try runtime.startService(target.name, writer),
            .stop => return runtime.stopService(target.name, writer),
            .restart => return runtime.restartService(target.name, writer),
        },
        .docker => switch (operation) {
            .show => try runtime.showWindow(session_layout.docker_window),
            .start => try runtime.start(config.keys.docker, writer),
            .stop => return runtime.stopDocker(writer),
            .restart => return runtime.restartDocker(writer),
        },
    }
    return .done;
}

fn incompleteReason(operation: Operation, output: []const u8) []const u8 {
    return switch (operation) {
        .restart => "the previous process did not stop",
        .show, .start, .stop => lastOutputLine(output, "see its window"),
    };
}

fn lastOutputLine(output: []const u8, fallback: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const visible = if (std.mem.lastIndexOfScalar(u8, line, '\r')) |i| line[i + 1 ..] else line;
        const trimmed = std.mem.trim(u8, visible, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return fallback;
}

fn visibleNames(gpa: std.mem.Allocator, snapshot: Snapshot) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    for (snapshot.rows) |row| {
        if (isVisible(row, snapshot.mode)) try names.append(gpa, row.selectionKey());
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
    var recovery_column = false;
    for (snapshot.rows) |row| {
        countMonitorRow(row, &live_count, &warn_count, &dead_count);
        if (row.recovery != .not_configured) recovery_column = true;
    }
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
            if (std.mem.eql(u8, name, row.selectionKey())) selected_index = visible.items.len;
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
            try writeMonitorRow(writer, row, selected_index == i, recovery_column);
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
    if (layout.actions) {
        try lines.begin();
        try writer.print("{s}{s}{s}", .{ ansi.dim, action_guide, ansi.reset });
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

const LineWriter = struct {
    writer: *std.Io.Writer,
    started: bool = false,

    fn begin(self: *LineWriter) !void {
        if (self.started) try self.writer.writeAll("\n");
        self.started = true;
    }
};

const Layout = struct {
    title: bool = true,
    title_gap: bool = true,
    notice_line: bool = true,
    rule: bool = true,
    actions: bool = true,
    guide: bool = true,
    commands: bool = true,
    row_capacity: usize = std.math.maxInt(usize),

    fn fit(height: ?u16, has_notice: bool) Layout {
        const rows = height orelse return .{};
        var layout: Layout = .{ .title = false, .title_gap = false, .notice_line = false, .rule = false, .actions = false, .guide = false, .commands = false };
        var budget: usize = @as(usize, rows) -| 1;
        const by_priority = [_]*bool{ &layout.guide, &layout.actions, &layout.notice_line, &layout.title, &layout.rule, &layout.commands, &layout.title_gap, &layout.notice_line };
        for (by_priority, 0..) |line, rank| {
            if (rank == 2 and !has_notice) continue;
            if (line.* or budget == 0) continue;
            line.* = true;
            budget -= 1;
        }
        layout.row_capacity = 1 + budget;
        return layout;
    }
};

fn pageRows(height: ?u16) usize {
    return Layout.fit(height, false).row_capacity;
}

const RowRange = struct { start: usize, end: usize };

fn rowWindow(count: usize, selected: ?usize, capacity: usize) RowRange {
    if (count <= capacity) return .{ .start = 0, .end = count };
    const index = selected orelse 0;
    const start = if (index >= capacity) index + 1 - capacity else 0;
    return .{ .start = start, .end = start + capacity };
}

fn serviceMonitorRow(ctx: RenderContext, service: std.json.Value) !MonitorRow {
    const observation = try observer(ctx).observeService(service);
    const policy = try config.Config.serviceRestartOnFailure(service);
    return .{
        .name = try config.Config.serviceName(service),
        .status = serviceMonitorStatus(observation),
        .exit_code = observation.pane.exit_code,
        .command = observation.pane.command,
        .port = if (observation.port) |p| try std.fmt.allocPrint(ctx.gpa, ":{d}", .{p}) else "no check",
        .recovery = recovery.view(if (policy) |value| value.max_retries else null, observation.pane.state, observation.pane.processId(), observation.pane.recovery),
    };
}

fn dockerMonitorRow(ctx: RenderContext) !MonitorRow {
    const observation = observer(ctx).observeDocker();
    defer observation.compose.deinit(ctx.gpa);
    return .{ .name = "docker", .kind = .docker, .status = dockerMonitorStatus(observation), .exit_code = observation.pane.exit_code, .command = observation.pane.command, .port = "compose" };
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

fn writeMonitorRow(writer: *std.Io.Writer, row: MonitorRow, selected: bool, recovery_column: bool) !void {
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
    if (recovery_column) {
        var buffer: [64]u8 = undefined;
        const cell = recoveryCell(row.recovery, &buffer);
        try writer.print(" {s}", .{cell.color});
        try ansi.writePadded(writer, cell.text, monitor_recovery_width);
        try writer.print("{s}", .{ansi.reset});
    }
    if (row.log.len > 0) try writer.print(" {s}│{s} {s}", .{ ansi.dim, ansi.reset, ansi.truncate(row.log, monitor_log_width) });
}

fn restartReason(gpa: std.mem.Allocator, record: recovery.Record) ![]const u8 {
    return switch (record.exit) {
        .failed => |status| std.fmt.allocPrint(gpa, "restarted after exit {d}", .{status}),
        .clean, .interrupted, .killed => "restarted after a kill signal",
    };
}

const RecoveryCell = struct { text: []const u8, color: []const u8 };

fn recoveryCell(view: recovery.View, buffer: []u8) RecoveryCell {
    return switch (view) {
        .not_configured => .{ .text = "", .color = "" },
        .unknown => .{ .text = "↻ ?", .color = ansi.dim },
        .none => |max| .{ .text = std.fmt.bufPrint(buffer, "↻ 0/{d}", .{max}) catch "↻", .color = ansi.dim },
        .restarted => |record| .{ .text = std.fmt.bufPrint(buffer, "↻ {d}/{d}", .{ record.attempt, record.max_retries }) catch "↻", .color = ansi.yellow },
        .waiting => |record| .{ .text = std.fmt.bufPrint(buffer, "↻ {d}/{d} wait", .{ record.attempt, record.max_retries }) catch "↻ wait", .color = ansi.cyan },
        .gave_up => |record| .{ .text = std.fmt.bufPrint(buffer, "↻ {d}/{d} limit", .{ record.attempt, record.max_retries }) catch "↻ limit", .color = ansi.red },
    };
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

fn testRuntime(gpa: std.mem.Allocator, recorder: *proc_runner.Recorder, json: []const u8) !Runtime {
    const runner: proc_runner.Runner = .{ .gpa = gpa, .io = undefined, .recorder = recorder };
    return .{
        .gpa = gpa,
        .io = undefined,
        .cfg = try config.Config.parse(gpa, json, "/home/me"),
        .config_path = "/tmp/demo/zask.json",
        .zask_path = "zask",
        .command_hint = .local,
        .runner_impl = runner,
        .tmux_impl = .{ .gpa = gpa, .runner = runner, .session = "demo" },
        .docker_impl = .{ .gpa = gpa, .runner = runner, .dir = "/tmp/demo", .file = "compose.yaml" },
        .validate_configured_dirs = false,
        .emit_env_file_tips = false,
    };
}

fn testStopAttempts() usize {
    return @import("../../workflow/waits.zig").stopAttempts();
}

fn testSelection(name: []const u8) !Selection {
    return .{ .name = try std.testing.allocator.dupe(u8, name) };
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

test "monitor.serviceMonitorStatus: maps service health to row status" {
    const cases = [_]struct {
        pane: observations.PaneState,
        listen: observations.ProbeObservation,
        http: observations.ProbeObservation = .not_configured,
        expected: MonitorStatus,
    }{
        .{ .pane = .busy, .listen = .passed, .expected = .live },
        .{ .pane = .busy, .listen = .not_configured, .expected = .live },
        .{ .pane = .busy, .listen = .failed, .expected = .waiting },
        .{ .pane = .busy, .listen = .passed, .http = .failed, .expected = .degraded },
        .{ .pane = .busy, .listen = .unavailable, .expected = .unknown },
        .{ .pane = .tmux_unavailable, .listen = .not_observed, .expected = .unknown },
        .{ .pane = .dead, .listen = .not_observed, .expected = .dead },
        .{ .pane = .idle, .listen = .not_observed, .expected = .stop },
        .{ .pane = .window_missing, .listen = .not_observed, .expected = .stop },
    };

    for (cases) |case| {
        const observation: observations.ServiceObservation = .{ .pane = .{ .state = case.pane }, .port = 3000, .listen = case.listen, .http = case.http, .observed_at = 0 };
        try std.testing.expectEqual(case.expected, serviceMonitorStatus(observation));
    }
}

test "monitor.dockerMonitorStatus: maps pane and compose state to row status" {
    const cases = [_]struct {
        pane: observations.PaneState,
        compose: observations.ComposeState = .empty,
        expected: MonitorStatus,
    }{
        .{ .pane = .busy, .compose = .running, .expected = .live },
        .{ .pane = .busy, .compose = .empty, .expected = .waiting },
        .{ .pane = .busy, .compose = .unavailable, .expected = .unknown },
        .{ .pane = .dead, .expected = .dead },
        .{ .pane = .idle, .expected = .stop },
        .{ .pane = .window_missing, .expected = .stop },
        .{ .pane = .tmux_unavailable, .expected = .unknown },
    };

    for (cases) |case| {
        const observation: observations.DockerObservation = .{ .pane = .{ .state = case.pane }, .compose = .{ .state = case.compose }, .observed_at = 0 };
        try std.testing.expectEqual(case.expected, dockerMonitorStatus(observation));
    }
}

test "monitor.serviceMonitorRow: labels the observed port and status" {
    const cases = [_]struct {
        name: []const u8,
        service: []const u8,
        pane: []const u8,
        listen_exit: ?u8 = null,
        status: MonitorStatus,
        port: []const u8,
        summary: []const u8,
    }{
        .{ .name = "port not ready", .service = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000}", .pane = "0||12345|node|\n", .listen_exit = 1, .status = .waiting, .port = ":3000", .summary = "waiting" },
        .{ .name = "exited with port", .service = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000}", .pane = "1|2|12345|node|\n", .status = .dead, .port = ":3000", .summary = "2" },
        .{ .name = "running without port", .service = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\"}", .pane = "0||12345|node|\n", .status = .live, .port = "no check", .summary = "live" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"project":{{"name":"demo","root":"/tmp/demo"}},"groups":[{{"name":"backend","services":[{s}]}}]}}
        , .{case.service});
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.pane, "", .{ .exited = 0 });
        if (case.listen_exit) |code| try recorder.enqueue("", "", .{ .exited = code });
        const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
        const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

        const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

        try std.testing.expectEqual(case.status, row.status);
        try std.testing.expectEqualStrings(case.port, row.port);
        try std.testing.expectEqualStrings(case.summary, row.status.summary(row.exit_code));
        try proc_runner.expectNoRemainingResponses(&recorder);
    }
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

test "monitor.actionForKey: maps keys to monitor actions" {
    const cases = [_]struct { key: keys.Key, expected: Action }{
        .{ .key = .{ .char = 'j' }, .expected = .{ .select = .down } },
        .{ .key = .down, .expected = .{ .select = .down } },
        .{ .key = .{ .char = 'k' }, .expected = .{ .select = .up } },
        .{ .key = .up, .expected = .{ .select = .up } },
        .{ .key = .enter, .expected = .{ .operate = .show } },
        .{ .key = .{ .char = 's' }, .expected = .{ .operate = .start } },
        .{ .key = .{ .char = 'x' }, .expected = .{ .operate = .stop } },
        .{ .key = .{ .char = 'r' }, .expected = .{ .operate = .restart } },
        .{ .key = .{ .char = 'l' }, .expected = .show_logs },
        .{ .key = .{ .char = 'f' }, .expected = .toggle_filter },
        .{ .key = .{ .char = 'q' }, .expected = .quit },
        .{ .key = .{ .ctrl = 'c' }, .expected = .quit },
        .{ .key = .{ .ctrl = 'n' }, .expected = .{ .select = .down } },
        .{ .key = .{ .ctrl = 'p' }, .expected = .{ .select = .up } },
        .{ .key = .{ .ctrl = 'v' }, .expected = .{ .page = .down } },
        .{ .key = .{ .alt = 'v' }, .expected = .{ .page = .up } },
        .{ .key = .{ .alt = '<' }, .expected = .{ .select = .first } },
        .{ .key = .{ .alt = '>' }, .expected = .{ .select = .last } },
        .{ .key = .{ .ctrl = 'g' }, .expected = .cancel },
        .{ .key = .{ .alt = 'x' }, .expected = .none },
        .{ .key = .escape, .expected = .none },
        .{ .key = .{ .char = 'z' }, .expected = .none },
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
    try std.testing.expect(std.mem.indexOf(u8, body, action_guide) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, key_guide) != null);
}

test "monitor.selection: distinguishes Docker from a service named docker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var compose = testRow("docker", .live);
    compose.kind = .docker;
    compose.port = "compose";
    const rows = [_]MonitorRow{ compose, testRow("docker", .dead) };
    const snapshot: Snapshot = .{ .rows = &rows };
    const names = try visibleNames(gpa, snapshot);
    var selection: Selection = .{};
    defer selection.deinit(gpa);

    try selection.track(gpa, names);
    const first = try testRender(gpa, snapshot, .{ .selected = selection.name });
    try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(first).?, "compose") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, first, ansi.reverse));

    try selection.move(gpa, names, .down);
    try std.testing.expectEqual(@as(?usize, 1), selection.position(names));
    const second = try testRender(gpa, snapshot, .{ .selected = selection.name });
    try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(second).?, "no check") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, ansi.reverse));

    try selection.track(gpa, try visibleNames(gpa, .{ .rows = &rows, .mode = .bad }));
    try std.testing.expectEqualStrings("docker", selection.name.?);
    try selection.move(gpa, names, .up);
    try std.testing.expectEqualStrings(docker_selection_key, selection.name.?);
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

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "svc-4", .size = .{ .cols = 80, .rows = 9 } });

    try std.testing.expectEqual(@as(usize, 9), std.mem.count(u8, body, "\n") + 1);
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

test "monitor.service: reads recovery only for the run it describes" {
    const cases = [_]struct {
        name: []const u8,
        service: []const u8 = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"restart_on_failure\":{}}",
        pane: []const u8,
        want: std.meta.Tag(recovery.View),
    }{
        .{ .name = "not configured", .service = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\"}", .pane = "1|1|100|node|900||gave_up,100,3,3,1\n", .want = .not_configured },
        .{ .name = "no recovery yet", .pane = "0||100|node|900||\n", .want = .none },
        .{ .name = "recovered run", .pane = "0||200|node|900||restarted,,2,3,1\n", .want = .restarted },
        .{ .name = "gave up", .pane = "1|1|100|node|900||gave_up,100,3,3,1\n", .want = .gave_up },
        .{ .name = "gave up on an earlier run", .pane = "1|1|200|node|900||gave_up,100,3,3,1\n", .want = .none },
        .{ .name = "unreadable record", .pane = "0||100|node|900||gave_up\n", .want = .unknown },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"project":{{"name":"demo","root":"/tmp/demo"}},"groups":[{{"name":"backend","services":[{s}]}}]}}
        , .{case.service});
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.pane, "", .{ .exited = 0 });
        const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
        const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

        const row = try serviceMonitorRow(ctx, (try cfg.services())[0]);

        try std.testing.expectEqual(case.want, std.meta.activeTag(row.recovery));
    }
}

test "monitor.observeSnapshot: shows why a live service was restarted" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"api","command":"serve","restart_on_failure":{}}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||200|node|900||restarted,,2,3,137\n", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = runner, .tmux = .{ .gpa = arena.allocator(), .runner = runner, .session = "demo" } };

    const snapshot = try observeSnapshot(ctx);

    try std.testing.expectEqual(MonitorStatus.live, snapshot.rows[0].status);
    try std.testing.expectEqualStrings("restarted after exit 137", snapshot.rows[0].log);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.render: keeps the restart reason whole in the log column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const reasons = [_][]const u8{
        try restartReason(gpa, .{ .kind = .restarted, .attempt = 3, .max_retries = 3, .exit = .{ .failed = 4294967295 } }),
        try restartReason(gpa, .{ .kind = .restarted, .attempt = 3, .max_retries = 3, .exit = .killed }),
    };

    for (reasons) |reason| {
        var row = testRow("a-very-long-service-name", .live);
        row.recovery = .{ .restarted = .{ .kind = .restarted, .attempt = 3, .max_retries = 3, .exit = .killed } };
        row.log = reason;
        const rows = [_]MonitorRow{row};

        const body = try testRender(gpa, .{ .rows = &rows }, .{});

        try std.testing.expect(std.mem.indexOf(u8, body, reason) != null);
    }
}

test "monitor.recoveryCell: labels each recovery state apart" {
    const record: recovery.Record = .{ .kind = .restarted, .attempt = 2, .max_retries = 3, .exit = .{ .failed = 1 } };
    const cases = [_]struct { view: recovery.View, text: []const u8 }{
        .{ .view = .not_configured, .text = "" },
        .{ .view = .unknown, .text = "↻ ?" },
        .{ .view = .{ .none = 3 }, .text = "↻ 0/3" },
        .{ .view = .{ .restarted = record }, .text = "↻ 2/3" },
        .{ .view = .{ .waiting = record }, .text = "↻ 2/3 wait" },
        .{ .view = .{ .gave_up = record }, .text = "↻ 2/3 limit" },
    };

    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        const cell = recoveryCell(case.view, &buffer);
        try std.testing.expectEqualStrings(case.text, cell.text);
        try std.testing.expect(ansi.displayWidth(cell.text) <= monitor_recovery_width);
    }
}

test "monitor.render: adds the recovery column only when a service has restart_on_failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var gave_up = testRow("worker", .dead);
    gave_up.recovery = .{ .gave_up = .{ .kind = .gave_up, .pid = 1, .attempt = 3, .max_retries = 3, .exit = .{ .failed = 1 } } };
    gave_up.log = "panic: boom";
    const with = [_]MonitorRow{ testRow("api", .live), gave_up };
    const without = [_]MonitorRow{ testRow("api", .live), testRow("web", .dead) };

    const shown = try testRender(arena.allocator(), .{ .rows = &with }, .{});
    const hidden = try testRender(arena.allocator(), .{ .rows = &without }, .{});

    try std.testing.expect(std.mem.indexOf(u8, shown, "↻ 3/3 limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "panic: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "↻") == null);
}

test "monitor.pageRows: pages by the rows a short pane shows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var rows: [20]MonitorRow = undefined;
    var names: [20][]const u8 = undefined;
    for (&rows, &names, 0..) |*row, *name, i| {
        name.* = try std.fmt.allocPrint(gpa, "svc-{d:0>2}", .{i});
        row.* = testRow(name.*, .live);
    }
    const size: terminal.Size = .{ .cols = 80, .rows = 9 };
    var selection: Selection = .{};
    defer selection.deinit(gpa);
    try selection.track(gpa, &names);

    try selection.move(gpa, &names, .{ .page_down = pageRows(size.rows) });
    const body = try testRender(gpa, .{ .rows = &rows }, .{ .selected = selection.name, .size = size });

    try std.testing.expectEqualStrings("svc-02", selection.name.?);
    try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(body) orelse return error.MissingSelectedRow, "svc-02") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "svc-"));
    try std.testing.expect(std.mem.indexOf(u8, body, "svc-00") == null);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), pageRows(null));
}

test "monitor.render: tiny pane keeps the selected row and drops lines by priority" {
    const title = "[zask-monitor]";
    const notice = "filter toggle failed";
    const cases = [_]struct {
        rows: u16,
        notice: ?[]const u8 = null,
        shown: []const []const u8,
        hidden: []const []const u8,
    }{
        .{ .rows = 4, .shown = &.{ title, action_guide, key_guide }, .hidden = &.{ "───", "zask status" } },
        .{ .rows = 4, .notice = notice, .shown = &.{ notice, action_guide, key_guide }, .hidden = &.{ title, "───" } },
        .{ .rows = 2, .shown = &.{key_guide}, .hidden = &.{ title, action_guide } },
        .{ .rows = 1, .shown = &.{}, .hidden = &.{ title, key_guide } },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rows = [_]MonitorRow{ testRow("api", .live), testRow("web", .live), testRow("worker", .dead) };

    for (cases) |case| {
        errdefer std.debug.print("rows: {d} notice: {}\n", .{ case.rows, case.notice != null });

        const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "worker", .size = .{ .cols = 80, .rows = case.rows }, .notice = case.notice });

        try std.testing.expectEqual(@as(usize, case.rows), std.mem.count(u8, body, "\n") + 1);
        try std.testing.expect(std.mem.indexOf(u8, testSelectedLine(body) orelse return error.MissingSelectedRow, "worker") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "api") == null);
        for (case.shown) |text| try std.testing.expect(std.mem.indexOf(u8, body, text) != null);
        for (case.hidden) |text| try std.testing.expect(std.mem.indexOf(u8, body, text) == null);
    }
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

test "monitor.selectedTarget: resolves only a visible selected row" {
    var docker_row = testRow("docker", .live);
    docker_row.kind = .docker;
    const rows = [_]MonitorRow{ docker_row, testRow("api", .live), testRow("web", .dead) };
    var api = try testSelection("api");
    defer api.deinit(std.testing.allocator);
    var docker = try testSelection(docker_selection_key);
    defer docker.deinit(std.testing.allocator);

    const all = selectedTarget(.{ .rows = &rows }, api) orelse return error.MissingTarget;
    const hidden = selectedTarget(.{ .rows = &rows, .mode = .bad }, api);
    const unselected = selectedTarget(.{ .rows = &rows }, .{});
    const compose = selectedTarget(.{ .rows = &rows }, docker) orelse return error.MissingTarget;

    try std.testing.expectEqualStrings("api", all.name);
    try std.testing.expectEqual(RowKind.service, all.kind);
    try std.testing.expectEqual(@as(?Target, null), hidden);
    try std.testing.expectEqual(@as(?Target, null), unselected);
    try std.testing.expectEqual(RowKind.docker, compose.kind);
}

test "monitor.lastOutputLine: picks the last visible output line" {
    const cases = [_]struct { output: []const u8, expected: []const u8 }{
        .{ .output = "Session not running. Run 'open' first.\n", .expected = "Session not running. Run 'open' first." },
        .{ .output = "Stopping api...\r  api ... stopping.\r  api ... warning: may not have stopped completely\n\n", .expected = "api ... warning: may not have stopped completely" },
        .{ .output = "", .expected = "WindowMissing" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, lastOutputLine(case.output, "WindowMissing"));
}

test "monitor.runOperation: restarts only the selected service when a group shares its name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||123|sleep\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||123|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("0||123|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const runtime = try testRuntime(arena.allocator(), &recorder,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"api","services":[
        \\    {"name":"api","dir":"api","command":"serve"},
        \\    {"name":"api-worker","dir":"api","command":"work"}
        \\  ]}]
        \\}
    );
    var output: std.Io.Writer.Allocating = .init(arena.allocator());

    const outcome = try runOperation(runtime, .restart, .{ .name = "api", .kind = .service }, &output.writer);

    try std.testing.expectEqual(runtime_mod.Outcome.done, outcome);
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "=demo:=api-worker") == null);
    try proc_runner.expectCommandOrder(&recorder, "C-c", "respawn-pane");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "monitor.runOperation: show selects the docker window for the docker row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("%1\n", "", .{ .exited = 0 });
    const runtime = try testRuntime(arena.allocator(), &recorder,
        \\{"project": {"name":"demo","root":"/tmp/demo"}, "docker": {"compose": "compose.yaml"}, "groups": []}
    );
    var output: std.Io.Writer.Allocating = .init(arena.allocator());

    _ = try runOperation(runtime, .show, .{ .name = "docker", .kind = .docker }, &output.writer);

    const select = proc_runner.findCommandContaining(&recorder, "select-window") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArgv(select, &.{ "tmux", "select-window", "-t", "=demo:=docker" });
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "attach-session") == null);
}

test "monitor.runOperation: stop reports a missing session without signaling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "can't find session: demo\n", .{ .exited = 1 });
    const runtime = try testRuntime(arena.allocator(), &recorder,
        \\{"project": {"name":"demo","root":"/tmp/demo"}, "groups": [{"name":"backend","services":[{"name":"api","command":"serve"}]}]}
    );
    var output: std.Io.Writer.Allocating = .init(arena.allocator());

    const result = runOperation(runtime, .stop, .{ .name = "api", .kind = .service }, &output.writer);

    try std.testing.expectError(error.SessionNotRunning, result);
    try std.testing.expectEqualStrings("Session not running. Run 'open' first.", lastOutputLine(output.writer.buffered(), "SessionNotRunning"));
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "send-keys") == null);
}

test "monitor.selectedTarget: a service named docker stays apart from Compose" {
    var compose_row = testRow("docker", .live);
    compose_row.kind = .docker;
    const rows = [_]MonitorRow{ compose_row, testRow("docker", .dead) };
    var service = try testSelection("docker");
    defer service.deinit(std.testing.allocator);
    var compose = try testSelection(docker_selection_key);
    defer compose.deinit(std.testing.allocator);

    const service_target = selectedTarget(.{ .rows = &rows }, service) orelse return error.MissingTarget;
    const compose_target = selectedTarget(.{ .rows = &rows }, compose) orelse return error.MissingTarget;
    const compose_hidden = selectedTarget(.{ .rows = &rows, .mode = .bad }, compose);

    try std.testing.expectEqual(RowKind.service, service_target.kind);
    try std.testing.expectEqual(RowKind.docker, compose_target.kind);
    try std.testing.expectEqual(@as(?Target, null), compose_hidden);
}

test "monitor.render: highlights the service named docker, not Compose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var compose_row = testRow("docker", .live);
    compose_row.kind = .docker;
    compose_row.port = "compose";
    const rows = [_]MonitorRow{ compose_row, testRow("docker", .dead) };

    const body = try testRender(arena.allocator(), .{ .rows = &rows }, .{ .selected = "docker" });

    const selected = testSelectedLine(body) orelse return error.MissingSelectedRow;
    try std.testing.expect(std.mem.indexOf(u8, selected, "compose") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, ansi.reverse));
}

test "monitor.runOperation: reports an unfinished stop as incomplete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||123|sleep\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    for (0..testStopAttempts()) |_| try recorder.enqueue("0||123|sleep\n", "", .{ .exited = 0 });
    const runtime = try testRuntime(arena.allocator(), &recorder,
        \\{"project": {"name":"demo","root":"/tmp/demo"}, "groups": [{"name":"backend","services":[{"name":"api","command":"serve"}]}]}
    );
    var output: std.Io.Writer.Allocating = .init(arena.allocator());

    const outcome = try runOperation(runtime, .stop, .{ .name = "api", .kind = .service }, &output.writer);

    try std.testing.expectEqual(runtime_mod.Outcome.incomplete, outcome);
    try std.testing.expectEqualStrings("api ... warning: may not have stopped completely", lastOutputLine(output.writer.buffered(), ""));
}

test "monitor: completed start keeps log failure and readiness warnings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    var recorder = proc_runner.Recorder.init(gpa);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("1|0|123|serve\n", "", .{ .exited = 0 });
    var runtime = try testRuntime(gpa, &recorder,
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]}
    );
    runtime.runner_impl.io = std.testing.io;
    runtime.service_log_dir = try std.fs.path.join(gpa, &.{ root, "blocked", "logs" });
    var output: std.Io.Writer.Allocating = .init(gpa);

    const outcome = try runOperation(runtime, .start, .{ .name = "api", .kind = .service }, &output.writer);
    var monitor: Monitor = undefined;
    monitor.setCompletedNotice(.start, "api", output.writer.buffered());

    try std.testing.expectEqual(runtime_mod.Outcome.done, outcome);
    try std.testing.expect(std.mem.indexOf(u8, monitor.notice.?, "started api") != null);
    try std.testing.expect(std.mem.indexOf(u8, monitor.notice.?, "has no port") != null);
    try std.testing.expect(std.mem.indexOf(u8, monitor.notice.?, "output is not saved") != null);
}

test "monitor: completed stop keeps the warning that file watch may restart it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "blocked", .data = "not a directory" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    var recorder = proc_runner.Recorder.init(gpa);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||123|serve\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||123|sh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    var runtime = try testRuntime(gpa, &recorder,
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]}
    );
    runtime.stop_marks = .{
        .io = std.testing.io,
        .dir = try std.fs.path.join(gpa, &.{ root, "blocked", "marks" }),
    };
    var output: std.Io.Writer.Allocating = .init(gpa);

    const outcome = try runOperation(runtime, .stop, .{ .name = "api", .kind = .service }, &output.writer);
    var monitor: Monitor = undefined;
    monitor.setCompletedNotice(.stop, "api", output.writer.buffered());

    try std.testing.expectEqual(runtime_mod.Outcome.done, outcome);
    try std.testing.expect(std.mem.indexOf(u8, monitor.notice.?, "stopped api") != null);
    try std.testing.expect(std.mem.indexOf(u8, monitor.notice.?, "file watch may restart it") != null);
    try proc_runner.expectNoRemainingResponses(&recorder);
}
