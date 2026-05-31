const std = @import("std");
const config = @import("../model/config.zig");
const docker_client = @import("../platform/docker.zig");
const observations = @import("../model/observations.zig");
const phases = @import("phases.zig");
const pathing = @import("pathing.zig");
const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const tmux_client = @import("../platform/tmux.zig");
const waits = @import("waits.zig");

/// observe: probe each pane before acting (a service may already be running).
/// prime: the caller just created the windows, so the panes are known-idle and
/// can be respawned without re-observing them.
pub const StartMode = enum { observe, prime };

pub const StartOptions = struct {
    mode: StartMode = .observe,
    /// When false, kick resources off but do not block on Docker readiness or
    /// port checks, so the caller can attach while they come up in the background.
    wait_ready: bool = true,
};

pub const Lifecycle = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,

    pub fn startAll(self: Lifecycle, profile: []const u8, writer: *std.Io.Writer, opts: StartOptions) !void {
        try phases.runPrechecks(self, writer);
        if (std.mem.eql(u8, profile, "docker")) return self.startDocker(writer, opts.wait_ready);
        const phase_list = self.cfg.phases();
        if (phase_list.len == 0) {
            if (self.cfg.dockerEnabled()) try self.startDocker(writer, opts.wait_ready);
            for (try self.cfg.services()) |service| try self.startService(try config.Config.serviceName(service), writer, opts.mode);
            return;
        }
        for (phase_list) |phase| {
            if (phase != .object) continue;
            switch (phases.phaseKind(phase)) {
                .docker => try self.startDocker(writer, opts.wait_ready),
                .command => try phases.runCommandPhase(self, phase, profile, writer),
                .services => try phases.runServicePhase(self, phase, profile, writer, opts),
            }
        }
    }

    pub fn stopAll(self: Lifecycle, writer: *std.Io.Writer) !void {
        const services = try self.cfg.services();
        if (services.len > 0) try writeProgress(writer, "Stopping services...\n", .{});
        var signaled = try self.broadcastStop(services, writer);
        defer signaled.deinit(self.gpa);
        try waits.waitForAllStopped(self, signaled.items, writer);
        try self.stopDocker(writer);
    }

    /// Broadcasts C-c and tears down Docker without waiting for services to
    /// settle. The caller is expected to kill the session right after, so the
    /// grace before that kill is the only stop budget services get.
    pub fn stopAllFast(self: Lifecycle, writer: *std.Io.Writer) !void {
        const services = try self.cfg.services();
        if (services.len > 0) try writeProgress(writer, "Stopping services...\n", .{});
        var signaled = try self.broadcastStop(services, writer);
        signaled.deinit(self.gpa);
        try self.stopDocker(writer);
    }

    pub fn startTarget(self: Lifecycle, target: []const u8, writer: *std.Io.Writer) !void {
        try self.ensureSessionActive(writer);
        if (std.mem.eql(u8, target, "--all")) return self.startAll("all", writer, .{});
        if (std.mem.eql(u8, target, "docker")) {
            try self.ensureDockerStarted(writer);
            return waits.ensureDockerReady(self, writer);
        }
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            defer self.gpa.free(services);
            for (services) |svc| try self.startService(svc, writer, .observe);
        } else |_| try self.startService(target, writer, .observe);
    }

    pub fn stopTarget(self: Lifecycle, target: []const u8, writer: *std.Io.Writer) !void {
        if (std.mem.eql(u8, target, "docker")) return self.stopDocker(writer);
        switch (self.tmux.observeSession()) {
            .active => {},
            .missing => {
                if (std.mem.eql(u8, target, "--all")) return self.stopDocker(writer);
                return sessionNotRunning(writer);
            },
            .unavailable => {
                try writer.writeAll("tmux unavailable\n");
                try writer.flush();
                return error.TmuxUnavailable;
            },
        }
        if (std.mem.eql(u8, target, "--all")) return self.stopAll(writer);
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            defer self.gpa.free(services);
            for (services) |svc| try self.stopService(svc, writer);
        } else |_| try self.stopService(target, writer);
    }

    pub fn restartTarget(self: Lifecycle, target: []const u8, writer: *std.Io.Writer) !void {
        if (std.mem.eql(u8, target, "docker")) {
            try self.ensureSessionActive(writer);
            try self.stopDocker(writer);
            try self.ensureDockerStarted(writer);
            return waits.ensureDockerReady(self, writer);
        }
        try self.ensureSessionActive(writer);
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            defer self.gpa.free(services);
            for (services) |svc| try self.restartService(svc, writer);
        } else |_| try self.restartService(target, writer);
    }

    pub fn startService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer, mode: StartMode) !void {
        try self.ensureServiceRunning(service, writer, mode);
    }

    pub fn stopDocker(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try writeProgress(writer, "Stopping Docker...\n", .{});
        // Interrupt the pane's `compose up` so the window returns to a shell, but
        // do not wait for it: `compose down` cleanly stops containers regardless
        // of the attached `up`, so the old settle before it was dead time.
        if (self.tmux.observeSession() == .active) {
            self.tmux.sendKeys("docker", &.{"C-c"}) catch {};
        }
        self.docker.down() catch {
            try writeProgress(writer, "Warning: docker compose down failed\n", .{});
        };
    }

    fn stopService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.ensureServiceStopped(service, writer);
    }

    /// Sends C-c to every running service without waiting and returns the signaled
    /// set, so callers can poll them together instead of blocking on each in turn.
    /// Services in reverse order keeps dependents stopped before their dependencies.
    fn broadcastStop(self: Lifecycle, services: []const std.json.Value, writer: *std.Io.Writer) !std.ArrayList([]const u8) {
        var signaled: std.ArrayList([]const u8) = .empty;
        errdefer signaled.deinit(self.gpa);
        var i = services.len;
        while (i > 0) {
            i -= 1;
            const name = try config.Config.serviceName(services[i]);
            const pane = self.tmux.observePane(name);
            defer pane.deinit(self.gpa);
            switch (serviceStopDecision(pane.state)) {
                .send_stop => {
                    try self.tmux.sendKeys(name, &.{"C-c"});
                    try signaled.append(self.gpa, name);
                },
                .no_op => try writeProgress(writer, "  {s} ... already stopped\n", .{name}),
                .tmux_unavailable => {
                    try writeProgress(writer, "Warning: tmux unavailable for {s}\n", .{name});
                    return error.TmuxUnavailable;
                },
            }
        }
        return signaled;
    }

    fn startDocker(self: Lifecycle, writer: *std.Io.Writer, wait_ready: bool) !void {
        if (!self.cfg.dockerEnabled()) return;
        try self.ensureDockerStarted(writer);
        if (!wait_ready) return;
        waits.ensureDockerReady(self, writer) catch {
            try writer.writeAll("Error: Docker failed to start\n");
            return error.DockerFailed;
        };
    }

    fn restartService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.stopService(service, writer);
        try self.startService(service, writer, .observe);
    }

    fn ensureSessionActive(self: Lifecycle, writer: *std.Io.Writer) !void {
        switch (self.tmux.observeSession()) {
            .active => return,
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
    }

    fn ensureServiceRunning(self: Lifecycle, service: []const u8, writer: *std.Io.Writer, mode: StartMode) !void {
        const value = try self.cfg.findService(service);
        if (mode == .observe) {
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
            switch (serviceStartDecision(pane)) {
                .no_op => {
                    try writeProgress(writer, "{s} already running\n", .{service});
                    return;
                },
                .send_start => {},
                .window_not_ready => return error.WindowNotReady,
                .tmux_unavailable => {
                    try writeProgress(writer, "Warning: tmux unavailable for {s}\n", .{service});
                    return error.TmuxUnavailable;
                },
            }
        }
        const service_dir = try pathing.absolute(self.gpa, self.runner.io, try self.cfg.serviceDir(self.gpa, value));
        const start_command = try config.Config.serviceStartCommand(self.gpa, value);
        try writeProgress(writer, "Starting {s}...\n", .{service});
        try self.tmux.respawnPane(service, service_dir, start_command);
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
            .tmux_unavailable => {
                try writeProgress(writer, "Warning: tmux unavailable for {s}\n", .{service});
                return error.TmuxUnavailable;
            },
        }
        try self.tmux.sendKeys(service, &.{"C-c"});
        try waits.waitForStopped(self, service, writer);
    }

    fn ensureDockerStarted(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try waits.ensureWindowReady(self, "docker");
        if (try self.dockerStartAlreadyHandled(writer)) return;
        try writeProgress(writer, "Starting Docker...\n", .{});
        const docker_dir = try pathing.absolute(self.gpa, self.runner.io, try self.cfg.dockerDir(self.gpa));
        const compose_file = try shell.quote(self.gpa, self.cfg.dockerComposeFile());
        const cmd = try std.fmt.allocPrint(self.gpa, "COMPOSE_MENU=false docker compose -f {s} up", .{compose_file});
        try self.tmux.respawnPane("docker", docker_dir, cmd);
    }

    fn dockerStartAlreadyHandled(self: Lifecycle, writer: *std.Io.Writer) !bool {
        var pane = self.tmux.observePane("docker");
        defer pane.deinit(self.gpa);
        switch (dockerStartDecision(pane)) {
            .send_start => return false,
            .window_not_ready => return error.WindowNotReady,
            .tmux_unavailable => return error.TmuxUnavailable,
            .no_op => {},
        }
        if (pane.state == .busy) {
            const compose = self.docker.observe();
            defer compose.deinit(self.gpa);
            switch (compose.state) {
                .running => {
                    try writeProgress(writer, "Docker already running\n", .{});
                    return true;
                },
                .empty => {
                    if (waits.waitForPaneIdle(self, "docker")) {
                        var refreshed = self.tmux.observePane("docker");
                        defer refreshed.deinit(self.gpa);
                        return switch (dockerStartDecision(refreshed)) {
                            .no_op => true,
                            .send_start => false,
                            .window_not_ready => error.WindowNotReady,
                            .tmux_unavailable => error.TmuxUnavailable,
                        };
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
        return true;
    }
};

fn sessionNotRunning(writer: *std.Io.Writer) !void {
    try writer.writeAll("Session not running. Run 'open' first.\n");
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

fn serviceStartDecision(pane: observations.PaneObservation) StartDecision {
    if (pane.command.len > 0 and tmux_client.isShellCommand(pane.command)) return .send_start;
    return startDecisionForState(pane.state);
}

fn startDecisionForState(state: observations.PaneState) StartDecision {
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

fn dockerStartDecision(pane: observations.PaneObservation) StartDecision {
    if (pane.command.len > 0 and tmux_client.isShellCommand(pane.command)) return .send_start;
    return startDecisionForState(pane.state);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn parseTestConfig(gpa: std.mem.Allocator, json: []const u8) !config.Config {
    return config.Config.parse(gpa, json, "/home/me");
}

fn testLifecycle(gpa: std.mem.Allocator, run: proc_runner.Runner, cfg: config.Config) Lifecycle {
    return .{
        .gpa = gpa,
        .cfg = cfg,
        .runner = run,
        .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
        .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
}

fn testLifecycleWithDockerDir(gpa: std.mem.Allocator, run: proc_runner.Runner, cfg: config.Config, docker_dir: []const u8) Lifecycle {
    var lifecycle = testLifecycle(gpa, run, cfg);
    lifecycle.docker.dir = docker_dir;
    return lifecycle;
}

test "lifecycle.decision: maps pane observations to start and stop decisions" {
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
        try std.testing.expectEqual(case.start, serviceStartDecision(observations.PaneObservation.empty(case.state)));
        try std.testing.expectEqual(case.start, dockerStartDecision(observations.PaneObservation.empty(case.state)));
        try std.testing.expectEqual(case.stop, serviceStopDecision(case.state));
    }
}

test "lifecycle.serviceStartDecision: treats shell pane as startable" {
    const pane = observations.PaneObservation.fromOwned(.busy, "0", "12345", "zsh");

    try std.testing.expectEqual(StartDecision.send_start, serviceStartDecision(pane));
}

test "lifecycle.dockerStartDecision: treats shell pane as startable" {
    const pane = observations.PaneObservation.fromOwned(.busy, "0", "12345", "zsh");

    try std.testing.expectEqual(StartDecision.send_start, dockerStartDecision(pane));
}

test "lifecycle.startAll: fast mode starts docker without waiting for ready" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
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
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{ .mode = .prime, .wait_ready = false });

    try proc_runner.expectCommandContaining(&recorder, "docker compose");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") == null);
    try std.testing.expectEqual(@as(usize, 0), recorder.sleeps.items.len);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "lifecycle.startAll: prime mode respawns service without observing pane" {
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
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{ .mode = .prime });

    try proc_runner.expectCommandContaining(&recorder, "respawn-pane");
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "list-panes") == null);
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "pgrep") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Starting api...") != null);
}

test "lifecycle.stopAll: signals every running service before polling once" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":"backend","command":"serve"},
        \\    {"name":"web","dir":"frontend","command":"dev"}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.stdout = "0|0|12345|node\n";
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopAll(&writer);

    const first_wait = recorder.sleeps.items[0].commands_before;
    var signals_before_wait: usize = 0;
    for (recorder.commands.items[0..first_wait]) |command| {
        if (proc_runner.commandContains(command, "C-c")) signals_before_wait += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), signals_before_wait);
    try std.testing.expectEqual(waits.stopAttempts(), recorder.sleeps.items.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "api ... warning: may not have stopped") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "web ... warning: may not have stopped") != null);
}

test "lifecycle.startAll: precheck abort stops startup and warn continues" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "prechecks": [
        \\    {"name":"warn-check","command":"false","on_fail":"warn"},
        \\    {"name":"abort-check","command":"false","on_fail":"abort"}
        \\  ],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.PrecheckFailed, lifecycle.startAll("all", &writer, .{}));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: warn-check check failed") != null);
    try proc_runner.expectCommandContaining(&recorder, "false");
}

test "lifecycle.startAll: starts idle docker before service command" {
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
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{});

    try proc_runner.expectCommandContaining(&recorder, "docker compose");
    try proc_runner.expectCommandContaining(&recorder, "serve");
    try proc_runner.expectCommandOrder(&recorder, "docker compose", "serve");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "lifecycle.startAll: honors docker startup order step" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "startup_order": [
        \\    {"command":"echo setup"},
        \\    {"docker": true},
        \\    {"group": "backend"}
        \\  ],
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{});

    try proc_runner.expectCommandOrder(&recorder, "echo setup", "docker compose");
    try proc_runner.expectCommandOrder(&recorder, "docker compose", "serve");
    try proc_runner.expectNoTmuxSizingCommands(&recorder);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "lifecycle.startAll: command phase runs interactively" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "startup_order": [{"command":"echo setup"}],
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{});

    const command = proc_runner.findCommandContaining(&recorder, "echo setup") orelse return error.CommandNotFound;
    try std.testing.expect(command.interactive);
    try proc_runner.expectCommandArgv(command, &.{ "bash", "-c", "echo setup" });
}

test "waits: report port and stop timeouts" {
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
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try recorder.enqueue("0|0|12345|node\n", "", .{ .exited = 0 });
        try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    }
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try waits.waitForPort(lifecycle, 5432, 2, &writer);
    try waits.waitForStopped(lifecycle, "api", &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: port 5432") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "api ... warning: may not have stopped") != null);
}

test "waits.ensureDockerReady: times out when compose never reports running" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml", "wait_timeout_seconds": 2},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.DockerNotReady, waits.ensureDockerReady(lifecycle, &writer));
    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items.len);
}

test "waits.ensureWindowReady: distinguishes missing windows from unavailable tmux" {
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
    try recorder.enqueue("", "", .{ .signal = @enumFromInt(1) });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);

    try std.testing.expectError(error.TmuxUnavailable, waits.ensureWindowReady(lifecycle, "api"));
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "waits.ensureWindowReady: retries missing windows until timeout" {
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
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);

    try std.testing.expectError(error.WindowNotReady, waits.ensureWindowReady(lifecycle, "api"));
    try std.testing.expectEqual(@as(usize, waits.windowReadyAttempts()), recorder.commands.items.len);
}

test "lifecycle.startAll: reports missing window as failure" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.WindowNotReady, lifecycle.startAll("all", &writer, .{}));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: window for api not ready") != null);
}

test "lifecycle.stopTarget: stop and restart require an active session" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, lifecycle.stopTarget("api", &writer));
    try std.testing.expectError(error.SessionNotRunning, lifecycle.restartTarget("api", &writer));

    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Session not running. Run 'open' first.") != null);
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
}

test "lifecycle.stopTarget: docker stop reaches compose down without tmux session" {
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
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    const down = proc_runner.findCommandContaining(&recorder, "down") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(down, 0, "docker");
    try proc_runner.expectCommandArg(down, 4, "down");
    try proc_runner.expectCommandCwd(down, "/tmp/demo");
}

test "lifecycle.stopTarget: docker stop reaches compose down when tmux send fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
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
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    const down = proc_runner.findCommandContaining(&recorder, "down") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(down, 0, "docker");
    try proc_runner.expectCommandArg(down, 4, "down");
}

test "lifecycle.startTarget: reports tmux unavailable distinctly from missing session" {
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
    try recorder.enqueueError(error.FileNotFound);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, lifecycle.startTarget("api", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
}

test "lifecycle.startTarget: surfaces diagnostic when pane observation becomes unavailable" {
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
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueueError(error.FileNotFound);
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, lifecycle.startTarget("api", &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: tmux unavailable for api") != null);
}

test "lifecycle.restartTarget: docker restart reports tmux unavailable without stopping compose" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.TmuxUnavailable, lifecycle.restartTarget("docker", &writer));
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "down") == null);
}

test "lifecycle.stopTarget: stop and restart report tmux unavailable distinctly from missing session" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    inline for (.{ "stop", "restart" }) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
        const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        const cfg = try parseTestConfig(arena.allocator(), json);
        const lifecycle = testLifecycle(arena.allocator(), run, cfg);
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        const result = if (std.mem.eql(u8, op, "stop"))
            lifecycle.stopTarget("api", &writer)
        else
            lifecycle.restartTarget("api", &writer);
        try std.testing.expectError(error.TmuxUnavailable, result);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") != null);
    }
}

test "lifecycle.stopTarget: docker stop runs compose down even when tmux is unavailable" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "error connecting to /tmp/tmux-501/default (Permission denied)", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    const down = proc_runner.findCommandContaining(&recorder, "down") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(down, 4, "down");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmux unavailable") == null);
}

test "lifecycle.stopTarget: docker stop warns when compose down fails" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "down failed", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.stopTarget("docker", &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: docker compose down failed") != null);
}

test "lifecycle.startTarget: docker start is a no-op when docker pane is running" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|docker\n", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    try proc_runner.expectCommandContaining(&recorder, "has-session");
    try proc_runner.expectCommandContaining(&recorder, "list-panes");
    try proc_runner.expectCommandContaining(&recorder, "ps");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "lifecycle.startTarget: docker start sends compose up after transient busy pane" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("\n", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    const respawn = proc_runner.findCommandContaining(&recorder, "docker compose") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(respawn, 1, "respawn-pane");
    try proc_runner.expectCommandArgContains(respawn, 9, "docker compose");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Starting Docker...") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "lifecycle.startTarget: docker start respawns shell pane without compose probe" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0|0|12345|zsh\n", "", .{ .exited = 0 });
    try recorder.enqueue("12346\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("api\n", "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    const respawn = proc_runner.findCommandContaining(&recorder, "docker compose") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(respawn, 1, "respawn-pane");
    try proc_runner.expectCommandOrder(&recorder, "pgrep", "respawn-pane");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Starting Docker...") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker already starting") == null);
}

test "lifecycle.startTarget: docker start disables compose menu and waits when started" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
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
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startTarget("docker", &writer);

    const respawn = proc_runner.findCommandContaining(&recorder, "COMPOSE_MENU=false") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(respawn, 1, "respawn-pane");
    try proc_runner.expectCommandArgContains(respawn, 9, "COMPOSE_MENU=false");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Docker containers ready") != null);
}

test "lifecycle.restartTarget: docker restart checks session before stopping compose" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    recorder.term = .{ .exited = 1 };
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, lifecycle.restartTarget("docker", &writer));

    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "down") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Session not running") != null);
}

test "lifecycle.restartTarget: docker restart runs compose down before compose up" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": []
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
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.restartTarget("docker", &writer);

    try proc_runner.expectCommandOrder(&recorder, "down", "docker compose");
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(waits.docker_ready_settle, recorder.sleeps.items[0].duration);
    try proc_runner.expectCommandContaining(&recorder, "docker compose");
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "lifecycle.startAll: respawns service pane without sending command to shell history" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo app","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycleWithDockerDir(arena.allocator(), run, cfg, "/tmp/demo app");
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{});

    const respawn = proc_runner.findCommandContaining(&recorder, "respawn-pane") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(respawn, 1, "respawn-pane");
    try proc_runner.expectCommandArg(respawn, 6, "/tmp/demo app/backend");
    try proc_runner.expectCommandArg(respawn, 7, "sh");
    try proc_runner.expectCommandArg(respawn, 8, "-lc");
    try proc_runner.expectCommandArgContains(respawn, 9, "serve");
    try std.testing.expect(proc_runner.findCommandContaining(&recorder, "send-keys") == null);
}

test "lifecycle.startAll: resolves relative service cwd before sending command" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"testdata/showcase/receipt-lab","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":".","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = threaded.io(), .recorder = &recorder };
    const cfg = try parseTestConfig(arena.allocator(), json);
    const lifecycle = testLifecycle(arena.allocator(), run, cfg);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), "testdata/showcase/receipt-lab", arena.allocator());
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try lifecycle.startAll("all", &writer, .{});

    const respawn = proc_runner.findCommandContaining(&recorder, "respawn-pane") orelse return error.CommandNotFound;
    try proc_runner.expectCommandArg(respawn, 6, cwd);
    try proc_runner.expectCommandArgContains(respawn, 9, "serve");
}
