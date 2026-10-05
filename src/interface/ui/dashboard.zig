const std = @import("std");
const ansi = @import("ansi.zig");
const clock = @import("../../platform/clock.zig");
const config = @import("../../model/config.zig");
const env = @import("../../platform/env.zig");
const monitor = @import("monitor.zig");
const observations = @import("../../model/observations.zig");
const proc_runner = @import("../../platform/runner.zig");
const service_observation = @import("../../workflow/service_observation.zig");
const terminal = @import("../../platform/terminal.zig");
const tmux_client = @import("../../platform/tmux.zig");
const RenderContext = @import("context.zig").RenderContext;
const Runtime = @import("../../workflow/runtime.zig").Runtime;

pub fn runLauncher(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map, cfg: config.Config, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const run: proc_runner.Runner = .{ .gpa = scratch, .io = io };
    const ctx: RenderContext = .{ .gpa = scratch, .cfg = cfg, .runner = run, .tmux = .{ .gpa = scratch, .runner = run, .session = try cfg.projectName() } };

    try writer.writeAll(ansi.clear_screen);
    try writer.print("{s}Opening {s}...{s}\n", .{ ansi.dim, try cfg.projectName(), ansi.reset });
    try writer.flush();
    const poll_runner: proc_runner.Runner = .{ .gpa = std.heap.smp_allocator, .io = io };
    waitForAttachedClient(.{ .gpa = std.heap.smp_allocator, .runner = poll_runner, .session = try cfg.projectName() }, poll_runner);
    ctx.runner.sleep(attach_resize_settle);

    const snapshot = try observeSnapshot(scratch, cfg, ctx.observer());
    try writer.writeAll(ansi.clear_screen);
    try renderLauncher(scratch, .{
        .project = try cfg.projectName(),
        .width = terminal.columns(io, std.Io.File.stdout()) orelse default_width,
        .observed_time = clock.localClockTime(snapshot.observed_at),
    }, snapshot, writer);
    try writer.flush();

    const shell = env.get(environ, "SHELL") orelse "sh";
    _ = try ctx.runner.run(&.{shell}, .{ .interactive = true });
}

pub fn runMonitor(runtime: Runtime, writer: *std.Io.Writer) !void {
    try monitor.run(runtime, writer);
}

const default_width = 80;
const client_poll_interval: std.Io.Duration = .fromMilliseconds(250);
const attach_resize_settle: std.Io.Duration = .fromMilliseconds(500);
const max_name_width = 16;
const min_name_width = 4;

fn waitForAttachedClient(tmux: tmux_client.Client, runner: proc_runner.Runner) void {
    while (true) {
        const clients = tmux.listClients() catch return;
        defer tmux_client.freeClientInfos(tmux.gpa, clients);
        if (clients.len > 0) return;
        runner.sleep(client_poll_interval);
    }
}

const EntryState = enum {
    exited,
    degraded,
    unknown,
    waiting,
    stopped,
    running,

    const display_order = [_]EntryState{ .exited, .degraded, .unknown, .waiting, .running, .stopped };

    fn needsAttention(self: EntryState) bool {
        return switch (self) {
            .exited, .degraded, .unknown, .waiting => true,
            .stopped, .running => false,
        };
    }

    fn icon(self: EntryState) []const u8 {
        return switch (self) {
            .running => "●",
            .waiting => "◐",
            .degraded => "▲",
            .stopped => "○",
            .exited => "✗",
            .unknown => "?",
        };
    }

    fn color(self: EntryState) []const u8 {
        return switch (self) {
            .running => ansi.green,
            .waiting => ansi.cyan,
            .degraded => ansi.yellow,
            .stopped => ansi.dim,
            .exited => ansi.red,
            .unknown => ansi.dim,
        };
    }

    fn label(self: EntryState) []const u8 {
        return @tagName(self);
    }
};

const EntryKind = enum {
    service,
    docker,
};

const Entry = struct {
    name: []const u8,
    kind: EntryKind,
    state: EntryState,
    exit_code: []const u8 = "",
};

const Snapshot = struct {
    observed_at: i64,
    entries: []const Entry,
};

fn observeSnapshot(gpa: std.mem.Allocator, cfg: config.Config, observer: service_observation.Observer) !Snapshot {
    var entries: std.ArrayList(Entry) = .empty;
    const observed_at = observer.runner.nowSeconds();
    if (cfg.dockerEnabled()) {
        const observation = observer.observeDocker();
        defer observation.deinit(observer.gpa);
        try entries.append(gpa, .{ .name = "docker", .kind = .docker, .state = dockerState(observation), .exit_code = try gpa.dupe(u8, observation.pane.exit_code) });
    }
    for (try cfg.services()) |service| {
        const observation = try observer.observeService(service);
        defer observation.deinit(observer.gpa);
        try entries.append(gpa, .{ .name = try config.Config.serviceName(service), .kind = .service, .state = serviceState(observation), .exit_code = try gpa.dupe(u8, observation.pane.exit_code) });
    }
    return .{ .observed_at = observed_at, .entries = try entries.toOwnedSlice(gpa) };
}

fn serviceState(observation: observations.ServiceObservation) EntryState {
    return switch (observation.health()) {
        .not_running => if (observation.pane.state == .dead) .exited else .stopped,
        .no_check, .ready => .running,
        .waiting => .waiting,
        .degraded => .degraded,
        .unavailable => .unknown,
    };
}

fn dockerState(observation: observations.DockerObservation) EntryState {
    return switch (observation.pane.state) {
        .dead => .exited,
        .idle, .window_missing => .stopped,
        .tmux_unavailable => .unknown,
        .busy => switch (observation.compose.state) {
            .running => .running,
            .empty => .waiting,
            .unavailable => .unknown,
        },
    };
}

const Situation = enum {
    no_services,
    not_started,
    needs_attention,
    running,
};

fn situationFor(entries: []const Entry) Situation {
    if (entries.len == 0) return .no_services;
    var any_running = false;
    for (entries) |entry| {
        if (entry.state.needsAttention()) return .needs_attention;
        if (entry.state == .running) any_running = true;
    }
    return if (any_running) .running else .not_started;
}

const Action = struct {
    keys: []const u8,
    description: []const u8,
};

fn situationMessage(situation: Situation) ?[]const u8 {
    return switch (situation) {
        .no_services => "No services are configured. Add them to the config and run 'zask re'.",
        .not_started => "Nothing is running yet.",
        .needs_attention, .running => null,
    };
}

fn situationActions(situation: Situation) []const Action {
    return switch (situation) {
        .no_services => &.{},
        .not_started => &.{
            .{ .keys = "zask start --all", .description = "start everything" },
            .{ .keys = "zask start <svc>", .description = "start one service" },
        },
        .needs_attention => &.{
            .{ .keys = "zask logs <svc>", .description = "open its window" },
            .{ .keys = "zask restart <svc>", .description = "restart it" },
        },
        .running => &.{
            .{ .keys = "zask logs <svc>", .description = "open its window" },
        },
    };
}

const common_actions = [_]Action{
    .{ .keys = "Ctrl+q w", .description = "choose a window" },
    .{ .keys = "Ctrl+q m", .description = "monitor: all / issues" },
    .{ .keys = "zask help", .description = "all commands" },
};

const Layout = struct {
    project: []const u8,
    width: usize,
    observed_time: ?clock.ClockTime,
};

fn renderLauncher(gpa: std.mem.Allocator, layout: Layout, snapshot: Snapshot, writer: *std.Io.Writer) !void {
    const situation = situationFor(snapshot.entries);
    try writeHeader(layout, writer);
    try writeCounts(layout, snapshot.entries, writer);
    try writer.writeByte('\n');

    if (situation == .needs_attention) try writeAttention(gpa, layout, snapshot.entries, writer);
    try writeNames(gpa, layout, snapshot.entries, .running, "Running", writer);
    try writeNames(gpa, layout, snapshot.entries, .stopped, "Stopped", writer);
    if (situationMessage(situation)) |message| {
        try writeWrappedText(writer, layout.width, message);
    }
    try writer.writeByte('\n');

    try writer.print("{s}Next{s}\n", .{ ansi.bold, ansi.reset });
    const actions = situationActions(situation);
    const keys_width = actionKeysWidth(actions);
    for (actions) |action| try writeAction(layout, action, keys_width, writer);
    for (common_actions) |action| try writeAction(layout, action, keys_width, writer);
    try writer.writeByte('\n');

    try writeWrappedText(writer, layout.width, "The monitor pane keeps this up to date.");
    const named = try std.fmt.allocPrint(gpa, "From elsewhere: zask {s} <command>", .{layout.project});
    try writer.print("{s}", .{ansi.dim});
    try writeWrappedText(writer, layout.width, named);
    try writer.print("{s}", .{ansi.reset});
}

fn writeHeader(layout: Layout, writer: *std.Io.Writer) !void {
    try writer.print("{s}{s}{s}{s}", .{ ansi.bold, ansi.cyan, ansi.truncate(layout.project, layout.width), ansi.reset });
    const time = layout.observed_time orelse return writer.writeByte('\n');
    var buffer: [16]u8 = undefined;
    const as_of = try std.fmt.bufPrint(&buffer, "as of {d:0>2}:{d:0>2}:{d:0>2}", .{ time.hour, time.minute, time.second });
    if (displayWidth(layout.project) + 2 + as_of.len <= layout.width) {
        try writer.print("  {s}{s}{s}\n", .{ ansi.dim, as_of, ansi.reset });
    } else {
        try writer.print("\n{s}{s}{s}\n", .{ ansi.dim, as_of, ansi.reset });
    }
}

fn writeCounts(layout: Layout, entries: []const Entry, writer: *std.Io.Writer) !void {
    if (entries.len == 0) return;
    var buffers: [EntryState.display_order.len][32]u8 = undefined;
    var spans: [EntryState.display_order.len]Span = undefined;
    var span_count: usize = 0;
    for (EntryState.display_order) |state| {
        const count = countState(entries, state);
        if (count == 0) continue;
        spans[span_count] = .{
            .text = try std.fmt.bufPrint(&buffers[span_count], "{s} {d} {s}", .{ state.icon(), count, state.label() }),
            .color = state.color(),
        };
        span_count += 1;
    }
    try writeFlow(writer, layout.width, 0, 0, spans[0..span_count], "  ");
}

fn writeAttention(gpa: std.mem.Allocator, layout: Layout, entries: []const Entry, writer: *std.Io.Writer) !void {
    try writer.print("{s}Needs attention{s}\n", .{ ansi.bold, ansi.reset });
    var name_width: usize = 0;
    var state_width: usize = 0;
    for (entries) |entry| {
        if (!entry.state.needsAttention()) continue;
        name_width = @max(name_width, @min(displayWidth(entry.name), max_name_width));
        state_width = @max(state_width, (try stateText(gpa, entry)).len);
    }
    for (EntryState.display_order) |state| {
        if (!state.needsAttention()) continue;
        for (entries) |entry| {
            if (entry.state != state) continue;
            try writeAttentionRow(gpa, layout, entry, name_width, state_width, writer);
        }
    }
}

fn writeAttentionRow(gpa: std.mem.Allocator, layout: Layout, entry: Entry, name_width: usize, state_width: usize, writer: *std.Io.Writer) !void {
    const state_text = try stateText(gpa, entry);
    const hint = try windowHint(gpa, entry);
    const fixed = "  ".len + 2 + 1 + state_width;
    const with_hint = fixed + name_width + 2 + displayWidth(hint);
    const show_hint = with_hint <= layout.width;
    const room = if (layout.width > fixed) layout.width - fixed else 0;
    const shown_name_width = if (show_hint) name_width else @max(@min(name_width, room), min_name_width);

    try writer.print("  {s}{s}{s} ", .{ entry.state.color(), entry.state.icon(), ansi.reset });
    try ansi.writePadded(writer, ansi.truncate(entry.name, shown_name_width), shown_name_width);
    try writer.print(" {s}", .{entry.state.color()});
    try ansi.writePadded(writer, state_text, state_width);
    try writer.print("{s}", .{ansi.reset});
    if (show_hint) try writer.print("  {s}{s}{s}", .{ ansi.dim, hint, ansi.reset });
    try writer.writeByte('\n');
}

fn stateText(gpa: std.mem.Allocator, entry: Entry) ![]const u8 {
    if (entry.state == .exited and entry.exit_code.len > 0) {
        return std.fmt.allocPrint(gpa, "exited {s}", .{entry.exit_code});
    }
    return entry.state.label();
}

fn windowHint(gpa: std.mem.Allocator, entry: Entry) ![]const u8 {
    return switch (entry.kind) {
        .service => std.fmt.allocPrint(gpa, "zask logs {s}", .{entry.name}),
        .docker => "window: docker",
    };
}

fn writeNames(gpa: std.mem.Allocator, layout: Layout, entries: []const Entry, state: EntryState, title: []const u8, writer: *std.Io.Writer) !void {
    var spans: std.ArrayList(Span) = .empty;
    for (entries) |entry| {
        if (entry.state == state) try spans.append(gpa, .{ .text = entry.name });
    }
    if (spans.items.len == 0) return;
    const label_width = "Running  ".len;
    try writer.print("{s}{s}{s}", .{ state.color(), title, ansi.reset });
    try ansi.writeSpaces(writer, label_width - title.len);
    try writeFlow(writer, layout.width, label_width, label_width, spans.items, ", ");
}

fn writeAction(layout: Layout, action: Action, keys_width: usize, writer: *std.Io.Writer) !void {
    try writer.print("  {s}{s}{s}", .{ ansi.green, action.keys, ansi.reset });
    const aligned = 2 + keys_width + 2 + action.description.len <= layout.width;
    const compact = 2 + action.keys.len + 2 + action.description.len <= layout.width;
    if (aligned or compact) {
        try ansi.writeSpaces(writer, (if (aligned) keys_width else action.keys.len) - action.keys.len + 2);
        try writer.print("{s}\n", .{action.description});
        return;
    }
    try writer.print("\n    {s}\n", .{ansi.truncate(action.description, if (layout.width > 4) layout.width - 4 else 0)});
}

fn actionKeysWidth(situation_actions: []const Action) usize {
    var width: usize = 0;
    for (situation_actions) |action| width = @max(width, action.keys.len);
    for (common_actions) |action| width = @max(width, action.keys.len);
    return width;
}

fn countState(entries: []const Entry, state: EntryState) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entry.state == state) count += 1;
    }
    return count;
}

const Span = struct {
    text: []const u8,
    color: []const u8 = "",
};

fn writeFlow(writer: *std.Io.Writer, width: usize, indent: usize, start: usize, spans: []const Span, separator: []const u8) !void {
    var column = start;
    const line_room = if (width > indent) width - indent else 0;
    for (spans, 0..) |span, index| {
        const text = ansi.truncate(span.text, line_room);
        if (index > 0) {
            if (column + separator.len + displayWidth(text) > width) {
                try writer.writeByte('\n');
                try ansi.writeSpaces(writer, indent);
                column = indent;
            } else {
                try writer.writeAll(separator);
                column += separator.len;
            }
        }
        if (span.color.len > 0) {
            try writer.print("{s}{s}{s}", .{ span.color, text, ansi.reset });
        } else {
            try writer.writeAll(text);
        }
        column += displayWidth(text);
    }
    try writer.writeByte('\n');
}

fn writeWrappedText(writer: *std.Io.Writer, width: usize, text: []const u8) !void {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var column: usize = 0;
    while (words.next()) |word| {
        if (column > 0 and column + 1 + displayWidth(word) > width) {
            try writer.writeByte('\n');
            column = 0;
        } else if (column > 0) {
            try writer.writeByte(' ');
            column += 1;
        }
        try writer.writeAll(word);
        column += displayWidth(word);
    }
    try writer.writeByte('\n');
}

fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_layout: Layout = .{ .project = "demo", .width = 80, .observed_time = .{ .hour = 9, .minute = 5, .second = 7 } };

fn testRender(gpa: std.mem.Allocator, layout: Layout, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    try renderLauncher(gpa, layout, .{ .observed_at = 0, .entries = entries }, &out.writer);
    return testStripAnsi(gpa, out.writer.buffered());
}

fn testStripAnsi(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    var plain: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            while (index < text.len and text[index] != 'm') index += 1;
            index += 1;
            continue;
        }
        try plain.append(gpa, text[index]);
        index += 1;
    }
    return plain.toOwnedSlice(gpa);
}

fn testExpectContains(body: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print("missing: {s}\n--- body ---\n{s}\n", .{ needle, body });
        return error.TestExpectedContains;
    }
}

fn testExpectNotContains(body: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, body, needle) != null) {
        std.debug.print("unexpected: {s}\n--- body ---\n{s}\n", .{ needle, body });
        return error.TestExpectedNotContains;
    }
}

fn testRecorderRunner(gpa: std.mem.Allocator, recorder: *proc_runner.Recorder) proc_runner.Runner {
    return .{ .gpa = gpa, .io = undefined, .recorder = recorder };
}

test "dashboard.waitForAttachedClient: polls until a client attaches" {
    var recorder = proc_runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("/dev/ttys001\n", "", .{ .exited = 0 });
    const run = testRecorderRunner(std.testing.allocator, &recorder);

    waitForAttachedClient(.{ .gpa = std.testing.allocator, .runner = run, .session = "demo" }, run);

    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try proc_runner.expectCommandArgvStartsWith(recorder.commands.items[1], &.{ "tmux", "list-clients", "-t", "=demo:" });
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "dashboard.waitForAttachedClient: stops when clients cannot be listed" {
    var recorder = proc_runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "no server running", .{ .exited = 1 });
    const run = testRecorderRunner(std.testing.allocator, &recorder);

    waitForAttachedClient(.{ .gpa = std.testing.allocator, .runner = run, .session = "demo" }, run);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), recorder.sleeps.items.len);
}

test "dashboard.serviceState: maps shared observation to entry state" {
    const cases = [_]struct {
        pane: observations.PaneState,
        listen: observations.ProbeObservation,
        http: observations.ProbeObservation = .not_configured,
        expected: EntryState,
    }{
        .{ .pane = .busy, .listen = .passed, .expected = .running },
        .{ .pane = .busy, .listen = .not_configured, .expected = .running },
        .{ .pane = .busy, .listen = .failed, .expected = .waiting },
        .{ .pane = .busy, .listen = .passed, .http = .failed, .expected = .degraded },
        .{ .pane = .busy, .listen = .unavailable, .expected = .unknown },
        .{ .pane = .tmux_unavailable, .listen = .not_observed, .expected = .unknown },
        .{ .pane = .dead, .listen = .not_observed, .expected = .exited },
        .{ .pane = .idle, .listen = .not_observed, .expected = .stopped },
        .{ .pane = .window_missing, .listen = .not_observed, .expected = .stopped },
    };

    for (cases) |case| {
        const observation: observations.ServiceObservation = .{ .pane = .{ .state = case.pane }, .port = 3000, .listen = case.listen, .http = case.http, .observed_at = 0 };
        try std.testing.expectEqual(case.expected, serviceState(observation));
    }
}

test "dashboard.dockerState: maps pane and compose state to entry state" {
    const cases = [_]struct {
        pane: observations.PaneState,
        compose: observations.ComposeState = .empty,
        expected: EntryState,
    }{
        .{ .pane = .busy, .compose = .running, .expected = .running },
        .{ .pane = .busy, .compose = .empty, .expected = .waiting },
        .{ .pane = .busy, .compose = .unavailable, .expected = .unknown },
        .{ .pane = .dead, .expected = .exited },
        .{ .pane = .idle, .expected = .stopped },
        .{ .pane = .window_missing, .expected = .stopped },
        .{ .pane = .tmux_unavailable, .expected = .unknown },
    };

    for (cases) |case| {
        const observation: observations.DockerObservation = .{ .pane = .{ .state = case.pane }, .compose = .{ .state = case.compose }, .observed_at = 0 };
        try std.testing.expectEqual(case.expected, dockerState(observation));
    }
}

test "dashboard.situationFor: picks the next step from entry states" {
    const running: Entry = .{ .name = "api", .kind = .service, .state = .running };
    const stopped: Entry = .{ .name = "web", .kind = .service, .state = .stopped };
    const waiting: Entry = .{ .name = "web", .kind = .service, .state = .waiting };
    const exited: Entry = .{ .name = "web", .kind = .service, .state = .exited };
    const cases = [_]struct {
        name: []const u8,
        entries: []const Entry,
        expected: Situation,
    }{
        .{ .name = "empty", .entries = &.{}, .expected = .no_services },
        .{ .name = "all stopped", .entries = &.{ stopped, stopped }, .expected = .not_started },
        .{ .name = "partly running", .entries = &.{ running, stopped }, .expected = .running },
        .{ .name = "waiting", .entries = &.{ running, waiting }, .expected = .needs_attention },
        .{ .name = "exited among stopped", .entries = &.{ stopped, exited }, .expected = .needs_attention },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.expected, situationFor(case.entries));
    }
}

test "dashboard.observeSnapshot: reads docker and services through the shared observer" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":"api","command":"serve"},
        \\    {"name":"worker","dir":"worker","command":"work"}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.now_seconds = 1_234;
    try recorder.enqueue("0||12345|docker|900\n", "", .{ .exited = 0 });
    try recorder.enqueue("db\n", "", .{ .exited = 0 });
    try recorder.enqueue("0||12346|node|900\n", "", .{ .exited = 0 });
    try recorder.enqueue("1|2|12347|node|900\n", "", .{ .exited = 0 });
    const run = testRecorderRunner(arena.allocator(), &recorder);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: RenderContext = .{ .gpa = arena.allocator(), .cfg = cfg, .runner = run, .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" } };

    const snapshot = try observeSnapshot(arena.allocator(), cfg, ctx.observer());

    try std.testing.expectEqual(@as(i64, 1_234), snapshot.observed_at);
    try std.testing.expectEqual(@as(usize, 3), snapshot.entries.len);
    try std.testing.expectEqual(EntryKind.docker, snapshot.entries[0].kind);
    try std.testing.expectEqual(EntryState.running, snapshot.entries[0].state);
    try std.testing.expectEqual(EntryState.running, snapshot.entries[1].state);
    try std.testing.expectEqual(EntryState.exited, snapshot.entries[2].state);
    try std.testing.expectEqualStrings("2", snapshot.entries[2].exit_code);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "dashboard.renderLauncher: shows observation time and counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try testRender(arena.allocator(), test_layout, &.{
        .{ .name = "api", .kind = .service, .state = .running },
        .{ .name = "web", .kind = .service, .state = .running },
        .{ .name = "worker", .kind = .service, .state = .stopped },
    });

    try testExpectContains(body, "demo  as of 09:05:07\n");
    try testExpectContains(body, "● 2 running  ○ 1 stopped\n");
    try testExpectContains(body, "Running  api, web\n");
    try testExpectContains(body, "Stopped  worker\n");
    try testExpectContains(body, "zask logs <svc>");
    try testExpectContains(body, "Ctrl+q m");
    try testExpectContains(body, "zask help");
    try testExpectContains(body, "zask demo <command>");
    try testExpectNotContains(body, "Needs attention");
}

test "dashboard.renderLauncher: omits time when local time is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var layout = test_layout;
    layout.observed_time = null;

    const body = try testRender(arena.allocator(), layout, &.{.{ .name = "api", .kind = .service, .state = .running }});

    try std.testing.expect(std.mem.startsWith(u8, body, "demo\n"));
    try testExpectNotContains(body, "as of");
}

test "dashboard.renderLauncher: points failing services at their windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try testRender(arena.allocator(), test_layout, &.{
        .{ .name = "docker", .kind = .docker, .state = .unknown },
        .{ .name = "api", .kind = .service, .state = .waiting },
        .{ .name = "web", .kind = .service, .state = .exited, .exit_code = "137" },
        .{ .name = "worker", .kind = .service, .state = .running },
    });

    try testExpectContains(body, "Needs attention\n  ✗ web    exited 137  zask logs web\n  ? docker unknown     window: docker\n  ◐ api    waiting     zask logs api\n");
    try testExpectContains(body, "zask restart <svc>");
    try testExpectContains(body, "Running  worker\n");
}

test "dashboard.renderLauncher: suggests starting when nothing runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try testRender(arena.allocator(), test_layout, &.{
        .{ .name = "api", .kind = .service, .state = .stopped },
        .{ .name = "web", .kind = .service, .state = .stopped },
    });

    try testExpectContains(body, "Nothing is running yet.");
    try testExpectContains(body, "zask start --all");
    try testExpectNotContains(body, "zask restart <svc>");
}

test "dashboard.renderLauncher: explains an empty workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const body = try testRender(arena.allocator(), test_layout, &.{});

    try testExpectContains(body, "No services are configured.");
    try testExpectContains(body, "zask help");
    try testExpectNotContains(body, "zask start --all");
}

test "dashboard.renderLauncher: keeps every line within a narrow pane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = [_]Entry{
        .{ .name = "notification-service", .kind = .service, .state = .exited, .exit_code = "1" },
        .{ .name = "api", .kind = .service, .state = .waiting },
        .{ .name = "frontend", .kind = .service, .state = .running },
        .{ .name = "admin-dashboard", .kind = .service, .state = .running },
        .{ .name = "background-jobs", .kind = .service, .state = .stopped },
        .{ .name = "mailer", .kind = .service, .state = .stopped },
    };

    for ([_]usize{ 24, 30, 40 }) |width| {
        errdefer std.debug.print("width: {d}\n", .{width});
        var layout = test_layout;
        layout.width = width;

        const body = try testRender(arena.allocator(), layout, &entries);

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            errdefer std.debug.print("line: {s}\n", .{line});
            try std.testing.expect(displayWidth(line) <= width);
        }
        try testExpectContains(body, "Needs attention");
        try testExpectContains(body, "Ctrl+q m");
    }
}
