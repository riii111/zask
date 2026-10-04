const std = @import("std");
const config = @import("../../model/config.zig");
const diagnostics = @import("../../model/diagnostics.zig");
const observations = @import("../../model/observations.zig");
const service_observation = @import("../../workflow/service_observation.zig");

/// Machine-readable contract of `status --json`. stdout carries exactly one
/// JSON document: `Status` with exit 0, or `ErrorDocument` with a non-zero
/// exit. Bump `schema_version` only for breaking changes; added fields keep it.
/// Tag names of the enums below are part of the contract, so they are mapped
/// from the observation model explicitly instead of reusing its tags.
pub const schema_version = 1;

pub const Status = struct {
    schema_version: u32 = schema_version,
    project: []const u8,
    session: Session,
    /// null when the config has no docker section.
    docker: ?Docker,
    services: []const Service,
};

/// tmux being unavailable is not a session state; it is reported as an error.
pub const Session = enum {
    active,
    missing,
};

pub const Service = struct {
    name: []const u8,
    group: []const u8,
    state: ProcessState,
    health: Health,
    /// Configured port; whether anything listens on it is `listen`.
    port: ?i64,
    listen: Probe,
    http: Probe,
    /// Set only for `exited`; null otherwise or when tmux gave no status.
    exit_code: ?i64,
    uptime: Uptime,
};

pub const Docker = struct {
    state: ProcessState,
    compose: Compose,
    exit_code: ?i64,
    uptime: Uptime,
};

pub const ProcessState = enum {
    running,
    stopped,
    exited,
    window_missing,
    session_missing,
    unavailable,
};

pub const Health = enum {
    not_running,
    no_check,
    waiting,
    ready,
    degraded,
    unavailable,
};

pub const Probe = enum {
    not_configured,
    not_observed,
    passed,
    failed,
    unavailable,
};

pub const Compose = enum {
    not_observed,
    running,
    empty,
    unavailable,
};

pub const Uptime = struct {
    state: UptimeState,
    /// Set only for `known`.
    seconds: ?i64,
};

pub const UptimeState = enum {
    known,
    unknown,
    not_running,
};

pub const ErrorDocument = struct {
    schema_version: u32 = schema_version,
    @"error": ErrorBody,
};

pub const ErrorBody = struct {
    code: []const u8,
    message: []const u8,
    /// Resolved config path once selection succeeded.
    config: ?[]const u8,
    diagnostics: []const DiagnosticEntry,
};

pub const DiagnosticEntry = struct {
    /// null for problems not tied to a config field.
    path: ?[]const u8,
    message: []const u8,
};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
    exit_code: u8,
};

pub const ErrorDetails = struct {
    config_path: ?[]const u8 = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
};

/// Observes the session and every configured service. Returns
/// error.TmuxUnavailable when tmux cannot answer whether the session exists.
/// Slices in the result are allocated with the observer's allocator or borrowed
/// from `cfg`; use an arena and keep `cfg` alive while the result is used.
pub fn collect(cfg: config.Config, observer: service_observation.Observer) !Status {
    const session: Session = switch (observer.tmux.observeSession()) {
        .active => .active,
        .missing => .missing,
        .unavailable => return error.TmuxUnavailable,
    };
    const configured = try cfg.services();
    const services = try observer.gpa.alloc(Service, configured.len);
    for (configured, services) |value, *service| {
        const observation = switch (session) {
            .active => try observer.observeService(value),
            .missing => observer.unprobedService(value, observations.PaneObservation.empty(.window_missing)),
        };
        defer observation.deinit(observer.gpa);
        service.* = try serviceEntry(value, observation, session);
    }
    return .{
        .project = try cfg.projectName(),
        .session = session,
        .docker = if (cfg.dockerEnabled()) dockerEntry(observer, session) else null,
        .services = services,
    };
}

pub fn writeStatus(writer: *std.Io.Writer, status: Status) !void {
    try writeDocument(writer, status);
}

/// Writes the error document and returns the failure it describes. Errors
/// without a stable code are reported as `unexpected`; the caller should
/// propagate those so the trace still reaches stderr.
pub fn writeError(gpa: std.mem.Allocator, writer: *std.Io.Writer, err: anyerror, details: ErrorDetails) !?Failure {
    const known = knownFailure(err);
    const entries = try gpa.alloc(DiagnosticEntry, details.diagnostics.len);
    defer gpa.free(entries);
    for (details.diagnostics, entries) |diagnostic, *entry| {
        entry.* = .{ .path = if (diagnostic.path.len == 0) null else diagnostic.path, .message = diagnostic.message };
    }
    try writeDocument(writer, ErrorDocument{ .@"error" = .{
        .code = if (known) |failure| failure.code else "unexpected",
        .message = if (known) |failure| failure.message else @errorName(err),
        .config = details.config_path,
        .diagnostics = entries,
    } });
    return known;
}

/// Stable codes for failures the CLI already reports; exit codes match the
/// text output (1 runtime/environment, 2 usage/config).
pub fn knownFailure(err: anyerror) ?Failure {
    return switch (err) {
        error.ConfigNotFound => .{ .code = "config_not_found", .message = "config not found", .exit_code = 2 },
        error.AmbiguousConfig => .{ .code = "ambiguous_config", .message = "multiple local config files found", .exit_code = 2 },
        error.InvalidConfigSyntax => .{ .code = "invalid_config_syntax", .message = "config is not valid JSON", .exit_code = 2 },
        error.InvalidConfig => .{ .code = "invalid_config", .message = "invalid config", .exit_code = 2 },
        error.ConfigTooLarge => .{ .code = "config_too_large", .message = "config file too large", .exit_code = 2 },
        error.TmuxUnavailable => .{ .code = "tmux_unavailable", .message = "tmux unavailable", .exit_code = 1 },
        error.OutputTooLarge => .{ .code = "output_too_large", .message = "command output too large", .exit_code = 1 },
        else => null,
    };
}

fn writeDocument(writer: *std.Io.Writer, document: anytype) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(document);
    try writer.writeByte('\n');
}

fn serviceEntry(value: std.json.Value, observation: observations.ServiceObservation, session: Session) !Service {
    return .{
        .name = try config.Config.serviceName(value),
        .group = config.Config.serviceGroup(value),
        .state = processState(observation.pane.state, session),
        .health = health(observation.health()),
        .port = observation.port,
        .listen = probe(observation.listen),
        .http = probe(observation.http),
        .exit_code = exitCode(observation.pane),
        .uptime = uptime(observation.uptime()),
    };
}

fn dockerEntry(observer: service_observation.Observer, session: Session) Docker {
    if (session == .missing) {
        return .{ .state = .session_missing, .compose = .not_observed, .exit_code = null, .uptime = uptime(.not_running) };
    }
    const observation = observer.observeDocker();
    defer observation.deinit(observer.gpa);
    return .{
        .state = processState(observation.pane.state, session),
        // The observer leaves compose `empty` without asking Docker when the
        // pane is not running; report that as not observed, not as empty.
        .compose = if (observation.pane.running()) compose(observation.compose.state) else .not_observed,
        .exit_code = exitCode(observation.pane),
        .uptime = uptime(observation.uptime()),
    };
}

fn processState(state: observations.PaneState, session: Session) ProcessState {
    if (session == .missing) return .session_missing;
    return switch (state) {
        .busy => .running,
        .idle => .stopped,
        .dead => .exited,
        .window_missing => .window_missing,
        .tmux_unavailable => .unavailable,
    };
}

fn health(value: observations.HealthObservation) Health {
    return switch (value) {
        .not_running => .not_running,
        .no_check => .no_check,
        .waiting => .waiting,
        .ready => .ready,
        .degraded => .degraded,
        .unavailable => .unavailable,
    };
}

fn probe(value: observations.ProbeObservation) Probe {
    return switch (value) {
        .not_configured => .not_configured,
        .not_observed => .not_observed,
        .passed => .passed,
        .failed => .failed,
        .unavailable => .unavailable,
    };
}

fn compose(state: observations.ComposeState) Compose {
    return switch (state) {
        .running => .running,
        .empty => .empty,
        .unavailable => .unavailable,
    };
}

fn uptime(value: observations.Uptime) Uptime {
    return switch (value) {
        .seconds => |seconds| .{ .state = .known, .seconds = seconds },
        .unknown => .{ .state = .unknown, .seconds = null },
        .not_running => .{ .state = .not_running, .seconds = null },
    };
}

fn exitCode(pane: observations.PaneObservation) ?i64 {
    if (pane.state != .dead) return null;
    return std.fmt.parseInt(i64, pane.exit_code, 10) catch null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const proc_runner = @import("../../platform/runner.zig");

const test_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "docker": {"compose":"compose.yaml"},
    \\  "groups": [{"name":"backend","services":[
    \\    {"name":"api","dir":"api","command":"serve","port":3000,"healthcheck":{"type":"http","path":"/ready"}},
    \\    {"name":"worker","dir":"worker","command":"work"},
    \\    {"name":"web","dir":"web","command":"dev","port":5173}
    \\  ]}]
    \\}
;

fn testObserver(gpa: std.mem.Allocator, recorder: *proc_runner.Recorder) service_observation.Observer {
    const run: proc_runner.Runner = .{ .gpa = gpa, .io = undefined, .recorder = recorder };
    recorder.now_seconds = 1_000;
    return .{
        .gpa = gpa,
        .runner = run,
        .tmux = .{ .gpa = gpa, .runner = run, .session = "demo" },
        .docker = .{ .gpa = gpa, .runner = run, .dir = "/tmp/demo", .file = "compose.yaml" },
    };
}

fn testRender(gpa: std.mem.Allocator, recorder: *proc_runner.Recorder, json: []const u8) ![]const u8 {
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    var out: std.Io.Writer.Allocating = .init(gpa);
    try writeStatus(&out.writer, try collect(cfg, testObserver(gpa, recorder)));
    return out.written();
}

test "status_json.collect: reports observed services and docker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("0||100|node|900\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("1|2|101|work|\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "can't find window: web", .{ .exited = 1 });
    try recorder.enqueue("0||103|docker|\n", "", .{ .exited = 0 });
    try recorder.enqueue("db\n", "", .{ .exited = 0 });

    const out = try testRender(arena.allocator(), &recorder, test_config);

    try std.testing.expectEqualStrings(
        \\{"schema_version":1,"project":"demo","session":"active","docker":{"state":"running","compose":"running","exit_code":null,"uptime":{"state":"unknown","seconds":null}},"services":[{"name":"api","group":"backend","state":"running","health":"ready","port":3000,"listen":"passed","http":"passed","exit_code":null,"uptime":{"state":"known","seconds":100}},{"name":"worker","group":"backend","state":"exited","health":"not_running","port":null,"listen":"not_configured","http":"not_configured","exit_code":2,"uptime":{"state":"not_running","seconds":null}},{"name":"web","group":"backend","state":"window_missing","health":"not_running","port":5173,"listen":"not_observed","http":"not_configured","exit_code":null,"uptime":{"state":"not_running","seconds":null}}]}
        \\
    , out);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "status_json.collect: reports configured services when session is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "can't find session: demo", .{ .exited = 1 });

    const out = try testRender(arena.allocator(), &recorder, test_config);

    try std.testing.expectEqualStrings(
        \\{"schema_version":1,"project":"demo","session":"missing","docker":{"state":"session_missing","compose":"not_observed","exit_code":null,"uptime":{"state":"not_running","seconds":null}},"services":[{"name":"api","group":"backend","state":"session_missing","health":"not_running","port":3000,"listen":"not_observed","http":"not_observed","exit_code":null,"uptime":{"state":"not_running","seconds":null}},{"name":"worker","group":"backend","state":"session_missing","health":"not_running","port":null,"listen":"not_configured","http":"not_configured","exit_code":null,"uptime":{"state":"not_running","seconds":null}},{"name":"web","group":"backend","state":"session_missing","health":"not_running","port":5173,"listen":"not_observed","http":"not_configured","exit_code":null,"uptime":{"state":"not_running","seconds":null}}]}
        \\
    , out);
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "status_json.collect: reports compose as not observed for a stopped docker pane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 0 });
    try recorder.enqueue("1|137|103|docker|900\n", "", .{ .exited = 0 });

    const out = try testRender(arena.allocator(), &recorder,
        \\{"project":{"name":"demo","root":"/tmp/demo"},"docker":{"compose":"compose.yaml"},"groups":[]}
    );

    try std.testing.expectEqualStrings(
        \\{"schema_version":1,"project":"demo","session":"active","docker":{"state":"exited","compose":"not_observed","exit_code":137,"uptime":{"state":"not_running","seconds":null}},"services":[]}
        \\
    , out);
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "status_json.collect: fails without output when tmux is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueueError(error.FileNotFound);
    const cfg = try config.Config.parse(arena.allocator(), test_config, "/home/me");

    try std.testing.expectError(error.TmuxUnavailable, collect(cfg, testObserver(arena.allocator(), &recorder)));

    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
}

test "status_json.writeError: renders config diagnostics" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const failure = try writeError(std.testing.allocator, &out.writer, error.InvalidConfig, .{
        .config_path = "/tmp/demo/zask.json",
        .diagnostics = &.{
            .{ .path = "groups[0].services[0].port", .message = "must be an integer" },
            .{ .path = "", .message = "no services" },
        },
    });

    try std.testing.expectEqual(@as(u8, 2), failure.?.exit_code);
    try std.testing.expectEqualStrings(
        \\{"schema_version":1,"error":{"code":"invalid_config","message":"invalid config","config":"/tmp/demo/zask.json","diagnostics":[{"path":"groups[0].services[0].port","message":"must be an integer"},{"path":null,"message":"no services"}]}}
        \\
    , out.written());
}

test "status_json.writeError: maps failures to codes and exit codes" {
    const cases = [_]struct {
        err: anyerror,
        code: []const u8,
        exit_code: ?u8,
    }{
        .{ .err = error.ConfigNotFound, .code = "config_not_found", .exit_code = 2 },
        .{ .err = error.AmbiguousConfig, .code = "ambiguous_config", .exit_code = 2 },
        .{ .err = error.InvalidConfigSyntax, .code = "invalid_config_syntax", .exit_code = 2 },
        .{ .err = error.ConfigTooLarge, .code = "config_too_large", .exit_code = 2 },
        .{ .err = error.TmuxUnavailable, .code = "tmux_unavailable", .exit_code = 1 },
        .{ .err = error.OutputTooLarge, .code = "output_too_large", .exit_code = 1 },
        .{ .err = error.HomeNotSet, .code = "unexpected", .exit_code = null },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{@errorName(case.err)});
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        const failure = try writeError(std.testing.allocator, &out.writer, case.err, .{});

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
        defer parsed.deinit();
        const body = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings(case.code, body.get("code").?.string);
        try std.testing.expect(body.get("config").? == .null);
        try std.testing.expectEqual(case.exit_code, if (failure) |known| known.exit_code else null);
    }
}
