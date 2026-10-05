const std = @import("std");
const recovery = @import("recovery.zig");

pub const SessionObservation = enum {
    active,
    missing,
    unavailable,
};

pub const WindowObservation = enum {
    present,
    missing,
    unavailable,
};

pub const StopMarkObservation = enum {
    stopped,
    not_stopped,
    unavailable,
};

pub const PaneState = enum {
    window_missing,
    idle,
    busy,
    dead,
    tmux_unavailable,
};

pub const PaneObservation = struct {
    state: PaneState,
    exit_code: []const u8 = "",
    pid: []const u8 = "",
    command: []const u8 = "",
    exit: PaneExit = .clean,
    started_at: ?i64 = null,
    recovery: recovery.RecordObservation = .none,

    pub fn empty(state: PaneState) PaneObservation {
        return .{ .state = state };
    }

    /// Takes ownership of the passed slices; the returned value frees them on
    /// deinit. Do not deinit or reuse the originals afterwards.
    pub fn fromOwned(state: PaneState, exit_code: []const u8, pid: []const u8, command: []const u8, started_at: ?i64) PaneObservation {
        return .{
            .state = state,
            .exit_code = exit_code,
            .pid = pid,
            .command = command,
            .started_at = started_at,
        };
    }

    pub fn deinit(self: PaneObservation, gpa: std.mem.Allocator) void {
        gpa.free(self.exit_code);
        gpa.free(self.pid);
        gpa.free(self.command);
    }

    pub fn running(self: PaneObservation) bool {
        return self.state == .busy;
    }

    pub fn processId(self: PaneObservation) ?i64 {
        return std.fmt.parseInt(i64, self.pid, 10) catch null;
    }

    pub fn uptime(self: PaneObservation, now: i64) Uptime {
        return switch (self.state) {
            .idle, .dead, .window_missing => .not_running,
            .tmux_unavailable => .unknown,
            .busy => {
                const started_at = self.started_at orelse return .unknown;
                if (started_at > now) return .unknown;
                return .{ .seconds = now - started_at };
            },
        };
    }
};

const sigint = 2;

pub fn paneExit(status: []const u8, signal: []const u8) PaneExit {
    const code = std.fmt.parseInt(u32, status, 10) catch
        return if (isInterruptSignal(signal)) .interrupted else .killed;
    return switch (code) {
        0 => .clean,
        else => .{ .failed = code },
    };
}

fn isInterruptSignal(signal: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(signal, "int") or std.ascii.eqlIgnoreCase(signal, "sigint")) return true;
    const number = std.fmt.parseInt(u32, signal, 10) catch return false;
    return number == sigint;
}

pub const PaneExit = union(enum) {
    clean,
    interrupted,
    failed: u32,
    killed,
};

pub const Uptime = union(enum) {
    not_running,
    unknown,
    seconds: i64,
};

pub const ComposeState = enum {
    unavailable,
    empty,
    running,
};

pub const ComposeObservation = struct {
    state: ComposeState,
    services: []const []const u8 = &.{},

    pub fn empty(state: ComposeState) ComposeObservation {
        return .{ .state = state };
    }

    /// Takes ownership of the passed slice and its elements; the returned value
    /// frees them on deinit. Do not deinit or reuse the original.
    pub fn fromOwned(state: ComposeState, services: []const []const u8) ComposeObservation {
        return .{
            .state = state,
            .services = services,
        };
    }

    pub fn deinit(self: ComposeObservation, gpa: std.mem.Allocator) void {
        for (self.services) |service| gpa.free(service);
        gpa.free(self.services);
    }

    pub fn contains(self: ComposeObservation, name: []const u8) bool {
        for (self.services) |service| {
            if (std.mem.eql(u8, service, name)) return true;
        }
        return false;
    }
};

pub const ProbeObservation = enum {
    not_configured,
    not_observed,
    passed,
    failed,
    unavailable,
};

pub const HealthObservation = enum {
    not_running,
    no_check,
    waiting,
    ready,
    degraded,
    unavailable,
};

pub const ServiceObservation = struct {
    pane: PaneObservation,
    port: ?i64,
    listen: ProbeObservation,
    http: ProbeObservation,
    observed_at: i64,

    pub fn deinit(self: ServiceObservation, gpa: std.mem.Allocator) void {
        self.pane.deinit(gpa);
    }

    pub fn health(self: ServiceObservation) HealthObservation {
        return serviceHealth(self.pane.state, self.listen, self.http);
    }

    pub fn uptime(self: ServiceObservation) Uptime {
        return self.pane.uptime(self.observed_at);
    }
};

pub const DockerObservation = struct {
    pane: PaneObservation,
    compose: ComposeObservation,
    observed_at: i64,

    pub fn deinit(self: DockerObservation, gpa: std.mem.Allocator) void {
        self.pane.deinit(gpa);
        self.compose.deinit(gpa);
    }

    pub fn uptime(self: DockerObservation) Uptime {
        return self.pane.uptime(self.observed_at);
    }
};

fn serviceHealth(pane: PaneState, listen: ProbeObservation, http: ProbeObservation) HealthObservation {
    return switch (pane) {
        .idle, .dead, .window_missing => .not_running,
        .tmux_unavailable => .unavailable,
        .busy => switch (listen) {
            .not_configured => .no_check,
            .failed => .waiting,
            .not_observed, .unavailable => .unavailable,
            .passed => switch (http) {
                .not_configured, .passed => .ready,
                .failed => .degraded,
                .not_observed, .unavailable => .unavailable,
            },
        },
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "observations.compose: reports contained services" {
    const services = try std.testing.allocator.alloc([]const u8, 2);
    services[0] = try std.testing.allocator.dupe(u8, "api");
    services[1] = try std.testing.allocator.dupe(u8, "db");
    const observation = ComposeObservation.fromOwned(.running, services);
    defer observation.deinit(std.testing.allocator);

    try std.testing.expect(observation.contains("api"));
    try std.testing.expect(!observation.contains("web"));
}

test "observations.compose.deinit: no-op for empty default services" {
    const observation = ComposeObservation.empty(.empty);
    observation.deinit(std.testing.allocator);
}

test "observations.docker.deinit: no-op for empty default fields" {
    const observation: DockerObservation = .{
        .pane = PaneObservation.empty(.window_missing),
        .compose = ComposeObservation.empty(.empty),
        .observed_at = 0,
    };
    observation.deinit(std.testing.allocator);
}

test "observations.pane.deinit: no-op for empty default fields" {
    const observation = PaneObservation.empty(.window_missing);
    observation.deinit(std.testing.allocator);
}

test "observations.pane.deinit: frees exit_code pid and command" {
    const exit_code = try std.testing.allocator.dupe(u8, "130");
    const pid = try std.testing.allocator.dupe(u8, "12345");
    const command = try std.testing.allocator.dupe(u8, "node");
    const observation = PaneObservation.fromOwned(.dead, exit_code, pid, command, null);
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(PaneState.dead, observation.state);
    try std.testing.expectEqualStrings("130", observation.exit_code);
    try std.testing.expectEqualStrings("12345", observation.pid);
    try std.testing.expectEqualStrings("node", observation.command);
}

test "observations.serviceHealth: maps pane state and probes to health" {
    const cases = [_]struct {
        pane: PaneState,
        listen: ProbeObservation,
        http: ProbeObservation,
        expected: HealthObservation,
    }{
        .{ .pane = .idle, .listen = .not_observed, .http = .not_observed, .expected = .not_running },
        .{ .pane = .dead, .listen = .not_observed, .http = .not_configured, .expected = .not_running },
        .{ .pane = .window_missing, .listen = .not_configured, .http = .not_configured, .expected = .not_running },
        .{ .pane = .tmux_unavailable, .listen = .not_observed, .http = .not_observed, .expected = .unavailable },
        .{ .pane = .busy, .listen = .not_configured, .http = .not_configured, .expected = .no_check },
        .{ .pane = .busy, .listen = .failed, .http = .not_observed, .expected = .waiting },
        .{ .pane = .busy, .listen = .unavailable, .http = .not_observed, .expected = .unavailable },
        .{ .pane = .busy, .listen = .not_observed, .http = .not_observed, .expected = .unavailable },
        .{ .pane = .busy, .listen = .passed, .http = .not_configured, .expected = .ready },
        .{ .pane = .busy, .listen = .passed, .http = .passed, .expected = .ready },
        .{ .pane = .busy, .listen = .passed, .http = .failed, .expected = .degraded },
        .{ .pane = .busy, .listen = .passed, .http = .unavailable, .expected = .unavailable },
        .{ .pane = .busy, .listen = .passed, .http = .not_observed, .expected = .unavailable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, serviceHealth(case.pane, case.listen, case.http));
    }
}

test "observations.paneExit: maps dead status and signal to exit kind" {
    const cases = [_]struct {
        status: []const u8,
        signal: []const u8 = "",
        want: PaneExit,
    }{
        .{ .status = "0", .want = .clean },
        .{ .status = "1", .want = .{ .failed = 1 } },
        .{ .status = "130", .want = .{ .failed = 130 } },
        .{ .status = "137", .want = .{ .failed = 137 } },
        .{ .status = "", .signal = "int", .want = .interrupted },
        .{ .status = "", .signal = "2", .want = .interrupted },
        .{ .status = "", .signal = "15", .want = .killed },
        .{ .status = "", .signal = "term", .want = .killed },
        .{ .status = "", .want = .killed },
        .{ .status = "x", .want = .killed },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.want, paneExit(case.status, case.signal));
    }
}

test "observations.pane.processId: parses pid or reports null" {
    const parsed: PaneObservation = .{ .state = .dead, .pid = "4242" };
    const missing: PaneObservation = .{ .state = .dead, .pid = "" };

    try std.testing.expectEqual(@as(?i64, 4242), parsed.processId());
    try std.testing.expectEqual(@as(?i64, null), missing.processId());
}

test "observations.pane.uptime: maps state and start marker to uptime" {
    const cases = [_]struct {
        state: PaneState,
        started_at: ?i64,
        expected: Uptime,
    }{
        .{ .state = .busy, .started_at = 1_000, .expected = .{ .seconds = 90 } },
        .{ .state = .busy, .started_at = 1_090, .expected = .{ .seconds = 0 } },
        .{ .state = .busy, .started_at = null, .expected = .unknown },
        .{ .state = .busy, .started_at = 2_000, .expected = .unknown },
        .{ .state = .idle, .started_at = 1_000, .expected = .not_running },
        .{ .state = .dead, .started_at = 1_000, .expected = .not_running },
        .{ .state = .window_missing, .started_at = null, .expected = .not_running },
        .{ .state = .tmux_unavailable, .started_at = null, .expected = .unknown },
    };

    for (cases) |case| {
        const pane: PaneObservation = .{ .state = case.state, .started_at = case.started_at };
        try std.testing.expectEqual(case.expected, pane.uptime(1_090));
    }
}

test "observations.service.uptime: measures from the observation time" {
    const observation: ServiceObservation = .{
        .pane = .{ .state = .busy, .started_at = 100 },
        .port = null,
        .listen = .not_configured,
        .http = .not_configured,
        .observed_at = 160,
    };

    try std.testing.expectEqual(Uptime{ .seconds = 60 }, observation.uptime());
}
