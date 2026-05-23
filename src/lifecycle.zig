const std = @import("std");
const config = @import("config.zig");
const config_value = @import("config_value.zig");
const docker_client = @import("infra/docker.zig");
const proc_runner = @import("infra/runner.zig");
const shell = @import("infra/shell.zig");
const tmux_client = @import("infra/tmux.zig");

pub const Lifecycle = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,

    pub fn startAll(self: Lifecycle, profile: []const u8, writer: *std.Io.Writer) !void {
        try self.runPrechecks(writer);
        if (self.cfg.dockerEnabled()) {
            try self.ensureDockerStarted(writer);
            self.ensureDockerReady(writer) catch {
                try writer.writeAll("Error: Docker failed to start\n");
                return error.DockerFailed;
            };
        }
        if (std.mem.eql(u8, profile, "docker")) return;
        const phases = self.cfg.phases();
        if (phases.len == 0) {
            for (try self.cfg.services()) |service| try self.startService(try config.Config.serviceName(service), writer);
            return;
        }
        for (phases) |phase| {
            if (phase != .object) continue;
            switch (phaseKind(phase)) {
                .docker => {},
                .command => try self.runCommandPhase(phase, profile, writer),
                .services => try self.runServicePhase(phase, profile, writer),
            }
        }
    }

    pub fn stopAll(self: Lifecycle, writer: *std.Io.Writer) !void {
        try writeProgress(writer, "Stopping services...\n", .{});
        const services = try self.cfg.services();
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
            return self.ensureDockerReady(writer);
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
            return self.ensureDockerReady(writer);
        }
        try self.ensureSessionActive(writer);
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            for (services) |svc| try self.restartService(svc, writer);
        } else |_| try self.restartService(target, writer);
    }

    fn startService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.ensureServiceRunning(service, writer);
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
        try self.ensureWindowReady(service);
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
        const target = try self.tmux.target(service);
        defer self.gpa.free(target);
        const cmd = try std.fmt.allocPrint(self.gpa, "cd {s} && {s}", .{ try shell.quote(self.gpa, try self.cfg.serviceDir(self.gpa, value)), try config.Config.serviceStartCommand(self.gpa, value) });
        try writeProgress(writer, "Starting {s}...\n", .{service});
        try self.tmux.sendKeys(target, &.{ cmd, "Enter" });
    }

    fn ensureServiceStopped(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        const pane = self.tmux.observePane(service);
        defer pane.deinit(self.gpa);
        switch (serviceStopDecision(pane.state)) {
            .send_stop => {},
            .no_op => {
                try writeProgress(writer, "{s} already stopped\n", .{service});
                return;
            },
            .tmux_unavailable => return error.TmuxUnavailable,
        }
        try writeProgress(writer, "Stopping {s}...\n", .{service});
        const target = try self.tmux.target(service);
        defer self.gpa.free(target);
        try self.tmux.sendKeys(target, &.{"C-c"});
        try self.waitForStopped(service, writer);
    }

    fn ensureDockerStarted(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try self.ensureWindowReady("docker");
        const pane = self.tmux.observePane("docker");
        defer pane.deinit(self.gpa);
        switch (dockerStartDecision(pane.state)) {
            .no_op => {
                try writeProgress(writer, "Docker already running\n", .{});
                return;
            },
            .send_start => {},
            .window_not_ready => return error.WindowNotReady,
            .tmux_unavailable => return error.TmuxUnavailable,
        }
        try writeProgress(writer, "Starting Docker...\n", .{});
        const target = try self.tmux.target("docker");
        defer self.gpa.free(target);
        try self.tmux.sendKeys(target, &.{ try std.fmt.allocPrint(self.gpa, "cd {s} && COMPOSE_MENU=false docker compose -f {s} up", .{ try shell.quote(self.gpa, try self.cfg.dockerDir(self.gpa)), try shell.quote(self.gpa, self.cfg.dockerComposeFile()) }), "Enter" });
    }

    pub fn stopDocker(self: Lifecycle, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return;
        try writeProgress(writer, "Stopping Docker...\n", .{});
        if (self.tmux.observeSession() == .active) {
            const target = try self.tmux.target("docker");
            defer self.gpa.free(target);
            try self.tmux.sendKeys(target, &.{"C-c"});
        }
        self.docker.down() catch {};
    }

    fn runPrechecks(self: Lifecycle, writer: *std.Io.Writer) !void {
        for (self.cfg.prechecks()) |check| {
            const name = config_value.optionalObjectString(check, "name", "precheck");
            const command = try config_value.requiredObjectString(check, "command");
            const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
            const dir = config_value.optionalObjectString(check, "dir", "");
            const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
            const result = self.runner.runCheckedCwd(&.{ "bash", "-c", command }, cwd) catch {
                if (std.mem.eql(u8, on_fail, "abort")) return error.PrecheckFailed;
                try writer.print("Warning: {s} check failed\n", .{name});
                continue;
            };
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
        }
    }

    fn runCommandPhase(self: Lifecycle, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
        const command = try config.Config.commandPhaseCommand(phase, profile);
        const dir = config_value.optionalObjectString(phase, "dir", "");
        const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
        _ = self.runner.runInteractiveCheckedCwd(&.{ "bash", "-c", command }, cwd) catch {
            if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
            try writer.writeAll("Warning: command phase failed\n");
            return;
        };
    }

    fn runServicePhase(self: Lifecycle, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
        if (phase.object.get("groups")) |groups| if (groups == .array) {
            for (groups.array.items) |group_value| {
                if (group_value != .string) continue;
                const group = self.cfg.resolvePhaseGroup(profile, group_value.string);
                for (try self.cfg.resolveGroup(self.gpa, group)) |svc| try self.startService(svc, writer);
            }
        };
        if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
            for (ports.array.items) |port_value| if (port_value == .integer) try self.waitForPort(port_value.integer, 120, writer);
        };
    }

    fn ensureDockerReady(self: Lifecycle, writer: *std.Io.Writer) !void {
        try writer.writeAll("Waiting for Docker containers...\n");
        var attempt: i64 = 0;
        const max_attempts = self.cfg.dockerWaitTimeout();
        while (attempt < max_attempts) : (attempt += 1) {
            const compose = self.docker.observe();
            defer compose.deinit(self.gpa);
            if (compose.state == .running) {
                self.runner.runDiscard(&.{ "sleep", "2" }) catch {};
                try writer.writeAll("Docker containers ready\n");
                return;
            }
            self.runner.runDiscard(&.{ "sleep", "1" }) catch {};
        }
        return error.DockerNotReady;
    }

    fn waitForPort(self: Lifecycle, port: i64, timeout: i64, writer: *std.Io.Writer) !void {
        const port_text = try std.fmt.allocPrint(self.gpa, "{d}", .{port});
        var elapsed: i64 = 0;
        while (elapsed < timeout) : (elapsed += 2) {
            if (self.runner.runCheckedDiscard(&.{ "nc", "-z", "localhost", port_text })) |_| return else |_| {}
            self.runner.runDiscard(&.{ "sleep", "2" }) catch {};
        }
        try writeProgress(writer, "Warning: port {d} did not become ready within {d}s\n", .{ port, timeout });
    }

    fn ensureWindowReady(self: Lifecycle, window: []const u8) !void {
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            if (self.tmux.observeWindow(window) == .present) return;
            self.runner.runDiscard(&.{ "sleep", "0.3" }) catch {};
        }
        return error.WindowNotReady;
    }

    fn waitForStopped(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        var attempt: usize = 0;
        while (attempt < 10) : (attempt += 1) {
            const pane = self.tmux.observePane(service);
            defer pane.deinit(self.gpa);
            if (pane.state != .busy) return;
            self.runner.runDiscard(&.{ "sleep", "0.5" }) catch {};
        }
        try writeProgress(writer, "Warning: {s} may not have stopped completely\n", .{service});
    }
};

const PhaseKind = enum {
    docker,
    command,
    services,
};

fn phaseKind(phase: std.json.Value) PhaseKind {
    const value = config_value.optionalObjectString(phase, "type", "");
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "command")) return .command;
    return .services;
}

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

fn serviceStartDecision(state: @import("observations.zig").PaneState) StartDecision {
    return switch (state) {
        .busy => .no_op,
        .idle, .dead => .send_start,
        .window_missing => .window_not_ready,
        .tmux_unavailable => .tmux_unavailable,
    };
}

fn serviceStopDecision(state: @import("observations.zig").PaneState) StopDecision {
    return switch (state) {
        .busy => .send_stop,
        .idle, .dead, .window_missing => .no_op,
        .tmux_unavailable => .tmux_unavailable,
    };
}

fn dockerStartDecision(state: @import("observations.zig").PaneState) StartDecision {
    return serviceStartDecision(state);
}

test "classifies lifecycle phase kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\[
        \\  {"type":"docker"},
        \\  {"type":"command"},
        \\  {"groups":["api"]}
        \\]
    , .{});

    try std.testing.expectEqual(PhaseKind.docker, phaseKind(parsed.array.items[0]));
    try std.testing.expectEqual(PhaseKind.command, phaseKind(parsed.array.items[1]));
    try std.testing.expectEqual(PhaseKind.services, phaseKind(parsed.array.items[2]));
}

test "maps pane observations to lifecycle start and stop decisions" {
    const observations = @import("observations.zig");
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
        try recorder.enqueue("", "", .{ .exited = 0 });
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

    try lifecycle.waitForPort(5432, 2, &writer);
    try lifecycle.waitForStopped("api", &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Warning: port 5432") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "api may not have stopped") != null);
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
