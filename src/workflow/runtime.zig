const std = @import("std");
const config = @import("../model/config.zig");
const docker_client = @import("../platform/docker.zig");
const env = @import("../platform/env.zig");
const lifecycle_mod = @import("lifecycle.zig");
const lock = @import("../platform/lock.zig");
const log_session = @import("log_session.zig");
const observations = @import("../model/observations.zig");
const paths = @import("../platform/paths.zig");
const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const session_layout = @import("session_layout.zig");
const tmux_client = @import("../platform/tmux.zig");
const tmux_setup = @import("tmux_setup.zig");
const validate = @import("../model/validate.zig");
const waits = @import("waits.zig");
const zask_command = @import("zask_command.zig");

const bye_kill_settle = std.Io.Duration.fromSeconds(1);
const tmux_status_bar_height = 1;

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

    pub fn attach(self: Runtime) !void {
        const tx = self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        } else {
            try tx.attachSession();
        }
    }

    pub fn detach(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            const tx = self.tmux();
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
        const tx = self.tmux();
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
        const manager = self.logSession();
        const log_file = manager.prepareLogFile(service) catch |err| switch (err) {
            error.LogSessionNotInitialized => {
                try writer.writeAll("Log session not initialized. Run 'hello' first.\n");
                try writer.flush();
                return error.LogSessionNotInitialized;
            },
            else => return err,
        };
        const tx = self.tmux();
        try tx.popup(self.cfg.popupWidth(), self.cfg.popupHeight(), try std.fmt.allocPrint(self.gpa, "nvim -c 'terminal tail -F {s}'", .{try shell.quote(self.gpa, log_file)}));
    }

    pub fn previewList(self: Runtime, pane_id: []const u8, client_width: u16, client_height: u16) !void {
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

        try tx.chooseTree(pane_id);
    }

    pub fn hello(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => {
                if (try self.sessionExists()) return self.attach();
                return err;
            },
            else => return err,
        };
        defer guard.release();
        try self.helloUnlocked(profile, writer);
    }

    pub fn helloUnlocked(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        if (try self.sessionExists()) {
            try self.installSessionOptions(scratch);
            try tmux_setup.bindControlKeys(scratch, self.tmux());
            try self.lifecycle().startAll(profile, writer);
            try self.attach();
            return;
        }
        const tx = self.tmux();
        try self.openSessionWithDashboardWindow(scratch);
        errdefer tx.killSession() catch {};
        try self.installSessionOptions(scratch);
        try self.configureDashboardWindow(scratch);
        try self.appendServiceAndDockerWindows(scratch);
        try self.focusDashboard();
        try tmux_setup.bindControlKeys(scratch, tx);
        try self.logSession().init();
        try self.setupPipePane(scratch, writer);
        try self.lifecycle().startAll(profile, writer);
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
        try self.lifecycle().stopAll(writer);
        self.cleanupPipePane() catch {};
        self.runner().sleep(bye_kill_settle);
        const tx = self.tmux();
        try tx.killSession();
    }

    pub fn kill(self: Runtime, writer: *std.Io.Writer) !void {
        const guard = try self.acquireLock();
        defer guard.release();
        try self.lifecycle().stopDocker(writer);
        try self.cleanupPipePane();
        if (try self.sessionExists()) {
            const tx = self.tmux();
            try tx.killSession();
        } else {
            try writer.writeAll("Session not running\n");
        }
    }

    pub fn re(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            const tx = self.tmux();
            const command = try zask_command.invoke(self.gpa, self.zask_path, self.config_path, "re");
            defer self.gpa.free(command);
            try tx.detachClientExec(command);
            return;
        }
        const guard = try self.acquireLock();
        defer guard.release();
        try self.byeUnlocked(writer);
        try self.helloUnlocked("all", writer);
    }

    pub fn up(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().startTarget(target, writer);
    }

    pub fn stop(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().stopTarget(target, writer);
    }

    pub fn restart(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        try self.lifecycle().restartTarget(target, writer);
    }

    pub fn exec(self: Runtime, container: []const u8, use_shell: bool, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return error.DockerDisabled;
        try validate.identifier(container);
        const dc = self.docker();
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
        };
    }

    fn logSession(self: Runtime) log_session.Manager {
        return .{
            .gpa = self.gpa,
            .io = self.io,
            .environ = self.environ,
            .cfg = self.cfg,
            .runner = self.runner(),
            .tmux = self.tmux(),
        };
    }

    fn acquireLock(self: Runtime) !lock.Lock {
        return lock.Lock.acquire(self.gpa, self.runner(), try self.cfg.projectName(), try paths.runtimeBase(self.gpa, self.environ));
    }

    fn openSessionWithDashboardWindow(self: Runtime, scratch: std.mem.Allocator) !void {
        const tx = self.tmux();
        const root = try self.cfg.projectRoot(scratch);
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
        const root = try self.cfg.projectRoot(scratch);
        try tx.splitWindow(session_layout.dashboard_window, root, try zask_command.invokeMonitor(scratch, self.zask_path, self.config_path));
        try tx.setWindowOption(session_layout.dashboard_window, session_layout.dashboard_pane_width_option, session_layout.dashboard_pane_width_value);
        try tx.selectLayout(session_layout.dashboard_window, session_layout.dashboard_layout);
    }

    fn appendServiceAndDockerWindows(self: Runtime, scratch: std.mem.Allocator) !void {
        const tx = self.tmux();
        var previous_window: []const u8 = session_layout.dashboard_window;
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            try tx.newWindowAfter(previous_window, name, try self.cfg.serviceDir(scratch, service), try zask_command.waitingPlaceholder(scratch, name));
            previous_window = name;
        }
        if (self.cfg.dockerEnabled()) {
            try tx.newWindowAfter(previous_window, session_layout.docker_window, try self.cfg.dockerDir(scratch), try zask_command.waitingPlaceholder(scratch, session_layout.docker_placeholder_title));
        }
    }

    fn focusDashboard(self: Runtime) !void {
        try self.tmux().selectWindow(session_layout.dashboard_window);
    }

    fn setupPipePane(self: Runtime, scratch: std.mem.Allocator, writer: *std.Io.Writer) !void {
        const manager = self.logSession();
        const tx = self.tmux();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            const log_file = manager.prepareLogFile(name) catch |err| {
                try writer.print("Warning: log setup failed for {s}: {}\n", .{ name, err });
                continue;
            };
            const quoted = shell.quote(scratch, log_file) catch |err| {
                try writer.print("Warning: log setup failed for {s}: {}\n", .{ name, err });
                continue;
            };
            const command = std.fmt.allocPrint(scratch, "cat >> {s}", .{quoted}) catch |err| {
                try writer.print("Warning: log setup failed for {s}: {}\n", .{ name, err });
                continue;
            };
            _ = tx.pipePane(name, command) catch {};
        }
    }

    fn cleanupPipePane(self: Runtime) !void {
        if (!try self.sessionExists()) return;
        const tx = self.tmux();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            _ = tx.pipePane(name, null) catch {};
        }
    }

    fn sessionExists(self: Runtime) !bool {
        return self.tmux().hasSession();
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

test "exec rejects disabled or unavailable containers" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": false},
        \\  "services": []
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

    try std.testing.expectError(error.DockerDisabled, runtime.exec("api", false, &writer));
}

test "exec reports missing containers and uses shell override" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "exec_defaults": {"db": "psql"}},
        \\  "services": []
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

    try recorder.enqueue("\n", "", .{ .exited = 0 });
    try std.testing.expectError(error.ContainerNotRunning, runtime.exec("db", false, &writer));
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    try std.testing.expectError(error.ContainerNotRunning, runtime.exec("db", false, &writer));
    try recorder.enqueue("db\n", "", .{ .exited = 0 });
    try runtime.exec("db", true, &writer);

    const command = recorder.commands.items[3];
    try std.testing.expect(command.interactive);
    try std.testing.expectEqualStrings("bash", command.argv[6]);
}

test "exec passes default command without shell wrapping" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "exec_defaults": {"db": "psql -c 'select 1'"}},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("db\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.exec("db", false, &writer);

    const command = recorder.commands.items[1];
    try std.testing.expect(command.interactive);
    try std.testing.expectEqualStrings("docker", command.argv[0]);
    try std.testing.expectEqualStrings("exec", command.argv[4]);
    try std.testing.expectEqualStrings("db", command.argv[5]);
    try std.testing.expectEqualStrings("psql", command.argv[6]);
    try std.testing.expectEqualStrings("-c", command.argv[7]);
    try std.testing.expectEqualStrings("select 1", command.argv[8]);
    try std.testing.expect(!proc_runner.commandContains(command, "bash -lc"));
}

test "bye kills session even when pipe cleanup fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api","dir":"backend","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.byeUnlocked(&writer);

    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try std.testing.expectEqualStrings("tmux", kill.argv[0]);
    try std.testing.expectEqualStrings("kill-session", kill.argv[1]);
}

test "bye reaches kill-session after cleanup failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": [{"name":"api","dir":"backend","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const runtime = testRuntime(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.byeUnlocked(&writer);

    const kill_index = recorder.commands.items.len - 1;
    try proc_runner.expectCommandOrder(&recorder, "C-c", "down");
    try proc_runner.expectCommandOrder(&recorder, "down", "pipe-pane");
    try std.testing.expectEqualStrings("kill-session", recorder.commands.items[kill_index].argv[1]);
    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items.len);
    try std.testing.expectEqual(waits.docker_ready_settle, recorder.sleeps.items[0].duration);
    try std.testing.expectEqual(bye_kill_settle, recorder.sleeps.items[1].duration);
    try std.testing.expectEqual(kill_index, recorder.sleeps.items[1].commands_before);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "attach from tmux switches client without mutating window sizes" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
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

    try runtime.attach();

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqualStrings("switch-client", recorder.commands.items[0].argv[1]);
}

test "new session setup creates dashboard service and docker windows" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "dir": "infra", "compose_file": "compose.yaml"},
        \\  "services": [{"name":"api","dir":"backend","command":"serve","group":"backend"}]
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

test "new session setup places docker after dashboard when services are empty" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "dir": "infra", "compose_file": "compose.yaml"},
        \\  "services": []
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

test "hello kills partially created session when session options fail" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
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

    try std.testing.expectError(error.CommandFailed, runtime.helloUnlocked("all", &writer));

    try proc_runner.expectCommandOrder(&recorder, "new-session", "kill-session");
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "hello creates session without tmuxp and keeps setup order" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const home_dir = try std.fmt.allocPrint(arena.allocator(), "/private/tmp/zask-test-home-{d}", .{std.c.getpid()});
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

    try runtime.helloUnlocked("all", &writer);

    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "tmuxp") == null);
    try proc_runner.expectCommandContaining(&recorder, "new-session");
    try proc_runner.expectCommandContaining(&recorder, "split-window");
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectCommandContaining(&recorder, "@zask_dash_mode");
    try proc_runner.expectCommandContaining(&recorder, "bind-key");
    try proc_runner.expectCommandContaining(&recorder, "preview-list");
    try proc_runner.expectCommandOrder(&recorder, "bind-key", "date");
    try proc_runner.expectCommandOrder(&recorder, "@zask_log_session_id", "attach-session");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "hello refreshes bindings for existing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
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

    try runtime.helloUnlocked("all", &writer);

    try std.testing.expectEqualStrings("has-session", recorder.commands.items[0].argv[1]);
    try proc_runner.expectCommandContaining(&recorder, "set-option");
    try proc_runner.expectCommandContaining(&recorder, "preview-list");
    try proc_runner.expectCommandOrder(&recorder, "preview-list", "switch-client");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "previewList resizes all windows before choose-tree" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
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

    try std.testing.expectEqualStrings("list-windows", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("resize-window", recorder.commands.items[1].argv[1]);
    try std.testing.expectEqualStrings("@1", recorder.commands.items[1].argv[7]);
    try std.testing.expectEqualStrings("resize-window", recorder.commands.items[2].argv[1]);
    try std.testing.expectEqualStrings("@2", recorder.commands.items[2].argv[7]);
    try std.testing.expectEqualStrings("list-windows", recorder.commands.items[3].argv[1]);
    try std.testing.expectEqualStrings("set-option", recorder.commands.items[4].argv[1]);
    try std.testing.expectEqualStrings("window-size", recorder.commands.items[4].argv[5]);
    try std.testing.expectEqualStrings("latest", recorder.commands.items[4].argv[6]);
    try std.testing.expectEqualStrings("set-option", recorder.commands.items[5].argv[1]);
    try std.testing.expectEqualStrings("choose-tree", recorder.commands.items[6].argv[1]);
    try std.testing.expectEqualStrings("%1", recorder.commands.items[6].argv[4]);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "previewList does not open choose-tree when resized windows mismatch" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
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
    try std.testing.expectEqualStrings("list-windows", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("resize-window", recorder.commands.items[1].argv[1]);
    try std.testing.expectEqualStrings("list-windows", recorder.commands.items[2].argv[1]);
    try std.testing.expectEqualStrings("set-option", recorder.commands.items[3].argv[1]);
    try std.testing.expectEqualStrings("window-size", recorder.commands.items[3].argv[5]);
    try std.testing.expectEqualStrings("latest", recorder.commands.items[3].argv[6]);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "hello attaches existing session when another hello holds the lock" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const base = try std.fmt.allocPrint(arena.allocator(), "/private/tmp/zask-test-runtime-{d}", .{std.c.getpid()});
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
    runtime.io = io;
    runtime.environ = &environ;
    runtime.runner_impl = run;
    runtime.tmux_impl.runner = run;
    runtime.docker_impl.runner = run;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runtime.hello("all", &writer);

    try std.testing.expectEqualStrings("has-session", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("switch-client", recorder.commands.items[1].argv[1]);
}

fn testRuntime(gpa: std.mem.Allocator, runner: proc_runner.Runner, cfg: config.Config) Runtime {
    return .{
        .gpa = gpa,
        .io = undefined,
        .cfg = cfg,
        .config_path = "/tmp/demo/config.json",
        .zask_path = "zask",
        .runner_impl = runner,
        .tmux_impl = .{ .gpa = gpa, .runner = runner, .session = "demo" },
        .docker_impl = .{ .gpa = gpa, .runner = runner, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
}
