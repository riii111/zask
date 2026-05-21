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

    pub fn selectWindow(self: Client, window: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "select-window", "-t", try self.target(window) });
    }

    pub fn killSession(self: Client) !void {
        _ = try self.runner.run(&.{ "tmux", "kill-session", "-t", self.session });
    }

    pub fn setOption(self: Client, name: []const u8, value: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "set-option", "-t", self.session, name, value });
    }

    pub fn bindRunShell(self: Client, key: []const u8, command: []const u8) !void {
        _ = try self.runner.run(&.{ "tmux", "bind-key", "-T", "prefix", key, "run-shell", command });
    }

    pub fn sendKeys(self: Client, pane_target: []const u8, keys: []const []const u8) !void {
        var argv = std.array_list.Managed([]const u8).init(self.gpa);
        try argv.appendSlice(&.{ "tmux", "send-keys", "-t", pane_target });
        try argv.appendSlice(keys);
        _ = try self.runner.run(argv.items);
    }

    pub fn pipePane(self: Client, pane_target: []const u8, command: ?[]const u8) !void {
        if (command) |cmd| {
            _ = try self.runner.run(&.{ "tmux", "pipe-pane", "-t", pane_target, cmd });
        } else {
            _ = try self.runner.run(&.{ "tmux", "pipe-pane", "-t", pane_target });
        }
    }

    pub fn panePid(self: Client, pane_target: []const u8) !?[]const u8 {
        const result = self.runner.run(&.{ "tmux", "list-panes", "-t", pane_target, "-F", "#{pane_pid}" }) catch return null;
        defer self.gpa.free(result.stderr);
        return try self.gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    pub fn target(self: Client, window: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ self.session, window });
    }
};
