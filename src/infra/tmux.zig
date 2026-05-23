const std = @import("std");
const observations = @import("../observations.zig");
const runner = @import("runner.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    session: []const u8,

    pub fn hasSession(self: Client) bool {
        return self.observeSession() == .active;
    }

    pub fn observeSession(self: Client) observations.SessionObservation {
        const result = self.runner.run(&.{ "tmux", "has-session", "-t", self.session }) catch return .unavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return .active;
        if (result.term == .exited) return .missing;
        return .unavailable;
    }

    pub fn switchClient(self: Client) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "switch-client", "-t", self.session });
    }

    pub fn attachSession(self: Client) !void {
        _ = try self.runner.runInteractiveChecked(&.{ "tmux", "attach-session", "-t", self.session });
    }

    pub fn detachClient(self: Client) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "detach-client" });
    }

    pub fn detachClientExec(self: Client, command: []const u8) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "detach-client", "-E", command });
    }

    pub fn selectWindow(self: Client, window: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        try self.runner.runCheckedDiscard(&.{ "tmux", "select-window", "-t", pane_target });
    }

    pub fn killSession(self: Client) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "kill-session", "-t", self.session });
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "set-option", "-t", self.session, name, value });
    }

    pub fn setWindowOption(self: Client, name: []const u8, value: []const u8) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "set-window-option", "-t", self.session, name, value });
    }

    pub fn showOption(self: Client, name: []const u8) !?[]const u8 {
        const result = self.runner.run(&.{ "tmux", "show-option", "-t", self.session, "-qv", name }) catch return null;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        const value = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (value.len == 0) return null;
        return try self.gpa.dupe(u8, value);
    }

    pub fn bindRunShell(self: Client, key: []const u8, command: []const u8) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "bind-key", "-T", "prefix", key, "run-shell", command });
    }

    pub fn resizeWindowToActiveClient(self: Client, window: []const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        try self.runner.runCheckedDiscard(&.{ "tmux", "resize-window", "-a", "-t", pane_target });
    }

    pub fn popup(self: Client, width: []const u8, height: []const u8, command: []const u8) !void {
        try self.runner.runCheckedDiscard(&.{ "tmux", "popup", "-w", width, "-h", height, "-E", command });
    }

    pub fn sendKeys(self: Client, pane_target: []const u8, keys: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ "tmux", "send-keys", "-t", pane_target });
        try argv.appendSlice(self.gpa, keys);
        try self.runner.runCheckedDiscard(argv.items);
    }

    pub fn pipePane(self: Client, pane_target: []const u8, command: ?[]const u8) !void {
        if (command) |cmd| {
            try self.runner.runCheckedDiscard(&.{ "tmux", "pipe-pane", "-t", pane_target, cmd });
        } else {
            try self.runner.runCheckedDiscard(&.{ "tmux", "pipe-pane", "-t", pane_target });
        }
    }

    pub fn windowExists(self: Client, window: []const u8) bool {
        return self.observeWindow(window) == .present;
    }

    pub fn observeWindow(self: Client, window: []const u8) observations.WindowObservation {
        const pane_target = self.target(window) catch return .unavailable;
        defer self.gpa.free(pane_target);
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", pane_target }) catch return .unavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) return .present;
        if (result.term == .exited) return .missing;
        return .unavailable;
    }

    pub fn paneRunning(self: Client, window: []const u8) bool {
        const observation = self.observePane(window);
        defer observation.deinit(self.gpa);
        return observation.running();
    }

    pub fn observePane(self: Client, window: []const u8) observations.PaneObservation {
        const info = self.paneInfo(window) catch |err| switch (err) {
            error.WindowMissing => return .{ .state = .window_missing },
            else => return .{ .state = .tmux_unavailable },
        };
        if (info.dead) return .{
            .state = .dead,
            .exit_code = info.exit_code,
            .pid = info.pid,
            .command = info.command,
            .owned = info.owned,
        };
        const result = self.runner.run(&.{ "pgrep", "-P", info.pid }) catch return .{
            .state = .tmux_unavailable,
            .exit_code = info.exit_code,
            .pid = info.pid,
            .command = info.command,
            .owned = info.owned,
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return .{
            .state = if (std.mem.trim(u8, result.stdout, " \t\r\n").len > 0) .busy else .idle,
            .exit_code = info.exit_code,
            .pid = info.pid,
            .command = info.command,
            .owned = info.owned,
        };
    }

    pub fn paneInfo(self: Client, window: []const u8) !PaneInfo {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", pane_target, "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}" }) catch return error.TmuxUnavailable;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited) return error.TmuxUnavailable;
        if (result.term.exited != 0) return error.WindowMissing;

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        const line = lines.next() orelse return .{};
        var fields = std.mem.splitScalar(u8, line, '|');
        const dead = fields.next() orelse "0";
        const exit_code = fields.next() orelse "0";
        const pid = fields.next() orelse "0";
        const command = fields.next() orelse "";
        return .{
            .dead = std.mem.eql(u8, dead, "1"),
            .exit_code = try self.gpa.dupe(u8, exit_code),
            .pid = try self.gpa.dupe(u8, pid),
            .command = try self.gpa.dupe(u8, command),
            .owned = true,
        };
    }

    pub fn capturePane(self: Client, window: []const u8) ![]const u8 {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        const result = self.runner.run(&.{ "tmux", "capture-pane", "-t", pane_target, "-p" }) catch return "";
        defer self.gpa.free(result.stderr);
        return result.stdout;
    }

    pub fn target(self: Client, window: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ self.session, window });
    }
};

pub const PaneInfo = struct {
    dead: bool = false,
    exit_code: []const u8 = "0",
    pid: []const u8 = "0",
    command: []const u8 = "",
    owned: bool = false,

    pub fn deinit(self: PaneInfo, gpa: std.mem.Allocator) void {
        if (!self.owned) return;
        gpa.free(self.exit_code);
        gpa.free(self.pid);
        gpa.free(self.command);
    }
};

pub fn isShellCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "zsh") or std.mem.eql(u8, command, "bash") or std.mem.eql(u8, command, "sh") or command.len == 0;
}

test "sendKeys records tmux command through runner" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.sendKeys("demo:api", &.{ "echo ok", "Enter" });

    const command = recorder.commands.items[0];
    try std.testing.expectEqualStrings("tmux", command.argv[0]);
    try std.testing.expectEqualStrings("send-keys", command.argv[1]);
    try std.testing.expectEqualStrings("demo:api", command.argv[3]);
    try std.testing.expectEqualStrings("echo ok", command.argv[4]);
    try std.testing.expectEqualStrings("Enter", command.argv[5]);
}

test "resizeWindowToActiveClient records resize command" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.resizeWindowToActiveClient("api");

    const command = recorder.commands.items[0];
    try std.testing.expectEqualStrings("tmux", command.argv[0]);
    try std.testing.expectEqualStrings("resize-window", command.argv[1]);
    try std.testing.expectEqualStrings("-a", command.argv[2]);
    try std.testing.expectEqualStrings("demo:api", command.argv[4]);
}

test "paneRunning checks pane child processes" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try std.testing.expect(client.paneRunning("api"));
    try std.testing.expectEqualStrings("pgrep", recorder.commands.items[1].argv[0]);
    try std.testing.expectEqualStrings("-P", recorder.commands.items[1].argv[1]);
    try std.testing.expectEqualStrings("12345", recorder.commands.items[1].argv[2]);
}

test "paneRunning rejects dead panes and panes without children" {
    var dead_recorder = runner.Recorder.init(std.testing.allocator);
    defer dead_recorder.deinit();
    try dead_recorder.enqueue("1|130|12345|node\n", "", .{ .exited = 0 });
    const dead_run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &dead_recorder };
    const dead_client = Client{ .gpa = std.testing.allocator, .runner = dead_run, .session = "demo" };
    try std.testing.expect(!dead_client.paneRunning("api"));
    try std.testing.expectEqual(@as(usize, 1), dead_recorder.commands.items.len);

    var idle_recorder = runner.Recorder.init(std.testing.allocator);
    defer idle_recorder.deinit();
    try idle_recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try idle_recorder.enqueue("\n", "", .{ .exited = 1 });
    const idle_run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &idle_recorder };
    const idle_client = Client{ .gpa = std.testing.allocator, .runner = idle_run, .session = "demo" };
    try std.testing.expect(!idle_client.paneRunning("api"));
}

test "showOption trims empty output to null" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue(" \n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try std.testing.expect(try client.showOption("@zask_dash_mode") == null);
}
