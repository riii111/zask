const std = @import("std");
const config = @import("../model/config.zig");
const configured_path = @import("configured_path.zig");
const docker_client = @import("../platform/docker.zig");
const env = @import("../platform/env.zig");
const lifecycle_mod = @import("lifecycle.zig");
const lock = @import("../platform/lock.zig");
const log_reader = @import("../platform/log_reader.zig");
const observations = @import("../model/observations.zig");
const paths = @import("../platform/paths.zig");
const pathing = @import("pathing.zig");
const phases = @import("phases.zig");
const proc_runner = @import("../platform/runner.zig");
const progress_mod = @import("progress.zig");
const service_log = @import("service_log.zig");
const service_observation = @import("service_observation.zig");
const session_layout = @import("session_layout.zig");
const tmux_client = @import("../platform/tmux.zig");
const tmux_setup = @import("tmux_setup.zig");
const waits = @import("waits.zig");
const zask_command = @import("zask_command.zig");

const close_kill_settle = std.Io.Duration.fromSeconds(1);
const tmux_status_bar_height = 1;

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const env.Map = null,
    cfg: config.Config,
    config_path: []const u8,
    zask_path: []const u8,
    command_hint: zask_command.InvocationHint,
    runner_impl: proc_runner.Runner,
    tmux_impl: tmux_client.Client,
    docker_impl: docker_client.Compose,
    validate_configured_dirs: bool = true,
    emit_env_file_tips: bool = true,
    lock_probe: lock.Probe = .system,
    /// See Lifecycle.service_log_dir.
    service_log_dir: ?[]const u8 = null,

    pub fn status(self: Runtime, writer: *std.Io.Writer) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.print("Session '{s}' is not running\n", .{try self.cfg.projectName()});
                return;
            },
            .unavailable => return waits.reportTmuxUnavailable(writer),
        }
        try writer.print("{s} Service Status\n", .{try self.cfg.projectName()});
        if (self.cfg.dockerEnabled()) {
            const compose = self.docker().observe();
            defer compose.deinit(self.gpa);
            try writer.print("  docker-compose: {s}\n", .{composeStatusText(compose.state)});
        }
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            const pane = self.tmux().observePane(name);
            defer pane.deinit(self.gpa);
            try writer.print("  {s} {s} [{s}]\n", .{ name, paneStatusText(pane.state), config.Config.serviceGroup(service) });
        }
    }

    /// Read-only service observation for callers outside the monitor; it shares
    /// this runtime's tmux session and compose project.
    pub fn observer(self: Runtime) service_observation.Observer {
        return .{ .gpa = self.gpa, .runner = self.runner(), .tmux = self.tmux(), .docker = self.docker() };
    }

    pub fn attach(self: Runtime, writer: *std.Io.Writer) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.writeAll("Session not running. Run 'open' first.\n");
                try writer.flush();
                return error.SessionNotRunning;
            },
            .unavailable => return waits.reportTmuxUnavailable(writer),
        }
        try self.attachExistingWithRefreshedHooks();
    }

    pub fn logs(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.writeAll("Session not running\n");
                try self.pointToSavedLog(service, writer);
                try writer.flush();
                return error.SessionNotRunning;
            },
            .unavailable => return waits.reportTmuxUnavailable(writer),
        }
        const tx = self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        }
        try tx.selectWindow(service);
        if (!try self.inTmux()) try self.attach(writer);
    }

    /// Writes only the service's recent pane lines to `out`; it never selects a
    /// window or attaches. Every failure is explained on `diag` and returned as
    /// an error, so an empty `out` on success always means an empty log.
    pub fn logsTail(self: Runtime, service: []const u8, max_lines: u32, out: *std.Io.Writer, diag: *std.Io.Writer) !void {
        try self.requireLoggedService(service, diag);
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try diag.writeAll("Session not running\n");
                try self.pointToSavedLog(service, diag);
                try diag.flush();
                return error.SessionNotRunning;
            },
            .unavailable => return waits.reportTmuxUnavailable(diag),
        }
        const lines = self.tmux().captureRecentLines(service, max_lines) catch |err| switch (err) {
            error.WindowMissing => {
                try diag.print("Service window not found: {s}\n", .{service});
                try self.pointToSavedLog(service, diag);
                try diag.flush();
                return error.ServiceWindowMissing;
            },
            error.TmuxUnavailable => return waits.reportTmuxUnavailable(diag),
            error.OutputTooLarge => {
                try diag.writeAll("Log output too large; request fewer lines\n");
                try diag.flush();
                return error.LogOutputTooLarge;
            },
            else => return err,
        };
        defer self.gpa.free(lines);
        try out.writeAll(lines);
        try out.flush();
    }

    /// Writes the saved log of the service (see service_log) to `out`, or only
    /// its last `max_lines` lines. It never touches tmux, so it reads the output
    /// of earlier runs after `close` as well as while the session runs. Every
    /// failure, including a service that has not saved output yet, is explained
    /// on `diag` and returned as an error.
    pub fn logsSaved(self: Runtime, service: []const u8, max_lines: ?u32, out: *std.Io.Writer, diag: *std.Io.Writer) !void {
        try self.requireLoggedService(service, diag);
        const path = try self.savedLogPath(service);
        defer self.gpa.free(path);
        log_reader.writeLines(self.io, path, max_lines, out) catch |err| switch (err) {
            error.FileNotFound => {
                try diag.print("No saved output for {s} yet; it is written to {s} once the service starts\n", .{ service, path });
                try diag.flush();
                return error.SavedLogMissing;
            },
            error.WriteFailed => return err,
            else => {
                try diag.print("Cannot read saved log {s} ({s})\n", .{ path, @errorName(err) });
                try diag.flush();
                return error.SavedLogUnreadable;
            },
        };
        try out.flush();
    }

    /// Writes only the saved log path of the service to `out`, whether or not
    /// the log exists yet, so it can be handed to an editor or `grep`.
    pub fn logsPath(self: Runtime, service: []const u8, out: *std.Io.Writer, diag: *std.Io.Writer) !void {
        try self.requireLoggedService(service, diag);
        const path = try self.savedLogPath(service);
        defer self.gpa.free(path);
        try out.print("{s}\n", .{path});
        try out.flush();
    }

    pub fn previewList(self: Runtime, pane_id: []const u8, client_width: u16, client_height: u16) !void {
        try self.syncWindowSizes(client_width, client_height);
        try self.tmux().chooseTree(pane_id);
    }

    /// Resizes every window to the client size, verifies, then restores
    /// auto-size for all of them. On failure the errdefer restores auto-size
    /// only for the windows already resized (windows[0..resized_count]); windows
    /// not yet resized are left untouched.
    pub fn syncWindowSizes(self: Runtime, client_width: u16, client_height: u16) !void {
        if (client_width == 0 or client_height <= tmux_status_bar_height) return error.InvalidPreviewSize;
        const expected_height = client_height - tmux_status_bar_height;
        const tx = self.tmux();

        const windows = try tx.listWindowSizes();
        defer tmux_client.freeWindowSizes(self.gpa, windows);
        var resized_count: usize = 0;
        errdefer {
            for (windows[0..resized_count]) |window| tx.restoreWindowAutoSize(window.id) catch {};
        }
        for (windows) |window| {
            try tx.resizeWindow(window.id, client_width, expected_height);
            resized_count += 1;
        }

        const resized = try tx.listWindowSizes();
        defer tmux_client.freeWindowSizes(self.gpa, resized);
        for (resized) |window| {
            if (window.width != client_width or window.height != expected_height) return error.WindowSizeMismatch;
        }
        for (resized) |window| try tx.restoreWindowAutoSize(window.id);
    }

    pub fn open(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        var progress = progress_mod.Line.init(writer);
        try self.openWithProgress(profile, &progress);
    }

    pub fn openWithProgress(self: Runtime, profile: []const u8, progress: anytype) !void {
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => switch (self.tmux().observeSession()) {
                .active => return self.attachExistingWithRefreshedHooks(),
                .missing => return err,
                .unavailable => return waits.reportTmuxUnavailable(progress.raw()),
            },
            else => return err,
        };
        defer guard.release();
        try self.openUnlockedWithProgress(profile, progress);
    }

    pub fn openUnlocked(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        var progress = progress_mod.Line.init(writer);
        try self.openUnlockedWithProgress(profile, &progress);
    }

    pub fn openUnlockedWithProgress(self: Runtime, profile: []const u8, progress: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        switch (self.tmux().observeSession()) {
            .active => {
                try progress.info("Workspace already open. Starting resources...\n", .{});
                try self.installSessionOptions(scratch);
                try tmux_setup.bindControlKeys(scratch, self.tmux());
                try self.warnServicesWithoutPort(profile, progress);
                try self.lifecycle().startAllWithProgress(profile, progress, .observe);
                try progress.step("Attaching to workspace...\n", .{});
                try progress.beforeInteractive();
                try self.attachExisting();
                return;
            },
            .missing => {},
            .unavailable => return waits.reportTmuxUnavailable(progress.raw()),
        }
        try progress.step("Opening workspace...\n", .{});
        const tx = self.tmux();
        try self.ensureOpenConfiguredPaths(scratch, progress.raw());
        try self.openSessionWithDashboardWindow(scratch);
        errdefer tx.killSession() catch {};
        try self.installSessionOptions(scratch);
        try self.configureDashboardWindow(scratch);
        try self.appendServiceAndDockerWindows(scratch);
        try self.focusDashboard();
        try tmux_setup.bindControlKeys(scratch, tx);
        try self.warnServicesWithoutPort(profile, progress);
        try self.lifecycle().startAllWithProgress(profile, progress, .prime);
        try progress.step("Attaching to workspace...\n", .{});
        try progress.beforeInteractive();
        try self.attachExisting();
    }

    pub fn close(self: Runtime, writer: *std.Io.Writer) !void {
        var progress = progress_mod.Line.init(writer);
        try self.closeWithProgress(&progress);
    }

    pub fn closeWithProgress(self: Runtime, progress: anytype) !void {
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => switch (self.tmux().observeSession()) {
                .unavailable => return waits.reportTmuxUnavailable(progress.raw()),
                else => return err,
            },
            else => return err,
        };
        defer guard.release();
        try self.closeUnlockedWithProgress(progress);
    }

    /// Teardown order is load-bearing: stop services and docker first so their
    /// stop signals reach the live panes, let them settle, then kill the tmux
    /// session. Killing the session first would orphan those resources.
    fn closeUnlockedWithProgress(self: Runtime, progress: anytype) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try progress.raw().writeAll("Session not running\n");
                return;
            },
            .unavailable => return waits.reportTmuxUnavailable(progress.raw()),
        }
        // kill-session below stops services regardless, so skip the graceful poll;
        // `stop --all` keeps it since it leaves the session running.
        try self.lifecycle().teardownResourcesWithProgress(progress);
        self.runner().sleep(close_kill_settle);
        const tx = self.tmux();
        try tx.killSession();
    }

    pub fn re(self: Runtime, writer: *std.Io.Writer) !void {
        var progress = progress_mod.Line.init(writer);
        try self.reWithProgress(&progress);
    }

    pub fn reWithProgress(self: Runtime, progress: anytype) !void {
        if (try self.inTmux()) {
            const tx = self.tmux();
            const command = try zask_command.invoke(self.gpa, self.zask_path, self.config_path, "re");
            defer self.gpa.free(command);
            try tx.detachClientExec(command);
            return;
        }
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => switch (self.tmux().observeSession()) {
                .active => return self.detachSingleClientForRe(),
                .missing => return err,
                .unavailable => return waits.reportTmuxUnavailable(progress.raw()),
            },
            else => return err,
        };
        defer guard.release();
        try self.closeUnlockedWithProgress(progress);
        try self.openUnlockedWithProgress("all", progress);
    }

    pub fn start(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().startTarget(target, writer);
    }

    pub fn stop(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().stopTarget(target, writer);
    }

    pub fn restart(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().restartTarget(target, writer);
    }

    fn requireLoggedService(self: Runtime, service: []const u8, diag: *std.Io.Writer) !void {
        _ = self.cfg.findService(service) catch |err| switch (err) {
            error.UnknownService => {
                try diag.print("Unknown service: {s}\n", .{service});
                try diag.flush();
                return error.ServiceNotFound;
            },
            else => return err,
        };
    }

    /// Caller owns the returned path.
    fn savedLogPath(self: Runtime, service: []const u8) ![]const u8 {
        const dir = self.service_log_dir orelse return error.SavedLogUnavailable;
        return service_log.servicePath(self.gpa, dir, service);
    }

    /// Points to the saved log when the pane cannot be read but earlier output
    /// was saved; it writes nothing when there is no saved log to point to.
    fn pointToSavedLog(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        const dir = self.service_log_dir orelse return;
        const path = try service_log.servicePath(self.gpa, dir, service);
        defer self.gpa.free(path);
        if (!log_reader.exists(self.io, path)) return;
        const args = try std.fmt.allocPrint(self.gpa, "logs {s} --saved", .{service});
        defer self.gpa.free(args);
        const command = try zask_command.hint(self.gpa, self.command_hint, args);
        defer self.gpa.free(command);
        try writer.print("Saved output: {s}\nRead it with: {s}\n", .{ path, command });
    }

    fn runner(self: Runtime) proc_runner.Runner {
        return self.runner_impl;
    }

    fn tmux(self: Runtime) tmux_client.Client {
        return self.tmux_impl;
    }

    fn docker(self: Runtime) docker_client.Compose {
        return self.docker_impl;
    }

    fn lifecycle(self: Runtime) lifecycle_mod.Lifecycle {
        return .{
            .gpa = self.gpa,
            .cfg = self.cfg,
            .runner = self.runner(),
            .tmux = self.tmux(),
            .docker = self.docker(),
            .validate_configured_dirs = self.validate_configured_dirs,
            .emit_env_file_tips = self.emit_env_file_tips,
            .command_hint = self.command_hint,
            .service_log_dir = self.service_log_dir,
        };
    }

    fn acquireLock(self: Runtime) !lock.Lock {
        return lock.Lock.acquire(self.gpa, self.io, try self.cfg.projectName(), try paths.runtimeBase(self.gpa, self.environ), self.lock_probe);
    }

    fn openSessionWithDashboardWindow(self: Runtime, scratch: std.mem.Allocator) !void {
        const tx = self.tmux();
        const root = try pathing.absolute(scratch, self.io, try self.cfg.projectRoot(scratch));
        try tx.newSession(session_layout.dashboard_window, root, try zask_command.invokeDashboard(scratch, self.zask_path, self.config_path));
    }

    fn installSessionOptions(self: Runtime, scratch: std.mem.Allocator) !void {
        try tmux_setup.applySessionOptions(scratch, self.tmux(), .{
            .project = try self.cfg.projectName(),
            .zask_path = self.zask_path,
            .config_path = self.config_path,
        });
    }

    fn configureDashboardWindow(self: Runtime, scratch: std.mem.Allocator) !void {
        const tx = self.tmux();
        const root = try pathing.absolute(scratch, self.io, try self.cfg.projectRoot(scratch));
        try tx.splitWindow(session_layout.dashboard_window, root, try zask_command.invokeMonitor(scratch, self.zask_path, self.config_path));
        try tx.setWindowOption(session_layout.dashboard_window, session_layout.dashboard_pane_width_option, session_layout.dashboard_pane_width_value);
        try tx.selectLayout(session_layout.dashboard_window, session_layout.dashboard_layout);
    }

    fn appendServiceAndDockerWindows(self: Runtime, scratch: std.mem.Allocator) !void {
        const tx = self.tmux();
        var previous_window: []const u8 = session_layout.dashboard_window;
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            try tx.newWindowAfter(previous_window, name, try pathing.absolute(scratch, self.io, try self.cfg.serviceDir(scratch, service)), try zask_command.waitingPlaceholder(scratch, name));
            previous_window = name;
        }
        if (self.cfg.dockerEnabled()) {
            try tx.newWindowAfter(previous_window, session_layout.docker_window, try pathing.absolute(scratch, self.io, try self.cfg.dockerDir(scratch)), try zask_command.waitingPlaceholder(scratch, session_layout.docker_placeholder_title));
        }
    }

    fn warnServicesWithoutPort(self: Runtime, profile: []const u8, progress: anytype) !void {
        if (std.mem.eql(u8, profile, "docker")) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        const services = try phases.resolvedServicePhaseServices(scratch, self.cfg, profile);
        for (services) |name| {
            const service = try self.cfg.findService(name);
            if (config.Config.servicePort(service) != null) continue;
            try progress.warn("Warning: {s} has no port; zask cannot check readiness for this service\n", .{name});
        }
    }

    fn ensureOpenConfiguredPaths(self: Runtime, scratch: std.mem.Allocator, writer: *std.Io.Writer) !void {
        if (!self.validate_configured_dirs) return;
        const project_root = try self.cfg.projectRoot(scratch);
        try self.ensureConfiguredDir(scratch, writer, .{
            .field = "project.root",
            .configured = try self.cfg.configuredProjectRoot(),
            .path = project_root,
        });
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            try self.ensureConfiguredDir(scratch, writer, .{
                .field = "service.dir",
                .service = name,
                .configured = config.Config.serviceDirValue(service),
                .project_root = project_root,
                .path = try self.cfg.serviceDir(scratch, service),
            });
            const env_files = try config.Config.serviceEnvFiles(scratch, service);
            for (env_files) |env_file| {
                try self.ensureConfiguredFile(scratch, writer, .{
                    .field = "env_file",
                    .service = name,
                    .configured = env_file.path,
                    .project_root = project_root,
                    .path = try self.cfg.serviceEnvFilePath(scratch, service, env_file),
                });
            }
        }
        if (self.cfg.dockerEnabled()) {
            try self.ensureConfiguredDir(scratch, writer, .{
                .field = "docker.compose",
                .configured = try self.cfg.configuredDockerCompose(scratch),
                .project_root = project_root,
                .path = try self.cfg.dockerDir(scratch),
            });
        }
    }

    fn ensureConfiguredDir(self: Runtime, scratch: std.mem.Allocator, writer: *std.Io.Writer, problem: configured_path.Problem) !void {
        try configured_path.ensureDir(scratch, self.io, writer, problem);
    }

    fn ensureConfiguredFile(self: Runtime, scratch: std.mem.Allocator, writer: *std.Io.Writer, problem: configured_path.Problem) !void {
        try configured_path.ensureFile(scratch, self.io, writer, problem);
    }

    fn focusDashboard(self: Runtime) !void {
        try self.tmux().selectWindow(session_layout.dashboard_window);
    }

    fn attachExistingWithRefreshedHooks(self: Runtime) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        try tmux_setup.bindClientSizeHooks(arena.allocator(), self.tmux());
        try self.attachExisting();
    }

    fn attachExisting(self: Runtime) !void {
        const tx = self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        } else {
            try tx.attachSession();
        }
    }

    fn detachSingleClientForRe(self: Runtime) !void {
        const tx = self.tmux();
        const clients = try tx.listClients();
        defer tmux_client.freeClientInfos(self.gpa, clients);
        if (clients.len != 1) return error.RestartRequiresSingleAttachedClient;

        const command = try zask_command.invoke(self.gpa, self.zask_path, self.config_path, "re");
        defer self.gpa.free(command);
        try tx.detachTargetClientExec(clients[0].name, command);
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

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testCloseUnlocked(runtime: Runtime, writer: *std.Io.Writer) !void {
    var progress = progress_mod.Line.init(writer);
    try runtime.closeUnlockedWithProgress(&progress);
}

test "runtime.status: maps observations to text" {
    try std.testing.expectEqualStrings("running", paneStatusText(.busy));
    try std.testing.expectEqualStrings("stopped", paneStatusText(.idle));
    try std.testing.expectEqualStrings("unknown", composeStatusText(.unavailable));
}

test "runtime.status: reports session not running when missing" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.status(&writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "is not running") != null);
}

test "runtime.status: renders dead pane and unavailable docker as degraded text" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose":"compose.yaml"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "no daemon", .{ .exited = 1 });
    try recorder.enqueue("1|130|12345|node\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.status(&writer);

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "docker-compose: unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "api stopped [backend]") != null);
}

test "runtime.status: distinguishes tmux unavailable from session missing" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.FileNotFound);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, runtime.status(&writer));

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "tmux unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "is not running") == null);
}

test "runtime.attach: reports tmux unavailable distinctly from missing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.FileNotFound);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, runtime.attach(&writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
}

test "runtime.logs: reports tmux unavailable distinctly from missing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, runtime.logs("api", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
}

test "runtime.close: kills session after signaling services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testCloseUnlocked(runtime, &writer);

    try proc_runner.expectCommandOrder(&recorder, "C-c", "kill-session");
    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.close: kills session after resource stop" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testCloseUnlocked(runtime, &writer);

    const kill_index = recorder.commands.items.len - 1;
    try proc_runner.expectCommandOrder(&recorder, "C-c", "down");
    try proc_runner.expectCommandOrder(&recorder, "down", "kill-session");
    try proc_runner.expectCommandArg(recorder.commands.items[kill_index], 1, "kill-session");
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(close_kill_settle, recorder.sleeps.items[0].duration);
    try std.testing.expectEqual(kill_index, recorder.sleeps.items[0].commands_before);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.close: skips stop polling before killing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.stdout = "0|0|12345|node\n";
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testCloseUnlocked(runtime, &writer);

    const kill_index = recorder.commands.items.len - 1;
    try proc_runner.expectCommandOrder(&recorder, "C-c", "kill-session");
    try proc_runner.expectCommandArg(recorder.commands.items[kill_index], 1, "kill-session");
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(close_kill_settle, recorder.sleeps.items[0].duration);
}

test "runtime.close: kills session even when a service signal fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testCloseUnlocked(runtime, &writer);

    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.close: kills session even when send-keys fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testCloseUnlocked(runtime, &writer);

    try proc_runner.expectCommandContaining(&recorder, "C-c");
    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.attach: refreshes size hooks before switching client" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("TMUX", "/tmp/tmux");
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.environ = &environ;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.attach(&writer);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "set-hook");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "switch-client");
    try proc_runner.expectCommandContaining(&recorder, "sync-size");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
}

test "runtime.attach: reports missing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, runtime.attach(&writer));

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Run 'open' first") != null);
}

test "runtime.attach: attaches session when outside tmux" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.attach(&writer);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandContaining(&recorder, "set-hook");
    const attach_cmd = proc_runner.findCommandContaining(&recorder, "attach-session") orelse return error.MissingAttachSession;
    try std.testing.expect(attach_cmd.interactive);
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "switch-client") == null);
}

test "runtime.logs: switches client then selects window inside tmux" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("TMUX", "/tmp/tmux");
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.environ = &environ;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.logs("api", &writer);

    try proc_runner.expectCommandOrder(&recorder, "switch-client", "select-window");
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "attach-session") == null);
}

test "runtime.logs: selects window then attaches outside tmux" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.logs("api", &writer);

    try proc_runner.expectCommandOrder(&recorder, "select-window", "attach-session");
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "switch-client") == null);
}

test "runtime.logsTail: writes recent lines without moving windows" {
    const cases = [_]struct {
        name: []const u8,
        inside_tmux: bool,
        pane: []const u8,
        expected: []const u8,
    }{
        .{ .name = "outside tmux", .inside_tmux = false, .pane = "booting\nlistening\n\n\n", .expected = "booting\nlistening\n" },
        .{ .name = "inside tmux", .inside_tmux = true, .pane = "booting\nlistening\n\n\n", .expected = "booting\nlistening\n" },
        .{ .name = "empty log", .inside_tmux = false, .pane = "\n\n\n", .expected = "" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var environ = env.Map.init(arena.allocator());
        defer environ.deinit();
        if (case.inside_tmux) try environ.put("TMUX", "/tmp/tmux");
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue("", "", .{ .exited = 0 });
        try recorder.enqueue(try std.mem.concat(arena.allocator(), u8, &.{ "0\n", case.pane }), "", .{ .exited = 0 });
        const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        var runtime = testRuntime(arena.allocator(), run, try testLogsConfig(arena.allocator()));
        runtime.environ = &environ;
        var out_buffer: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buffer);
        var diag_buffer: [128]u8 = undefined;
        var diag: std.Io.Writer = .fixed(&diag_buffer);

        try runtime.logsTail("api", 100, &out, &diag);

        try std.testing.expectEqualStrings(case.expected, out.buffered());
        try std.testing.expectEqualStrings("", diag.buffered());
        try proc_runner.expectCommandContaining(&recorder, "capture-pane");
        try expectNoWindowMovement(&recorder);
    }
}

test "runtime.logsTail: reports failures instead of an empty log" {
    const permission_denied = "error connecting to /tmp/tmux-501/default (Permission denied)";
    const cases = [_]struct {
        name: []const u8,
        service: []const u8 = "api",
        session_stderr: ?[]const u8 = null,
        pane_stderr: ?[]const u8 = null,
        capture_error: ?anyerror = null,
        expected_error: anyerror,
        expected_diag: []const u8,
    }{
        .{ .name = "unknown service", .service = "worker", .expected_error = error.ServiceNotFound, .expected_diag = "Unknown service: worker\n" },
        .{ .name = "missing session", .session_stderr = "can't find session: demo", .expected_error = error.SessionNotRunning, .expected_diag = "Session not running\n" },
        .{ .name = "unavailable session", .session_stderr = permission_denied, .expected_error = error.TmuxUnavailable, .expected_diag = "tmux unavailable\n" },
        .{ .name = "missing pane", .pane_stderr = "can't find window: api", .expected_error = error.ServiceWindowMissing, .expected_diag = "Service window not found: api\n" },
        .{ .name = "unavailable pane", .pane_stderr = permission_denied, .expected_error = error.TmuxUnavailable, .expected_diag = "tmux unavailable\n" },
        .{ .name = "unavailable capture", .capture_error = error.FileNotFound, .expected_error = error.TmuxUnavailable, .expected_diag = "tmux unavailable\n" },
        .{ .name = "oversized capture", .capture_error = error.OutputTooLarge, .expected_error = error.LogOutputTooLarge, .expected_diag = "Log output too large; request fewer lines\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        if (case.session_stderr) |stderr| {
            try recorder.enqueue("", stderr, .{ .exited = 1 });
        } else if (case.pane_stderr) |stderr| {
            try recorder.enqueue("", "", .{ .exited = 0 });
            try recorder.enqueue("", stderr, .{ .exited = 1 });
        } else {
            try recorder.enqueue("", "", .{ .exited = 0 });
            if (case.capture_error) |err| try recorder.enqueueError(err);
        }
        const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        const runtime = testRuntime(arena.allocator(), run, try testLogsConfig(arena.allocator()));
        var out_buffer: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buffer);
        var diag_buffer: [128]u8 = undefined;
        var diag: std.Io.Writer = .fixed(&diag_buffer);

        try std.testing.expectError(case.expected_error, runtime.logsTail(case.service, 100, &out, &diag));

        try std.testing.expectEqualStrings("", out.buffered());
        try std.testing.expectEqualStrings(case.expected_diag, diag.buffered());
        try expectNoWindowMovement(&recorder);
    }
}

test "runtime.logsSaved: reads the saved log without touching tmux" {
    const cases = [_]struct {
        name: []const u8,
        max_lines: ?u32,
        expected: []const u8,
    }{
        .{ .name = "whole log", .max_lines = null, .expected = testSavedLog },
        .{ .name = "last lines", .max_lines = 2, .expected = "boom\nexit 1\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var fixture = try TestSavedLogFixture.init(std.testing.allocator, testSavedLog);
        defer fixture.deinit();
        var out_buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buffer);
        var diag_buffer: [256]u8 = undefined;
        var diag: std.Io.Writer = .fixed(&diag_buffer);

        try fixture.runtime.logsSaved("api", case.max_lines, &out, &diag);

        try std.testing.expectEqualStrings(case.expected, out.buffered());
        try std.testing.expectEqualStrings("", diag.buffered());
        try std.testing.expectEqual(@as(usize, 0), fixture.recorder.commands.items.len);
    }
}

test "runtime.logsSaved: reports a service without saved output" {
    var fixture = try TestSavedLogFixture.init(std.testing.allocator, null);
    defer fixture.deinit();
    var out_buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var diag_buffer: [512]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&diag_buffer);

    try std.testing.expectError(error.SavedLogMissing, fixture.runtime.logsSaved("api", 5, &out, &diag));

    const expected = try std.fmt.allocPrint(fixture.arena.allocator(), "No saved output for api yet; it is written to {s} once the service starts\n", .{fixture.log_path});
    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectEqualStrings(expected, diag.buffered());
}

test "runtime.logsSaved: rejects an unknown service before reading a log" {
    var fixture = try TestSavedLogFixture.init(std.testing.allocator, testSavedLog);
    defer fixture.deinit();
    var out_buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var diag_buffer: [128]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&diag_buffer);

    try std.testing.expectError(error.ServiceNotFound, fixture.runtime.logsSaved("worker", null, &out, &diag));

    try std.testing.expectEqualStrings("", out.buffered());
    try std.testing.expectEqualStrings("Unknown service: worker\n", diag.buffered());
}

test "runtime.logsPath: prints the saved log path before any output is saved" {
    var fixture = try TestSavedLogFixture.init(std.testing.allocator, null);
    defer fixture.deinit();
    var out_buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    var diag_buffer: [64]u8 = undefined;
    var diag: std.Io.Writer = .fixed(&diag_buffer);

    try fixture.runtime.logsPath("api", &out, &diag);

    const expected = try std.fmt.allocPrint(fixture.arena.allocator(), "{s}\n", .{fixture.log_path});
    try std.testing.expectEqualStrings(expected, out.buffered());
    try std.testing.expectEqualStrings("", diag.buffered());
    try std.testing.expectEqual(@as(usize, 0), fixture.recorder.commands.items.len);
}

test "runtime.logsTail: missing session points to the saved log" {
    const cases = [_]struct {
        name: []const u8,
        saved: ?[]const u8,
        expected_hint: bool,
    }{
        .{ .name = "saved log", .saved = testSavedLog, .expected_hint = true },
        .{ .name = "no saved log", .saved = null, .expected_hint = false },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var fixture = try TestSavedLogFixture.init(std.testing.allocator, case.saved);
        defer fixture.deinit();
        try fixture.recorder.enqueue("", "can't find session: demo", .{ .exited = 1 });
        var out_buffer: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buffer);
        var diag_buffer: [512]u8 = undefined;
        var diag: std.Io.Writer = .fixed(&diag_buffer);

        try std.testing.expectError(error.SessionNotRunning, fixture.runtime.logsTail("api", 5, &out, &diag));

        const expected = if (case.expected_hint)
            try std.fmt.allocPrint(fixture.arena.allocator(), "Session not running\nSaved output: {s}\nRead it with: zask --config '/tmp/demo/config.json' logs api --saved\n", .{fixture.log_path})
        else
            "Session not running\n";
        try std.testing.expectEqualStrings("", out.buffered());
        try std.testing.expectEqualStrings(expected, diag.buffered());
    }
}

test "runtime.logs: missing session points to the saved log" {
    var fixture = try TestSavedLogFixture.init(std.testing.allocator, testSavedLog);
    defer fixture.deinit();
    try fixture.recorder.enqueue("", "can't find session: demo", .{ .exited = 1 });
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, fixture.runtime.logs("api", &writer));

    const expected = try std.fmt.allocPrint(fixture.arena.allocator(), "Session not running\nSaved output: {s}\nRead it with: zask --config '/tmp/demo/config.json' logs api --saved\n", .{fixture.log_path});
    try std.testing.expectEqualStrings(expected, writer.buffered());
    try expectNoWindowMovement(&fixture.recorder);
}

test "runtime.openSession: creates dashboard service and docker windows" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "infra/compose.yaml"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);

    try runtime.openSessionWithDashboardWindow(arena.allocator());
    try runtime.installSessionOptions(arena.allocator());
    try runtime.configureDashboardWindow(arena.allocator());
    try runtime.appendServiceAndDockerWindows(arena.allocator());
    try runtime.focusDashboard();

    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "tmuxp") == null);
    try proc_runner.expectCommandContaining(&recorder, "new-session");
    try proc_runner.expectCommandContaining(&recorder, "split-window");
    try proc_runner.expectCommandContaining(&recorder, "main-pane-width");
    try proc_runner.expectCommandContaining(&recorder, "main-vertical");
    try proc_runner.expectCommandContaining(&recorder, "new-window");
    try proc_runner.expectCommandContaining(&recorder, "demo:dashboard");
    try proc_runner.expectCommandContaining(&recorder, "demo:api");
    try proc_runner.expectCommandContaining(&recorder, "/tmp/demo/backend");
    try proc_runner.expectCommandContaining(&recorder, "/tmp/demo/infra");
    try proc_runner.expectCommandOrder(&recorder, "remain-on-exit", "api");
    try proc_runner.expectCommandOrder(&recorder, "docker", "select-window");
    try proc_runner.expectCommandContaining(&recorder, "@zask_dash_mode");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.openSession: places docker after dashboard" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "infra/compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);

    try runtime.openSessionWithDashboardWindow(arena.allocator());
    try runtime.installSessionOptions(arena.allocator());
    try runtime.configureDashboardWindow(arena.allocator());
    try runtime.appendServiceAndDockerWindows(arena.allocator());
    try runtime.focusDashboard();

    try proc_runner.expectCommandContaining(&recorder, "demo:dashboard");
    try proc_runner.expectCommandContaining(&recorder, "/tmp/demo/infra");
    try proc_runner.expectCommandOrder(&recorder, "docker", "select-window");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.open: reports missing service directory before creating session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"demo","root":"{s}"}},
        \\  "groups": [{{"name":"backend","services":[{{"name":"api","dir":"missing-api","command":"serve"}}]}}]
        \\}}
    , .{root});
    var recorder = proc_runner.Recorder.init(gpa);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = gpa, .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    var runtime = testRuntime(gpa, run, cfg);
    runtime.io = io;
    runtime.validate_configured_dirs = true;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try std.testing.expectError(error.ConfigPathNotFound, runtime.openUnlockedWithProgress("all", &progress));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Error: configured directory not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "field: service.dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service: api") != null);
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "new-session") == null);
}

test "runtime.open: reports missing env file before creating session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"demo","root":"{s}"}},
        \\  "groups": [{{"name":"backend","services":[{{"name":"api","command":"serve","env_file":"missing.env"}}]}}]
        \\}}
    , .{root});
    var recorder = proc_runner.Recorder.init(gpa);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = gpa, .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    var runtime = testRuntime(gpa, run, cfg);
    runtime.io = io;
    runtime.validate_configured_dirs = true;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try std.testing.expectError(error.ConfigPathNotFound, runtime.openUnlockedWithProgress("all", &progress));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Error: configured file not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "field: env_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service: api") != null);
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "new-session") == null);
}

test "runtime.open: kills partial session on setup failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "set-option failed", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CommandFailed, runtime.openUnlocked("all", &writer));

    try proc_runner.expectCommandOrder(&recorder, "new-session", "kill-session");
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.open: creates session without tmuxp" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const home_dir = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-home-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, home_dir) catch {};
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("HOME", home_dir);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.io = io;
    runtime.environ = &environ;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.openUnlocked("all", &writer);

    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "tmuxp") == null);
    try proc_runner.expectCommandContaining(&recorder, "new-session");
    try proc_runner.expectCommandContaining(&recorder, "split-window");
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectCommandContaining(&recorder, "@zask_dash_mode");
    try proc_runner.expectCommandContaining(&recorder, "bind-key");
    try proc_runner.expectCommandContaining(&recorder, "preview-list");
    try proc_runner.expectCommandOrder(&recorder, "bind-key", "attach-session");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.open: clears progress before attaching" {
    const ProgressSpy = struct {
        writer: *std.Io.Writer,
        recorder: *const proc_runner.Recorder,
        before_interactive_count: usize = 0,

        pub fn raw(self: *@This()) *std.Io.Writer {
            return self.writer;
        }

        pub fn step(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try self.writer.print(fmt, args);
        }

        pub fn info(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try self.step(fmt, args);
        }

        pub fn focus(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try self.step(fmt, args);
        }

        pub fn command(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            _ = self;
            _ = fmt;
            _ = args;
        }

        pub fn status(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try self.step(fmt, args);
        }

        pub fn detail(self: *@This(), lines: []const []const u8) !void {
            _ = self;
            _ = lines;
        }

        pub fn warn(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try self.step(fmt, args);
        }

        pub fn warnContext(self: *@This()) !void {
            _ = self;
        }

        pub fn beforeInteractive(self: *@This()) !void {
            if (proc_runner.findCommandContaining(self.recorder, "attach-session") != null) return error.AttachBeforeInteractive;
            self.before_interactive_count += 1;
        }

        pub fn failContext(self: *@This()) !void {
            _ = self;
        }

        pub fn finishSuccess(self: *@This()) !void {
            _ = self;
        }

        pub fn finishError(self: *@This()) !void {
            _ = self;
        }
    };
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = ProgressSpy{ .writer = &writer, .recorder = &recorder };

    try runtime.openUnlockedWithProgress("all", &progress);

    try std.testing.expectEqual(@as(usize, 1), progress.before_interactive_count);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Attaching to workspace") != null);
    try proc_runner.expectCommandOrder(&recorder, "bind-key", "attach-session");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.open: warns when service has no readiness port" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":"backend","command":"serve"},
        \\    {"name":"web","dir":"frontend","command":"dev","port":3000}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try runtime.warnServicesWithoutPort("all", &progress);

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Warning: api has no port; zask cannot check readiness for this service") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "web has no port") == null);
}

test "runtime.open: warns only for services in selected profile" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[
        \\      {"name":"api","dir":"backend","command":"serve","port":3000}
        \\    ]},
        \\    {"name":"worker","services":[
        \\      {"name":"job","dir":"worker","command":"run"}
        \\    ]}
        \\  ],
        \\  "startup_order": [{"group":"backend"}],
        \\  "start_profiles": {
        \\    "jobs": {"profile":"jobs","group_overrides":{"backend":"worker"}}
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress = progress_mod.Line.init(&writer);

    try runtime.warnServicesWithoutPort("all", &progress);
    try runtime.warnServicesWithoutPort("jobs", &progress);

    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "api has no port") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Warning: job has no port; zask cannot check readiness for this service") != null);
}

test "runtime.open: refreshes bindings for existing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("TMUX", "/tmp/tmux");
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.environ = &environ;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.openUnlocked("all", &writer);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectCommandContaining(&recorder, "preview-list");
    try proc_runner.expectCommandOrder(&recorder, "preview-list", "switch-client");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.previewList: resizes windows before choose-tree" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("@1|80|24\n@2|80|24\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("@1|120|39\n@2|120|39\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);

    try runtime.previewList("%1", 120, 40);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "resize-window");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 7, "@1");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "resize-window");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 7, "@2");
    try proc_runner.expectCommandArg(recorder.commands.items[3], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[4], 1, "set-option");
    try proc_runner.expectCommandArg(recorder.commands.items[4], 5, "window-size");
    try proc_runner.expectCommandArg(recorder.commands.items[4], 6, "latest");
    try proc_runner.expectCommandArg(recorder.commands.items[5], 1, "set-option");
    try proc_runner.expectCommandArg(recorder.commands.items[6], 1, "choose-tree");
    try proc_runner.expectCommandArg(recorder.commands.items[6], 4, "%1");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.previewList: rejects resized window mismatch" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("@1|80|24\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("@1|119|39\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);

    try std.testing.expectError(error.WindowSizeMismatch, runtime.previewList("%1", 120, 40));

    try std.testing.expectEqual(@as(usize, 4), recorder.commands.items.len);
    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "resize-window");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[3], 1, "set-option");
    try proc_runner.expectCommandArg(recorder.commands.items[3], 5, "window-size");
    try proc_runner.expectCommandArg(recorder.commands.items[3], 6, "latest");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.syncWindowSizes: resizes windows without opening tree mode" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("@1|80|24\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("@1|120|39\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);

    try runtime.syncWindowSizes(120, 40);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "resize-window");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "list-windows");
    try proc_runner.expectCommandArg(recorder.commands.items[3], 1, "set-option");
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "choose-tree") == null);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "runtime.open: attaches when lock is busy" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    try environ.put("TMUX", "/tmp/tmux");
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.open("all", &writer);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "set-hook");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "switch-client");
}

test "runtime.open: preserves lock busy before session exists" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-missing-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.LockBusy, runtime.open("all", &writer));

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "runtime.open: reports tmux unavailable when lock busy and tmux unreachable" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-busy-unavail-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, runtime.open("all", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
}

test "runtime.close: reports tmux unavailable when lock busy and tmux unreachable" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-close-busy-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, runtime.close(&writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
}

test "runtime.re: delegates to single attached client when lock is busy" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-re-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("/dev/ttys001\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.re(&writer);

    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "list-clients");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 1, "detach-client");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 2, "-t");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 3, "/dev/ttys001");
    try proc_runner.expectCommandArg(recorder.commands.items[2], 4, "-E");
    try proc_runner.expectCommandArgContains(recorder.commands.items[2], 5, " re");
}

test "runtime.re: rejects lock busy delegation with multiple attached clients" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/tmp/zask-test-runtime-re-multi-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const lock_dir = try std.fs.path.join(arena.allocator(), &.{ base, "zask", "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const pid_path = try std.fs.path.join(arena.allocator(), &.{ lock_dir, "pid" });
    try paths.writeFileMode(io, pid_path, try std.fmt.allocPrint(arena.allocator(), "{d}", .{std.c.getpid()}), @enumFromInt(0o600));

    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", base);
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("/dev/ttys001\n/dev/ttys002\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = io, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.lock_probe = .{ .fake = .{ .pid = std.c.getpid(), .alive = true } };
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.RestartRequiresSingleAttachedClient, runtime.re(&writer));

    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try proc_runner.expectCommandArg(recorder.commands.items[0], 1, "has-session");
    try proc_runner.expectCommandArg(recorder.commands.items[1], 1, "list-clients");
}

test "runtime.re: detaches client exec inside tmux" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("TMUX", "/tmp/tmux");
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var runtime = testRuntime(arena.allocator(), run, cfg);
    runtime.environ = &environ;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.re(&writer);

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    const cmd = recorder.commands.items[0];
    try proc_runner.expectCommandArg(cmd, 1, "detach-client");
    try proc_runner.expectCommandArg(cmd, 2, "-E");
    try proc_runner.expectCommandArgContains(cmd, 3, " re");
    try proc_runner.expectCommandArgContains(cmd, 3, "--config");
}

fn testLogsConfig(gpa: std.mem.Allocator) !config.Config {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    return config.Config.parse(gpa, json, "/home/me");
}

fn expectNoWindowMovement(recorder: *const proc_runner.Recorder) !void {
    for ([_][]const u8{ "select-window", "switch-client", "attach-session" }) |command| {
        try std.testing.expect(proc_runner.findCommandContaining(recorder, command) == null);
    }
}

const testSavedLog = "=== zask: api started at 2026-09-21T14:13:20Z ===\nlistening\nboom\nexit 1\n";

/// A runtime whose service logs live in a temporary directory, holding the
/// given saved `api.log` (none when null).
const TestSavedLogFixture = struct {
    arena: std.heap.ArenaAllocator,
    threaded: std.Io.Threaded,
    tmp: std.testing.TmpDir,
    recorder: proc_runner.Recorder,
    runtime: Runtime,
    log_path: []const u8,

    fn init(gpa: std.mem.Allocator, saved: ?[]const u8) !*TestSavedLogFixture {
        const self = try gpa.create(TestSavedLogFixture);
        errdefer gpa.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer self.threaded.deinit();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const scratch = self.arena.allocator();
        const io = self.threaded.io();
        try self.tmp.dir.createDirPath(io, "logs");
        if (saved) |data| try self.tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log", .data = data });
        const root = try self.tmp.dir.realPathFileAlloc(io, ".", scratch);
        const log_dir = try std.fs.path.join(scratch, &.{ root, "logs" });
        self.log_path = try std.fs.path.join(scratch, &.{ log_dir, "api.log" });
        self.recorder = proc_runner.Recorder.init(scratch);
        const run = proc_runner.Runner{ .gpa = scratch, .io = io, .recorder = &self.recorder };
        self.runtime = testRuntime(scratch, run, try testLogsConfig(scratch));
        self.runtime.io = io;
        self.runtime.service_log_dir = log_dir;
        return self;
    }

    fn deinit(self: *TestSavedLogFixture) void {
        const gpa = self.arena.child_allocator;
        self.recorder.deinit();
        self.tmp.cleanup();
        self.threaded.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

fn testRuntime(gpa: std.mem.Allocator, runner: proc_runner.Runner, cfg: config.Config) Runtime {
    return .{
        .gpa = gpa,
        .io = undefined,
        .cfg = cfg,
        .config_path = "/tmp/demo/config.json",
        .zask_path = "zask",
        .command_hint = .{ .config = "/tmp/demo/config.json" },
        .runner_impl = runner,
        .tmux_impl = .{ .gpa = gpa, .runner = runner, .session = "demo" },
        .docker_impl = .{ .gpa = gpa, .runner = runner, .dir = "/tmp/demo", .file = "compose.yaml" },
        .validate_configured_dirs = false,
        .emit_env_file_tips = false,
    };
}
