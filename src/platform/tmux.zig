const std = @import("std");
const observations = @import("../model/observations.zig");
const recovery = @import("../model/recovery.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");
const tmux_options = @import("../model/tmux_options.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    session: []const u8,
    tmux_path: []const u8 = "tmux",

    pub fn hasSession(self: Client) bool {
        return self.observeSession() == .active;
    }

    pub fn observeSession(self: Client) observations.SessionObservation {
        const session_target = self.sessionTarget() catch return .unavailable;
        defer self.gpa.free(session_target);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "has-session", "-t", session_target }, .{}) catch return .unavailable);
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
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "kill-session", "-t", session_target }, .{ .check = true, .discard = true });
    }

    pub fn switchClient(self: Client) !void {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "switch-client", "-t", session_target }, .{ .check = true, .discard = true });
    }

    pub fn attachSession(self: Client) !void {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "attach-session", "-t", session_target }, .{ .interactive = true, .check = true });
    }

    pub fn detachClientExec(self: Client, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client", "-E", command }, .{ .check = true, .discard = true });
    }

    pub fn detachTargetClientExec(self: Client, client_name: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client", "-t", client_name, "-E", command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice; free it with freeClientInfos.
    pub fn listClients(self: Client) ![]ClientInfo {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "list-clients", "-t", session_target, "-F", "#{client_name}" }, .{ .check = true }));
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

    pub fn clientShowingPane(self: Client, pane_id: []const u8) !?[]const u8 {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        const run_result = self.runner.run(&.{ self.tmux_path, "list-clients", "-t", session_target, "-F", "#{client_activity}|#{pane_id}|#{client_name}" }, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.TmuxUnavailable,
        };
        const result = runner.captured(run_result);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited != 0) return if (serverUnavailable(result.stderr)) error.TmuxUnavailable else null;

        var best: ?[]const u8 = null;
        var best_activity: u64 = 0;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '|');
            const activity = std.fmt.parseUnsigned(u64, fields.next().?, 10) catch return error.InvalidClientListOutput;
            const pane = fields.next() orelse return error.InvalidClientListOutput;
            const name = fields.rest();
            if (name.len == 0) return error.InvalidClientListOutput;
            if (!std.mem.eql(u8, pane, pane_id)) continue;
            if (best == null or activity > best_activity) {
                best = name;
                best_activity = activity;
            }
        }
        return if (best) |name| try self.gpa.dupe(u8, name) else null;
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
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "new-window", "-d", "-t", session_target, "-n", window_name, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    pub fn newWindowAfter(self: Client, after_window: []const u8, window_name: []const u8, cwd: []const u8, command: []const u8) !void {
        const target_window = try self.target(after_window);
        defer self.gpa.free(target_window);
        _ = try self.runner.run(&.{ self.tmux_path, "new-window", "-d", "-a", "-t", target_window, "-n", window_name, "-c", cwd, command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice; free it with freeWindowSizes.
    pub fn listWindowSizes(self: Client) ![]WindowSize {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "list-windows", "-t", session_target, "-F", "#{window_id}|#{window_width}|#{window_height}" }, .{ .check = true }));
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
        if (info.starting) return info.consumeIntoObservation(.busy);
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
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "list-panes", "-t", pane_target, "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}|#{" ++ tmux_options.started_at ++ "}|#{pane_dead_signal}|#{" ++ tmux_options.recovery ++ "}|#{" ++ tmux_options.starting ++ "}" }, .{}) catch return error.TmuxUnavailable);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited != 0) return if (serverUnavailable(result.stderr)) error.TmuxUnavailable else error.WindowMissing;

        // Lenient parse (intentional, unlike listWindowSizes): this query fixes
        // its own eight-field format, and pane_dead_status is legitimately empty
        // for live panes ("0||pid|cmd||"). tmux before 3.3 has no
        // pane_dead_signal and leaves it empty. observePane runs on a hot path, so a
        // truncated or unexpected line degrades to defaults rather than aborting
        // the surrounding lifecycle. Extra pane lines from split windows are
        // ignored; only the first pane is observed. The start marker is empty
        // for panes zask has not spawned, and a non-numeric value is treated
        // the same: an unknown start, never a guessed one. The recovery record
        // has its own strict parse; the final field marks a pending spawn.
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        const line = lines.next() orelse "";
        var fields = std.mem.splitScalar(u8, line, '|');
        const dead = fields.next() orelse "0";
        const exit_code = fields.next() orelse "0";
        const pid = fields.next() orelse "0";
        const command = fields.next() orelse "";
        const started_at = std.fmt.parseInt(i64, fields.next() orelse "", 10) catch null;
        const exit = observations.paneExit(exit_code, fields.next() orelse "");
        var info = try PaneInfo.init(self.gpa, std.mem.eql(u8, dead, "1"), exit_code, pid, command, started_at);
        info.exit = exit;
        info.recovery = recovery.parse(fields.next() orelse "");
        const starting = fields.next() orelse "";
        info.starting = starting.len > 0;
        return info;
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
        if (max_lines == 0) return .{ .lines = try self.gpa.alloc([]const u8, 0) };
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const start = try std.fmt.allocPrint(self.gpa, "-{d}", .{max_lines});
        defer self.gpa.free(start);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "capture-pane", "-t", pane_target, "-p", "-S", start }, .{}) catch return .{ .lines = try self.gpa.alloc([]const u8, 0) });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return try tailNonEmptyLines(self.gpa, result.stdout, max_lines);
    }

    pub fn captureRecentLines(self: Client, window: []const u8, max_lines: u32) ![]const u8 {
        if (max_lines == 0) return self.gpa.dupe(u8, "");
        const window_target = try self.target(window);
        defer self.gpa.free(window_target);

        var rows: u64 = max_lines;
        while (true) {
            const capture = try self.captureRowsWithHistory(window_target, rows);
            defer self.gpa.free(capture.output);
            const content = withoutTrailingBlankLines(capture.text);
            if (rows >= capture.history_size or lineCount(content) > max_lines) {
                if (content.len == 0) return self.gpa.dupe(u8, "");
                return std.mem.concat(self.gpa, u8, &.{ lastLines(content, max_lines), "\n" });
            }
            rows = @min(rows * 2, capture.history_size);
        }
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

    pub fn respawnPane(self: Client, window: []const u8, cwd: []const u8, command: []const u8, started_at: i64) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const wrapped_command = try self.buildRespawnScript(command, null);
        defer self.gpa.free(wrapped_command);
        const started_at_text = try std.fmt.allocPrint(self.gpa, "{d}", .{started_at});
        defer self.gpa.free(started_at_text);
        errdefer self.setPaneOption(window, tmux_options.starting, null) catch {};
        const argv = [_][]const u8{ self.tmux_path, "set-option", "-p", "-t", pane_target, tmux_options.starting, "starting", ";", "respawn-pane", "-k", "-t", pane_target, "-c", cwd, "sh", "-lc", wrapped_command, ";", "set-option", "-p", "-t", pane_target, tmux_options.started_at, started_at_text };
        _ = try self.runner.run(&argv, .{ .check = true, .discard = true });
    }

    pub fn respawnPaneWithOutputLog(self: Client, window: []const u8, cwd: []const u8, command: []const u8, started_at: i64, log: ?OutputLog, recovery_record: ?[]const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const wrapped_command = try self.buildRespawnScript(command, log);
        defer self.gpa.free(wrapped_command);
        const started_at_text = try std.fmt.allocPrint(self.gpa, "{d}", .{started_at});
        defer self.gpa.free(started_at_text);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        errdefer self.setPaneOption(window, tmux_options.starting, null) catch {};
        try argv.appendSlice(self.gpa, &.{ self.tmux_path, "set-option", "-p", "-t", pane_target, tmux_options.starting, if (log) |l| l.token else "starting", ";", "respawn-pane", "-k", "-t", pane_target, "-c", cwd, "sh", "-lc", wrapped_command, ";", "pipe-pane", "-t", pane_target });
        const pipe_command = if (log) |output| try buildOutputPipe(self.gpa, output) else null;
        defer if (pipe_command) |value| self.gpa.free(value);
        if (pipe_command) |value| try argv.append(self.gpa, value);
        try argv.appendSlice(self.gpa, &.{ ";", "set-option", "-p", "-t", pane_target, tmux_options.log_run, if (log) |l| l.token else "" });
        if (recovery_record) |value| {
            try argv.appendSlice(self.gpa, &.{ ";", "set-option", "-p", "-t", pane_target, tmux_options.recovery, value });
        } else {
            try argv.appendSlice(self.gpa, &.{ ";", "set-option", "-p", "-u", "-t", pane_target, tmux_options.recovery });
        }
        try argv.appendSlice(self.gpa, &.{ ";", "set-option", "-p", "-t", pane_target, tmux_options.started_at, started_at_text });
        _ = try self.runner.run(argv.items, .{ .check = true, .discard = true });
    }

    pub fn showPaneOption(self: Client, window: []const u8, name: []const u8) !?[]const u8 {
        const target_name = try self.target(window);
        defer self.gpa.free(target_name);
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "show-options", "-pqv", "-t", target_name, name }, .{ .check = true }));
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const value = std.mem.trim(u8, result.stdout, " \t\r\n");
        return if (value.len > 0) try self.gpa.dupe(u8, value) else null;
    }

    pub fn setPaneOption(self: Client, window: []const u8, name: []const u8, value: ?[]const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        if (value) |text| {
            _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-p", "-t", pane_target, name, text }, .{ .check = true, .discard = true });
        } else {
            _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-p", "-u", "-t", pane_target, name }, .{ .check = true, .discard = true });
        }
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-t", session_target, name, value }, .{ .check = true, .discard = true });
    }

    pub fn setHook(self: Client, name: []const u8, command: []const u8) !void {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        _ = try self.runner.run(&.{ self.tmux_path, "set-hook", "-t", session_target, name, command }, .{ .check = true, .discard = true });
    }

    /// Caller owns the returned slice when the result is non-null.
    pub fn showOption(self: Client, name: []const u8) !?[]const u8 {
        const session_target = try self.sessionTarget();
        defer self.gpa.free(session_target);
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "show-option", "-t", session_target, "-qv", name }, .{}) catch return null);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const value = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (value.len == 0) return null;
        return try self.gpa.dupe(u8, value);
    }

    pub fn bindRunShell(self: Client, key: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "bind-key", "-T", "prefix", key, "run-shell", command }, .{ .check = true, .discard = true });
    }

    pub fn rootKeyBinding(self: Client, key: []const u8) !?[]const u8 {
        const result = runner.captured(try self.runner.run(&.{ self.tmux_path, "list-keys", "-T", "root" }, .{ .check = true }));
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, bindingKey(line) orelse continue, key)) return try self.gpa.dupe(u8, line);
        }
        return null;
    }

    pub fn bindRootKey(self: Client, key: []const u8, command: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ self.tmux_path, "bind-key", "-T", "root", key });
        try argv.appendSlice(self.gpa, command);
        _ = try self.runner.run(argv.items, .{ .check = true, .discard = true });
    }

    pub fn chooseTree(self: Client, pane_id: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "choose-tree", "-Zw", "-t", pane_id }, .{ .check = true, .discard = true });
    }

    pub fn displayPopup(self: Client, client_name: []const u8, title: []const u8, command: []const u8) !void {
        const run_result = self.runner.run(&.{ self.tmux_path, "display-popup", "-c", client_name, "-EE", "-w", "90%", "-h", "80%", "-T", title, command }, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.TmuxUnavailable,
        };
        const result = runner.captured(run_result);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited == 0) return;
        if (std.mem.trim(u8, result.stderr, " \t\r\n").len == 0) return;
        return if (serverUnavailable(result.stderr)) error.TmuxUnavailable else error.PopupUnavailable;
    }

    fn target(self: Client, window: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "={s}:={s}", .{ self.session, window });
    }

    fn sessionTarget(self: Client) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "={s}:", .{self.session});
    }

    fn captureRowsWithHistory(self: Client, window_target: []const u8, rows: u64) !RowsCapture {
        const start = try std.fmt.allocPrint(self.gpa, "-{d}", .{rows});
        defer self.gpa.free(start);
        const output = try self.paneQuery(&.{ self.tmux_path, "display-message", "-p", "-t", window_target, "#{history_size}", ";", "capture-pane", "-p", "-J", "-t", window_target, "-S", start });
        errdefer self.gpa.free(output);

        const newline = std.mem.indexOfScalar(u8, output, '\n') orelse return error.InvalidPaneHistoryOutput;
        const history_size = std.fmt.parseUnsigned(u64, output[0..newline], 10) catch return error.InvalidPaneHistoryOutput;
        return .{ .output = output, .text = output[newline + 1 ..], .history_size = history_size };
    }

    fn paneQuery(self: Client, argv: []const []const u8) ![]const u8 {
        const run_result = self.runner.run(argv, .{}) catch |err| switch (err) {
            error.OutOfMemory, error.OutputTooLarge => return err,
            else => return error.TmuxUnavailable,
        };
        const result = runner.captured(run_result);
        errdefer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited != 0) return if (serverUnavailable(result.stderr)) error.TmuxUnavailable else error.WindowMissing;
        return result.stdout;
    }

    fn buildRespawnScript(self: Client, command: []const u8, log: ?OutputLog) ![]const u8 {
        const tmux_path = try shell.quote(self.gpa, self.tmux_path);
        defer self.gpa.free(tmux_path);
        const token = if (log) |l| l.token else "starting";
        const marker = if (log != null) try std.fmt.allocPrint(self.gpa, "printf '\\033]9999;zask-output-done;{s}\\007'", .{token}) else try self.gpa.dupe(u8, "");
        defer self.gpa.free(marker);
        return std.fmt.allocPrint(self.gpa,
            \\__zask_clear_starting() {{
            \\  if [ -n "$TMUX_PANE" ]; then
            \\    if [ "$__zask_interrupted" = 1 ]; then
            \\      {s} if-shell -F -t "$TMUX_PANE" "#{{==:#{{pane_pid}},$$}}" "set-option -p -u -t $TMUX_PANE @zask_starting ; set-option -p -u -t $TMUX_PANE @zask_started_at"
            \\    else
            \\      {s} if-shell -F -t "$TMUX_PANE" "#{{&&:#{{==:#{{pane_pid}},$$}},#{{==:#{{@zask_starting}},{s}}}}}" "set-option -p -u -t $TMUX_PANE @zask_starting"
            \\    fi
            \\  fi
            \\}}
            \\__zask_interrupted=0
            \\trap '__zask_interrupted=1; __zask_clear_starting' INT
            \\(
            \\__zask_clear_starting
            \\{s}
            \\)
            \\__zask_status=$?
            \\__zask_clear_starting
            \\{s}
            \\if [ "$__zask_interrupted" = 1 ]; then
            \\  exec "${{SHELL:-sh}}"
            \\fi
            \\exit "$__zask_status"
        , .{ tmux_path, tmux_path, token, command, marker });
    }
};

/// A non-zero tmux exit means "missing" by default: no server / no session is
/// the normal not-yet-opened state. Only treat it as unavailable when the socket
/// exists but cannot be used (permission denied), which is a genuine fault.
fn serverUnavailable(stderr: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(stderr, "permission denied") != null or
        std.ascii.indexOfIgnoreCase(stderr, "operation not permitted") != null;
}

fn buildOutputPipe(gpa: std.mem.Allocator, log: OutputLog) ![]const u8 {
    const header = try shell.quote(gpa, log.header);
    defer gpa.free(header);
    const path = try shell.quote(gpa, log.path);
    defer gpa.free(path);
    const executable = try shell.quote(gpa, log.relay_path);
    defer gpa.free(executable);
    const notice_text = try std.fmt.allocPrint(gpa, "zask: output is no longer saved to {s}", .{log.path});
    defer gpa.free(notice_text);
    const notice = try shell.quote(gpa, notice_text);
    defer gpa.free(notice);
    const command = try std.fmt.allocPrint(gpa, "umask 077; printf '%s' {s} >> {s}; {s} _log-stream {s} {s} || printf '\\r\\n%s\\r\\n' {s} > {s}", .{ header, path, executable, path, log.token, notice, pane_tty_placeholder });
    defer gpa.free(command);
    const formats_escaped = try std.mem.replaceOwned(u8, gpa, command, "#", "##");
    defer gpa.free(formats_escaped);
    const escaped = try std.mem.replaceOwned(u8, gpa, formats_escaped, "%", "%%");
    defer gpa.free(escaped);
    const with_tty = try std.mem.replaceOwned(u8, gpa, escaped, pane_tty_placeholder, "'#{pane_tty}'");
    defer gpa.free(with_tty);
    return gpa.dupe(u8, with_tty);
}

const pane_tty_placeholder = "\x00pane_tty\x00";

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

fn withoutTrailingBlankLines(pane: []const u8) []const u8 {
    var content = std.mem.trimEnd(u8, pane, "\n");
    while (content.len > 0) {
        const line_start = if (std.mem.lastIndexOfScalar(u8, content, '\n')) |index| index + 1 else 0;
        if (std.mem.trim(u8, content[line_start..], " \t\r").len != 0) break;
        content = content[0..line_start -| 1];
    }
    return content;
}

fn lineCount(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + 1;
}

fn lastLines(content: []const u8, max_lines: u32) []const u8 {
    var start = content.len;
    var kept: u32 = 0;
    while (start > 0) : (start -= 1) {
        if (content[start - 1] != '\n') continue;
        kept += 1;
        if (kept == max_lines) break;
    }
    return content[start..];
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

const RowsCapture = struct {
    output: []const u8,
    text: []const u8,
    history_size: u64,
};

pub const OutputLog = struct {
    path: []const u8,
    header: []const u8,

    relay_path: []const u8 = "zask",
    token: []const u8 = "test-token",
};

pub const PaneTail = struct {
    lines: []const []const u8,

    pub fn deinit(self: PaneTail, gpa: std.mem.Allocator) void {
        for (self.lines) |line| gpa.free(line);
        gpa.free(self.lines);
    }
};

pub const PaneInfo = struct {
    starting: bool = false,
    dead: bool,
    exit_code: []const u8,
    pid: []const u8,
    command: []const u8,
    started_at: ?i64,
    exit: observations.PaneExit = .clean,
    recovery: recovery.RecordObservation = .none,

    fn init(gpa: std.mem.Allocator, dead: bool, exit_code: []const u8, pid: []const u8, command: []const u8, started_at: ?i64) !PaneInfo {
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
            .started_at = started_at,
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
        var observation = observations.PaneObservation.fromOwned(state, self.exit_code, self.pid, self.command, self.started_at);
        observation.exit = self.exit;
        observation.recovery = self.recovery;
        return observation;
    }
};

fn bindingKey(line: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    if (!std.mem.eql(u8, fields.next() orelse return null, "bind-key")) return null;
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, "-T")) {
            _ = fields.next() orelse return null;
            return fields.next();
        }
    }
    return null;
}

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
    try runner.expectCommandArgv(split, &.{ "tmux", "split-window", "-t", "=demo:=dashboard", "-c", "/tmp/demo app", "zask monitor" });

    const option = recorder.commands.items[1];
    try runner.expectCommandArgv(option, &.{ "tmux", "set-window-option", "-t", "=demo:=dashboard", "main-pane-width", "50%" });

    const layout = recorder.commands.items[2];
    try runner.expectCommandArgv(layout, &.{ "tmux", "select-layout", "-t", "=demo:=dashboard", "main-vertical" });
}

test "tmux.newWindow: records append target when requested" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.newWindow("api", "/tmp/demo app/backend", "echo waiting");
    try client.newWindowAfter("api", "worker", "/tmp/demo app/worker", "echo worker");

    const window = recorder.commands.items[0];
    try runner.expectCommandArgv(window, &.{ "tmux", "new-window", "-d", "-t", "=demo:", "-n", "api", "-c", "/tmp/demo app/backend", "echo waiting" });

    const after_window = recorder.commands.items[1];
    try runner.expectCommandArgv(after_window, &.{ "tmux", "new-window", "-d", "-a", "-t", "=demo:=api", "-n", "worker", "-c", "/tmp/demo app/worker", "echo worker" });
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

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "switch-client", "-t", "=demo:" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "attach-session", "-t", "=demo:" });
    try std.testing.expect(recorder.commands.items[1].interactive);
    try runner.expectCommandArgv(recorder.commands.items[2], &.{ "tmux", "detach-client", "-E", "zask re" });
    try runner.expectCommandArgv(recorder.commands.items[3], &.{ "tmux", "detach-client", "-t", "/dev/ttys001", "-E", "zask re" });
    try runner.expectCommandArgv(recorder.commands.items[4], &.{ "tmux", "kill-session", "-t", "=demo:" });
}

test "tmux.listClients: parses attached client names" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("/dev/ttys001\n/dev/ttys002\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const clients = try client.listClients();
    defer freeClientInfos(std.testing.allocator, clients);

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-clients", "-t", "=demo:", "-F", "#{client_name}" });
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

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "set-option", "-t", "=demo:", "@mode", "all" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "set-hook", "-t", "=demo:", "client-attached", "zask sync-size" });
    try runner.expectCommandArgv(recorder.commands.items[2], &.{ "tmux", "bind-key", "-T", "prefix", "w", "run-shell", "zask preview-list" });
}

test "tmux.sendKeys: records command through runner" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.sendKeys("api", &.{ "echo ok", "Enter" });

    const command = recorder.commands.items[0];
    try runner.expectCommandArgv(command, &.{ "tmux", "send-keys", "-t", "=demo:=api", "echo ok", "Enter" });
}

test "tmux.rootKeyBinding: finds the key in the root table listing" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const table =
        \\bind-key    -T root MouseDown1Pane select-pane -t = \\; send-keys -M
        \\bind-key -r -T root C-v           send-keys -l x
        \\bind-key    -T root M->           send-keys End
        \\
    ;
    try recorder.enqueue(table, "", .{ .exited = 0 });
    try recorder.enqueue(table, "", .{ .exited = 0 });
    try recorder.enqueue(table, "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const unbound = try client.rootKeyBinding("M-v");
    const bound = try client.rootKeyBinding("C-v");
    defer if (bound) |text| std.testing.allocator.free(text);
    const symbol = try client.rootKeyBinding("M->");
    defer if (symbol) |text| std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(?[]const u8, null), unbound);
    try std.testing.expectEqualStrings("bind-key -r -T root C-v           send-keys -l x", bound.?);
    try std.testing.expectEqualStrings("bind-key    -T root M->           send-keys End", symbol.?);
    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-keys", "-T", "root" });
}

test "tmux.bindRootKey: binds the command in the root table" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.bindRootKey("M-<", &.{ "send-keys", "Home" });

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "bind-key", "-T", "root", "M-<", "send-keys", "Home" });
}

test "tmux.respawnPane: records wrapped shell command" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPane("api", "/tmp/demo app", "npm run dev", 1_700_000_000);

    const command = recorder.commands.items[0];
    try runner.expectCommandArg(command, 8, "respawn-pane");
    try runner.expectCommandArg(command, 14, "sh");
    try runner.expectCommandArg(command, 15, "-lc");
    try runner.expectCommandArgContains(command, 16, "trap '__zask_interrupted=1; __zask_clear_starting' INT");
    try runner.expectCommandArgContains(command, 16, "npm run dev");
    try runner.expectCommandArgContains(command, 16, "exec \"${SHELL:-sh}\"");
}

test "tmux.respawnPane: records start marker after respawn in the same invocation" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPane("api", "/tmp/demo", "npm run dev", 1_700_000_000);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    const argv = recorder.commands.items[0].argv;
    try runner.expectCommandArgv(.{ .argv = argv[17..], .cwd = null, .interactive = false }, &.{ ";", "set-option", "-p", "-t", "=demo:=api", "@zask_started_at", "1700000000" });
}

test "tmux.respawnPaneWithOutputLog: appends output to the log in the respawn invocation" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPaneWithOutputLog("api", "/tmp/demo", "npm run dev", 1_700_000_000, .{
        .path = "/state/it's #1 100%/api.log",
        .header = "=== api ===\n",
    }, null);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    const argv = recorder.commands.items[0].argv;
    try runner.expectCommandArg(recorder.commands.items[0], 8, "respawn-pane");
    try runner.expectCommandArgContains(recorder.commands.items[0], 16, "npm run dev");
    try runner.expectCommandArgv(.{ .argv = argv[17..], .cwd = null, .interactive = false }, &.{
        ";",             "pipe-pane",  "-t",         "=demo:=api",     "umask 077; printf '%%s' '=== api ===\n' >> '/state/it'\\''s ##1 100%%/api.log'; 'zask' _log-stream '/state/it'\\''s ##1 100%%/api.log' test-token || printf '\\r\\n%%s\\r\\n' 'zask: output is no longer saved to /state/it'\\''s ##1 100%%/api.log' > '#{pane_tty}'",
        ";",             "set-option", "-p",         "-t",             "=demo:=api",
        "@zask_log_run", "test-token", ";",          "set-option",     "-p",
        "-u",            "-t",         "=demo:=api", "@zask_recovery", ";",
        "set-option",    "-p",         "-t",         "=demo:=api",     "@zask_started_at",
        "1700000000",
    });
}

test "tmux.respawnPaneWithOutputLog: closes an earlier pipe without a log" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPaneWithOutputLog("api", "/tmp/demo", "npm run dev", 1_700_000_000, null, null);

    const argv = recorder.commands.items[0].argv;
    try runner.expectCommandArgv(.{ .argv = argv[17..], .cwd = null, .interactive = false }, &.{ ";", "pipe-pane", "-t", "=demo:=api", ";", "set-option", "-p", "-t", "=demo:=api", "@zask_log_run", "", ";", "set-option", "-p", "-u", "-t", "=demo:=api", "@zask_recovery", ";", "set-option", "-p", "-t", "=demo:=api", "@zask_started_at", "1700000000" });
}

test "tmux.respawnPaneWithOutputLog: sets the recovery record in the respawn invocation" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.respawnPaneWithOutputLog("api", "/tmp/demo", "npm run dev", 1_700_000_000, null, "restarted,,1,3,2");

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    const argv = recorder.commands.items[0].argv;
    try runner.expectCommandArgv(.{ .argv = argv[argv.len - 14 .. argv.len - 7], .cwd = null, .interactive = false }, &.{ ";", "set-option", "-p", "-t", "=demo:=api", "@zask_recovery", "restarted,,1,3,2" });
}

test "tmux.setPaneOption: sets or unsets a pane option" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const client = testClient(&recorder);

    try client.setPaneOption("api", "@zask_recovery", "gave_up,12,3,3,1");
    try client.setPaneOption("api", "@zask_recovery", null);

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "set-option", "-p", "-t", "=demo:=api", "@zask_recovery", "gave_up,12,3,3,1" });
    try runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "set-option", "-p", "-u", "-t", "=demo:=api", "@zask_recovery" });
}

test "tmux.buildRespawnScript: propagates command exit status" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const client = Client{
        .gpa = std.testing.allocator,
        .runner = undefined,
        .session = "demo",
    };
    const wrapped_command = try client.buildRespawnScript("sh -c 'exit 7'", null);
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
    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-windows", "-t", "=demo:", "-F", "#{window_id}|#{window_width}|#{window_height}" });
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
    recorder.term = .{ .signal = .TERM };
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

test "tmux.showOption: returns trimmed output or null when blank" {
    const cases = [_]struct { stdout: []const u8, expected: ?[]const u8 }{
        .{ .stdout = " \n", .expected = null },
        .{ .stdout = " all \n", .expected = "all" },
    };
    for (cases) |case| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.stdout, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const value = try client.showOption("@zask_dash_mode");
        defer if (value) |owned| std.testing.allocator.free(owned);

        try std.testing.expectEqualDeep(case.expected, value);
    }
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
    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "capture-pane", "-t", "=demo:=api", "-p", "-S", "-2" });
}

test "tmux.captureTail: keeps order after multiple ring wraps" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("one\ntwo\nthree\nfour\nfive\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const tail = try client.captureTail("api", 2);
    defer tail.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), tail.lines.len);
    try std.testing.expectEqualStrings("four", tail.lines[0]);
    try std.testing.expectEqualStrings("five", tail.lines[1]);
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

test "tmux.captureRecentLines: reads history size and rows in one invocation" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const output = try client.captureRecentLines("api", 100);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "display-message", "-p", "-t", "=demo:=api", "#{history_size}", ";", "capture-pane", "-p", "-J", "-t", "=demo:=api", "-S", "-100" });
}

test "tmux.captureRecentLines: keeps the last lines of the pane" {
    const cases = [_]struct {
        name: []const u8,
        stdout: []const u8,
        max_lines: u32,
        expected: []const u8,
    }{
        .{ .name = "more than requested", .stdout = "0\none\ntwo\nthree\nfour\n", .max_lines = 2, .expected = "three\nfour\n" },
        .{ .name = "fewer than requested", .stdout = "0\none\ntwo\n", .max_lines = 100, .expected = "one\ntwo\n" },
        .{ .name = "blank screen padding", .stdout = "0\none\n\ntwo\n\n  \n\n", .max_lines = 100, .expected = "one\n\ntwo\n" },
        .{ .name = "inner blank kept in tail", .stdout = "0\none\ntwo\n\nthree\n\n\n", .max_lines = 2, .expected = "\nthree\n" },
        .{ .name = "empty pane", .stdout = "0\n\n\n\n", .max_lines = 100, .expected = "" },
        .{ .name = "raw text unchanged", .stdout = "0\na\tb \x1b[1m  \n\n", .max_lines = 1, .expected = "a\tb \x1b[1m  \n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.stdout, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const output = try client.captureRecentLines("api", case.max_lines);
        defer std.testing.allocator.free(output);

        try std.testing.expectEqualStrings(case.expected, output);
    }
}

test "tmux.captureRecentLines: widens the range past wrapped rows" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("100\ncut\nwrapped line\n", "", .{ .exited = 0 });
    try recorder.enqueue("100\ncut\nfirst\nwrapped line\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const output = try client.captureRecentLines("api", 2);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("first\nwrapped line\n", output);
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try runner.expectCommandArg(recorder.commands.items[1], 13, "-4");
}

test "tmux.captureRecentLines: stops widening at the top of history" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("3\nonly\n", "", .{ .exited = 0 });
    try recorder.enqueue("3\nfirst\nonly\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const output = try client.captureRecentLines("api", 2);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("first\nonly\n", output);
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try runner.expectCommandArg(recorder.commands.items[1], 13, "-3");
}

test "tmux.captureRecentLines: reports query failures as errors" {
    const cases = [_]struct {
        name: []const u8,
        term: ?std.process.Child.Term,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        spawn_error: ?anyerror = null,
        expected: anyerror,
    }{
        .{ .name = "missing window", .term = .{ .exited = 1 }, .stdout = "12\n", .stderr = "can't find window: api", .expected = error.WindowMissing },
        .{ .name = "permission denied", .term = .{ .exited = 1 }, .stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .expected = error.TmuxUnavailable },
        .{ .name = "signaled", .term = .{ .signal = @enumFromInt(9) }, .expected = error.TmuxUnavailable },
        .{ .name = "spawn error", .term = null, .spawn_error = error.FileNotFound, .expected = error.TmuxUnavailable },
        .{ .name = "too large", .term = null, .spawn_error = error.OutputTooLarge, .expected = error.OutputTooLarge },
        .{ .name = "non-numeric history", .term = .{ .exited = 0 }, .stdout = "rows\nline\n", .expected = error.InvalidPaneHistoryOutput },
        .{ .name = "missing history line", .term = .{ .exited = 0 }, .stdout = "", .expected = error.InvalidPaneHistoryOutput },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        if (case.spawn_error) |err| try recorder.enqueueError(err) else try recorder.enqueue(case.stdout, case.stderr, case.term.?);
        const client = testClient(&recorder);

        try std.testing.expectError(case.expected, client.captureRecentLines("api", 100));
    }
}

test "tmux.displayPopup: targets the client and keeps failed commands on screen" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    try client.displayPopup("/dev/pts/1", " api ", "less file");

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "display-popup", "-c", "/dev/pts/1", "-EE", "-w", "90%", "-h", "80%", "-T", " api ", "less file" });
}

test "tmux.displayPopup: a popup command's own exit status is not a failure" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const client = testClient(&recorder);

    try client.displayPopup("/dev/pts/1", " api ", "less file");
}

test "tmux.displayPopup: reports rejected popups apart from tmux failures" {
    const cases = [_]struct {
        name: []const u8,
        term: ?std.process.Child.Term,
        stderr: []const u8 = "",
        spawn_error: ?anyerror = null,
        expected: anyerror,
    }{
        .{ .name = "client gone", .term = .{ .exited = 1 }, .stderr = "can't find client: /dev/pts/1", .expected = error.PopupUnavailable },
        .{ .name = "old tmux", .term = .{ .exited = 1 }, .stderr = "unknown command: display-popup", .expected = error.PopupUnavailable },
        .{ .name = "permission denied", .term = .{ .exited = 1 }, .stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .expected = error.TmuxUnavailable },
        .{ .name = "signaled", .term = .{ .signal = @enumFromInt(9) }, .expected = error.TmuxUnavailable },
        .{ .name = "spawn error", .term = null, .spawn_error = error.FileNotFound, .expected = error.TmuxUnavailable },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        if (case.spawn_error) |err| try recorder.enqueueError(err) else try recorder.enqueue("", case.stderr, case.term.?);
        const client = testClient(&recorder);

        try std.testing.expectError(case.expected, client.displayPopup("/dev/pts/1", " api ", "less file"));
    }
}

test "tmux.clientShowingPane: picks the most recently active client on the pane" {
    const cases = [_]struct {
        name: []const u8,
        stdout: []const u8,
        expected: ?[]const u8,
    }{
        .{ .name = "latest of two", .stdout = "100|%3|/dev/pts/1\n300|%3|/dev/pts/2\n200|%3|/dev/pts/3\n", .expected = "/dev/pts/2" },
        .{ .name = "other pane ignored", .stdout = "900|%7|/dev/pts/1\n100|%3|/dev/pts/2\n", .expected = "/dev/pts/2" },
        .{ .name = "name with separator", .stdout = "100|%3|/tmp/a|b\n", .expected = "/tmp/a|b" },
        .{ .name = "no client on pane", .stdout = "900|%7|/dev/pts/1\n", .expected = null },
        .{ .name = "no client", .stdout = "", .expected = null },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.stdout, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const name = try client.clientShowingPane("%3");
        defer if (name) |owned| std.testing.allocator.free(owned);

        try std.testing.expectEqualDeep(case.expected, name);
        try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-clients", "-t", "=demo:", "-F", "#{client_activity}|#{pane_id}|#{client_name}" });
    }
}

test "tmux.clientShowingPane: reports failures apart from a missing session" {
    const cases = [_]struct {
        name: []const u8,
        term: ?std.process.Child.Term,
        stdout: []const u8 = "",
        stderr: []const u8 = "",
        spawn_error: ?anyerror = null,
        expected: anyerror!?[]const u8,
    }{
        .{ .name = "missing session", .term = .{ .exited = 1 }, .stderr = "can't find session: demo", .expected = null },
        .{ .name = "permission denied", .term = .{ .exited = 1 }, .stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .expected = error.TmuxUnavailable },
        .{ .name = "spawn error", .term = null, .spawn_error = error.FileNotFound, .expected = error.TmuxUnavailable },
        .{ .name = "malformed line", .term = .{ .exited = 0 }, .stdout = "%3|/dev/pts/1\n", .expected = error.InvalidClientListOutput },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        if (case.spawn_error) |err| try recorder.enqueueError(err) else try recorder.enqueue(case.stdout, case.stderr, case.term.?);
        const client = testClient(&recorder);

        try std.testing.expectEqualDeep(case.expected, client.clientShowingPane("%3"));
    }
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

test "tmux.paneInfo: parses start marker" {
    const cases = [_]struct {
        line: []const u8,
        expected: ?i64,
    }{
        .{ .line = "0||12345|node|1700000000\n", .expected = 1_700_000_000 },
        .{ .line = "0||12345|node|\n", .expected = null },
        .{ .line = "0||12345|node\n", .expected = null },
        .{ .line = "0||12345|node|soon\n", .expected = null },
    };

    for (cases) |case| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.line, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const info = try client.paneInfo("api");
        defer info.deinit(std.testing.allocator);

        try std.testing.expectEqual(case.expected, info.started_at);
        try std.testing.expectEqualStrings("node", info.command);
    }
}

test "tmux.paneInfo: queries the start marker option" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0||12345|node|\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try runner.expectCommandArgv(recorder.commands.items[0], &.{ "tmux", "list-panes", "-t", "=demo:=api", "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}|#{@zask_started_at}|#{pane_dead_signal}|#{@zask_recovery}|#{@zask_starting}" });
}

test "tmux.observePane: carries the recovery record into the observation" {
    const cases = [_]struct {
        line: []const u8,
        want: recovery.RecordObservation,
    }{
        .{ .line = "1|3|12345|sh|1700000000||\n", .want = .none },
        .{ .line = "1|3|12345|sh|1700000000|\n", .want = .none },
        .{ .line = "1|3|12345|sh|1700000000||gave_up,12345,3,3,3\n", .want = .{ .record = .{ .kind = .gave_up, .pid = 12345, .attempt = 3, .max_retries = 3, .exit = .{ .failed = 3 } } } },
        .{ .line = "1|3|12345|sh|1700000000||gave_up|3\n", .want = .malformed },
    };

    for (cases) |case| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.line, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const observation = client.observePane("api");
        defer observation.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(case.want, observation.recovery);
    }
}

test "tmux.observePane: classifies a dead pane from status and signal" {
    const cases = [_]struct {
        line: []const u8,
        want: observations.PaneExit,
    }{
        .{ .line = "1|3|12345|sh|1700000000|\n", .want = .{ .failed = 3 } },
        .{ .line = "1||12345|sleep|1700000000|int\n", .want = .interrupted },
        .{ .line = "1||12345|sleep|1700000000|kill\n", .want = .killed },
    };

    for (cases) |case| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(case.line, "", .{ .exited = 0 });
        const client = testClient(&recorder);

        const observation = client.observePane("api");
        defer observation.deinit(std.testing.allocator);

        try std.testing.expectEqual(observations.PaneState.dead, observation.state);
        try std.testing.expectEqual(case.want, observation.exit);
    }
}

test "tmux.observePane: carries start marker into the observation" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0||12345|node|1700000000\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const observation = client.observePane("api");
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.PaneState.busy, observation.state);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), observation.started_at);
}

test "tmux.paneInfo: ignores extra trailing fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|node|42|unexpected\n", "", .{ .exited = 0 });
    const client = testClient(&recorder);

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.dead);
    try std.testing.expectEqualStrings("12345", info.pid);
    try std.testing.expectEqualStrings("node", info.command);
}

test "tmux.observePane: pending spawn is busy before its child appears, dead still wins" {
    for ([_]bool{ false, true }) |dead| {
        var recorder = runner.Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue(if (dead) "1|3|123|sh|1700000000|||token\n" else "0||123|sh|1700000000|||token\n", "", .{ .exited = 0 });
        const observation = testClient(&recorder).observePane("api");
        defer observation.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (dead) observations.PaneState.dead else observations.PaneState.busy, observation.state);
        try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
        try runner.expectNoRemainingResponses(&recorder);
    }
}
