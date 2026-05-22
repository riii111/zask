const std = @import("std");
const config = @import("config.zig");
const dashboard_ui = @import("dashboard.zig");
const docker_client = @import("docker.zig");
const lifecycle_mod = @import("lifecycle.zig");
const paths = @import("paths.zig");
const render = @import("render.zig");
const proc_runner = @import("runner.zig");
const shell = @import("shell.zig");
const tmux_client = @import("tmux.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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

    pub fn logs(self: Runtime, service: []const u8) !void {
        _ = try self.cfg.findService(service);
        if (try self.inTmux()) {
            try (try self.tmux()).switchClient();
        }
        try (try self.tmux()).selectWindow(service);
        if (!try self.inTmux()) try self.attach();
    }

    pub fn follow(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = writer;
        _ = try self.cfg.findService(service);
        const log_dir = try self.logDir();
        const mkdir_result = try self.run(&.{ "mkdir", "-p", log_dir });
        self.gpa.free(mkdir_result.stdout);
        self.gpa.free(mkdir_result.stderr);
        const log_file = try std.fs.path.join(self.gpa, &.{ log_dir, try std.fmt.allocPrint(self.gpa, "{s}.log", .{service}) });
        if (!try self.pathExists(log_file)) {
            const touch_result = try self.run(&.{ "touch", log_file });
            self.gpa.free(touch_result.stdout);
            self.gpa.free(touch_result.stderr);
        }
        try (try self.tmux()).popup(self.cfg.popupWidth(), self.cfg.popupHeight(), try std.fmt.allocPrint(self.gpa, "nvim -c 'terminal tail -F {s}'", .{try shell.quote(self.gpa, log_file)}));
    }

    pub fn hello(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        if (try self.sessionExists()) {
            try (try self.lifecycle()).startAll(profile, writer);
            try self.attach();
            return;
        }
        const session_file = try self.writeSessionFile();
        _ = try self.run(&.{ "tmuxp", "load", "-d", session_file });
        const tx = try self.tmux();
        try tx.setOption("prefix", "C-q");
        try tx.setOption("status-format[0]", "#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}");
        try tx.setOption("@mux_dash_mode", "all");
        try tx.bindRunShell("m", "mode=$(tmux show-option -qv @mux_dash_mode); if [ \"$mode\" = \"all\" ]; then tmux set-option @mux_dash_mode bad; else tmux set-option @mux_dash_mode all; fi");
        try tx.bindRunShell("f", try std.fmt.allocPrint(self.gpa, "{s} --config {s} follow \"#{{window_name}}\"", .{ self.zask_path, self.config_path }));
        try self.initLogDir();
        try self.setupPipePane();
        try (try self.lifecycle()).startAll(profile, writer);
        try self.attach();
    }

    pub fn bye(self: Runtime, writer: *std.Io.Writer) !void {
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            return;
        }
        try (try self.lifecycle()).stopAll(writer);
        try self.cleanupPipePane();
        try (try self.tmux()).killSession();
    }

    pub fn kill(self: Runtime, writer: *std.Io.Writer) !void {
        try (try self.lifecycle()).stopTarget("docker", writer);
        try self.cleanupPipePane();
        if (try self.sessionExists()) {
            try (try self.tmux()).killSession();
        } else {
            try writer.writeAll("Session not running\n");
        }
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
        const dc = try self.docker();
        const running = try dc.runningServices();
        defer self.gpa.free(running.stdout);
        defer self.gpa.free(running.stderr);
        if (std.mem.indexOf(u8, running.stdout, container) == null) {
            try writer.print("Container '{s}' is not running\n", .{container});
            return error.ContainerNotRunning;
        }
        const exec_cmd = if (use_shell) "bash" else self.cfg.dockerExecDefault(container);
        try dc.execInteractive(container, exec_cmd);
    }

    pub fn dashboard(self: Runtime, writer: *std.Io.Writer) !void {
        try dashboard_ui.runLauncher(self.gpa, self.io, self.cfg, writer);
    }

    pub fn monitorOnce(self: Runtime, writer: *std.Io.Writer) !void {
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

    fn writeSessionFile(self: Runtime) ![]const u8 {
        const dir = try std.fs.path.join(self.gpa, &.{ try paths.configBase(self.gpa), try self.cfg.projectName() });
        const mkdir_result = try self.run(&.{ "mkdir", "-p", dir });
        self.gpa.free(mkdir_result.stdout);
        self.gpa.free(mkdir_result.stderr);
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
        const result = try self.run(&.{ "mkdir", "-p", dir });
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
        try (try self.tmux()).setOption("@mux_log_session_id", session_id);
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
        _ = self;
        return std.c.getenv("TMUX") != null;
    }

    fn logDir(self: Runtime) ![]const u8 {
        const session_id = (try self.tmux()).showOption("@mux_log_session_id") catch null;
        return self.logDirForSession(session_id orelse "current");
    }

    fn logBaseDir(self: Runtime) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try paths.dataBase(self.gpa), try self.cfg.projectName(), "logs" });
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
        const script = try std.fmt.allocPrint(self.gpa, "ls -dt {s}/*/ 2>/dev/null | tail -n +{d} | xargs rm -rf", .{ try shell.quote(self.gpa, base), keep + 1 });
        const result = self.run(&.{ "bash", "-c", script }) catch return;
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    fn pathExists(self: Runtime, path: []const u8) !bool {
        return paths.exists(self.io, path);
    }

    fn run(self: Runtime, argv: []const []const u8) !std.process.RunResult {
        return try self.runner().run(argv);
    }

    fn runInteractive(self: Runtime, argv: []const []const u8) !std.process.Child.Term {
        return try self.runner().runInteractive(argv);
    }
};
