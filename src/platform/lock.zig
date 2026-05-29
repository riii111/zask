const std = @import("std");
const paths = @import("paths.zig");
const runner = @import("runner.zig");

pub const Lock = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,

    pub fn acquire(gpa: std.mem.Allocator, proc: runner.Runner, name: []const u8, base: []const u8) !Lock {
        try ensurePrivateDir(proc.io, base);
        const dir = try std.fs.path.join(gpa, &.{ base, try std.fmt.allocPrint(gpa, "{s}.lock", .{name}) });
        errdefer gpa.free(dir);
        const pid = try std.fmt.allocPrint(gpa, "{d}", .{proc.currentPid()});
        defer gpa.free(pid);
        if (try acquireDir(proc.io, dir)) {
            try writePid(gpa, proc, dir, pid);
            return .{ .gpa = gpa, .io = proc.io, .dir = dir };
        }
        if (try lockAlive(gpa, proc, dir)) return error.LockBusy;

        const stale_dir = try std.fmt.allocPrint(gpa, "{s}.stale.{d}", .{ dir, proc.currentPid() });
        defer gpa.free(stale_dir);
        std.Io.Dir.renameAbsolute(dir, stale_dir, proc.io) catch return error.LockBusy;
        defer std.Io.Dir.cwd().deleteTree(proc.io, stale_dir) catch {};
        if (!try acquireDir(proc.io, dir)) return error.LockBusy;
        try writePid(gpa, proc, dir, pid);
        return .{ .gpa = gpa, .io = proc.io, .dir = dir };
    }

    pub fn release(self: Lock) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
    }
};

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, private_dir_permissions);
}

fn acquireDir(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.createDirAbsolute(io, path, private_dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    return true;
}

fn writePid(gpa: std.mem.Allocator, proc: runner.Runner, dir: []const u8, pid: []const u8) !void {
    const io = proc.io;
    const pid_path = try std.fs.path.join(gpa, &.{ dir, "pid" });
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ pid_path, proc.currentPid() });
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    try paths.writeFileMode(io, tmp_path, pid, private_file_permissions);
    try std.Io.Dir.renameAbsolute(tmp_path, pid_path, io);
}

fn lockAlive(gpa: std.mem.Allocator, proc: runner.Runner, dir: []const u8) !bool {
    const pid_path = try std.fs.path.join(gpa, &.{ dir, "pid" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(proc.io, pid_path, gpa, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    };
    defer gpa.free(bytes);
    const pid_text = std.mem.trim(u8, bytes, " \t\r\n");
    if (pid_text.len == 0) return false;
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch return false;
    return proc.processAlive(pid);
}

const private_dir_permissions: std.Io.Dir.Permissions = @enumFromInt(0o700);
const private_file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "lock blocks concurrent acquire and releases directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const run = runner.Runner{ .gpa = gpa, .io = threaded.io() };
    const name = try std.fmt.allocPrint(gpa, "zask-test-{d}", .{std.c.getpid()});

    const base = try std.fs.path.join(gpa, &.{ "/tmp", "zask-test-locks" });
    const first = try Lock.acquire(gpa, run, name, base);
    try std.testing.expectError(error.LockBusy, Lock.acquire(gpa, run, name, base));
    first.release();
    const second = try Lock.acquire(gpa, run, name, base);
    second.release();
}

test "lock recovers stale pid files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const run = runner.Runner{ .gpa = gpa, .io = io };
    const name = try std.fmt.allocPrint(gpa, "zask-test-stale-{d}", .{std.c.getpid()});
    const base = try std.fs.path.join(gpa, &.{ "/tmp", "zask-test-locks" });
    const dir = try std.fs.path.join(gpa, &.{ base, try std.fmt.allocPrint(gpa, "{s}.lock", .{name}) });
    const pid_path = try std.fs.path.join(gpa, &.{ dir, "pid" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, private_dir_permissions);
    try paths.writeFileMode(io, pid_path, "99999999", private_file_permissions);

    const lock = try Lock.acquire(gpa, run, name, base);
    lock.release();
}

test "lock.acquire: treats live holder as busy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var recorder = runner.Recorder.init(gpa);
    defer recorder.deinit();
    recorder.process_alive = true;
    const run = runner.Runner{ .gpa = gpa, .io = io, .recorder = &recorder };
    const base = try std.fmt.allocPrint(gpa, "/private/tmp/zask-test-lock-live-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const dir = try std.fs.path.join(gpa, &.{ base, "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, private_dir_permissions);
    try paths.writeFileMode(io, try std.fs.path.join(gpa, &.{ dir, "pid" }), "4242", private_file_permissions);

    try std.testing.expectError(error.LockBusy, Lock.acquire(gpa, run, "demo", base));
}

test "lock.acquire: recovers when holder is dead empty or unparseable" {
    const cases = [_][]const u8{ "4242", "", "not-a-pid" };
    for (cases, 0..) |pid_contents, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        var recorder = runner.Recorder.init(gpa);
        defer recorder.deinit();
        recorder.process_alive = false;
        const run = runner.Runner{ .gpa = gpa, .io = io, .recorder = &recorder };
        const base = try std.fmt.allocPrint(gpa, "/private/tmp/zask-test-lock-dead-{d}-{d}", .{ std.c.getpid(), index });
        defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
        const dir = try std.fs.path.join(gpa, &.{ base, "demo.lock" });
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, private_dir_permissions);
        try paths.writeFileMode(io, try std.fs.path.join(gpa, &.{ dir, "pid" }), pid_contents, private_file_permissions);

        const lock = try Lock.acquire(gpa, run, "demo", base);
        lock.release();
    }
}

test "lock.acquire: reports busy when stale rename cannot proceed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var recorder = runner.Recorder.init(gpa);
    defer recorder.deinit();
    recorder.pid = 4242;
    recorder.process_alive = false;
    const run = runner.Runner{ .gpa = gpa, .io = io, .recorder = &recorder };
    const base = try std.fmt.allocPrint(gpa, "/private/tmp/zask-test-lock-rename-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const dir = try std.fs.path.join(gpa, &.{ base, "demo.lock" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, private_dir_permissions);
    try paths.writeFileMode(io, try std.fs.path.join(gpa, &.{ dir, "pid" }), "4242", private_file_permissions);

    const blocking_stale = try std.fmt.allocPrint(gpa, "{s}.stale.{d}", .{ dir, recorder.pid });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, blocking_stale, private_dir_permissions);
    try paths.writeFileMode(io, try std.fs.path.join(gpa, &.{ blocking_stale, "occupied" }), "x", private_file_permissions);

    try std.testing.expectError(error.LockBusy, Lock.acquire(gpa, run, "demo", base));
}
