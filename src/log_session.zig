const std = @import("std");
const config = @import("config.zig");
const env = @import("infra/env.zig");
const paths = @import("infra/paths.zig");
const runner_mod = @import("infra/runner.zig");
const tmux_client = @import("infra/tmux.zig");
const tmux_options = @import("tmux_options.zig");

pub const Manager = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const env.Map,
    cfg: config.Config,
    runner: runner_mod.Runner,
    tmux: tmux_client.Client,

    pub fn init(self: Manager) !void {
        const session_id = try self.sessionId();
        const session_dir = try self.dirForSession(session_id);
        _ = try self.runner.run(&.{ "mkdir", "-p", session_dir }, .{ .check = true, .discard = true });
        _ = try self.runner.run(&.{ "chmod", "700", session_dir }, .{ .check = true, .discard = true });
        try self.tmux.setOption(tmux_options.log_session_id, session_id);
        try self.cleanupOld();
    }

    pub fn dir(self: Manager) ![]const u8 {
        const session_id = self.tmux.showOption(tmux_options.log_session_id) catch null;
        const value = session_id orelse return error.LogSessionNotInitialized;
        try validateSessionId(value);
        return self.dirForSession(value);
    }

    pub fn prepareLogFile(self: Manager, service: []const u8) ![]const u8 {
        const log_dir = try self.dir();
        _ = try self.runner.run(&.{ "mkdir", "-p", log_dir }, .{ .check = true, .discard = true });
        _ = try self.runner.run(&.{ "chmod", "700", log_dir }, .{ .check = true, .discard = true });
        const log_file = try std.fs.path.join(self.gpa, &.{ log_dir, try std.fmt.allocPrint(self.gpa, "{s}.log", .{service}) });
        _ = try self.runner.run(&.{ "touch", log_file }, .{ .check = true, .discard = true });
        _ = try self.runner.run(&.{ "chmod", "600", log_file }, .{ .check = true, .discard = true });
        return log_file;
    }

    fn baseDir(self: Manager) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try paths.dataBase(self.gpa, self.environ), try self.cfg.projectName(), "logs" });
    }

    fn dirForSession(self: Manager, session_id: []const u8) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try self.baseDir(), session_id });
    }

    fn sessionId(self: Manager) ![]const u8 {
        const result = runner_mod.captured(try self.runner.run(&.{ "date", "+%Y%m%d_%H%M%S" }, .{}));
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return try self.gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn cleanupOld(self: Manager) !void {
        const base = try self.baseDir();
        const keep = self.cfg.logKeepSessions();
        if (keep < 0) return;
        var base_dir = std.Io.Dir.openDirAbsolute(self.io, base, .{ .iterate = true }) catch return;
        defer base_dir.close(self.io);

        var entries: std.ArrayList(LogEntry) = .empty;
        defer {
            for (entries.items) |entry| self.gpa.free(entry.name);
            entries.deinit(self.gpa);
        }
        var it = base_dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            validateSessionId(entry.name) catch continue;
            const stat = base_dir.statFile(self.io, entry.name, .{}) catch continue;
            try entries.append(self.gpa, .{ .name = try self.gpa.dupe(u8, entry.name), .mtime = stat.mtime.nanoseconds });
        }
        std.mem.sort(LogEntry, entries.items, {}, logEntryNewer);

        const keep_count: usize = @intCast(keep);
        if (entries.items.len <= keep_count) return;
        for (entries.items[keep_count..]) |entry| {
            const path = try std.fs.path.join(self.gpa, &.{ base, entry.name });
            std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
        }
    }
};

const LogEntry = struct {
    name: []const u8,
    mtime: i96,
};

fn logEntryNewer(_: void, lhs: LogEntry, rhs: LogEntry) bool {
    return lhs.mtime > rhs.mtime;
}

fn validateSessionId(value: []const u8) !void {
    if (value.len == 0) return error.InvalidLogSessionId;
    for (value) |byte| {
        switch (byte) {
            '0'...'9', '_' => {},
            else => return error.InvalidLogSessionId,
        }
    }
}

test "validates log session ids" {
    try validateSessionId("20260523_010203");
    try std.testing.expect(logEntryNewer({}, .{ .name = "new", .mtime = 2 }, .{ .name = "old", .mtime = 1 }));
    try std.testing.expectError(error.InvalidLogSessionId, validateSessionId("../bad"));
    try std.testing.expectError(error.InvalidLogSessionId, validateSessionId("bad name"));
    try std.testing.expectError(error.InvalidLogSessionId, validateSessionId(""));
}
