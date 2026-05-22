const std = @import("std");
const runner = @import("runner.zig");

pub const Client = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    session: []const u8,

    pub fn hasSession(self: Client) bool {
        const result = self.runner.run(&.{ "tmux", "has-session", "-t", self.session }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term == .exited and result.term.exited == 0;
    }

    pub fn switchClient(self: Client) !void {
        _ = try self.runner.run(&.{ "tmux", "switch-client", "-t", self.session });
    }

    pub fn attachSession(self: Client) !void {
        _ = try self.runner.runInteractive(&.{ "tmux", "attach-session", "-t", self.session });
    }

    pub fn detachClient(self: Client) !void {
        _ = try self.runner.run(&.{ "tmux", "detach-client" });
    }

    pub fn detachClientExec(self: Client, command: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "detach-client", "-E", command });
    }

    pub fn selectWindow(self: Client, window: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "select-window", "-t", try self.target(window) });
    }

    pub fn killSession(self: Client) !void {
        _ = try self.runner.run(&.{ "tmux", "kill-session", "-t", self.session });
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "set-option", "-t", self.session, name, value });
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
        _ = try self.runner.run(&.{ "tmux", "bind-key", "-T", "prefix", key, "run-shell", command });
    }

    pub fn popup(self: Client, width: []const u8, height: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "popup", "-w", width, "-h", height, "-E", command });
    }

    pub fn sendKeys(self: Client, pane_target: []const u8, keys: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ "tmux", "send-keys", "-t", pane_target });
        try argv.appendSlice(self.gpa, keys);
        _ = try self.runner.run(argv.items);
    }

    pub fn pipePane(self: Client, pane_target: []const u8, command: ?[]const u8) !void {
        if (command) |cmd| {
            _ = try self.runner.run(&.{ "tmux", "pipe-pane", "-t", pane_target, cmd });
        } else {
            _ = try self.runner.run(&.{ "tmux", "pipe-pane", "-t", pane_target });
        }
    }

    pub fn windowExists(self: Client, window: []const u8) bool {
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", self.target(window) catch return false }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term == .exited and result.term.exited == 0;
    }

    pub fn paneRunning(self: Client, window: []const u8) bool {
        const info = self.paneInfo(window) catch return false;
        if (info.dead) return false;
        if (!isShellCommand(info.command)) return true;
        const result = self.runner.run(&.{ "pgrep", "-P", info.pid }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return std.mem.trim(u8, result.stdout, " \t\r\n").len > 0;
    }

    pub fn paneInfo(self: Client, window: []const u8) !PaneInfo {
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", try self.target(window), "-F", "#{pane_dead}|#{pane_dead_status}|#{pane_pid}|#{pane_current_command}" }) catch return .{};
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

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
        };
    }

    pub fn panePid(self: Client, pane_target: []const u8) !?[]const u8 {
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", pane_target, "-F", "#{pane_pid}" }) catch return null;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return try self.gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    pub fn capturePane(self: Client, window: []const u8) ![]const u8 {
        const result = self.runner.run(&.{ "tmux", "capture-pane", "-t", try self.target(window), "-p" }) catch return "";
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
};

pub fn isShellCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "zsh") or std.mem.eql(u8, command, "bash") or std.mem.eql(u8, command, "sh") or command.len == 0;
}

test "sendKeys records tmux command through runner" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = std.Io.null, .recorder = &recorder };
    const client = Client{ .gpa = std.testing.allocator, .runner = run, .session = "demo" };

    try client.sendKeys("demo:api", &.{ "echo ok", "Enter" });

    const command = recorder.commands.items[0];
    try std.testing.expectEqualStrings("tmux", command.argv[0]);
    try std.testing.expectEqualStrings("send-keys", command.argv[1]);
    try std.testing.expectEqualStrings("demo:api", command.argv[3]);
    try std.testing.expectEqualStrings("echo ok", command.argv[4]);
    try std.testing.expectEqualStrings("Enter", command.argv[5]);
}
