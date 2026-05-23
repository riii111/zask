const std = @import("std");
const config = @import("config.zig");
const dashboard_ui = @import("ui/dashboard.zig");
const docker_client = @import("infra/docker.zig");
const env = @import("infra/env.zig");
const lifecycle_mod = @import("lifecycle.zig");
const lock = @import("infra/lock.zig");
const log_session = @import("log_session.zig");
const observations = @import("observations.zig");
const paths = @import("infra/paths.zig");
const render = @import("ui/render.zig");
const proc_runner = @import("infra/runner.zig");
const shell = @import("infra/shell.zig");
const tmux_client = @import("infra/tmux.zig");
const tmux_setup = @import("tmux_setup.zig");
const validate = @import("validate.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const env.Map = null,
    cfg: config.Config,
    config_path: []const u8,
    zask_path: []const u8,
    runner_impl: proc_runner.Runner,
    tmux_impl: tmux_client.Client,
    docker_impl: docker_client.Compose,

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
            const compose = (try self.docker()).observe();
            defer compose.deinit(self.gpa);
            try writer.print("  docker-compose: {s}\n", .{composeStatusText(compose.state)});
        }
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            const pane = (try self.tmux()).observePane(name);
            defer pane.deinit(self.gpa);
            try writer.print("  {s} {s} [{s}]\n", .{ name, paneStatusText(pane.state), config.Config.serviceGroup(service) });
        }
    }

    pub fn attach(self: Runtime) !void {
        const tx = try self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        } else {
            try tx.attachSession();
        }
    }

    pub fn detach(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            const tx = try self.tmux();
            try tx.detachClient();
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
        const tx = try self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        }
        try tx.selectWindow(service);
        if (!try self.inTmux()) try self.attach();
    }

    pub fn follow(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            try writer.flush();
            return error.SessionNotRunning;
        }
        const manager = try self.logSession();
        const log_file = manager.prepareLogFile(service) catch |err| switch (err) {
            error.LogSessionNotInitialized => {
                try writer.writeAll("Log session not initialized. Run 'hello' first.\n");
                try writer.flush();
                return error.LogSessionNotInitialized;
            },
            else => return err,
        };
        const tx = try self.tmux();
        try tx.popup(self.cfg.popupWidth(), self.cfg.popupHeight(), try std.fmt.allocPrint(self.gpa, "nvim -c 'terminal tail -F {s}'", .{try shell.quote(self.gpa, log_file)}));
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
        _ = try self.runner().run(&.{ "tmuxp", "load", "-d", session_file }, .{ .check = true, .discard = true });
        const tx = try self.tmux();
        errdefer tx.killSession() catch {};
        try tmux_setup.applySessionOptions(tx, self.zask_path, self.config_path);
        try tmux_setup.bindControlKeys(self.gpa, tx);
        try self.resizeWindows();
        try (try self.logSession()).init();
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
        const tx = try self.tmux();
        try tx.killSession();
    }

    pub fn kill(self: Runtime, writer: *std.Io.Writer) !void {
        const guard = try self.acquireLock();
        defer guard.release();
        try (try self.lifecycle()).stopDocker(writer);
        try self.cleanupPipePane();
        if (try self.sessionExists()) {
            const tx = try self.tmux();
            try tx.killSession();
        } else {
            try writer.writeAll("Session not running\n");
        }
    }

    pub fn re(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            const tx = try self.tmux();
            try tx.detachClientExec(try std.fmt.allocPrint(self.gpa, "{s} --config {s} re", .{ try shell.quote(self.gpa, self.zask_path), try shell.quote(self.gpa, self.config_path) }));
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
        const compose = dc.observe();
        defer compose.deinit(self.gpa);
        if (compose.state == .unavailable) {
            try writer.writeAll("Docker compose services unavailable\n");
            return error.DockerUnavailable;
        }
        if (compose.state == .empty) {
            try writer.writeAll("No running containers. Run 'up docker' first.\n");
            return error.ContainerNotRunning;
        }
        if (!compose.contains(container)) {
            try writer.print("Container '{s}' is not running\n", .{container});
            try writer.writeAll("Running containers:\n");
            for (compose.services) |service| try writer.print("  {s}\n", .{service});
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
        return self.runner_impl;
    }

    fn tmux(self: Runtime) !tmux_client.Client {
        return self.tmux_impl;
    }

    fn docker(self: Runtime) !docker_client.Compose {
        return self.docker_impl;
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

    fn logSession(self: Runtime) !log_session.Manager {
        return .{
            .gpa = self.gpa,
            .io = self.io,
            .environ = self.environ,
            .cfg = self.cfg,
            .runner = self.runner(),
            .tmux = try self.tmux(),
        };
    }

    fn acquireLock(self: Runtime) !lock.Lock {
        return lock.Lock.acquire(self.gpa, self.runner(), try self.cfg.projectName(), try paths.runtimeBase(self.gpa, self.environ));
    }

    fn writeSessionFile(self: Runtime) ![]const u8 {
        const dir = try std.fs.path.join(self.gpa, &.{ try paths.configBase(self.gpa, self.environ), try self.cfg.projectName() });
        _ = try self.runner().run(&.{ "mkdir", "-p", dir }, .{ .check = true, .discard = true });
        const path = try std.fs.path.join(self.gpa, &.{ dir, "session.yml" });
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try self.renderSession(&out.writer);
        try paths.writeFile(self.io, path, out.writer.buffered());
        return path;
    }

    fn setupPipePane(self: Runtime) !void {
        const manager = try self.logSession();
        const tx = try self.tmux();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            const target = try tx.target(name);
            defer self.gpa.free(target);
            const log_file = manager.prepareLogFile(name) catch continue;
            const quoted = shell.quote(self.gpa, log_file) catch continue;
            const command = std.fmt.allocPrint(self.gpa, "cat >> {s}", .{quoted}) catch continue;
            _ = tx.pipePane(target, command) catch {};
        }
    }

    fn cleanupPipePane(self: Runtime) !void {
        if (!try self.sessionExists()) return;
        const tx = try self.tmux();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            const target = try tx.target(name);
            defer self.gpa.free(target);
            _ = tx.pipePane(target, null) catch {};
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

    fn inTmux(self: Runtime) !bool {
        return env.exists(self.environ, "TMUX");
    }
};

fn paneStatusText(state: observations.PaneState) []const u8 {
    return switch (state) {
        .busy => "running",
        .idle, .dead, .window_missing => "stopped",
        .tmux_unavailable => "unknown",
    };
}

fn composeStatusText(state: observations.ComposeState) []const u8 {
    return switch (state) {
        .running => "running",
        .empty => "stopped",
        .unavailable => "unknown",
    };
}

test "maps observations to status text" {
    try std.testing.expectEqualStrings("running", paneStatusText(.busy));
    try std.testing.expectEqualStrings("stopped", paneStatusText(.idle));
    try std.testing.expectEqualStrings("unknown", composeStatusText(.unavailable));
}
