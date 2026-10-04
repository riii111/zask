const std = @import("std");
const config = @import("../model/config.zig");
const docker_client = @import("../platform/docker.zig");
const observations = @import("../model/observations.zig");
const proc_runner = @import("../platform/runner.zig");
const tmux_client = @import("../platform/tmux.zig");

/// Read-only observation of configured services shared by every caller that
/// reports service state. Probes run only for running panes, and nothing here
/// starts, stops, or selects anything.
pub const Observer = struct {
    gpa: std.mem.Allocator,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,

    /// Caller owns the result and must deinit it with this observer's allocator.
    pub fn observeService(self: Observer, service: std.json.Value) !observations.ServiceObservation {
        const pane = self.tmux.observePane(try config.Config.serviceName(service));
        errdefer pane.deinit(self.gpa);
        var result = self.unprobedService(service, pane);
        if (!pane.running()) return result;
        const configured_port = result.port orelse return result;

        result.listen = try self.probeListen(configured_port);
        if (result.listen != .passed or result.http == .not_configured) return result;
        result.http = try self.probeHttp(configured_port, config.Config.serviceHealthcheckPath(service));
        return result;
    }

    /// Observation with the given pane and no probe run, for callers that know
    /// the pane without asking tmux (e.g. the session is not running). Takes
    /// ownership of `pane`; deinit the result, not the pane.
    pub fn unprobedService(self: Observer, service: std.json.Value, pane: observations.PaneObservation) observations.ServiceObservation {
        const port = config.Config.servicePort(service);
        const http_configured = port != null and std.mem.eql(u8, config.Config.serviceHealthcheckType(service), "http");
        return .{
            .pane = pane,
            .port = port,
            .listen = if (port == null) .not_configured else .not_observed,
            .http = if (http_configured) .not_observed else .not_configured,
            .observed_at = self.runner.nowSeconds(),
        };
    }

    /// Caller owns the result and must deinit it with this observer's allocator.
    pub fn observeDocker(self: Observer) observations.DockerObservation {
        const pane = self.tmux.observePane("docker");
        const compose = if (pane.running()) self.docker.observe() else observations.ComposeObservation.empty(.empty);
        return .{ .pane = pane, .compose = compose, .observed_at = self.runner.nowSeconds() };
    }

    fn probeListen(self: Observer, port: i64) !observations.ProbeObservation {
        const port_text = try std.fmt.allocPrint(self.gpa, "{d}", .{port});
        defer self.gpa.free(port_text);
        return self.probe(&.{ "nc", "-z", "localhost", port_text });
    }

    fn probeHttp(self: Observer, port: i64, path: []const u8) !observations.ProbeObservation {
        const url = try std.fmt.allocPrint(self.gpa, "http://localhost:{d}{s}", .{ port, path });
        defer self.gpa.free(url);
        return self.probe(&.{ "curl", "-sf", "--max-time", "1", url });
    }

    /// A probe that cannot be spawned is `unavailable`, not `failed`: a missing
    /// `nc` / `curl` must not read as a service that is not ready.
    fn probe(self: Observer, argv: []const []const u8) observations.ProbeObservation {
        const result = proc_runner.captured(self.runner.run(argv, .{}) catch return .unavailable);
        defer self.runner.gpa.free(result.stdout);
        defer self.runner.gpa.free(result.stderr);
        return if (result.term == .exited and result.term.exited == 0) .passed else .failed;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_now = 1_000;

const TestProbe = union(enum) {
    exit: u8,
    spawn_error,
};

fn testObserver(gpa: std.mem.Allocator, recorder: *proc_runner.Recorder) Observer {
    const run: proc_runner.Runner = .{ .gpa = gpa, .io = undefined, .recorder = recorder };
    recorder.now_seconds = test_now;
    return .{
        .gpa = gpa,
        .runner = run,
        .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
        .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
}

fn testService(gpa: std.mem.Allocator, service_json: []const u8) !std.json.Value {
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"demo","root":"/tmp/demo"}},
        \\  "groups": [{{"name":"backend","services":[{s}]}}]
        \\}}
    , .{service_json});
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    return (try cfg.services())[0];
}

fn testEnqueueProbe(recorder: *proc_runner.Recorder, probe: TestProbe) !void {
    switch (probe) {
        .exit => |code| try recorder.enqueue("", "", .{ .exited = code }),
        .spawn_error => try recorder.enqueueError(error.FileNotFound),
    }
}

fn testCommandCount(recorder: *const proc_runner.Recorder, name: []const u8) usize {
    var count: usize = 0;
    for (recorder.commands.items) |command| {
        if (std.mem.eql(u8, command.argv[0], name)) count += 1;
    }
    return count;
}

test "observer.service: maps probe results of a running service to health" {
    const tcp = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000}";
    const http = "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000,\"healthcheck\":{\"type\":\"http\",\"path\":\"/ready\"}}";
    const cases = [_]struct {
        name: []const u8,
        service: []const u8,
        probes: []const TestProbe,
        listen: observations.ProbeObservation,
        http: observations.ProbeObservation,
        health: observations.HealthObservation,
    }{
        .{ .name = "tcp ready", .service = tcp, .probes = &.{.{ .exit = 0 }}, .listen = .passed, .http = .not_configured, .health = .ready },
        .{ .name = "tcp waiting", .service = tcp, .probes = &.{.{ .exit = 1 }}, .listen = .failed, .http = .not_configured, .health = .waiting },
        .{ .name = "nc missing", .service = tcp, .probes = &.{.spawn_error}, .listen = .unavailable, .http = .not_configured, .health = .unavailable },
        .{ .name = "http ready", .service = http, .probes = &.{ .{ .exit = 0 }, .{ .exit = 0 } }, .listen = .passed, .http = .passed, .health = .ready },
        .{ .name = "http failing", .service = http, .probes = &.{ .{ .exit = 0 }, .{ .exit = 22 } }, .listen = .passed, .http = .failed, .health = .degraded },
        .{ .name = "curl missing", .service = http, .probes = &.{ .{ .exit = 0 }, .spawn_error }, .listen = .passed, .http = .unavailable, .health = .unavailable },
        .{ .name = "http before listen", .service = http, .probes = &.{.{ .exit = 1 }}, .listen = .failed, .http = .not_observed, .health = .waiting },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue("0||12345|node|900\n", "", .{ .exited = 0 });
        for (case.probes) |probe| try testEnqueueProbe(&recorder, probe);
        const observer = testObserver(arena.allocator(), &recorder);

        const observation = try observer.observeService(try testService(arena.allocator(), case.service));

        try std.testing.expectEqual(case.listen, observation.listen);
        try std.testing.expectEqual(case.http, observation.http);
        try std.testing.expectEqual(case.health, observation.health());
        try std.testing.expectEqual(@as(?i64, 3000), observation.port);
        try proc_runner.expectNoRemainingResponses(&recorder);
    }
}

test "observer.service: probes the configured http path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0||12345|node|900\n", "", .{ .exited = 0 });
    const observer = testObserver(arena.allocator(), &recorder);

    _ = try observer.observeService(try testService(arena.allocator(), "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000,\"healthcheck\":{\"type\":\"http\",\"path\":\"/ready\"}}"));

    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "nc", "-z", "localhost", "3000" });
    try proc_runner.expectCommandArgv(recorder.commands.items[2], &.{ "curl", "-sf", "--max-time", "1", "http://localhost:3000/ready" });
}

test "observer.service: skips probes unless the pane is running" {
    const cases = [_]struct {
        name: []const u8,
        pane_stdout: []const u8,
        pane_stderr: []const u8 = "",
        pane_exit: u8 = 0,
        pgrep_called: bool = false,
        state: observations.PaneState,
        health: observations.HealthObservation,
        uptime: observations.Uptime,
    }{
        .{ .name = "stopped shell", .pane_stdout = "0||12345|zsh|900\n", .pgrep_called = true, .state = .idle, .health = .not_running, .uptime = .not_running },
        .{ .name = "exited", .pane_stdout = "1|2|12345|node|900\n", .state = .dead, .health = .not_running, .uptime = .not_running },
        .{ .name = "missing window", .pane_stdout = "", .pane_stderr = "can't find window", .pane_exit = 1, .state = .window_missing, .health = .not_running, .uptime = .not_running },
        .{ .name = "tmux unavailable", .pane_stdout = "", .pane_stderr = "Permission denied", .pane_exit = 1, .state = .tmux_unavailable, .health = .unavailable, .uptime = .unknown },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.pane_stdout, case.pane_stderr, .{ .exited = case.pane_exit });
        if (case.pgrep_called) try recorder.enqueue("", "", .{ .exited = 1 });
        const observer = testObserver(arena.allocator(), &recorder);

        const observation = try observer.observeService(try testService(arena.allocator(), "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\",\"port\":3000,\"healthcheck\":{\"type\":\"http\"}}"));

        try std.testing.expectEqual(case.state, observation.pane.state);
        try std.testing.expectEqual(observations.ProbeObservation.not_observed, observation.listen);
        try std.testing.expectEqual(observations.ProbeObservation.not_observed, observation.http);
        try std.testing.expectEqual(case.health, observation.health());
        try std.testing.expectEqual(case.uptime, observation.uptime());
        try std.testing.expectEqual(@as(usize, 0), testCommandCount(&recorder, "nc"));
        try std.testing.expectEqual(@as(usize, 0), testCommandCount(&recorder, "curl"));
        try proc_runner.expectNoRemainingResponses(&recorder);
    }
}

test "observer.service: keeps exit code of an exited service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("1|2|12345|node|900\n", "", .{ .exited = 0 });
    const observer = testObserver(arena.allocator(), &recorder);

    const observation = try observer.observeService(try testService(arena.allocator(), "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\"}"));

    try std.testing.expectEqual(observations.PaneState.dead, observation.pane.state);
    try std.testing.expectEqualStrings("2", observation.pane.exit_code);
}

test "observer.service: reports no check for a running service without port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("0||12345|node|900\n", "", .{ .exited = 0 });
    const observer = testObserver(arena.allocator(), &recorder);

    const observation = try observer.observeService(try testService(arena.allocator(), "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\"}"));

    try std.testing.expectEqual(@as(?i64, null), observation.port);
    try std.testing.expectEqual(observations.ProbeObservation.not_configured, observation.listen);
    try std.testing.expectEqual(observations.ProbeObservation.not_configured, observation.http);
    try std.testing.expectEqual(observations.HealthObservation.no_check, observation.health());
    try std.testing.expectEqual(@as(usize, 0), testCommandCount(&recorder, "nc"));
}

test "observer.service: measures uptime from the start marker" {
    const cases = [_]struct {
        line: []const u8,
        uptime: observations.Uptime,
    }{
        .{ .line = "0||12345|node|900\n", .uptime = .{ .seconds = 100 } },
        .{ .line = "0||12345|node|\n", .uptime = .unknown },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.line, "", .{ .exited = 0 });
        const observer = testObserver(arena.allocator(), &recorder);

        const observation = try observer.observeService(try testService(arena.allocator(), "{\"name\":\"api\",\"dir\":\"api\",\"command\":\"serve\"}"));

        try std.testing.expectEqual(@as(i64, test_now), observation.observed_at);
        try std.testing.expectEqual(case.uptime, observation.uptime());
    }
}

test "observer.docker: observes compose only for a running pane" {
    const cases = [_]struct {
        pane_stdout: []const u8,
        pgrep_called: bool,
        compose: observations.ComposeState,
        docker_calls: usize,
    }{
        .{ .pane_stdout = "0||12345|docker|900\n", .pgrep_called = false, .compose = .running, .docker_calls = 1 },
        .{ .pane_stdout = "0||12345|zsh|900\n", .pgrep_called = true, .compose = .empty, .docker_calls = 0 },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.pane_stdout, "", .{ .exited = 0 });
        if (case.pgrep_called) try recorder.enqueue("", "", .{ .exited = 1 });
        if (case.docker_calls > 0) try recorder.enqueue("api\n", "", .{ .exited = 0 });
        const observer = testObserver(arena.allocator(), &recorder);

        const observation = observer.observeDocker();

        try std.testing.expectEqual(case.compose, observation.compose.state);
        try std.testing.expectEqual(case.docker_calls, testCommandCount(&recorder, "docker"));
        try proc_runner.expectNoRemainingResponses(&recorder);
    }
}
