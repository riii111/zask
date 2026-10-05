const std = @import("std");
const env = @import("../platform/env.zig");
const log_file = @import("../platform/log_file.zig");
const paths = @import("../platform/paths.zig");

/// Each start appends to `<service>.log`, so a restart never erases the output
/// of the run that failed before it. A log that reached this size moves to
/// `<service>.log.1` at the next start, replacing the older generation, which
/// keeps the pair bounded while the previous runs stay readable.
pub const rotate_at_bytes: u64 = 8 * 1024 * 1024;

/// Caller owns the returned path: `<XDG state>/zask/<project>/logs`.
pub fn directory(gpa: std.mem.Allocator, environ: ?*const env.Map, project: []const u8) ![]const u8 {
    const base = try paths.stateBase(gpa, environ);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, project, "logs" });
}

/// Caller owns the returned path.
pub fn servicePath(gpa: std.mem.Allocator, dir: []const u8, service: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(gpa, "{s}.log", .{service});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// One start's log: where the output goes and the header line that marks
/// where this start begins in it. Free both with `deinit`.
pub const Recording = struct {
    path: []const u8,
    header: []const u8,

    pub fn deinit(self: Recording, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.header);
    }
};

/// Readies the service log for a start at `started_at` (Unix seconds), rotating
/// it first when it reached rotate_at_bytes. Earlier output is never truncated.
/// Fails when the log cannot be written; the caller owns the result.
///
/// Concurrent calls for one service, even from separate zask processes, are
/// serialized only while the log is prepared (see log_file.prepareAppend), so
/// rotation never loses a generation. Two starts that both get here still
/// each set up their own pipe; keeping one start per service from pane
/// observation through respawn is the caller's lock to hold.
pub fn begin(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, service: []const u8, started_at: i64) !Recording {
    return beginRotatingAt(gpa, io, dir, service, started_at, rotate_at_bytes);
}

/// Appends a zask line about `service` to its log, after the output of the
/// run it is about: `text` is written as one line.
pub fn appendNote(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, service: []const u8, text: []const u8) !void {
    const path = try servicePath(gpa, dir, service);
    defer gpa.free(path);
    const line = try std.fmt.allocPrint(gpa, "{s}\n", .{text});
    defer gpa.free(line);
    try log_file.appendText(io, path, line);
}

fn beginRotatingAt(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, service: []const u8, started_at: i64, rotate_at: u64) !Recording {
    const path = try servicePath(gpa, dir, service);
    errdefer gpa.free(path);
    const rotated = try std.fmt.allocPrint(gpa, "{s}.1", .{path});
    defer gpa.free(rotated);
    const existing = try log_file.prepareAppend(io, path, rotated, rotate_at);
    const header = try startHeader(gpa, service, started_at, existing > 0);
    return .{ .path = path, .header = header };
}

/// A blank line separates the header from earlier output, which may not end
/// with a newline when the previous run was cut off mid-line.
fn startHeader(gpa: std.mem.Allocator, service: []const u8, started_at: i64, follows_output: bool) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(started_at, 0)) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    return std.fmt.allocPrint(gpa, "{s}=== zask: {s} started at {d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z ===\n", .{
        if (follows_output) "\n" else "",
        service,
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "service_log.directory: prefers XDG_STATE_HOME" {
    const gpa = std.testing.allocator;
    var environ = env.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_STATE_HOME", "/state");

    const dir = try directory(gpa, &environ, "demo");
    defer gpa.free(dir);

    try std.testing.expectEqualStrings("/state/zask/demo/logs", dir);
}

test "service_log.directory: falls back to the home state directory" {
    const gpa = std.testing.allocator;
    var environ = env.Map.init(gpa);
    defer environ.deinit();
    try environ.put("HOME", "/home/me");

    const dir = try directory(gpa, &environ, "demo");
    defer gpa.free(dir);

    try std.testing.expectEqualStrings("/home/me/.local/state/zask/demo/logs", dir);
}

test "service_log.begin: first start creates the log with a bare header" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "logs" });
    defer gpa.free(dir);

    const recording = try begin(gpa, io, dir, "api", 1_790_000_000);
    defer recording.deinit(gpa);

    const expected_path = try std.fs.path.join(gpa, &.{ dir, "api.log" });
    defer gpa.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, recording.path);
    try std.testing.expectEqualStrings("=== zask: api started at 2026-09-21T14:13:20Z ===\n", recording.header);
    _ = try tmp.dir.statFile(io, "logs/api.log", .{});
}

test "service_log.begin: restart keeps earlier output and separates its header" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log", .data = "panic: boom" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "logs" });
    defer gpa.free(dir);

    const recording = try begin(gpa, io, dir, "api", 0);
    defer recording.deinit(gpa);

    try std.testing.expectEqualStrings("\n=== zask: api started at 1970-01-01T00:00:00Z ===\n", recording.header);
    const kept = try tmp.dir.readFileAlloc(io, "logs/api.log", gpa, .limited(64));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("panic: boom", kept);
}

test "service_log.begin: rotation starts a fresh log after the previous one" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log", .data = "previous run" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "logs" });
    defer gpa.free(dir);

    const recording = try beginRotatingAt(gpa, io, dir, "api", 0, 4);
    defer recording.deinit(gpa);

    try std.testing.expectEqualStrings("=== zask: api started at 1970-01-01T00:00:00Z ===\n", recording.header);
    const rotated = try tmp.dir.readFileAlloc(io, "logs/api.log.1", gpa, .limited(64));
    defer gpa.free(rotated);
    try std.testing.expectEqualStrings("previous run", rotated);
}
