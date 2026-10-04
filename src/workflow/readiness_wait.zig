const std = @import("std");
const config = @import("../model/config.zig");
const observations = @import("../model/observations.zig");
const service_observation = @import("service_observation.zig");
const waits = @import("waits.zig");

/// Matches the startup port wait so `wait` gives up no sooner than `open` would.
pub const default_timeout_seconds = 180;
const poll_interval_seconds = 1;

/// What one observation means for a service being waited on.
pub const WaitDecision = enum {
    /// The configured port listens and, when configured, the HTTP check passes.
    ready,
    /// No port is configured, so a running process is the success condition.
    running_without_check,
    pending,
    not_running,
    unobservable,
};

pub fn waitDecision(health: observations.HealthObservation) WaitDecision {
    return switch (health) {
        .ready => .ready,
        .no_check => .running_without_check,
        .waiting, .degraded => .pending,
        .not_running => .not_running,
        .unavailable => .unobservable,
    };
}

/// Polls the shared service observation until every target is ready. Read-only:
/// nothing is started, stopped, or selected, so a service that is not running
/// fails at once instead of being waited on. `timeout_seconds` bounds the whole
/// wait, not each service. A target is a group (checked first, as in `start`)
/// or a service; a service named by several targets is waited on once.
pub fn waitReady(cfg: config.Config, observer: service_observation.Observer, targets: []const []const u8, timeout_seconds: u32, writer: *std.Io.Writer) !void {
    const gpa = observer.gpa;
    const services = try expandTargets(gpa, cfg, targets, writer);
    defer gpa.free(services);
    const deadline = observer.runner.nowSeconds() + timeout_seconds;
    switch (observer.tmux.observeSession()) {
        .active => {},
        .missing => {
            try waits.writeProgress(writer, "Session not running\n", .{});
            return error.SessionNotRunning;
        },
        .unavailable => return waits.reportTmuxUnavailable(writer),
    }

    // Last health per service for the timeout report; null until observed.
    const last = try gpa.alloc(?observations.HealthObservation, services.len);
    defer gpa.free(last);
    @memset(last, null);
    const reported = try gpa.alloc(bool, services.len);
    defer gpa.free(reported);
    @memset(reported, false);

    // Every round re-observes all targets, so one that became ready and then
    // exited still fails the wait. The deadline is checked before each
    // observation as well; since every probe is time-bounded (nc -w 1, curl
    // --max-time 1), the wait overruns the deadline by at most one probe.
    while (true) {
        var all_ready = true;
        for (services, last, reported) |service, *health, *was_reported| {
            if (observer.runner.nowSeconds() > deadline) return reportTimeout(writer, services, last, timeout_seconds);
            const name = try config.Config.serviceName(service);
            const observation = try observer.observeService(service);
            defer observation.deinit(gpa);
            health.* = observation.health();
            switch (waitDecision(observation.health())) {
                .ready => if (!was_reported.*) {
                    was_reported.* = true;
                    try waits.writeProgress(writer, "{s} ready\n", .{name});
                },
                .running_without_check => if (!was_reported.*) {
                    was_reported.* = true;
                    try waits.writeProgress(writer, "{s} running (no port to check)\n", .{name});
                },
                .pending => all_ready = false,
                .not_running => return reportNotRunning(writer, name, observation.pane),
                .unobservable => return reportUnobservable(writer, name, observation),
            }
        }
        const now = observer.runner.nowSeconds();
        if (all_ready and now <= deadline) return;
        if (now >= deadline) return reportTimeout(writer, services, last, timeout_seconds);
        observer.runner.sleep(std.Io.Duration.fromSeconds(@min(poll_interval_seconds, deadline - now)));
    }
}

/// Caller owns the returned slice; the values borrow from `cfg`.
fn expandTargets(gpa: std.mem.Allocator, cfg: config.Config, targets: []const []const u8, writer: *std.Io.Writer) ![]std.json.Value {
    var services: std.ArrayList(std.json.Value) = .empty;
    errdefer services.deinit(gpa);
    for (targets) |target| {
        if (cfg.resolveGroup(gpa, target)) |names| {
            defer gpa.free(names);
            for (names) |name| try appendUnique(gpa, &services, try findTarget(cfg, name, writer));
        } else |err| switch (err) {
            error.UnknownGroup => try appendUnique(gpa, &services, try findTarget(cfg, target, writer)),
            else => return err,
        }
    }
    return services.toOwnedSlice(gpa);
}

fn findTarget(cfg: config.Config, name: []const u8, writer: *std.Io.Writer) !std.json.Value {
    return cfg.findService(name) catch |err| switch (err) {
        error.UnknownService => {
            try waits.writeProgress(writer, "Unknown service or group: {s}\n", .{name});
            return error.UnknownTarget;
        },
        else => return err,
    };
}

fn appendUnique(gpa: std.mem.Allocator, services: *std.ArrayList(std.json.Value), service: std.json.Value) !void {
    const name = try config.Config.serviceName(service);
    for (services.items) |existing| {
        if (std.mem.eql(u8, try config.Config.serviceName(existing), name)) return;
    }
    try services.append(gpa, service);
}

fn reportNotRunning(writer: *std.Io.Writer, name: []const u8, pane: observations.PaneObservation) !void {
    switch (pane.state) {
        .dead => if (pane.exit_code.len > 0)
            try waits.writeProgress(writer, "{s} exited with code {s}\n", .{ name, pane.exit_code })
        else
            try waits.writeProgress(writer, "{s} exited\n", .{name}),
        .idle => try waits.writeProgress(writer, "{s} is not running\n", .{name}),
        .window_missing => try waits.writeProgress(writer, "{s} has no window\n", .{name}),
        // serviceHealth maps these to running or unavailable, never not_running.
        .busy, .tmux_unavailable => unreachable,
    }
    return error.ServiceNotRunning;
}

fn reportUnobservable(writer: *std.Io.Writer, name: []const u8, observation: observations.ServiceObservation) !void {
    if (observation.pane.state == .tmux_unavailable) return waits.reportTmuxUnavailable(writer);
    const probe = if (observation.listen == .unavailable) "nc" else if (observation.http == .unavailable) "curl" else "probe";
    try waits.writeProgress(writer, "{s}: cannot check readiness ({s} unavailable)\n", .{ name, probe });
    return error.ReadinessUnavailable;
}

fn reportTimeout(writer: *std.Io.Writer, services: []const std.json.Value, last: []const ?observations.HealthObservation, timeout_seconds: u32) !void {
    try writer.print("Timed out after {d}s waiting for:\n", .{timeout_seconds});
    var listed: usize = 0;
    for (services, last) |service, health| {
        const name = try config.Config.serviceName(service);
        const port = config.Config.servicePort(service) orelse 0;
        const observed = health orelse {
            listed += 1;
            try writer.print("  {s}: not checked before the deadline\n", .{name});
            continue;
        };
        switch (observed) {
            .waiting => try writer.print("  {s}: port {d} not listening\n", .{ name, port }),
            .degraded => try writer.print("  {s}: HTTP check on port {d} failing\n", .{ name, port }),
            // Not reaching the deadline check: not_running / unavailable end
            // the wait at once.
            .ready, .no_check, .not_running, .unavailable => continue,
        }
        listed += 1;
    }
    if (listed == 0) try writer.writeAll("  all targets became ready only after the deadline\n");
    try writer.flush();
    return error.WaitTimedOut;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const proc_runner = @import("../platform/runner.zig");

const test_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "groups": [{"name":"backend","services":[
    \\    {"name":"api","dir":"api","command":"serve","port":3000,"healthcheck":{"type":"http","path":"/ready"}},
    \\    {"name":"worker","dir":"worker","command":"work"},
    \\    {"name":"web","dir":"web","command":"dev","port":5173}
    \\  ]}]
    \\}
;

const test_session_active = "";
const test_pane_running = "0||100|node|900\n";

const TestHarness = struct {
    arena: std.heap.ArenaAllocator,
    recorder: proc_runner.Recorder,
    out: std.Io.Writer.Allocating,

    fn init(self: *TestHarness) void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.recorder = proc_runner.Recorder.init(self.arena.allocator());
        self.recorder.now_seconds = 1_000;
        self.recorder.advance_clock_on_sleep = true;
        self.out = .init(self.arena.allocator());
    }

    fn deinit(self: *TestHarness) void {
        self.recorder.deinit();
        self.arena.deinit();
    }

    fn enqueue(self: *TestHarness, stdout: []const u8, exit: u8) !void {
        try self.recorder.enqueue(stdout, "", .{ .exited = exit });
    }

    fn wait(self: *TestHarness, targets: []const []const u8, timeout_seconds: u32) !void {
        const gpa = self.arena.allocator();
        const cfg = try config.Config.parse(gpa, test_config, "/home/me");
        const run: proc_runner.Runner = .{ .gpa = gpa, .io = undefined, .recorder = &self.recorder };
        const observer: service_observation.Observer = .{
            .gpa = gpa,
            .runner = run,
            .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
            .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
        };
        return waitReady(cfg, observer, targets, timeout_seconds, &self.out.writer);
    }

    fn output(self: *TestHarness) []const u8 {
        return self.out.written();
    }

    fn commandCount(self: *TestHarness, name: []const u8) usize {
        var count: usize = 0;
        for (self.recorder.commands.items) |command| {
            if (std.mem.eql(u8, command.argv[0], name)) count += 1;
        }
        return count;
    }

    /// Fails if the wait issued anything beyond observation queries.
    fn expectReadOnly(self: *TestHarness) !void {
        for (self.recorder.commands.items) |command| {
            for ([_][]const u8{ "respawn-pane", "send-keys", "select-window", "kill-session", "new-window" }) |mutating| {
                try std.testing.expect(!proc_runner.commandContains(command, mutating));
            }
        }
    }
};

test "readiness_wait.waitDecision: maps health to wait decision" {
    const cases = [_]struct {
        health: observations.HealthObservation,
        expected: WaitDecision,
    }{
        .{ .health = .ready, .expected = .ready },
        .{ .health = .no_check, .expected = .running_without_check },
        .{ .health = .waiting, .expected = .pending },
        .{ .health = .degraded, .expected = .pending },
        .{ .health = .not_running, .expected = .not_running },
        .{ .health = .unavailable, .expected = .unobservable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, waitDecision(case.health));
    }
}

test "readiness_wait.waitReady: succeeds once the port listens" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 1);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);

    try h.wait(&.{"web"}, 30);

    try std.testing.expectEqualStrings("web ready\n", h.output());
    try std.testing.expectEqual(@as(usize, 1), h.recorder.sleeps.items.len);
    try std.testing.expectEqual(@as(usize, 2), h.commandCount("nc"));
    try proc_runner.expectNoRemainingResponses(&h.recorder);
    try h.expectReadOnly();
}

test "readiness_wait.waitReady: waits for a failing HTTP check to pass" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 22);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);

    try h.wait(&.{"api"}, 30);

    try std.testing.expectEqualStrings("api ready\n", h.output());
    try std.testing.expectEqual(@as(usize, 2), h.commandCount("curl"));
    try proc_runner.expectNoRemainingResponses(&h.recorder);
}

test "readiness_wait.waitReady: treats a running service without port as done" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);

    try h.wait(&.{"worker"}, 30);

    try std.testing.expectEqualStrings("worker running (no port to check)\n", h.output());
    try std.testing.expectEqual(@as(usize, 0), h.commandCount("nc"));
    try std.testing.expectEqual(@as(usize, 0), h.recorder.sleeps.items.len);
}

test "readiness_wait.waitReady: waits for every service of a group" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    // round 1: api ready, worker running, web not listening yet
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 1);
    // round 2: every service is observed again; api and worker are not reported twice
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);

    try h.wait(&.{ "backend", "api" }, 30);

    try std.testing.expectEqualStrings("api ready\nworker running (no port to check)\nweb ready\n", h.output());
    try std.testing.expectEqual(@as(usize, 4), h.commandCount("nc"));
    try proc_runner.expectNoRemainingResponses(&h.recorder);
    try h.expectReadOnly();
}

test "readiness_wait.waitReady: fails when a ready service exits before the others are ready" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 1);
    try h.enqueue("1|1|100|node|900\n", 0);

    try std.testing.expectError(error.ServiceNotRunning, h.wait(&.{ "api", "web" }, 30));

    try std.testing.expectEqualStrings("api ready\napi exited with code 1\n", h.output());
    try proc_runner.expectNoRemainingResponses(&h.recorder);
}

test "readiness_wait.waitReady: does not succeed when observing outlasts the deadline" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    h.recorder.seconds_per_command = 1;
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);

    try std.testing.expectError(error.WaitTimedOut, h.wait(&.{ "api", "web" }, 1));

    try std.testing.expectEqualStrings(
        \\api ready
        \\Timed out after 1s waiting for:
        \\  web: not checked before the deadline
        \\
    , h.output());
    try std.testing.expectEqual(@as(usize, 2), h.commandCount("tmux"));
    try proc_runner.expectNoRemainingResponses(&h.recorder);
}

test "readiness_wait.waitReady: counts the session check against the deadline" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    h.recorder.seconds_per_command = 2;
    try h.enqueue(test_session_active, 0);

    try std.testing.expectError(error.WaitTimedOut, h.wait(&.{"web"}, 1));

    try std.testing.expectEqualStrings("Timed out after 1s waiting for:\n  web: not checked before the deadline\n", h.output());
    try std.testing.expectEqual(@as(usize, 1), h.recorder.commands.items.len);
}

test "readiness_wait.waitReady: times out when the last round ends past the deadline" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    h.recorder.seconds_per_command = 1;
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 0);
    try h.enqueue("", 0);

    try std.testing.expectError(error.WaitTimedOut, h.wait(&.{"api"}, 1));

    try std.testing.expectEqualStrings(
        \\api ready
        \\Timed out after 1s waiting for:
        \\  all targets became ready only after the deadline
        \\
    , h.output());
}

test "readiness_wait.waitReady: fails when a service exits while waiting" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 1);
    try h.enqueue("1|2|100|node|900\n", 0);

    try std.testing.expectError(error.ServiceNotRunning, h.wait(&.{"web"}, 30));

    try std.testing.expectEqualStrings("web exited with code 2\n", h.output());
    try proc_runner.expectNoRemainingResponses(&h.recorder);
}

test "readiness_wait.waitReady: fails at once for a service that is not running" {
    const cases = [_]struct {
        pane_stdout: []const u8,
        pane_stderr: []const u8 = "",
        pane_exit: u8 = 0,
        pgrep_called: bool = false,
        message: []const u8,
    }{
        .{ .pane_stdout = "0||100|zsh|900\n", .pgrep_called = true, .message = "web is not running\n" },
        .{ .pane_stdout = "", .pane_stderr = "can't find window: web", .pane_exit = 1, .message = "web has no window\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.message});
        var h: TestHarness = undefined;
        h.init();
        defer h.deinit();
        try h.enqueue(test_session_active, 0);
        try h.recorder.enqueue(case.pane_stdout, case.pane_stderr, .{ .exited = case.pane_exit });
        if (case.pgrep_called) try h.enqueue("", 1);

        try std.testing.expectError(error.ServiceNotRunning, h.wait(&.{"web"}, 30));

        try std.testing.expectEqualStrings(case.message, h.output());
        try std.testing.expectEqual(@as(usize, 0), h.recorder.sleeps.items.len);
        try h.expectReadOnly();
    }
}

test "readiness_wait.waitReady: fails when readiness cannot be observed" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.recorder.enqueueError(error.FileNotFound);

    try std.testing.expectError(error.ReadinessUnavailable, h.wait(&.{"web"}, 30));

    try std.testing.expectEqualStrings("web: cannot check readiness (nc unavailable)\n", h.output());
}

test "readiness_wait.waitReady: times out within the overall limit" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    for (0..3) |_| {
        try h.enqueue(test_pane_running, 0);
        try h.enqueue("", 0);
        try h.enqueue("", 22);
        try h.enqueue(test_pane_running, 0);
        try h.enqueue("", 1);
    }

    try std.testing.expectError(error.WaitTimedOut, h.wait(&.{ "api", "web" }, 2));

    try std.testing.expectEqualStrings(
        \\Timed out after 2s waiting for:
        \\  api: HTTP check on port 3000 failing
        \\  web: port 5173 not listening
        \\
    , h.output());
    try std.testing.expectEqual(@as(usize, 2), h.recorder.sleeps.items.len);
    try std.testing.expectEqual(@as(i64, 1_002), h.recorder.now_seconds);
    try proc_runner.expectNoRemainingResponses(&h.recorder);
}

test "readiness_wait.waitReady: checks once with a zero timeout" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.enqueue(test_session_active, 0);
    try h.enqueue(test_pane_running, 0);
    try h.enqueue("", 1);

    try std.testing.expectError(error.WaitTimedOut, h.wait(&.{"web"}, 0));

    try std.testing.expectEqual(@as(usize, 0), h.recorder.sleeps.items.len);
}

test "readiness_wait.waitReady: rejects unknown targets before observing" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();

    try std.testing.expectError(error.UnknownTarget, h.wait(&.{ "api", "missing" }, 30));

    try std.testing.expectEqualStrings("Unknown service or group: missing\n", h.output());
    try std.testing.expectEqual(@as(usize, 0), h.recorder.commands.items.len);
}

test "readiness_wait.waitReady: fails without a running session" {
    var h: TestHarness = undefined;
    h.init();
    defer h.deinit();
    try h.recorder.enqueue("", "can't find session: demo", .{ .exited = 1 });

    try std.testing.expectError(error.SessionNotRunning, h.wait(&.{"api"}, 30));

    try std.testing.expectEqualStrings("Session not running\n", h.output());
    try std.testing.expectEqual(@as(usize, 1), h.recorder.commands.items.len);
}
