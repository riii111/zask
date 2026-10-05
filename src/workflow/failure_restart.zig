//! Restarts services that exit abnormally. Runs in the `zask-watch` loop next
//! to file watch, so recovery keeps going after the monitor closes or the
//! client detaches and ends when `close` kills the session. Restarts use the
//! same lifecycle start as `zask start`, under the service lock and the stop
//! record shared with file watch. Each step is also left on the service pane
//! as a recovery record for the monitor, and giving up is noted in the
//! service log.

const std = @import("std");
const config = @import("../model/config.zig");
const lifecycle = @import("lifecycle.zig");
const observations = @import("../model/observations.zig");
const recovery = @import("../model/recovery.zig");

/// A failure this long after the last restart was not a crash loop, so it
/// starts the retry count over.
pub const stable_run_seconds: i64 = 30;

/// What the service pane shows, combined with the stop record.
pub const Observed = enum {
    running,
    /// `zask stop`, `zask close`, or Ctrl-C in the window.
    stopped,
    window_closed,
    exited_cleanly,
    failed,
    stop_mark_unavailable,
    tmux_unavailable,
};

/// The wrapper turns Ctrl-C into an idle shell, so a dead pane exited on its
/// own, unless the service replaced the wrapper with `exec` and died from
/// Ctrl-C. A stop record wins over the exit status because `zask stop` may
/// race the exit it caused.
pub fn observed(state: observations.PaneState, exit: observations.PaneExit, mark: observations.StopMarkObservation) Observed {
    return switch (state) {
        .busy => .running,
        .idle => .stopped,
        .window_missing => .window_closed,
        .tmux_unavailable => .tmux_unavailable,
        .dead => switch (mark) {
            .stopped => .stopped,
            .unavailable => .stop_mark_unavailable,
            .not_stopped => switch (exit) {
                .clean => .exited_cleanly,
                .interrupted => .stopped,
                .failed, .killed => .failed,
            },
        },
    };
}

/// One observation of a service pane, already reduced to what recovery needs.
pub const Run = struct {
    state: observations.PaneState,
    /// Meaningful only for dead panes.
    exit: observations.PaneExit = .clean,
    /// Tells one run of the pane from the next.
    pid: ?i64 = null,
};

pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    services: std.ArrayList(Service),

    /// A failure waiting `delay_ms` before its restart.
    const Pending = struct {
        pid: ?i64,
        failed_at_ns: i96,
    };

    const Service = struct {
        name: []const u8,
        policy: config.RestartOnFailure,
        /// Restarts made for the current series of failures.
        restarts: u32 = 0,
        /// Pid the pane had right after this supervisor's last restart: the new
        /// run, or the failed one when the restart did not start anything. A
        /// failure of any other run (a manual or file-change start) starts the
        /// count over.
        restarted_pid: ?i64 = null,
        /// Unix seconds of the last restart; the series ends once a failure
        /// comes `stable_run_seconds` after it.
        restarted_at: i64 = 0,
        pending: ?Pending = null,
        /// Pid of the dead run already reported as final (clean exit, retries
        /// used up), so a pane that stays dead is reported once.
        reported_pid: ?i64 = null,
    };

    /// Supervises every service with `restart_on_failure`. Call `deinit` on
    /// the result. `cfg` must outlive the supervisor; names borrow from it.
    pub fn init(gpa: std.mem.Allocator, cfg: config.Config) !Supervisor {
        var self: Supervisor = .{ .gpa = gpa, .services = .empty };
        errdefer self.deinit();
        for (try cfg.services()) |service| {
            const policy = (try config.Config.serviceRestartOnFailure(service)) orelse continue;
            try self.services.append(gpa, .{ .name = try config.Config.serviceName(service), .policy = policy });
        }
        return self;
    }

    pub fn deinit(self: *Supervisor) void {
        self.services.deinit(self.gpa);
    }

    pub fn isEmpty(self: Supervisor) bool {
        return self.services.items.len == 0;
    }

    pub fn writeSupervised(self: Supervisor, writer: *std.Io.Writer) !void {
        for (self.services.items) |service| {
            try writer.print("Restarting {s} on failure: up to {d} times, {f} apart\n", .{ service.name, service.policy.max_retries, DelayText{ .ms = service.policy.delay_ms } });
        }
        try writer.flush();
    }

    /// Observes every supervised service once and restarts those whose
    /// failure has waited `delay_ms`. `ctx` provides `now() i96` (monotonic
    /// ns), `nowSeconds() i64` (Unix seconds), `observeRun(name) Run`,
    /// `stopMark(name)`, `recover(name, notice, record, writer) !StartOutcome`,
    /// `recordRecovery(name, ?recovery.Record) !void` (null clears), and
    /// `noteInLog(name, text) !void`. Restart failures are reported and count
    /// as attempts; a restart that finds the service already started or
    /// stopped by someone else does not. A record or note that cannot be
    /// written is reported and does not stop recovery.
    pub fn tick(self: *Supervisor, ctx: anytype, writer: *std.Io.Writer) !void {
        for (self.services.items) |*service| {
            try self.check(service, ctx, writer);
            try writer.flush();
        }
    }

    fn check(self: *Supervisor, service: *Service, ctx: anytype, writer: *std.Io.Writer) !void {
        const run: Run = ctx.observeRun(service.name);
        const mark: observations.StopMarkObservation = if (run.state == .dead) ctx.stopMark(service.name) else .not_stopped;
        switch (observed(run.state, run.exit, mark)) {
            .running, .tmux_unavailable => service.pending = null,
            .stopped => if (service.pending != null) {
                service.pending = null;
                try writer.print("  {s} was stopped; not restarting\n", .{service.name});
                try recordOnPane(service.name, null, ctx, writer);
            },
            .window_closed => if (service.pending != null) {
                service.pending = null;
                try writer.print("  {s} window is closed; not restarting\n", .{service.name});
            },
            .exited_cleanly => if (!reported(service, run.pid)) {
                service.reported_pid = run.pid;
                try writer.print("{s} exited with status 0; not restarting\n", .{service.name});
            },
            .stop_mark_unavailable => if (!reported(service, run.pid)) {
                service.reported_pid = run.pid;
                service.pending = null;
                try writer.print("Warning: cannot read whether {s} was stopped; not restarting\n", .{service.name});
                try recordOnPane(service.name, .{ .kind = .unconfirmed, .pid = run.pid, .attempt = service.restarts, .max_retries = service.policy.max_retries, .exit = run.exit }, ctx, writer);
            },
            .failed => try self.handleFailure(service, run, ctx, writer),
        }
    }

    fn handleFailure(self: *Supervisor, service: *Service, run: Run, ctx: anytype, writer: *std.Io.Writer) !void {
        if (reported(service, run.pid)) return;
        const now_ns = ctx.now();
        // Another run (a manual or file-change start) failed before this tick
        // saw it running; it gets its own delay and series.
        if (service.pending) |pending| {
            if (pending.pid != run.pid) service.pending = null;
        }
        const failed_at = if (service.pending) |pending| pending.failed_at_ns else first: {
            if (!continuesSeries(service.*, run.pid, ctx.nowSeconds())) service.restarts = 0;
            const exit_text: recovery.ExitText = .{ .exit = run.exit };
            if (service.restarts >= service.policy.max_retries) {
                service.reported_pid = run.pid;
                try writer.print("{s} {f} after {d} restarts in a row; not restarting. Fix it and start it again.\n", .{ service.name, exit_text, service.restarts });
                try recordOnPane(service.name, .{ .kind = .gave_up, .pid = run.pid, .attempt = service.restarts, .max_retries = service.policy.max_retries, .exit = run.exit }, ctx, writer);
                const note = try std.fmt.allocPrint(self.gpa, "zask: {s} {f} after {d} restarts in a row; not restarting it", .{ service.name, exit_text, service.restarts });
                defer self.gpa.free(note);
                ctx.noteInLog(service.name, note) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => try writer.print("  Warning: could not note this in the {s} log: {s}\n", .{ service.name, @errorName(err) }),
                };
                return;
            }
            try writer.print("{s} {f}; restarting in {f} ({d}/{d})\n", .{ service.name, exit_text, DelayText{ .ms = service.policy.delay_ms }, service.restarts + 1, service.policy.max_retries });
            try recordOnPane(service.name, .{ .kind = .waiting, .pid = run.pid, .attempt = service.restarts + 1, .max_retries = service.policy.max_retries, .exit = run.exit }, ctx, writer);
            service.pending = .{ .pid = run.pid, .failed_at_ns = now_ns };
            break :first now_ns;
        };
        if (now_ns - failed_at < @as(i96, service.policy.delay_ms) * std.time.ns_per_ms) return;

        service.pending = null;
        const attempt = service.restarts + 1;
        const notice = try std.fmt.allocPrint(self.gpa, "zask: restarting {s} after it {f} ({d}/{d})", .{ service.name, recovery.ExitText{ .exit = run.exit }, attempt, service.policy.max_retries });
        defer self.gpa.free(notice);
        const record: recovery.Record = .{ .kind = .restarted, .attempt = attempt, .max_retries = service.policy.max_retries, .exit = run.exit };
        const outcome: lifecycle.StartOutcome = ctx.recover(service.name, notice, record, writer) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => failed: {
                try writer.print("  Warning: could not restart {s}: {s}\n", .{ service.name, @errorName(err) });
                break :failed .started;
            },
        };
        // Someone else started or stopped the service under the lock first;
        // that run is not part of this series.
        if (outcome == .skipped) return;
        service.restarts = attempt;
        service.restarted_at = ctx.nowSeconds();
        service.restarted_pid = ctx.observeRun(service.name).pid;
    }
};

/// A failure continues the series when the pane still holds the run this
/// supervisor left there and it failed within `stable_run_seconds` of that
/// restart. Measuring from the restart rather than the run start keeps a
/// restart that started nothing in the series. An unknown pid counts as the
/// same run, so the limit still holds.
fn continuesSeries(service: Supervisor.Service, pid: ?i64, now_seconds: i64) bool {
    if (pid != null and service.restarted_pid != pid) return false;
    return now_seconds - service.restarted_at < stable_run_seconds;
}

fn reported(service: *const Supervisor.Service, pid: ?i64) bool {
    return pid != null and service.reported_pid == pid;
}

fn recordOnPane(name: []const u8, record: ?recovery.Record, ctx: anytype, writer: *std.Io.Writer) !void {
    ctx.recordRecovery(name, record) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => try writer.print("  Warning: the monitor cannot show recovery of {s}: {s}\n", .{ name, @errorName(err) }),
    };
}

const DelayText = struct {
    ms: u64,

    pub fn format(self: DelayText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ms % std.time.ms_per_s == 0) return writer.print("{d}s", .{self.ms / std.time.ms_per_s});
        try writer.print("{d}ms", .{self.ms});
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestContext = struct {
    now_ns: i96 = 0,
    now_s: i64 = 1_000,
    run: Run = .{ .state = .busy, .pid = 100 },
    mark: observations.StopMarkObservation = .not_stopped,
    fail_recover: bool = false,
    /// A manual start that wins the service lock before the next recovery.
    started_elsewhere: ?i64 = null,
    next_pid: i64 = 200,
    recovers: std.ArrayList([]const u8) = .empty,
    /// The record each recovery start left on the pane.
    recovered_records: std.ArrayList(?recovery.Record) = .empty,
    /// The record on the pane; recordRecovery and recover replace it.
    record: ?recovery.Record = null,
    fail_record: bool = false,
    notes: std.ArrayList([]const u8) = .empty,
    fail_note: bool = false,

    fn deinit(self: *TestContext) void {
        for (self.recovers.items) |notice| std.testing.allocator.free(notice);
        self.recovers.deinit(std.testing.allocator);
        self.recovered_records.deinit(std.testing.allocator);
        for (self.notes.items) |note| std.testing.allocator.free(note);
        self.notes.deinit(std.testing.allocator);
    }

    pub fn now(self: *TestContext) i96 {
        return self.now_ns;
    }

    pub fn nowSeconds(self: *TestContext) i64 {
        return self.now_s;
    }

    pub fn observeRun(self: *TestContext, name: []const u8) Run {
        _ = name;
        return self.run;
    }

    pub fn stopMark(self: *TestContext, name: []const u8) observations.StopMarkObservation {
        _ = name;
        return self.mark;
    }

    pub fn recover(self: *TestContext, name: []const u8, notice: []const u8, record: ?recovery.Record, writer: *std.Io.Writer) !lifecycle.StartOutcome {
        _ = name;
        _ = writer;
        if (self.fail_recover) return error.CommandFailed;
        if (self.started_elsewhere) |pid| {
            self.started_elsewhere = null;
            self.run = .{ .state = .busy, .pid = pid };
            self.record = null;
            return .skipped;
        }
        try self.recovers.append(std.testing.allocator, try std.testing.allocator.dupe(u8, notice));
        try self.recovered_records.append(std.testing.allocator, record);
        self.record = record;
        self.run = .{ .state = .busy, .pid = self.next_pid };
        self.next_pid += 1;
        return .started;
    }

    pub fn recordRecovery(self: *TestContext, name: []const u8, record: ?recovery.Record) error{ CommandFailed, OutOfMemory }!void {
        _ = name;
        if (self.fail_record) return error.CommandFailed;
        self.record = record;
    }

    pub fn noteInLog(self: *TestContext, name: []const u8, text: []const u8) !void {
        _ = name;
        if (self.fail_note) return error.AccessDenied;
        try self.notes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, text));
    }

    /// The current run dies `after_s` seconds from now.
    fn crash(self: *TestContext, after_s: i64, exit: observations.PaneExit) void {
        self.now_s += after_s;
        self.run.state = .dead;
        self.run.exit = exit;
    }
};

const TestSupervisor = struct {
    arena: std.heap.ArenaAllocator,
    supervisor: Supervisor,
    output: std.Io.Writer.Allocating,

    fn init(services_json: []const u8) !TestSupervisor {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"project":{{"name":"demo","root":"/tmp/demo"}},"groups":[{{"name":"be","services":{s}}}]}}
        , .{services_json});
        const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
        return .{
            .arena = arena,
            .supervisor = try Supervisor.init(std.testing.allocator, cfg),
            .output = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *TestSupervisor) void {
        self.output.deinit();
        self.supervisor.deinit();
        self.arena.deinit();
    }

    fn tick(self: *TestSupervisor, ctx: *TestContext) !void {
        try self.supervisor.tick(ctx, &self.output.writer);
    }

    fn written(self: *TestSupervisor) []const u8 {
        return self.output.written();
    }
};

fn testApi(delay_ms: u64, max_retries: u32) !TestSupervisor {
    var buffer: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&buffer,
        \\[{{"name":"api","command":"serve","restart_on_failure":{{"max_retries":{d},"delay_ms":{d}}}}}]
    , .{ max_retries, delay_ms });
    return TestSupervisor.init(json);
}

test "failure_restart.observed: maps pane state, exit, and stop mark" {
    const cases = [_]struct {
        state: observations.PaneState,
        exit: observations.PaneExit = .{ .failed = 1 },
        mark: observations.StopMarkObservation = .not_stopped,
        want: Observed,
    }{
        .{ .state = .busy, .want = .running },
        .{ .state = .idle, .want = .stopped },
        .{ .state = .window_missing, .want = .window_closed },
        .{ .state = .tmux_unavailable, .want = .tmux_unavailable },
        .{ .state = .dead, .want = .failed },
        .{ .state = .dead, .exit = .killed, .want = .failed },
        .{ .state = .dead, .exit = .clean, .want = .exited_cleanly },
        .{ .state = .dead, .exit = .interrupted, .want = .stopped },
        .{ .state = .dead, .mark = .stopped, .want = .stopped },
        .{ .state = .dead, .exit = .clean, .mark = .stopped, .want = .stopped },
        .{ .state = .dead, .mark = .unavailable, .want = .stop_mark_unavailable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.want, observed(case.state, case.exit, case.mark));
    }
}

test "failure_restart.Supervisor: skips services without the setting" {
    var project = try TestSupervisor.init(
        \\[{"name":"api","command":"serve","restart_on_failure":{}},{"name":"web","command":"dev"}]
    );
    defer project.deinit();

    try std.testing.expectEqual(@as(usize, 1), project.supervisor.services.items.len);
    try std.testing.expectEqualStrings("api", project.supervisor.services.items[0].name);
}

test "failure_restart.tick: restarts a failed service after the delay" {
    var project = try testApi(1000, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(60, .{ .failed = 1 });

    try project.tick(&ctx);
    const before_delay = ctx.recovers.items.len;
    ctx.now_ns += 999 * std.time.ns_per_ms;
    try project.tick(&ctx);
    const just_before = ctx.recovers.items.len;
    ctx.now_ns += 1 * std.time.ns_per_ms;
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 0), before_delay);
    try std.testing.expectEqual(@as(usize, 0), just_before);
    try std.testing.expectEqual(@as(usize, 1), ctx.recovers.items.len);
    try std.testing.expectEqualStrings("zask: restarting api after it exited with status 1 (1/3)", ctx.recovers.items[0]);
    try std.testing.expectEqualStrings("api exited with status 1; restarting in 1s (1/3)\n", project.written());
}

test "failure_restart.tick: gives up after max_retries quick failures in a row" {
    var project = try testApi(0, 2);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();

    for (0..4) |_| {
        ctx.crash(1, .killed);
        try project.tick(&ctx);
    }
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.recovers.items.len);
    try std.testing.expectEqualStrings("zask: restarting api after it was killed (2/2)", ctx.recovers.items[1]);
    try std.testing.expect(std.mem.endsWith(u8, project.written(), "api was killed after 2 restarts in a row; not restarting. Fix it and start it again.\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, project.written(), "not restarting"));
}

test "failure_restart.tick: a long run starts the retry count over" {
    var project = try testApi(0, 1);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);

    ctx.crash(stable_run_seconds, .{ .failed = 1 });
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.recovers.items.len);
}

test "failure_restart.tick: a start by someone else starts the retry count over" {
    var project = try testApi(0, 1);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);
    const given_up = ctx.recovers.items.len;

    ctx.run = .{ .state = .busy, .pid = 900 };
    try project.tick(&ctx);
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 1), given_up);
    try std.testing.expectEqual(@as(usize, 2), ctx.recovers.items.len);
}

test "failure_restart.tick: leaves a clean exit stopped and reports it once" {
    var project = try testApi(0, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .clean);

    try project.tick(&ctx);
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.recovers.items.len);
    try std.testing.expectEqualStrings("api exited with status 0; not restarting\n", project.written());
}

test "failure_restart.tick: a stop during the delay cancels the restart" {
    var project = try testApi(1000, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 2 });
    try project.tick(&ctx);

    ctx.mark = .stopped;
    ctx.now_ns += 2 * std.time.ns_per_s;
    try project.tick(&ctx);
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 0), ctx.recovers.items.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, project.written(), "api was stopped; not restarting"));
}

test "failure_restart.tick: does not restart stopped, missing, or unreadable services" {
    const cases = [_]struct {
        state: observations.PaneState,
        mark: observations.StopMarkObservation = .not_stopped,
    }{
        .{ .state = .idle },
        .{ .state = .window_missing },
        .{ .state = .tmux_unavailable },
        .{ .state = .dead, .mark = .stopped },
        .{ .state = .dead, .mark = .unavailable },
    };

    for (cases) |case| {
        var project = try testApi(0, 3);
        defer project.deinit();
        var ctx: TestContext = .{ .mark = case.mark };
        defer ctx.deinit();
        ctx.run.state = case.state;

        try project.tick(&ctx);
        try project.tick(&ctx);

        try std.testing.expectEqual(@as(usize, 0), ctx.recovers.items.len);
    }
}

test "failure_restart.tick: a failed restart counts toward the limit" {
    var project = try testApi(0, 2);
    defer project.deinit();
    var ctx: TestContext = .{ .fail_recover = true };
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });

    for (0..4) |_| try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, project.written(), "Warning: could not restart api: CommandFailed"));
    try std.testing.expect(std.mem.endsWith(u8, project.written(), "after 2 restarts in a row; not restarting. Fix it and start it again.\n"));
}

test "failure_restart.tick: failed restarts after a long run still hit the limit" {
    var project = try testApi(0, 2);
    defer project.deinit();
    var ctx: TestContext = .{ .fail_recover = true };
    defer ctx.deinit();
    ctx.crash(stable_run_seconds * 10, .{ .failed = 1 });

    for (0..6) |_| {
        ctx.now_s += 1;
        try project.tick(&ctx);
    }

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, project.written(), "Warning: could not restart api"));
    try std.testing.expect(std.mem.endsWith(u8, project.written(), "after 2 restarts in a row; not restarting. Fix it and start it again.\n"));
}

test "failure_restart.tick: another run failing during the delay waits its own delay" {
    var project = try testApi(1000, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);

    ctx.now_ns += 900 * std.time.ns_per_ms;
    ctx.run = .{ .state = .dead, .exit = .{ .failed = 2 }, .pid = 900 };
    try project.tick(&ctx);
    ctx.now_ns += 900 * std.time.ns_per_ms;
    try project.tick(&ctx);
    const before_own_delay = ctx.recovers.items.len;
    ctx.now_ns += 100 * std.time.ns_per_ms;
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 0), before_own_delay);
    try std.testing.expectEqual(@as(usize, 1), ctx.recovers.items.len);
    try std.testing.expectEqualStrings("zask: restarting api after it exited with status 2 (1/3)", ctx.recovers.items[0]);
}

test "failure_restart.tick: a manual start winning the lock gets a fresh series" {
    var project = try testApi(0, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);
    ctx.crash(1, .{ .failed = 1 });

    ctx.started_elsewhere = 900;
    try project.tick(&ctx);
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 2), ctx.recovers.items.len);
    try std.testing.expectEqualStrings("zask: restarting api after it exited with status 1 (1/3)", ctx.recovers.items[1]);
}

test "failure_restart.tick: records the wait and the restart for the monitor" {
    var project = try testApi(1000, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(60, .{ .failed = 1 });

    try project.tick(&ctx);
    const waiting = ctx.record;
    ctx.now_ns += 1000 * std.time.ns_per_ms;
    try project.tick(&ctx);

    try std.testing.expectEqualDeep(@as(?recovery.Record, .{ .kind = .waiting, .pid = 100, .attempt = 1, .max_retries = 3, .exit = .{ .failed = 1 } }), waiting);
    try std.testing.expectEqualDeep(@as(?recovery.Record, .{ .kind = .restarted, .attempt = 1, .max_retries = 3, .exit = .{ .failed = 1 } }), ctx.recovered_records.items[0]);
}

test "failure_restart.tick: records and logs giving up at the limit" {
    var project = try testApi(0, 1);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);

    ctx.crash(1, .killed);
    try project.tick(&ctx);
    try project.tick(&ctx);

    try std.testing.expectEqualDeep(@as(?recovery.Record, .{ .kind = .gave_up, .pid = 200, .attempt = 1, .max_retries = 1, .exit = .killed }), ctx.record);
    try std.testing.expectEqual(@as(usize, 1), ctx.notes.items.len);
    try std.testing.expectEqualStrings("zask: api was killed after 1 restarts in a row; not restarting it", ctx.notes.items[0]);
}

test "failure_restart.tick: a stop during the delay clears the wait record" {
    var project = try testApi(1000, 3);
    defer project.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 2 });
    try project.tick(&ctx);
    const waiting = ctx.record;

    ctx.mark = .stopped;
    try project.tick(&ctx);

    try std.testing.expect(waiting != null);
    try std.testing.expectEqual(@as(?recovery.Record, null), ctx.record);
}

test "failure_restart.tick: records an unreadable stop as unconfirmed" {
    var project = try testApi(0, 3);
    defer project.deinit();
    var ctx: TestContext = .{ .mark = .unavailable };
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });

    try project.tick(&ctx);

    try std.testing.expectEqual(recovery.Kind.unconfirmed, ctx.record.?.kind);
    try std.testing.expectEqual(@as(?i64, 100), ctx.record.?.pid);
}

test "failure_restart.tick: keeps recovering when the record or note cannot be written" {
    var project = try testApi(0, 1);
    defer project.deinit();
    var ctx: TestContext = .{ .fail_record = true, .fail_note = true };
    defer ctx.deinit();
    ctx.crash(1, .{ .failed = 1 });
    try project.tick(&ctx);
    ctx.crash(1, .{ .failed = 1 });

    try project.tick(&ctx);

    try std.testing.expectEqual(@as(usize, 1), ctx.recovers.items.len);
    try std.testing.expect(std.mem.indexOf(u8, project.written(), "Warning: the monitor cannot show recovery of api: CommandFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, project.written(), "Warning: could not note this in the api log: AccessDenied") != null);
}

test "failure_restart.writeSupervised: lists policy per service" {
    var project = try TestSupervisor.init(
        \\[{"name":"api","command":"serve","restart_on_failure":{}},{"name":"job","command":"run","restart_on_failure":{"max_retries":5,"delay_ms":250}}]
    );
    defer project.deinit();

    try project.supervisor.writeSupervised(&project.output.writer);

    try std.testing.expectEqualStrings(
        \\Restarting api on failure: up to 3 times, 1s apart
        \\Restarting job on failure: up to 5 times, 250ms apart
        \\
    , project.written());
}
