const std = @import("std");
const config = @import("../model/config.zig");
const docker_client = @import("../platform/docker.zig");
const env = @import("../platform/env.zig");
const lifecycle_mod = @import("lifecycle.zig");
const lock = @import("../platform/lock.zig");
const observations = @import("../model/observations.zig");
const paths = @import("../platform/paths.zig");
const pathing = @import("pathing.zig");
const proc_runner = @import("../platform/runner.zig");
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
    runner_impl: proc_runner.Runner,
    tmux_impl: tmux_client.Client,
    docker_impl: docker_client.Compose,
    lock_probe: lock.Probe = .system,

    pub fn status(self: Runtime, writer: *std.Io.Writer) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.print("Session '{s}' is not running\n", .{try self.cfg.sessionName()});
                return;
            },
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
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

    pub fn attach(self: Runtime, writer: *std.Io.Writer) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.writeAll("Session not running. Run 'open' first.\n");
                try writer.flush();
                return error.SessionNotRunning;
            },
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
        }
        try self.attachExistingWithRefreshedHooks();
    }

    pub fn logs(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.writeAll("Session not running\n");
                try writer.flush();
                return error.SessionNotRunning;
            },
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
        }
        const tx = self.tmux();
        if (try self.inTmux()) {
            try tx.switchClient();
        }
        try tx.selectWindow(service);
        if (!try self.inTmux()) try self.attach(writer);
    }

    pub fn previewList(self: Runtime, pane_id: []const u8, client_width: u16, client_height: u16) !void {
        try self.syncWindowSizes(client_width, client_height);
        try self.tmux().chooseTree(pane_id);
    }

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
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => switch (self.tmux().observeSession()) {
                .active => return self.attachExistingWithRefreshedHooks(),
                .missing => return err,
                .unavailable => {
                    try writer.writeAll("tmux unavailable\n");
                    try writer.flush();
                    return error.TmuxUnavailable;
                },
            },
            else => return err,
        };
        defer guard.release();
        try self.openUnlocked(profile, writer);
    }

    pub fn openUnlocked(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const scratch = arena.allocator();
        switch (self.tmux().observeSession()) {
            .active => {
                try writer.writeAll("Workspace already open. Starting resources...\n");
                try writer.flush();
                try self.installSessionOptions(scratch);
                try tmux_setup.bindControlKeys(scratch, self.tmux());
                try self.lifecycle().startAll(profile, writer, .{});
                try writer.writeAll("Attaching to workspace...\n");
                try writer.flush();
                try self.attachExisting();
                return;
            },
            .missing => {},
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
        }
        try writer.writeAll("Opening workspace...\n");
        try writer.flush();
        const tx = self.tmux();
        try self.openSessionWithDashboardWindow(scratch);
        errdefer tx.killSession() catch {};
        try self.installSessionOptions(scratch);
        try self.configureDashboardWindow(scratch);
        try self.appendServiceAndDockerWindows(scratch);
        try self.focusDashboard();
        try tmux_setup.bindControlKeys(scratch, tx);
        try self.lifecycle().startAll(profile, writer, .{ .mode = .prime });
        try writer.writeAll("Attaching to workspace...\n");
        try writer.flush();
        try self.attachExisting();
    }

    pub fn close(self: Runtime, writer: *std.Io.Writer) !void {
        const guard = self.acquireLock() catch |err| switch (err) {
            error.LockBusy => switch (self.tmux().observeSession()) {
                .unavailable => {
                    try writer.writeAll("tmux unavailable\n");
                    try writer.flush();
                    return error.TmuxUnavailable;
                },
                else => return err,
            },
            else => return err,
        };
        defer guard.release();
        try self.closeUnlocked(writer);
    }

    fn closeUnlocked(self: Runtime, writer: *std.Io.Writer) !void {
        switch (self.tmux().observeSession()) {
            .active => {},
            .missing => {
                try writer.writeAll("Session not running\n");
                return;
            },
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
        }
        // kill-session below stops services anyway, so don't pay the graceful poll
        // here; `stop --all` keeps it since it leaves the session up.
        try self.lifecycle().stopAllFast(writer);
        self.runner().sleep(close_kill_settle);
        const tx = self.tmux();
        try tx.killSession();
    }

    pub fn re(self: Runtime, writer: *std.Io.Writer) !void {
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
                .unavailable => {
                    try writer.writeAll("tmux unavailable\n");
                    try writer.flush();
                    return error.TmuxUnavailable;
                },
            },
            else => return err,
        };
        defer guard.release();
        try self.closeUnlocked(writer);
        try self.openUnlocked("all", writer);
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

test "runtime.status: maps observations to text" {
    try std.testing.expectEqualStrings("running", paneStatusText(.busy));
    try std.testing.expectEqualStrings("stopped", paneStatusText(.idle));
    try std.testing.expectEqualStrings("unknown", composeStatusText(.unavailable));
}

test "runtime.status: reports session not running when missing" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

    try runtime.closeUnlocked(&writer);

    try proc_runner.expectCommandOrder(&recorder, "C-c", "kill-session");
    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.close: kills session after resource stop" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

    try runtime.closeUnlocked(&writer);

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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

    try runtime.closeUnlocked(&writer);

    const kill_index = recorder.commands.items.len - 1;
    try proc_runner.expectCommandOrder(&recorder, "C-c", "kill-session");
    try proc_runner.expectCommandArg(recorder.commands.items[kill_index], 1, "kill-session");
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(close_kill_settle, recorder.sleeps.items[0].duration);
}

test "runtime.close: kills session even when a service signal fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

    try runtime.closeUnlocked(&writer);

    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.close: kills session even when send-keys fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

    try runtime.closeUnlocked(&writer);

    try proc_runner.expectCommandContaining(&recorder, "C-c");
    const kill = recorder.commands.items[recorder.commands.items.len - 1];
    try proc_runner.expectCommandArgv(kill, &.{ "tmux", "kill-session", "-t", "demo" });
}

test "runtime.attach: refreshes size hooks before switching client" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

test "runtime.openSession: creates dashboard service and docker windows" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

test "runtime.open: kills partial session on setup failure" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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

test "runtime.open: refreshes bindings for existing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
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
