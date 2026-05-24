const std = @import("std");
const config = @import("../model/config.zig");
const docker_client = @import("../platform/docker.zig");
const observations = @import("../model/observations.zig");
const phases = @import("phases.zig");
const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const tmux_client = @import("../platform/tmux.zig");
const waits = @import("waits.zig");

pub const Lifecycle = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,

    pub fn startAll(self: Lifecycle, profile: []const u8, writer: *std.Io.Writer) !void {
        try phases.runPrechecks(self, writer);
        if (self.cfg.dockerEnabled()) {
            try self.ensureDockerStarted(writer);
            waits.ensureDockerReady(self, writer) catch {
                try writer.writeAll("Error: Docker failed to start\n");
                return error.DockerFailed;
            };
        }
        if (std.mem.eql(u8, profile, "docker")) return;
        const phase_list = self.cfg.phases();
        if (phase_list.len == 0) {
            for (try self.cfg.services()) |service| try self.startService(try config.Config.serviceName(service), writer);
            return;
        }
        for (phase_list) |phase| {
            if (phase != .object) continue;
            switch (phases.phaseKind(phase)) {
                .docker => {},
                .command => try phases.runCommandPhase(self, phase, profile, writer),
                .services => try phases.runServicePhase(self, phase, profile, writer),
            }
        }
    }

    pub fn stopAll(self: Lifecycle, writer: *std.Io.Writer) !void {
        const services = try self.cfg.services();
        if (services.len > 0) try writeProgress(writer, "Stopping services...\n", .{});
        var i = services.len;
        while (i > 0) {
            i -= 1;
            try self.stopService(try config.Config.serviceName(services[i]), writer);
        }
        try self.stopDocker(writer);
    }

    pub fn startTarget(self: Lifecycle, target: ?[]const u8, writer: *std.Io.Writer) !void {
        const t = target orelse "--all";
        try self.ensureSessionActive(writer);
        if (std.mem.eql(u8, t, "--all")) return self.startAll("all", writer);
        if (std.mem.eql(u8, t, "docker")) {
            try self.ensureDockerStarted(writer);
            return waits.ensureDockerReady(self, writer);
        }
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.startService(svc, writer);
        } else |_| try self.startService(t, writer);
    }

    pub fn stopTarget(self: Lifecycle, target: ?[]const u8, writer: *std.Io.Writer) !void {
        const t = target orelse "--all";
        if (std.mem.eql(u8, t, "docker")) return self.stopDocker(writer);
        if (self.tmux.observeSession() != .active) {
            if (std.mem.eql(u8, t, "--all")) return self.stopDocker(writer);
            return sessionNotRunning(writer);
        }
        if (std.mem.eql(u8, t, "--all")) return self.stopAll(writer);
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.stopService(svc, writer);
        } else |_| try self.stopService(t, writer);
    }

    pub fn restartTarget(self: Lifecycle, target: []const u8, writer: *std.Io.Writer) !void {
        if (std.mem.eql(u8, target, "docker")) {
            try self.stopDocker(writer);
            try self.ensureSessionActive(writer);
            try self.ensureDockerStarted(writer);
            return waits.ensureDockerReady(self, writer);
        }
        try self.ensureSessionActive(writer);
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            for (services) |svc| try self.restartService(svc, writer);
        } else |_| try self.restartService(target, writer);
    }

    pub fn startService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.ensureServiceRunning(service, writer);
    }

    pub fn stopDocker(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try writeProgress(writer, "Stopping Docker...\n", .{});
        if (self.tmux.observeSession() == .active) {
            var sent = true;
            self.tmux.sendKeys("docker", &.{"C-c"}) catch {
                sent = false;
            };
            if (sent) self.runner.sleep(waits.docker_ready_settle);
        }
        self.docker.down() catch {};
    }

    fn stopService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.ensureServiceStopped(service, writer);
    }

    fn restartService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.stopService(service, writer);
        try self.startService(service, writer);
    }

    fn ensureSessionActive(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (self.tmux.observeSession() == .active) return;
        try writer.writeAll("Session not running. Run 'hello' first.\n");
        try writer.flush();
        return error.SessionNotRunning;
    }

    fn ensureServiceRunning(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        const value = try self.cfg.findService(service);
        waits.ensureWindowReady(self, service) catch |err| switch (err) {
            error.WindowNotReady => {
                try writeProgress(writer, "Warning: window for {s} not ready\n", .{service});
                return error.WindowNotReady;
            },
            error.TmuxUnavailable => {
                try writeProgress(writer, "Warning: tmux unavailable for {s}\n", .{service});
                return error.TmuxUnavailable;
            },
        };
        const pane = self.tmux.observePane(service);
        defer pane.deinit(self.gpa);
        switch (serviceStartDecision(pane.state)) {
            .no_op => {
                try writeProgress(writer, "{s} already running\n", .{service});
                return;
            },
            .send_start => {},
            .window_not_ready => return error.WindowNotReady,
            .tmux_unavailable => return error.TmuxUnavailable,
        }
        const service_dir = try shell.quote(self.gpa, try self.cfg.serviceDir(self.gpa, value));
        const start_command = try config.Config.serviceStartCommand(self.gpa, value);
        const cmd = try std.fmt.allocPrint(self.gpa, "cd {s} && {s}", .{ service_dir, start_command });
        try writeProgress(writer, "Starting {s}...\n", .{service});
        try self.tmux.sendKeys(service, &.{ cmd, "Enter" });
    }

    fn ensureServiceStopped(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        const pane = self.tmux.observePane(service);
        defer pane.deinit(self.gpa);
        switch (serviceStopDecision(pane.state)) {
            .send_stop => {},
            .no_op => {
                try writeProgress(writer, "  {s} ... already stopped\n", .{service});
                return;
            },
            .tmux_unavailable => return error.TmuxUnavailable,
        }
        try self.tmux.sendKeys(service, &.{"C-c"});
        try waits.waitForStopped(self, service, writer);
    }

    fn ensureDockerStarted(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try waits.ensureWindowReady(self, "docker");
        if (try self.dockerStartAlreadyHandled(writer)) return;
        try writeProgress(writer, "Starting Docker...\n", .{});
        const docker_dir = try shell.quote(self.gpa, try self.cfg.dockerDir(self.gpa));
        const compose_file = try shell.quote(self.gpa, self.cfg.dockerComposeFile());
        const cmd = try std.fmt.allocPrint(self.gpa, "cd {s} && COMPOSE_MENU=false docker compose -f {s} up", .{ docker_dir, compose_file });
        try self.tmux.sendKeys("docker", &.{ cmd, "Enter" });
    }

    fn dockerStartAlreadyHandled(self: Lifecycle, writer: *std.Io.Writer) !bool {
        var state = try self.dockerStartPaneState();
        if (state == .busy) {
            const compose = self.docker.observe();
            defer compose.deinit(self.gpa);
            switch (compose.state) {
                .running => {
                    try writeProgress(writer, "Docker already running\n", .{});
                    return true;
                },
                .empty => {
                    if (waits.waitForPaneIdle(self, "docker")) {
                        state = try self.dockerStartPaneState();
                    } else {
                        try writeProgress(writer, "Docker already starting\n", .{});
                        return true;
                    }
                },
                .unavailable => {
                    try writeProgress(writer, "Docker already starting\n", .{});
                    return true;
                },
            }
        }
        return switch (dockerStartDecision(state)) {
            .no_op => true,
            .send_start => false,
            .window_not_ready => error.WindowNotReady,
            .tmux_unavailable => error.TmuxUnavailable,
        };
    }

    fn dockerStartPaneState(self: Lifecycle) !observations.PaneState {
        const pane = self.tmux.observePane("docker");
        defer pane.deinit(self.gpa);
        return pane.state;
    }
};

fn sessionNotRunning(writer: *std.Io.Writer) !void {
    try writer.writeAll("Session not running. Run 'hello' first.\n");
    try writer.flush();
    return error.SessionNotRunning;
}

fn writeProgress(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.flush();
}

const StartDecision = enum {
    no_op,
    send_start,
    window_not_ready,
    tmux_unavailable,
};

const StopDecision = enum {
    no_op,
    send_stop,
    tmux_unavailable,
};

fn serviceStartDecision(state: observations.PaneState) StartDecision {
    return switch (state) {
        .busy => .no_op,
        .idle, .dead => .send_start,
        .window_missing => .window_not_ready,
        .tmux_unavailable => .tmux_unavailable,
    };
}

fn serviceStopDecision(state: observations.PaneState) StopDecision {
    return switch (state) {
        .busy => .send_stop,
        .idle, .dead, .window_missing => .no_op,
        .tmux_unavailable => .tmux_unavailable,
    };
}

fn dockerStartDecision(state: observations.PaneState) StartDecision {
    return serviceStartDecision(state);
}

test "maps pane observations to lifecycle start and stop decisions" {
    const cases = [_]struct {
        state: observations.PaneState,
        start: StartDecision,
        stop: StopDecision,
    }{
        .{ .state = .busy, .start = .no_op, .stop = .send_stop },
        .{ .state = .idle, .start = .send_start, .stop = .no_op },
        .{ .state = .dead, .start = .send_start, .stop = .no_op },
        .{ .state = .window_missing, .start = .window_not_ready, .stop = .no_op },
        .{ .state = .tmux_unavailable, .start = .tmux_unavailable, .stop = .tmux_unavailable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.start, serviceStartDecision(case.state));
        try std.testing.expectEqual(case.start, dockerStartDecision(case.state));
        try std.testing.expectEqual(case.stop, serviceStopDecision(case.state));
    }
}

test "precheck abort stops startup and warn continues" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "prechecks": [
        \\    {"name":"warn-check","command":"false","on_fail":"warn"},
        \\    {"name":"abort-check","command":"false","on_fail":"abort"}
        \\  ],
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.PrecheckFailed, lifecycle.startAll("all", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: warn-check check failed") != null);
    try proc_runner.expectCommandContaining(&recorder, "false");
}

test "startAll starts idle docker before service command" {
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
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer);

    try proc_runner.expectCommandContaining(&recorder, "docker compose");
    try proc_runner.expectCommandContaining(&recorder, "cd '/tmp/demo/backend' && serve");
    try proc_runner.expectCommandOrder(&recorder, "docker compose", "cd '/tmp/demo/backend' && serve");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "command phase runs interactively" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "phases": [{"type":"command","command":"echo setup"}],
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer);

    try std.testing.expect(recorder.commands.items[0].interactive);
    try std.testing.expectEqualStrings("bash", recorder.commands.items[0].argv[0]);
    try std.testing.expectEqualStrings("-c", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("echo setup", recorder.commands.items[0].argv[2]);
}

test "wait helpers report timeouts" {
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
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
        try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    }
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try waits.waitForPort(lifecycle, 5432, 2, &writer);
    try waits.waitForStopped(lifecycle, "api", &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: port 5432") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "api ... warning: may not have stopped") != null);
}

test "window readiness distinguishes missing windows from unavailable tmux" {
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
    try recorder.enqueue("", "", .{ .signal = @enumFromInt(1) });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };

    try std.testing.expectError(error.TmuxUnavailable, waits.ensureWindowReady(lifecycle, "api"));
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "window readiness retries missing windows until timeout" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };

    try std.testing.expectError(error.WindowNotReady, waits.ensureWindowReady(lifecycle, "api"));
    try std.testing.expectEqual(@as(usize, waits.windowReadyAttempts()), recorder.commands.items.len);
}

test "service start reports missing window as failure" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WindowNotReady, lifecycle.startAll("all", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: window for api not ready") != null);
}

test "stop and restart targets require an active session" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, lifecycle.stopTarget("api", &writer));
    try std.testing.expectError(error.SessionNotRunning, lifecycle.restartTarget("api", &writer));

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Session not running. Run 'hello' first.") != null);
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
}

test "docker stop reaches compose down without tmux session" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    const down = recorder.commands.items[1];
    try std.testing.expectEqualStrings("docker", down.argv[0]);
    try std.testing.expectEqualStrings("down", down.argv[4]);
    try std.testing.expectEqualStrings("/tmp/demo", down.cwd.?);
}

test "docker stop reaches compose down when tmux send fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    const down = recorder.commands.items[2];
    try std.testing.expectEqualStrings("docker", down.argv[0]);
    try std.testing.expectEqualStrings("down", down.argv[4]);
}

test "docker start is a no-op when docker pane is running" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|docker\n", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|docker\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("NAME SERVICE STATUS\none api running\n", "", .{ .exited = 0 });
    try recorder.enqueue("NAME SERVICE STATUS\none api running\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    try std.testing.expectEqualStrings("has-session", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("list-panes", recorder.commands.items[1].argv[1]);
    try std.testing.expectEqualStrings("pgrep", recorder.commands.items[3].argv[0]);
    try std.testing.expectEqualStrings("ps", recorder.commands.items[4].argv[4]);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "docker start sends compose up after transient busy pane" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|docker\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    const send_keys = recorder.commands.items[9];
    try std.testing.expectEqualStrings("send-keys", send_keys.argv[1]);
    try std.testing.expect(std.mem.indexOf(u8, send_keys.argv[4], "docker compose") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Starting Docker...") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "docker start disables compose menu and waits when started" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("NAME SERVICE STATUS\none api running\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    const send_keys = recorder.commands.items[4];
    try std.testing.expectEqualStrings("send-keys", send_keys.argv[1]);
    try std.testing.expect(std.mem.indexOf(u8, send_keys.argv[4], "COMPOSE_MENU=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "docker restart stops compose before reporting missing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, lifecycle.restartTarget("docker", &writer));

    try std.testing.expectEqualStrings("docker", recorder.commands.items[1].argv[0]);
    try std.testing.expectEqualStrings("down", recorder.commands.items[1].argv[4]);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Session not running") != null);
}

test "docker restart runs compose down before compose up" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.restartTarget("docker", &writer);

    try proc_runner.expectCommandOrder(&recorder, "down", "docker compose");
    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items.len);
    try std.testing.expectEqual(waits.docker_ready_settle, recorder.sleeps.items[0].duration);
    try proc_runner.expectCommandContaining(&recorder, "docker compose");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "startAll dispatches quoted service command to tmux" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo app","session_name":"demo"},
        \\  "services": [{"name":"api","dir":"backend","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const lifecycle = Lifecycle{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = arena.allocator(), .runner = run, .session = "demo" },
        .docker = .{ .gpa = arena.allocator(), .runner = run, .dir = "/tmp/demo app", .file = "compose.yaml" },
    };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer);

    const send_keys = recorder.commands.items[3];
    try std.testing.expectEqualStrings("tmux", send_keys.argv[0]);
    try std.testing.expectEqualStrings("send-keys", send_keys.argv[1]);
    try std.testing.expectEqualStrings("demo:api", send_keys.argv[3]);
    try std.testing.expectEqualStrings("cd '/tmp/demo app/backend' && serve", send_keys.argv[4]);
    try std.testing.expectEqualStrings("Enter", send_keys.argv[5]);
}
