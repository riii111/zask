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
        if (result.term == .exited) return .missing;
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

    pub fn detachClient(self: Client) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client" }, .{ .check = true, .discard = true });
    }

    pub fn detachClientExec(self: Client, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "detach-client", "-E", command }, .{ .check = true, .discard = true });
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
        if (result.term == .exited) return .missing;
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
        const run_result = self.runner.run(&.{ "pgrep", "-P", info.pid }, .{}) catch return .{
            .state = .tmux_unavailable,
            .exit_code = info.exit_code,
            .pid = info.pid,
            .command = info.command,
            .owned = info.owned,
        };
        const result = runner.captured(run_result);
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
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "list-panes", "-t", pane_target, "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}" }, .{}) catch return error.TmuxUnavailable);
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
        const result = runner.captured(self.runner.run(&.{ self.tmux_path, "capture-pane", "-t", pane_target, "-p" }, .{}) catch return "");
        defer self.gpa.free(result.stderr);
        return result.stdout;
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

    pub fn pipePane(self: Client, window: []const u8, command: ?[]const u8) !void {
        const pane_target = try self.target(window);
        defer self.gpa.free(pane_target);
        if (command) |cmd| {
            _ = try self.runner.run(&.{ self.tmux_path, "pipe-pane", "-t", pane_target, cmd }, .{ .check = true, .discard = true });
        } else {
            _ = try self.runner.run(&.{ self.tmux_path, "pipe-pane", "-t", pane_target }, .{ .check = true, .discard = true });
        }
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "set-option", "-t", self.session, name, value }, .{ .check = true, .discard = true });
    }

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

    pub fn popup(self: Client, width: []const u8, height: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ self.tmux_path, "popup", "-w", width, "-h", height, "-E", command }, .{ .check = true, .discard = true });
    }

    fn target(self: Client, window: []const u8) ![]const u8 {
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

    try client.sendKeys("api", &.{ "echo ok", "Enter" });

    const command = recorder.commands.items[0];
    try std.testing.expectEqualStrings("tmux", command.argv[0]);
    try std.testing.expectEqualStrings("send-keys", command.argv[1]);
    try std.testing.expectEqualStrings("demo:api", command.argv[3]);
    try std.testing.expectEqualStrings("echo ok", command.argv[4]);
    try std.testing.expectEqualStrings("Enter", command.argv[5]);
}

test "session construction records tmux commands through runner" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.newSession("dashboard", "/tmp/demo app", "zask dashboard");
    try client.splitWindow("dashboard", "/tmp/demo app", "zask monitor");
    try client.setWindowOption("dashboard", "main-pane-width", "50%");
    try client.selectLayout("dashboard", "main-vertical");
    try client.newWindow("api", "/tmp/demo app/backend", "echo waiting");
    try client.newWindowAfter("api", "worker", "/tmp/demo app/worker", "echo worker");

    const session = recorder.commands.items[0];
    try std.testing.expectEqualStrings("tmux", session.argv[0]);
    try std.testing.expectEqualStrings("new-session", session.argv[1]);
    try std.testing.expectEqualStrings("-d", session.argv[2]);
    try std.testing.expectEqualStrings("demo", session.argv[4]);
    try std.testing.expectEqualStrings("dashboard", session.argv[6]);
    try std.testing.expectEqualStrings("/tmp/demo app", session.argv[8]);
    try std.testing.expectEqualStrings("zask dashboard", session.argv[9]);

    const split = recorder.commands.items[1];
    try std.testing.expectEqualStrings("split-window", split.argv[1]);
    try std.testing.expectEqualStrings("demo:dashboard", split.argv[3]);
    try std.testing.expectEqualStrings("/tmp/demo app", split.argv[5]);
    try std.testing.expectEqualStrings("zask monitor", split.argv[6]);

    const option = recorder.commands.items[2];
    try std.testing.expectEqualStrings("set-window-option", option.argv[1]);
    try std.testing.expectEqualStrings("demo:dashboard", option.argv[3]);
    try std.testing.expectEqualStrings("main-pane-width", option.argv[4]);
    try std.testing.expectEqualStrings("50%", option.argv[5]);

    const layout = recorder.commands.items[3];
    try std.testing.expectEqualStrings("select-layout", layout.argv[1]);
    try std.testing.expectEqualStrings("demo:dashboard", layout.argv[3]);
    try std.testing.expectEqualStrings("main-vertical", layout.argv[4]);

    const window = recorder.commands.items[4];
    try std.testing.expectEqualStrings("new-window", window.argv[1]);
    try std.testing.expectEqualStrings("-d", window.argv[2]);
    try std.testing.expectEqualStrings("demo", window.argv[4]);
    try std.testing.expectEqualStrings("api", window.argv[6]);
    try std.testing.expectEqualStrings("/tmp/demo app/backend", window.argv[8]);
    try std.testing.expectEqualStrings("echo waiting", window.argv[9]);

    const after_window = recorder.commands.items[5];
    try std.testing.expectEqualStrings("new-window", after_window.argv[1]);
    try std.testing.expectEqualStrings("-d", after_window.argv[2]);
    try std.testing.expectEqualStrings("-a", after_window.argv[3]);
    try std.testing.expectEqualStrings("demo:api", after_window.argv[5]);
    try std.testing.expectEqualStrings("worker", after_window.argv[7]);
    try std.testing.expectEqualStrings("/tmp/demo app/worker", after_window.argv[9]);
    try std.testing.expectEqualStrings("echo worker", after_window.argv[10]);
}

test "client lifecycle commands record tmux argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.switchClient();
    try client.attachSession();
    try client.detachClient();
    try client.detachClientExec("zask re");
    try client.killSession();

    try std.testing.expectEqualStrings("switch-client", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("attach-session", recorder.commands.items[1].argv[1]);
    try std.testing.expect(recorder.commands.items[1].interactive);
    try std.testing.expectEqualStrings("detach-client", recorder.commands.items[2].argv[1]);
    try std.testing.expectEqualStrings("-E", recorder.commands.items[3].argv[2]);
    try std.testing.expectEqualStrings("zask re", recorder.commands.items[3].argv[3]);
    try std.testing.expectEqualStrings("kill-session", recorder.commands.items[4].argv[1]);
}

test "options popup and pipe helpers record tmux argv" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.setOption("@mode", "all");
    try client.bindRunShell("f", "zask follow api");
    try client.popup("80%", "60%", "tail -f log");
    try client.pipePane("api", "cat >> api.log");
    try client.pipePane("api", null);

    try std.testing.expectEqualStrings("set-option", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("@mode", recorder.commands.items[0].argv[4]);
    try std.testing.expectEqualStrings("bind-key", recorder.commands.items[1].argv[1]);
    try std.testing.expectEqualStrings("f", recorder.commands.items[1].argv[4]);
    try std.testing.expectEqualStrings("run-shell", recorder.commands.items[1].argv[5]);
    try std.testing.expectEqualStrings("popup", recorder.commands.items[2].argv[1]);
    try std.testing.expectEqualStrings("80%", recorder.commands.items[2].argv[3]);
    try std.testing.expectEqualStrings("tail -f log", recorder.commands.items[2].argv[7]);
    try std.testing.expectEqualStrings("pipe-pane", recorder.commands.items[3].argv[1]);
    try std.testing.expectEqualStrings("cat >> api.log", recorder.commands.items[3].argv[4]);
    try std.testing.expectEqual(@as(usize, 4), recorder.commands.items[4].argv.len);
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

test "showOption returns non-empty trimmed output" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue(" all \n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    const value = (try client.showOption("@zask_dash_mode")).?;
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("all", value);
}

test "capturePane returns captured stdout" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("line one\nline two\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    const output = try client.capturePane("api");
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("line one\nline two\n", output);
}

test "paneInfo uses first pane line and preserves parsed fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("0|0|111|zsh\n0|0|222|node\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(!info.dead);
    try std.testing.expectEqualStrings("0", info.exit_code);
    try std.testing.expectEqualStrings("111", info.pid);
    try std.testing.expectEqualStrings("zsh", info.command);
}

test "paneInfo defaults missing fields" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("1\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    const info = try client.paneInfo("api");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.dead);
    try std.testing.expectEqualStrings("0", info.exit_code);
    try std.testing.expectEqualStrings("0", info.pid);
    try std.testing.expectEqualStrings("", info.command);
}
