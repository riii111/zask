const std = @import("std");
const observations = @import("../model/observations.zig");
const runner = @import("runner.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    session: []const u8,
    tmux_path: []const u8 = "tmux",

    pub fn hasSession(self: Client) bool {
        return self.observeSession() == .active;
    }

    pub fn observeSession(self: Client) observations.SessionObservation {
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "has-session", "-t", self.session }, .{}) catch return .unavailable);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return .active;
        if (result.term == .exited) return if (serverUnavailable(result.stderr)) .unavailable else .missing;
        return .unavailable;
    }

    pub fn newSession(self: Client, window_name: []const u8, cwd: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "new-session", "-d", "-s", self.session, "-n", window_name, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    pub fn killSession(self: Client) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "kill-session", "-t", self.session }, .{ .check = true, .discard = true });
    }

    pub fn switchClient(self: Client) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "switch-client", "-t", self.session }, .{ .check = true, .discard = true });
    }

    pub fn attachSession(self: Client) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "attach-session", "-t", self.session }, .{ .interactive = true, .check = true });
    }

    pub fn detachClientExec(self: Client, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client", "-E", command }, .{ .check = true, .discard = true });
    }

    pub fn detachTargetClientExec(self: Client, client_name: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client", "-t", client_name, "-E", command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice; free it with freeClientInfos.
    pub fn listClients(self: Client) ![]ClientInfo {
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "list-clients", "-t", self.session, "-F", "#{client_name}" }, .{ .check = true }));
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

        var clients: std.ArrayList(ClientInfo) = .empty;
        errdefer {
            for (clients.items) |client| client.deinit(self.gpa);
            clients.deinit(self.gpa);
        }

        // Lenient parse: single-column output, so there is no field-count
        // contract to break; blank lines are skipped and the rest are kept.
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t\r\n");
            if (name.len == 0) continue;
            try clients.ensureUnusedCapacity(self.gpa, 1);
            clients.appendAssumeCapacity(.{ .name = try self.gpa.dupe(u8, name) });
        }

        return try clients.toOwnedSlice(self.gpa);
    }

    pub fn windowExists(self: Client, window: []const u8) bool {
        return self.observeWindow(window) == .present;
    }

    pub fn observeWindow(self: Client, window: []const u8) observations.WindowObservation {
        const pane_target = self.target(window) catch return .unavailable;
        defer self.gpa.free(pane_target);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "list-panes", "-t", pane_target }, .{}) catch return .unavailable);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return .present;
        if (result.term == .exited) return if (serverUnavailable(result.stderr)) .unavailable else .missing;
        return .unavailable;
    }

    pub fn newWindow(self: Client, window_name: []const u8, cwd: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "new-window", "-d", "-t", self.session, "-n", window_name, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    pub fn newWindowAfter(self: Client, after_window: []const u8, window_name: []const u8, cwd: []const u8, command: []const u8) !void {
        const target_window = try self.target(after_window);
        defer self.gpa.free(target_window);
        _ = try self.runner.run(&.{ self.tmux_path, "new-window", "-d", "-a", "-t", target_window, "-n", window_name, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice; free it with freeWindowSizes.
    pub fn listWindowSizes(self: Client) ![]WindowSize {
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "list-windows", "-t", self.session, "-F", "#{window_id}|#{window_width}|#{window_height}" }, .{ .check = true }));
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

        var windows: std.ArrayList(WindowSize) = .empty;
        errdefer {
            for (windows.items) |window| window.deinit(self.gpa);
            windows.deinit(self.gpa);
        }

        // Strict parse: format is fixed, so a field-count or numeric mismatch is
        // a contract violation (error) rather than a silently defaulted value.
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '|');
            const id = fields.next() orelse return error.InvalidWindowSizeOutput;
            const width_text = fields.next() orelse return error.InvalidWindowSizeOutput;
            const height_text = fields.next() orelse return error.InvalidWindowSizeOutput;
            if (fields.next() != null) return error.InvalidWindowSizeOutput;
            const width = std.fmt.parseUnsigned(u16, width_text, 10) catch return error.InvalidWindowSizeOutput;
            const height = std.fmt.parseUnsigned(u16, height_text, 10) catch return error.InvalidWindowSizeOutput;
            try windows.ensureUnusedCapacity(self.gpa, 1);
            const owned_id = try self.gpa.dupe(u8, id);
            windows.appendAssumeCapacity(.{
                .id = owned_id,
                .width = width,
                .height = height,
            });
        }

        return try windows.toOwnedSlice(self.gpa);
    }

    pub fn resizeWindow(self: Client, target_window: []const u8, width: u16, height: u16) !void {
        const width_text = try std.fmt.allocPrint(self.gpa, "{d}", .{width});
        defer self.gpa.free(width_text);
        const height_text = try std.fmt.allocPrint(self.gpa, "{d}", .{height});
        defer self.gpa.free(height_text);
        _ = try self.runner.run(&.{ self.tmux_path, "resize-window", "-x", width_text, "-y", height_text, "-t", target_window }, .{ .check = true, .discard = true });
    }

    pub fn restoreWindowAutoSize(self: Client, target_window: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-w", "-t", target_window, "window-size", "latest" }, .{ .check = true, .discard = true });
    }

    pub fn splitWindow(self: Client, window: []const u8, cwd: []const u8, command: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        _ = try self.runner.run(&.{ self.tmux_path, "split-window", "-t", pane_target, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    pub fn selectWindow(self: Client, window: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        _ = try self.runner.run(&.{ self.tmux_path, "select-window", "-t", pane_target }, .{ .check = true, .discard = true });
    }

    pub fn selectLayout(self: Client, window: []const u8, layout: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        _ = try self.runner.run(&.{ self.tmux_path, "select-layout", "-t", pane_target, layout }, .{ .check = true, .discard = true });
    }

    pub fn setWindowOption(self: Client, window: []const u8, name: []const u8, value: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        _ = try self.runner.run(&.{ self.tmux_path, "set-window-option", "-t", pane_target, name, value }, .{ .check = true, .discard = true });
    }

    pub fn paneRunning(self: Client, window: []const u8) bool {
        const observation = self.observePane(window);
        defer observation.deinit(self.gpa);
        return observation.running();
    }

    pub fn observePane(self: Client, window: []const u8) observations.PaneObservation {
        const info = self.paneInfo(window) catch |err| switch (err) {
            error.WindowMissing => return observations.PaneObservation.empty(.window_missing),
            else => return observations.PaneObservation.empty(.tmux_unavailable),
        };
        if (info.dead) return info.consumeIntoObservation(.dead);
        if (!isShellCommand(info.command)) return info.consumeIntoObservation(.busy);
        const run_result = self.runner.run(&.{ "pgrep", "-P", info.pid }, .{}) catch return info.consumeIntoObservation(.tmux_unavailable);
        const result = runner.captured(run_result);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const state: observations.PaneState = if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) .busy else .idle;
        return info.consumeIntoObservation(state);
    }

    /// Returns pane fields owned by the result; caller must deinit, unless the
    /// value is moved into an observation via consumeIntoObservation.
    pub fn paneInfo(self: Client, window: []const u8) !PaneInfo {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "list-panes", "-t", pane_target, "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}" }, .{}) catch return error.TmuxUnavailable);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited != 0) return if (serverUnavailable(result.stderr)) error.TmuxUnavailable else error.WindowMissing;

        // Lenient parse (intentional, unlike listWindowSizes): this query fixes
        // its own four-field format, and pane_dead_status is legitimately empty
        // for live panes ("0||pid|cmd"). observePane runs on a hot path, so a
        // truncated or unexpected line degrades to defaults rather than aborting
        // the surrounding lifecycle. Extra pane lines from split windows are
        // ignored; only the first pane is observed.
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        const line = lines.next() orelse "";
        var fields = std.mem.splitScalar(u8, line, '|');
        const dead = fields.next() orelse "0";
        const exit_code = fields.next() orelse "0";
        const pid = fields.next() orelse "0";
        const command = fields.next() orelse "";
        return PaneInfo.init(self.gpa, std.mem.eql(u8, dead, "1"), exit_code, pid, command);
    }

    /// Caller owns the returned slice. When the pane cannot be captured an empty
    /// but still owned slice is returned, so the caller frees it the same way in
    /// both cases. An empty result is indistinguishable from a genuinely empty
    /// pane.
    pub fn capturePane(self: Client, window: []const u8) ![]const u8 {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "capture-pane", "-t", pane_target, "-p" }, .{}) catch return self.gpa.dupe(u8, ""));
        defer self.gpa.free(result.stderr);
        return result.stdout;
    }

    /// Caller owns the returned tail; call `deinit` to free every line. Capture
    /// failures are reported as an empty tail so startup diagnostics can still
    /// render the surrounding context.
    pub fn captureTail(self: Client, window: []const u8, max_lines: usize) !PaneTail {
        const pane = try self.capturePane(window);
        defer self.gpa.free(pane);
        return try tailNonEmptyLines(self.gpa, pane, max_lines);
    }

    /// Caller owns the returned slice. Capture failures are reported as an empty
    /// line so startup diagnostics can still render the surrounding context.
    /// The returned line is display-safe, but it may still contain sensitive log
    /// text; callers should keep it brief.
    pub fn captureLastLine(self: Client, window: []const u8) ![]const u8 {
        const tail = try self.captureTail(window, 1);
        defer tail.deinit(self.gpa);
        if (tail.lines.len == 0) return self.gpa.dupe(u8, "");
        return try self.gpa.dupe(u8, tail.lines[0]);
    }

    pub fn sendKeys(self: Client, window: []const u8, keys: []const []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ self.tmux_path, "send-keys", "-t", pane_target });
        try argv.appendSlice(self.gpa, keys);
        _ = try self.runner.run(argv.items, .{ .check = true, .discard = true });
    }

    pub fn respawnPane(self: Client, window: []const u8, cwd: []const u8, command: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const wrapped_command = try self.buildRespawnScript(command);
        defer self.gpa.free(wrapped_command);
        _ = try self.runner.run(&.{ self.tmux_path, "respawn-pane", "-k", "-t", pane_target, "-c", cwd, "sh", "-lc", wrapped_command }, .{ .check = true, .discard = true });
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-t", self.session, name, value }, .{ .check = true, .discard = true });
    }

    pub fn setHook(self: Client, name: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "set-hook", "-t", self.session, name, command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice when the result is non-null.
    pub fn showOption(self: Client, name: []const u8) !?[]const u8 {
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "show-option", "-t", self.session, "-qv", name }, .{}) catch return null);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const value = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (value.len == 0) return null;
        return try self.gpa.dupe(u8, value);
    }

    pub fn bindRunShell(self: Client, key: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "bind-key", "-T", "prefix", key, "run-shell", command }, .{ .check = true, .discard = true });
    }

    pub fn chooseTree(self: Client, pane_id: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "choose-tree", "-Zw", "-t", pane_id }, .{ .check = true, .discard = true });
    }

    fn target(self: Client, window: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ self.session, window });
    }

    fn buildRespawnScript(self: Client, command: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa,
            \\__zask_interrupted=0
            \\trap '__zask_interrupted=1' INT
            \\{s}
            \\__zask_status=$?
            \\# SIGINT may surface only as exit status 130 when the trap is not run.
            \\if [ "$__zask_interrupted" = 1 ] || [ "$__zask_status" = 130 ]; then
            \\  exec "${{SHELL:-sh}}"
            \\fi
            \\exit "$__zask_status"
        , .{command});
    }
};

/// A non-zero tmux exit means "missing" by default: no server / no session is
/// the normal not-yet-opened state. Only treat it as unavailable when the socket
/// exists but cannot be used (permission denied), which is a genuine fault.
fn serverUnavailable(stderr: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(stderr, "permission denied") != null or
        std.ascii.indexOfIgnoreCase(stderr, "operation not permitted") != null;
}

fn tailNonEmptyLines(gpa: std.mem.Allocator, pane: []const u8, max_lines: usize) !PaneTail {
    if (max_lines == 0) return .{ .lines = try gpa.alloc([]const u8, 0) };
    const slots = try gpa.alloc([]const u8, max_lines);
    defer gpa.free(slots);
    var count: usize = 0;
    var next: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < count) : (i += 1) gpa.free(slots[i]);
    }

    var lines = std.mem.splitScalar(u8, pane, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n\x00");
        if (trimmed.len == 0) continue;
        const sanitized = try sanitizeLogLine(gpa, trimmed);
        if (count < max_lines) {
            slots[count] = sanitized;
            count += 1;
            continue;
        }
        gpa.free(slots[next]);
        slots[next] = sanitized;
        next = (next + 1) % max_lines;
    }

    const out = try gpa.alloc([]const u8, count);
    errdefer gpa.free(out);
    const start = if (count == max_lines) next else 0;
    for (out, 0..) |*line, index| {
        line.* = slots[(start + index) % max_lines];
    }
    return .{ .lines = out };
}

fn sanitizeLogLine(gpa: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (line) |byte| {
        if (byte == '\t' or (byte >= 0x20 and byte != 0x7f)) {
            try out.writer.writeByte(byte);
        } else {
            try out.writer.writeByte('?');
        }
    }
    return out.toOwnedSlice();
}

pub const WindowSize = struct {
    id: []const u8,
    width: u16,
    height: u16,

    pub fn deinit(self: WindowSize, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
    }
};

pub fn freeWindowSizes(gpa: std.mem.Allocator, windows: []WindowSize) void {
    for (windows) |window| window.deinit(gpa);
    gpa.free(windows);
}

pub const ClientInfo = struct {
    name: []const u8,

    pub fn deinit(self: ClientInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
    }
};

pub fn freeClientInfos(gpa: std.mem.Allocator, clients: []ClientInfo) void {
    for (clients) |client| client.deinit(gpa);
    gpa.free(clients);
}

pub const PaneTail = struct {
    lines: []const []const u8,

    pub fn deinit(self: PaneTail, gpa: std.mem.Allocator) void {
        for (self.lines) |line| gpa.free(line);
        gpa.free(self.lines);
    }
};

pub const PaneInfo = struct {
    dead: bool,
    exit_code: []const u8,
    pid: []const u8,
    command: []const u8,

    fn init(gpa: std.mem.Allocator, dead: bool, exit_code: []const u8, pid: []const u8, command: []const u8) !PaneInfo {
        const owned_exit_code = try gpa.dupe(u8, exit_code);
        errdefer gpa.free(owned_exit_code);
        const owned_pid = try gpa.dupe(u8, pid);
        errdefer gpa.free(owned_pid);
        const owned_command = try gpa.dupe(u8, command);
        return .{
            .dead = dead,
            .exit_code = owned_exit_code,
            .pid = owned_pid,
            .command = owned_command,
        };
    }

    pub fn deinit(self: PaneInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.exit_code);
        gpa.free(self.pid);
        gpa.free(self.command);
    }

    /// Transfers ownership of pane field slices into the returned observation.
    /// The original PaneInfo must not be deinit'd afterwards.
    fn consumeIntoObservation(self: PaneInfo, state: observations.PaneState) observations.PaneObservation {
        return observations.PaneObservation.fromOwned(state, self.exit_code, self.pid, self.command);
    }
};

pub fn isShellCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "zsh") or std.mem.eql(u8, command, "bash") or std.mem.eql(u8, command, "sh") or command.len == 0;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testClient(recorder: *runner.Recorder) Client {
    return .{
        .gpa = std.testing.allocator,
        .runner = .{ .gpa = std.testing.allocator, .io = undefined, .recorder = recorder },
        .session = "demo",
    };
}

test "tmux.observeSession: distinguishes active missing and unavailable" {
    const cases = [_]struct {
        term: ?std.process.Child.Term,
        stderr: []const u8 = "",
        spawn_error: ?anyerror = null,
        expected: observations.SessionObservation,
    }{
        .{ .term = .{ .exited = 0 }, .expected = .active },
        .{ .term = .{ .exited = 1 }, .stderr = "can't find session: demo", .expected = .missing },
        .{ .term = .{ .exited = 1 }, .stderr = "no server running on /tmp/tmux-501/default", .expected = .missing },
        .{ .term = .{ .exited = 1 }, .stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .expected = .unavailable },
        .{ .term = .{ .exited = 1 }, .stderr = "error connecting to /tmp/tmux-501/default (Operation not permitted)", .expected = .unavailable },
        .{ .term = null, .spawn_error = error.FileNotFound, .expected = .unavailable },
    };

    for (cases) |case| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        if (case.spawn_error) |err| try recorder.enqueueError(err) else try recorder.enqueue("", case.stderr, case.term.?);
        const client = testClient(&recorder);

        try std.testing.expectEqual(case.expected, client.observeSession());
    }
}

test "tmux.newSession: records session argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.newSession("dashboard", "/tmp/demo app", "zask dashboard");

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    const command = recorder.commands.items[0];
    try runner.expectCommandArgv(command, &.{ "tmux", "new-session", "-d", "-s", "demo", "-n", "dashboard", "-c", "/tmp/demo app", "zask dashboard" });
}

test "tmux.window: layout helpers record argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.splitWindow("dashboard", "/tmp/demo app", "zask monitor");
    try client.setWindowOption("dashboard", "main-pane-width", "50%");
    try client.selectLayout("dashboard", "main-vertical");

    const split = recorder.commands.items[0];
    try runner.expectCommandArgv(split, &.{ "tmux", "split-window", "-t", "demo:dashboard", "-c", "/tmp/demo app", "zask monitor" });

    const option = recorder.commands.items[1];
    try runner.expectCommandArgv(option, &.{ "tmux", "set-window-option", "-t", "demo:dashboard", "main-pane-width", "50%" });

    const layout = recorder.commands.items[2];
    try runner.expectCommandArgv(layout, &.{ "tmux", "select-layout", "-t", "demo:dashboard", "main-vertical" });
}

test "tmux.newWindow: records append target when requested" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.newWindow("api", "/tmp/demo app/backend", "echo waiting");
    try client.newWindowAfter("api", "worker", "/tmp/demo app/worker", "echo worker");

    const window = recorder.commands.items[0];
    try runner.expectCommandArgv(window, &.{ "tmux", "new-window", "-d", "-t", "demo", "-n", "api", "-c", "/tmp/demo app/backend", "echo waiting" });

    const after_window = recorder.commands.items[1];
    try runner.expectCommandArgv(after_window, &.{ "tmux", "new-window", "-d", "-a", "-t", "demo:api", "-n", "worker", "-c", "/tmp/demo app/worker", "echo worker" });
}

test "tmux.client: lifecycle commands record argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.switchClient();
    try client.attachSession();
    try client.detachClientExec("zask re");
    try client.detachTargetClientExec("/dev/ttys001", "zask re");
    try client.killSession();

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "switch-client", "-t", "demo" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "attach-session", "-t", "demo" });
    try std.testing.expect(recorder.commands.items[1].interactive);
    try runner.expectCommandArgv(recorder.commands.items[2], &.{ "tmux", "detach-client", "-E", "zask re" });
    try runner.expectCommandArgv(recorder.commands.items[3], &.{ "tmux", "detach-client", "-t", "/dev/ttys001", "-E", "zask re" });
    try runner.expectCommandArgv(recorder.commands.items[4], &.{ "tmux", "kill-session", "-t", "demo" });
}

test "tmux.listClients: parses attached client names" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("/dev/ttys001\n/dev/ttys002\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const clients = try client.listClients();
    defer freeClientInfos(std.testing.allocator, clients);

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-clients", "-t", "demo", "-F", "#{client_name}" });
    try std.testing.expectEqual(@as(usize, 2), clients.len);
    try std.testing.expectEqualStrings("/dev/ttys001", clients[0].name);
    try std.testing.expectEqualStrings("/dev/ttys002", clients[1].name);
}

test "tmux.option: option and binding helpers record argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.setOption("@mode", "all");
    try client.setHook("client-attached", "zask sync-size");
    try client.bindRunShell("w", "zask preview-list");

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "set-option", "-t", "demo", "@mode", "all" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "set-hook", "-t", "demo", "client-attached", "zask sync-size" });
    try runner.expectCommandArgv(recorder.commands.items[2], &.{ "tmux", "bind-key", "-T", "prefix", "w", "run-shell", "zask preview-list" });
}

test "tmux.sendKeys: records command through runner" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.sendKeys("api", &.{ "echo ok", "Enter" });

    const command = recorder.commands.items[0];
    try runner.expectCommandArgv(command, &.{ "tmux", "send-keys", "-t", "demo:api", "echo ok", "Enter" });
}

test "tmux.respawnPane: records wrapped shell command" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPane("api", "/tmp/demo app", "npm run dev");

    const command = recorder.commands.items[0];
    try runner.expectCommandArg(command, 1, "respawn-pane");
    try runner.expectCommandArg(command, 7, "sh");
    try runner.expectCommandArg(command, 8, "-lc");
    try runner.expectCommandArgContains(command, 9, "trap '__zask_interrupted=1' INT");
    try runner.expectCommandArgContains(command, 9, "npm run dev");
    try runner.expectCommandArgContains(command, 9, "exec \"${SHELL:-sh}\"");
}

test "tmux.buildRespawnScript: propagates command exit status" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const client = Client{
        .gpa = std.testing.allocator,
        .runner = undefined,
        .session = "demo",
    };
    const wrapped_command = try client.buildRespawnScript("sh -c 'exit 7'");
    defer std.testing.allocator.free(wrapped_command);

    const result = try std.process.run(std.testing.allocator, threaded.io(), .{
        .argv = &.{ "sh", "-c", wrapped_command },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, result.term);
}

test "tmux.resizeWindow: sizing helpers record and parse argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("@1|120|39\n@2|120|39\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const windows = try client.listWindowSizes();
    defer {
        for (windows) |window| window.deinit(std.testing.allocator);
        std.testing.allocator.free(windows);
    }
    try client.resizeWindow("@1", 120, 39);
    try client.restoreWindowAutoSize("@1");
    try client.chooseTree("%1");

    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expectEqualStrings("@1", windows[0].id);
    try std.testing.expectEqual(@as(u16, 120), windows[0].width);
    try std.testing.expectEqual(@as(u16, 39), windows[0].height);
    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-windows", "-t", "demo", "-F", "#{window_id}|#{window_width}|#{window_height}" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "resize-window", "-x", "120", "-y", "39", "-t", "@1" });
    try runner.expectCommandArgv(recorder.commands.items[2], &.{ "tmux", "set-option", "-w", "-t", "@1", "window-size", "latest" });
    try runner.expectCommandArgv(recorder.commands.items[3], &.{ "tmux", "choose-tree", "-Zw", "-t", "%1" });
}

test "tmux.listWindowSizes: rejects malformed fixed-format output" {
    const cases = [_][]const u8{
        "@1|120\n",
        "@1|120|39|extra\n",
        "@1|wide|39\n",
        "@1|120|tall\n",
    };

    for (cases) |stdout| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(stdout, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        try std.testing.expectError(error.InvalidWindowSizeOutput, client.listWindowSizes());
    }
}

test "tmux.paneRunning: accepts direct non-shell process" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    try std.testing.expect(client.paneRunning("api"));
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "tmux.paneRunning: rejects dead panes and idle shell panes" {
    var dead_recorder = runner.Recorder.init(std.testing.allocator);
    defer dead_recorder.deinit();
    try dead_recorder.enqueue("1|130|12345|node\n", "", .{ .exited = 0 });
    const dead_client = testClient(&dead_recorder);

    try std.testing.expect(!dead_client.paneRunning("api"));
    try std.testing.expectEqual(@as(usize, 1), dead_recorder.commands.items.len);

    var idle_recorder = runner.Recorder.init(std.testing.allocator);
    defer idle_recorder.deinit();
    try idle_recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try idle_recorder.enqueue("\n", "", .{ .exited = 1 });
    const idle_client = testClient(&idle_recorder);

    try std.testing.expect(!idle_client.paneRunning("api"));
}

test "tmux.observePane: returns window missing when pane info command fails" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "no such window", .{ .exited = 1 });
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.window_missing, observation.state);
    try std.testing.expectEqualStrings("", observation.exit_code);
    try std.testing.expectEqualStrings("", observation.pid);
    try std.testing.expectEqualStrings("", observation.command);
}

test "tmux.observePane: returns unavailable on pane info permission denied" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.tmux_unavailable, observation.state);
}

test "tmux.observePane: returns unavailable when pane info cannot be captured" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    recorder.term = .{ .signal = std.posix.SIG.TERM };
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.tmux_unavailable, observation.state);
    try std.testing.expectEqualStrings("", observation.exit_code);
    try std.testing.expectEqualStrings("", observation.pid);
    try std.testing.expectEqualStrings("", observation.command);
}

test "tmux.observePane: preserves pane fields on pgrep spawn error" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueueError(error.FileNotFound);
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.tmux_unavailable, observation.state);
    try std.testing.expectEqualStrings("0", observation.exit_code);
    try std.testing.expectEqualStrings("12345", observation.pid);
    try std.testing.expectEqualStrings("zsh", observation.command);
    try runner.expectCommandArg(recorder.commands.items[1], 0, "pgrep");
}

test "tmux.observePane: returns dead pane fields without checking children" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("1|130|12345|node\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.dead, observation.state);
    try std.testing.expectEqualStrings("130", observation.exit_code);
    try std.testing.expectEqualStrings("12345", observation.pid);
    try std.testing.expectEqualStrings("node", observation.command);
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "tmux.showOption: trims empty output to null" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue(" \n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    try std.testing.expect(try client.showOption("@zask_dash_mode") == null);
}

test "tmux.showOption: returns non-empty trimmed output" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue(" all \n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const value = (try client.showOption("@zask_dash_mode")).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("all", value);
}

test "tmux.capturePane: returns captured stdout" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("line one\nline two\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const output = try client.capturePane("api");
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("line one\nline two\n", output);
}

test "tmux.capturePane: returns owned empty slice when capture fails" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueueError(error.FileNotFound);
    const client = testClient(&recorder);

    const output = try client.capturePane("api");
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("", output);
}

test "tmux.captureLastLine: returns last non-empty pane line" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("first\n\n  last error  \n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const line = try client.captureLastLine("api");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("last error", line);
}

test "tmux.captureTail: returns last display-safe pane lines" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("first\nsecond\nbad\x1b[2J\rsecret\x07\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const tail = try client.captureTail("api", 2);
    defer tail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), tail.lines.len);
    try std.testing.expectEqualStrings("second", tail.lines[0]);
    try std.testing.expectEqualStrings("bad?[2J?secret?", tail.lines[1]);
}

test "tmux.captureTail: returns empty tail when no lines are requested" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("first\nsecond\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const tail = try client.captureTail("api", 0);
    defer tail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tail.lines.len);
}

test "tmux.captureLastLine: replaces control bytes in pane output" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("ok\nbad\x1b[2J\rsecret\x07\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const line = try client.captureLastLine("api");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("bad?[2J?secret?", line);
}

test "tmux.captureLastLine: returns owned empty slice when capture fails" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueueError(error.FileNotFound);
    const client = testClient(&recorder);

    const line = try client.captureLastLine("api");
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("", line);
}

test "tmux.paneInfo: uses first pane line and preserves parsed fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|111|zsh\n0|0|222|node\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.dead);
    try std.testing.expectEqualStrings("0", info.exit_code);
    try std.testing.expectEqualStrings("111", info.pid);
    try std.testing.expectEqualStrings("zsh", info.command);
}

test "tmux.paneInfo: accepts empty dead status for live pane" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0||12345|zsh\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.dead);
    try std.testing.expectEqualStrings("", info.exit_code);
    try std.testing.expectEqualStrings("12345", info.pid);
    try std.testing.expectEqualStrings("zsh", info.command);
}

test "tmux.paneInfo: defaults missing fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("1\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.dead);
    try std.testing.expectEqualStrings("0", info.exit_code);
    try std.testing.expectEqualStrings("0", info.pid);
    try std.testing.expectEqualStrings("", info.command);
}

test "tmux.paneInfo: ignores extra trailing fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|node|unexpected\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.dead);
    try std.testing.expectEqualStrings("12345", info.pid);
    try std.testing.expectEqualStrings("node", info.command);
}
