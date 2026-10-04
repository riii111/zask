//! Restarts services when their watched files change. The `zask-watch` window
//! runs this loop for the life of the session, so it keeps going after the
//! monitor closes or the client detaches and ends when `close` kills the
//! session. Restarts use the same lifecycle steps as `zask restart`.

const std = @import("std");
const config = @import("../model/config.zig");
const observations = @import("../model/observations.zig");
const file_scan = @import("../platform/file_scan.zig");
const file_watch = @import("file_watch.zig");

pub const RestartDecision = enum {
    restart,
    skip_stopped,
    skip_missing,
    stop_mark_unavailable,
    tmux_unavailable,
};

/// A stop mark means the user ran `zask stop` (or `close`), possibly while the
/// process is still exiting and its pane looks busy. An idle pane means the
/// service was stopped (including Ctrl-C in the pane) or was not started by the
/// open profile. Neither may be started by a file change. A dead pane exited
/// on its own; restarting it lets a fix bring the service back.
pub fn restartDecision(state: observations.PaneState, mark: observations.StopMarkObservation) RestartDecision {
    switch (mark) {
        .not_stopped => {},
        .stopped => return .skip_stopped,
        .unavailable => return .stop_mark_unavailable,
    }
    return switch (state) {
        .busy, .dead => .restart,
        .idle => .skip_stopped,
        .window_missing => .skip_missing,
        .tmux_unavailable => .tmux_unavailable,
    };
}

/// A batch this long after a watch restart, beyond the debounce period, most
/// likely came from the restarted service writing into its own watched files
/// (logs, build output).
pub const loop_settle_ns: i96 = 3 * std.time.ns_per_s;
/// Restarts in a row, each starting within the loop window of the previous
/// one finishing, before restarts pause.
pub const loop_limit: u8 = 3;

/// Batches are reported only after `debounce_ms` without changes, so the loop
/// window must include it or a long debounce would hide every loop.
pub fn loopWindowNs(debounce_ms: u64) i96 {
    return loop_settle_ns + @as(i96, debounce_ms) * std.time.ns_per_ms;
}

/// Stops restart loops caused by a service changing its own watched files.
/// Restarts pause after `limit` quick restarts in a row and resume with the
/// first batch that follows `window_ns` without changes.
pub const LoopGuard = struct {
    window_ns: i96,
    limit: u8 = loop_limit,
    quick_restarts: u8 = 0,
    last_restart_ns: ?i96 = null,
    /// Time of the latest batch while paused; null when not paused.
    paused_batch_ns: ?i96 = null,

    pub const Verdict = enum {
        restart,
        /// Restarts pause from this batch on.
        pause,
        /// Restarts were already paused and changes have not stopped yet.
        paused,
    };

    pub fn check(self: *LoopGuard, now_ns: i96) Verdict {
        if (self.paused_batch_ns) |last| {
            self.paused_batch_ns = now_ns;
            if (now_ns - last < self.window_ns) return .paused;
            self.paused_batch_ns = null;
            // One more quick batch after resuming means the loop is back.
            self.quick_restarts = self.limit - 1;
            return .restart;
        }
        const quick = if (self.last_restart_ns) |last| now_ns - last < self.window_ns else false;
        if (!quick) {
            self.quick_restarts = 0;
            return .restart;
        }
        if (self.quick_restarts + 1 >= self.limit) {
            self.paused_batch_ns = now_ns;
            return .pause;
        }
        self.quick_restarts += 1;
        return .restart;
    }

    /// `now_ns` is taken after the restart finishes, so time spent stopping
    /// and starting does not count toward the loop window.
    pub fn restarted(self: *LoopGuard, now_ns: i96) void {
        self.last_restart_ns = now_ns;
    }
};

pub const Supervisor = struct {
    gpa: std.mem.Allocator,
    services: std.ArrayList(Service),

    const Service = struct {
        name: []const u8,
        watcher: file_watch.Watcher,
        guard: LoopGuard,
    };

    /// Watches every service with a `watch` setting. Call `deinit` on the
    /// result. `cfg` must outlive the supervisor; watchers borrow its strings.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !Supervisor {
        var self: Supervisor = .{ .gpa = gpa, .services = .empty };
        errdefer self.deinit();
        for (try cfg.services()) |service| {
            var watcher = (try file_watch.Watcher.init(gpa, io, cfg, service)) orelse continue;
            self.services.append(gpa, .{
                .name = try config.Config.serviceName(service),
                .watcher = watcher,
                .guard = .{ .window_ns = loopWindowNs(watcher.spec.debounce_ms) },
            }) catch |err| {
                watcher.deinit();
                return err;
            };
        }
        return self;
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.services.items) |*service| service.watcher.deinit();
        self.services.deinit(self.gpa);
    }

    pub fn isEmpty(self: Supervisor) bool {
        return self.services.items.len == 0;
    }

    pub fn writeWatching(self: Supervisor, writer: *std.Io.Writer) !void {
        for (self.services.items) |service| {
            try writer.print("Watching {s}:", .{service.name});
            for (service.watcher.spec.paths) |path| try writer.print(" {s}", .{path});
            try writer.writeByte('\n');
        }
        try writer.flush();
    }

    /// Polls every watcher once and restarts services whose changes are ready.
    /// `ctx` provides `now() i96` (monotonic ns), `paneState(name)`,
    /// `stopMark(name)`, and `restart(name, notice, writer)`. Restart failures
    /// are reported and watching continues.
    pub fn tick(self: *Supervisor, ctx: anytype, writer: *std.Io.Writer) !void {
        for (self.services.items) |*service| {
            const now_ns = ctx.now();
            const event = (try service.watcher.poll(now_ns)) orelse continue;
            switch (event) {
                .failed => |failure| try writeFailure(writer, service.name, failure),
                .changed => |changes| try self.handleChanges(service, changes, now_ns, ctx, writer),
            }
            try writer.flush();
        }
    }

    fn handleChanges(self: *Supervisor, service: *Service, changes: []const file_watch.Change, now_ns: i96, ctx: anytype, writer: *std.Io.Writer) !void {
        const summary: ChangeSummary = .{ .changes = changes };
        try writer.print("{s}: {f}\n", .{ service.name, summary });
        switch (restartDecision(ctx.paneState(service.name), ctx.stopMark(service.name))) {
            .restart => {},
            .skip_stopped => return writer.print("  {s} is stopped; not restarting\n", .{service.name}),
            .skip_missing => return writer.print("  {s} window is closed; not restarting\n", .{service.name}),
            .stop_mark_unavailable => return writer.print("  Warning: cannot read whether {s} was stopped; not restarting\n", .{service.name}),
            .tmux_unavailable => return writer.print("  Warning: tmux unavailable; not restarting {s}\n", .{service.name}),
        }
        switch (service.guard.check(now_ns)) {
            .restart => {},
            .pause => return writer.print(
                \\  Warning: {s} changed within {d}s of each of its last {d} restarts.
                \\  Restarts pause until changes stop for {d}s. Add files the service writes to watch.exclude.
                \\
            , .{ service.name, secondsText(service.guard.window_ns), service.guard.limit, secondsText(service.guard.window_ns) }),
            .paused => return writer.print("  restarts paused for {s}; files are still changing\n", .{service.name}),
        }
        const notice = try std.fmt.allocPrint(self.gpa, "zask: restarting {s} after file change: {f}", .{ service.name, summary });
        defer self.gpa.free(notice);
        ctx.restart(service.name, notice, writer) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try writer.print("  Warning: could not restart {s}: {s}\n", .{ service.name, @errorName(err) }),
        };
        service.guard.restarted(ctx.now());
    }
};

/// Formats a batch as its first change plus a count of the rest.
pub const ChangeSummary = struct {
    changes: []const file_watch.Change,

    pub fn format(self: ChangeSummary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.changes.len == 0) return;
        const first = self.changes[0];
        try writer.print("{s} {s}", .{ first.path, @tagName(first.kind) });
        if (self.changes.len > 1) try writer.print(" (+{d} more)", .{self.changes.len - 1});
    }
};

fn writeFailure(writer: *std.Io.Writer, service: []const u8, failure: file_scan.Failure) !void {
    try writer.print("Warning: cannot watch {s}: {s}: {s}\n", .{ service, failureText(failure.reason), failure.path });
    try writer.print("  Changes are ignored until the path can be scanned again.\n", .{});
}

fn failureText(reason: file_scan.FailureReason) []const u8 {
    return switch (reason) {
        .missing => "path not found",
        .access_denied => "permission denied",
        .too_many_files => "too many files; add exclude patterns",
        .io_error => "I/O error",
    };
}

/// Rounds up so the printed wait is never shorter than the real one.
fn secondsText(ns: i96) i96 {
    return @divFloor(ns + std.time.ns_per_s - 1, std.time.ns_per_s);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestContext = struct {
    now_ns: i96 = 0,
    restart_ns: i96 = 0,
    state: observations.PaneState = .busy,
    mark: observations.StopMarkObservation = .not_stopped,
    fail_restart: bool = false,
    restarts: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *TestContext) void {
        for (self.restarts.items) |notice| std.testing.allocator.free(notice);
        self.restarts.deinit(std.testing.allocator);
    }

    pub fn now(self: *TestContext) i96 {
        return self.now_ns;
    }

    pub fn paneState(self: *TestContext, name: []const u8) observations.PaneState {
        _ = name;
        return self.state;
    }

    pub fn stopMark(self: *TestContext, name: []const u8) observations.StopMarkObservation {
        _ = name;
        return self.mark;
    }

    pub fn restart(self: *TestContext, name: []const u8, notice: []const u8, writer: *std.Io.Writer) !void {
        _ = name;
        _ = writer;
        if (self.fail_restart) return error.CommandFailed;
        try self.restarts.append(std.testing.allocator, try std.testing.allocator.dupe(u8, notice));
        self.now_ns += self.restart_ns;
    }
};

const TestProject = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,

    fn init(services_json: []const u8) !TestProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"project":{{"name":"demo","root":"{s}"}},"groups":[{{"name":"be","services":{s}}}]}}
        , .{ root, services_json });
        const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
        return .{ .tmp = tmp, .arena = arena, .cfg = cfg };
    }

    fn deinit(self: *TestProject) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn write(self: TestProject, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }
};

fn testWatchedProject() !TestProject {
    var project = try TestProject.init(
        \\[{"name":"api","command":"serve","watch":{"debounce_ms":0,"exclude":["*.log"]}}]
    );
    errdefer project.deinit();
    try project.write("main.zig", "1");
    return project;
}

test "watch_restart.restartDecision: maps pane state and stop mark to restart decision" {
    const cases = [_]struct {
        state: observations.PaneState,
        mark: observations.StopMarkObservation = .not_stopped,
        want: RestartDecision,
    }{
        .{ .state = .busy, .want = .restart },
        .{ .state = .dead, .want = .restart },
        .{ .state = .idle, .want = .skip_stopped },
        .{ .state = .window_missing, .want = .skip_missing },
        .{ .state = .tmux_unavailable, .want = .tmux_unavailable },
        .{ .state = .busy, .mark = .stopped, .want = .skip_stopped },
        .{ .state = .dead, .mark = .stopped, .want = .skip_stopped },
        .{ .state = .busy, .mark = .unavailable, .want = .stop_mark_unavailable },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.want, restartDecision(case.state, case.mark));
    }
}

test "watch_restart.LoopGuard: restarts edits spaced past the loop window" {
    var guard: LoopGuard = .{ .window_ns = 100, .limit = 3 };

    for (0..5) |index| {
        const now: i96 = @intCast(index * 1000);
        try std.testing.expectEqual(LoopGuard.Verdict.restart, guard.check(now));
        guard.restarted(now + 10);
    }
}

test "watch_restart.LoopGuard: pauses after quick restarts in a row" {
    var guard: LoopGuard = .{ .window_ns = 100, .limit = 3 };

    try std.testing.expectEqual(LoopGuard.Verdict.restart, guard.check(0));
    guard.restarted(10);
    try std.testing.expectEqual(LoopGuard.Verdict.restart, guard.check(50));
    guard.restarted(60);
    try std.testing.expectEqual(LoopGuard.Verdict.restart, guard.check(100));
    guard.restarted(110);
    try std.testing.expectEqual(LoopGuard.Verdict.pause, guard.check(150));
    try std.testing.expectEqual(LoopGuard.Verdict.paused, guard.check(240));
}

test "watch_restart.LoopGuard: resumes after changes stop for the loop window" {
    var guard: LoopGuard = .{ .window_ns = 100, .limit = 2 };
    _ = guard.check(0);
    guard.restarted(10);
    _ = guard.check(50);
    guard.restarted(60);
    try std.testing.expectEqual(LoopGuard.Verdict.pause, guard.check(100));

    const resumed = guard.check(250);
    guard.restarted(260);
    const looped_again = guard.check(300);

    try std.testing.expectEqual(LoopGuard.Verdict.restart, resumed);
    try std.testing.expectEqual(LoopGuard.Verdict.pause, looped_again);
}

test "watch_restart.ChangeSummary: shows first change and remaining count" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.print("{f}|{f}", .{
        ChangeSummary{ .changes = &.{.{ .kind = .modified, .path = "src/a.zig" }} },
        ChangeSummary{ .changes = &.{ .{ .kind = .created, .path = "b" }, .{ .kind = .deleted, .path = "c" }, .{ .kind = .modified, .path = "d" } } },
    });

    try std.testing.expectEqualStrings("src/a.zig modified|b created (+2 more)", writer.buffered());
}

test "watch_restart.Supervisor: watches only services with watch settings" {
    var project = try TestProject.init(
        \\[{"name":"api","command":"serve","watch":{"paths":["src","lib"]}},{"name":"web","command":"dev"}]
    );
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try supervisor.writeWatching(&writer);

    try std.testing.expectEqualStrings("Watching api: src lib\n", writer.buffered());
}

test "watch_restart.Supervisor: restarts running service with change reason" {
    var project = try testWatchedProject();
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    try project.write("main.zig", "22");
    try project.write("app.log", "ignored");
    ctx.now_ns += 1;
    try supervisor.tick(&ctx, &writer);

    try std.testing.expectEqual(@as(usize, 1), ctx.restarts.items.len);
    try std.testing.expectEqualStrings("zask: restarting api after file change: main.zig modified", ctx.restarts.items[0]);
    try std.testing.expectEqualStrings("api: main.zig modified\n", writer.buffered());
}

test "watch_restart.Supervisor: leaves stopped service stopped" {
    var project = try testWatchedProject();
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{ .state = .idle };
    defer ctx.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    try project.write("main.zig", "22");
    ctx.now_ns += 1;
    try supervisor.tick(&ctx, &writer);

    try std.testing.expectEqual(@as(usize, 0), ctx.restarts.items.len);
    try std.testing.expectEqualStrings("api: main.zig modified\n  api is stopped; not restarting\n", writer.buffered());
}

test "watch_restart.Supervisor: leaves a stopping service stopped while its pane is busy" {
    var project = try testWatchedProject();
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{ .state = .busy, .mark = .stopped };
    defer ctx.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    try project.write("main.zig", "22");
    ctx.now_ns += 1;
    try supervisor.tick(&ctx, &writer);

    try std.testing.expectEqual(@as(usize, 0), ctx.restarts.items.len);
    try std.testing.expectEqualStrings("api: main.zig modified\n  api is stopped; not restarting\n", writer.buffered());
}

test "watch_restart.Supervisor: pauses restarts when the service keeps changing its files" {
    var project = try testWatchedProject();
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{ .restart_ns = 1000 };
    defer ctx.deinit();
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    const growing = "xxxxxxxxxx";
    for (0..loop_limit + 2) |index| {
        // A new size marks each write as a change even within one mtime tick.
        try project.write("main.zig", growing[0 .. index + 2]);
        ctx.now_ns += 1;
        try supervisor.tick(&ctx, &writer);
    }

    try std.testing.expectEqual(@as(usize, loop_limit), ctx.restarts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Restarts pause until changes stop for 3s.") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "restarts paused for api; files are still changing") != null);
}

test "watch_restart.Supervisor: keeps watching after a restart fails" {
    var project = try testWatchedProject();
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{ .fail_restart = true };
    defer ctx.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    try project.write("main.zig", "22");
    ctx.now_ns += 1;
    try supervisor.tick(&ctx, &writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "  Warning: could not restart api: CommandFailed\n") != null);
}

test "watch_restart.Supervisor: reports a missing watch path" {
    var project = try TestProject.init(
        \\[{"name":"api","command":"serve","watch":{"paths":["src"]}}]
    );
    defer project.deinit();
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{};
    defer ctx.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try supervisor.tick(&ctx, &writer);

    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Warning: cannot watch api: path not found: "));
    try std.testing.expectEqual(@as(usize, 0), ctx.restarts.items.len);
}

test "watch_restart.Supervisor: pauses restart loops behind a long debounce" {
    var project = try TestProject.init(
        \\[{"name":"api","command":"serve","watch":{"debounce_ms":3500}}]
    );
    defer project.deinit();
    try project.write("main.zig", "1");
    var supervisor = try Supervisor.init(std.testing.allocator, std.testing.io, project.cfg);
    defer supervisor.deinit();
    var ctx: TestContext = .{ .restart_ns = std.time.ns_per_s };
    defer ctx.deinit();
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try supervisor.tick(&ctx, &writer);

    const growing = "xxxxxxxxxx";
    for (0..loop_limit + 2) |index| {
        // The service rewrites its file right after each restart; the batch
        // is reported once the 3.5s debounce passes.
        try project.write("main.zig", growing[0 .. index + 2]);
        ctx.now_ns += std.time.ns_per_ms;
        try supervisor.tick(&ctx, &writer);
        ctx.now_ns += 3500 * std.time.ns_per_ms;
        try supervisor.tick(&ctx, &writer);
    }

    try std.testing.expectEqual(@as(usize, loop_limit), ctx.restarts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Restarts pause until changes stop for 7s.") != null);
}
