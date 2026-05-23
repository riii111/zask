const std = @import("std");
const config = @import("config.zig");
const dashboard_ui = @import("ui/dashboard.zig");
const docker_client = @import("infra/docker.zig");
const env = @import("infra/env.zig");
const lifecycle_mod = @import("lifecycle.zig");
const lock = @import("infra/lock.zig");
const paths = @import("infra/paths.zig");
const render = @import("ui/render.zig");
const proc_runner = @import("infra/runner.zig");
const shell = @import("infra/shell.zig");
const tmux_client = @import("infra/tmux.zig");
const tmux_options = @import("tmux_options.zig");
const validate = @import("validate.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const env.Map = null,
    cfg: config.Config,
    config_path: []const u8,
    zask_path: []const u8,

    pub fn renderSession(self: Runtime, writer: *std.Io.Writer) !void {
        try render.renderTmuxp(self.cfg, self.gpa, writer, self.zask_path, self.config_path);
    }

    pub fn list(self: Runtime, writer: *std.Io.Writer) !void {
        if (self.cfg.dockerEnabled()) try writer.writeAll("docker\n");
        for (try self.cfg.services()) |service| {
            try writer.print("{s}\n", .{try config.Config.serviceName(service)});
        }
    }

    pub fn status(self: Runtime, writer: *std.Io.Writer) !void {
        if (!try self.sessionExists()) {
            try writer.print("Session '{s}' is not running\n", .{try self.cfg.sessionName()});
            return;
        }
        try writer.print("{s} Service Status\n", .{try self.cfg.projectName()});
        if (self.cfg.dockerEnabled()) {
            try writer.print("  docker-compose: {s}\n", .{if (try self.dockerRunning()) "running" else "stopped"});
        }
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            try writer.print("  {s} {s} [{s}]\n", .{ name, if (try self.serviceRunning(name)) "running" else "stopped", config.Config.serviceGroup(service) });
        }
    }

    pub fn attach(self: Runtime) !void {
        if (try self.inTmux()) {
            try (try self.tmux()).switchClient();
        } else {
            try (try self.tmux()).attachSession();
        }
    }

    pub fn detach(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            try (try self.tmux()).detachClient();
        } else {
            try writer.writeAll("Not in tmux session\n");
        }
    }

    pub fn logs(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            try writer.flush();
            return error.SessionNotRunning;
        }
        if (try self.inTmux()) {
            try (try self.tmux()).switchClient();
        }
        try (try self.tmux()).selectWindow(service);
        if (!try self.inTmux()) try self.attach();
    }

    pub fn follow(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            try writer.flush();
            return error.SessionNotRunning;
        }
        const log_dir = self.logDir() catch |err| switch (err) {
            error.LogSessionNotInitialized => {
                try writer.writeAll("Log session not initialized. Run 'hello' first.\n");
                try writer.flush();
                return error.LogSessionNotInitialized;
            },
            else => return err,
        };
        try self.runner().runCheckedDiscard(&.{ "mkdir", "-p", log_dir });
        const log_file = try std.fs.path.join(self.gpa, &.{ log_dir, try std.fmt.allocPrint(self.gpa, "{s}.log", .{service}) });
        if (!try self.pathExists(log_file)) {
            try self.runner().runCheckedDiscard(&.{ "touch", log_file });
        }
        try (try self.tmux()).popup(self.cfg.popupWidth(), self.cfg.popupHeight(), try std.fmt.allocPrint(self.gpa, "nvim -c 'terminal tail -F {s}'", .{try shell.quote(self.gpa, log_file)}));
    }

    pub fn hello(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        const guard = try self.acquireLock();
        defer guard.release();
        try self.helloUnlocked(profile, writer);
    }

    pub fn helloUnlocked(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        if (try self.sessionExists()) {
            try (try self.lifecycle()).startAll(profile, writer);
            try self.attach();
            return;
        }
        const session_file = try self.writeSessionFile();
        try self.runner().runCheckedDiscard(&.{ "tmuxp", "load", "-d", session_file });
        const tx = try self.tmux();
        try tx.setOption("prefix", "C-q");
        try tx.setOption("status-format[0]", "#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}");
        try tx.setOption(tmux_options.dash_mode, "all");
        try tx.setOption(tmux_options.zask_path, self.zask_path);
        try tx.setOption(tmux_options.config_path, self.config_path);
        try tx.bindRunShell("m", try std.fmt.allocPrint(self.gpa, "session=\"#{{session_name}}\"; mode=$(tmux show-option -t \"$session\" -qv {s}); if [ \"$mode\" = \"all\" ]; then tmux set-option -t \"$session\" {s} bad; else tmux set-option -t \"$session\" {s} all; fi", .{ tmux_options.dash_mode, tmux_options.dash_mode, tmux_options.dash_mode }));
        try tx.bindRunShell("f", try std.fmt.allocPrint(self.gpa, "session=\"#{{session_name}}\"; zask=$(tmux show-option -t \"$session\" -qv {s}); config=$(tmux show-option -t \"$session\" -qv {s}); \"$zask\" --config \"$config\" follow \"#{{window_name}}\"", .{ tmux_options.zask_path, tmux_options.config_path }));
        try self.resizeWindows();
        try self.initLogDir();
        try self.setupPipePane();
        try (try self.lifecycle()).startAll(profile, writer);
        try self.attach();
    }

    pub fn bye(self: Runtime, writer: *std.Io.Writer) !void {
        const guard = try self.acquireLock();
        defer guard.release();
        try self.byeUnlocked(writer);
    }

    fn byeUnlocked(self: Runtime, writer: *std.Io.Writer) !void {
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            return;
        }
        try (try self.lifecycle()).stopAll(writer);
        try self.cleanupPipePane();
        try (try self.tmux()).killSession();
    }

    pub fn kill(self: Runtime, writer: *std.Io.Writer) !void {
        const guard = try self.acquireLock();
        defer guard.release();
        try (try self.lifecycle()).stopDocker(writer);
        try self.cleanupPipePane();
        if (try self.sessionExists()) {
            try (try self.tmux()).killSession();
        } else {
            try writer.writeAll("Session not running\n");
        }
    }

    pub fn re(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            try (try self.tmux()).detachClientExec(try std.fmt.allocPrint(self.gpa, "{s} --config {s} re", .{ try shell.quote(self.gpa, self.zask_path), try shell.quote(self.gpa, self.config_path) }));
            return;
        }
        const guard = try self.acquireLock();
        defer guard.release();
        try self.byeUnlocked(writer);
        try self.helloUnlocked("all", writer);
    }

    pub fn up(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        try (try self.lifecycle()).startTarget(target, writer);
    }

    pub fn stop(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        try (try self.lifecycle()).stopTarget(target, writer);
    }

    pub fn restart(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        try (try self.lifecycle()).restartTarget(target, writer);
    }

    pub fn exec(self: Runtime, container: []const u8, use_shell: bool, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return error.DockerDisabled;
        try validate.identifier(container);
        const dc = try self.docker();
        const running = try dc.runningServices();
        defer self.gpa.free(running.stdout);
        defer self.gpa.free(running.stderr);
        if (running.term != .exited or running.term.exited != 0) {
            try writer.writeAll("Docker compose services unavailable\n");
            return error.DockerUnavailable;
        }
        if (std.mem.trim(u8, running.stdout, " \t\r\n").len == 0) {
            try writer.writeAll("No running containers. Run 'up docker' first.\n");
            return error.ContainerNotRunning;
        }
        if (!serviceListContains(running.stdout, container)) {
            try writer.print("Container '{s}' is not running\n", .{container});
            try writer.writeAll("Running containers:\n");
            var lines = std.mem.splitScalar(u8, running.stdout, '\n');
            while (lines.next()) |line| {
                const item = std.mem.trim(u8, line, " \t\r");
                if (item.len > 0) try writer.print("  {s}\n", .{item});
            }
            return error.ContainerNotRunning;
        }
        const exec_cmd = if (use_shell) "bash" else self.cfg.dockerExecDefault(container);
        try dc.execInteractive(container, exec_cmd);
    }

    pub fn dashboard(self: Runtime, writer: *std.Io.Writer) !void {
        try dashboard_ui.runLauncher(self.gpa, self.io, self.environ, self.cfg, writer);
    }

    pub fn monitor(self: Runtime, writer: *std.Io.Writer) !void {
        try dashboard_ui.runMonitor(self.gpa, self.io, self.cfg, writer);
    }

    fn runner(self: Runtime) proc_runner.Runner {
        return .{ .gpa = self.gpa, .io = self.io };
    }

    fn tmux(self: Runtime) !tmux_client.Client {
        return .{ .gpa = self.gpa, .runner = self.runner(), .session = try self.cfg.sessionName() };
    }

    fn docker(self: Runtime) !docker_client.Compose {
        return .{
            .gpa = self.gpa,
            .runner = self.runner(),
            .dir = try self.cfg.dockerDir(self.gpa),
            .file = self.cfg.dockerComposeFile(),
        };
    }

    fn lifecycle(self: Runtime) !lifecycle_mod.Lifecycle {
        return .{
            .gpa = self.gpa,
            .cfg = self.cfg,
            .runner = self.runner(),
            .tmux = try self.tmux(),
            .docker = try self.docker(),
        };
    }

    fn acquireLock(self: Runtime) !lock.Lock {
        return lock.Lock.acquire(self.gpa, self.runner(), try self.cfg.projectName(), try paths.runtimeBase(self.gpa, self.environ));
    }

    fn writeSessionFile(self: Runtime) ![]const u8 {
        const dir = try std.fs.path.join(self.gpa, &.{ try paths.configBase(self.gpa, self.environ), try self.cfg.projectName() });
        try self.runner().runCheckedDiscard(&.{ "mkdir", "-p", dir });
        const path = try std.fs.path.join(self.gpa, &.{ dir, "session.yml" });
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try self.renderSession(&out.writer);
        try paths.writeFile(self.io, path, out.writer.buffered());
        return path;
    }

    fn initLogDir(self: Runtime) !void {
        const session_id = try self.logSessionId();
        const dir = try self.logDirForSession(session_id);
        try self.runner().runCheckedDiscard(&.{ "mkdir", "-p", dir });
        try (try self.tmux()).setOption(tmux_options.log_session_id, session_id);
        try self.cleanupOldLogs();
    }

    fn setupPipePane(self: Runtime) !void {
        const dir = try self.logDir();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            _ = (try self.tmux()).pipePane(try (try self.tmux()).target(name), try std.fmt.allocPrint(self.gpa, "cat >> {s}", .{try shell.quote(self.gpa, try std.fs.path.join(self.gpa, &.{ dir, try std.fmt.allocPrint(self.gpa, "{s}.log", .{name}) }))})) catch {};
        }
    }

    fn cleanupPipePane(self: Runtime) !void {
        if (!try self.sessionExists()) return;
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            _ = (try self.tmux()).pipePane(try (try self.tmux()).target(name), null) catch {};
        }
    }

    fn resizeWindows(self: Runtime) !void {
        const tx = try self.tmux();
        tx.resizeWindowToActiveClient("dashboard") catch {};
        for (try self.cfg.services()) |service| {
            tx.resizeWindowToActiveClient(try config.Config.serviceName(service)) catch {};
        }
        if (self.cfg.dockerEnabled()) tx.resizeWindowToActiveClient("docker") catch {};
        tx.setWindowOption("window-size", "latest") catch {};
    }

    fn sessionExists(self: Runtime) !bool {
        return (try self.tmux()).hasSession();
    }

    fn serviceRunning(self: Runtime, service: []const u8) !bool {
        return (try self.tmux()).paneRunning(service);
    }

    fn dockerRunning(self: Runtime) !bool {
        return (try self.docker()).running();
    }

    fn inTmux(self: Runtime) !bool {
        return env.exists(self.environ, "TMUX");
    }

    fn logDir(self: Runtime) ![]const u8 {
        const session_id = (try self.tmux()).showOption(tmux_options.log_session_id) catch null;
        const value = session_id orelse return error.LogSessionNotInitialized;
        try validateLogSessionId(value);
        return self.logDirForSession(value);
    }

    fn logBaseDir(self: Runtime) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try paths.dataBase(self.gpa, self.environ), try self.cfg.projectName(), "logs" });
    }

    fn logDirForSession(self: Runtime, session_id: []const u8) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try self.logBaseDir(), session_id });
    }

    fn logSessionId(self: Runtime) ![]const u8 {
        const result = try self.run(&.{ "date", "+%Y%m%d_%H%M%S" });
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return try self.gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    fn cleanupOldLogs(self: Runtime) !void {
        const base = try self.logBaseDir();
        const keep = self.cfg.logKeepSessions();
        if (keep < 0) return;
        var dir = std.Io.Dir.openDirAbsolute(self.io, base, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var entries: std.ArrayList(LogEntry) = .empty;
        defer {
            for (entries.items) |entry| self.gpa.free(entry.name);
            entries.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            validateLogSessionId(entry.name) catch continue;
            const stat = dir.statFile(self.io, entry.name, .{}) catch continue;
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

    fn pathExists(self: Runtime, path: []const u8) !bool {
        return paths.exists(self.io, path);
    }

    fn run(self: Runtime, argv: []const []const u8) !std.process.RunResult {
        return try self.runner().run(argv);
    }
};

fn serviceListContains(output: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), name)) return true;
    }
    return false;
}

const LogEntry = struct {
    name: []const u8,
    mtime: i96,
};

fn logEntryNewer(_: void, lhs: LogEntry, rhs: LogEntry) bool {
    return lhs.mtime > rhs.mtime;
}

fn validateLogSessionId(value: []const u8) !void {
    if (value.len == 0) return error.InvalidLogSessionId;
    for (value) |byte| {
        switch (byte) {
            '0'...'9', '_' => {},
            else => return error.InvalidLogSessionId,
        }
    }
}

test "matches docker compose services by full line" {
    try std.testing.expect(serviceListContains("api\ndb\n", "db"));
    try std.testing.expect(serviceListContains("api\r\ndb\r\n", "api"));
    try std.testing.expect(!serviceListContains("mydb\ndb-replica\n", "db"));
    try std.testing.expect(serviceListContains(" api \n", "api"));
}

test "validates log session ids" {
    try validateLogSessionId("20260523_010203");
    try std.testing.expect(logEntryNewer({}, .{ .name = "new", .mtime = 2 }, .{ .name = "old", .mtime = 1 }));
    try std.testing.expectError(error.InvalidLogSessionId, validateLogSessionId("../bad"));
    try std.testing.expectError(error.InvalidLogSessionId, validateLogSessionId("bad name"));
    try std.testing.expectError(error.InvalidLogSessionId, validateLogSessionId(""));
}
