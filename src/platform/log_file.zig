const std = @import("std");

/// Readies `path` for appending without truncating it: creates the parent
/// directory, moves an existing file of at least `rotate_at` bytes to
/// `rotated_path` (replacing what was there), and creates the file when
/// missing. Opening the file for writing here is the writability check, so a
/// log that cannot be written fails before the caller relies on it. Returns
/// the size of the file left at `path`.
///
/// Logs may hold secrets, so the directory, the log, and the rotated log are
/// set to owner-only even when they already existed with wider modes.
///
/// Calls for the same `path` from any process are serialized by an exclusive
/// advisory lock on `<path>.lock`, held only while this function runs: the
/// second caller sees the log the first one left, so one generation is
/// rotated once and never replaced by a fresh log. Whatever the caller does
/// with the log afterwards (starting a writer) is not covered by this lock.
pub fn prepareAppend(io: std.Io, path: []const u8, rotated_path: []const u8, rotate_at: u64) !u64 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try ensurePrivateDir(io, dir);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buffer, "{s}.lock", .{path}) catch return error.NameTooLong;
    var lock = try cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = private_file_permissions });
    defer lock.close(io);

    try restrictExisting(io, rotated_path);
    if (try existingSize(io, path) >= rotate_at) {
        try restrictExisting(io, path);
        try cwd.rename(path, cwd, rotated_path, io);
    }
    var file = try cwd.createFile(io, path, .{ .truncate = false, .permissions = private_file_permissions });
    defer file.close(io);
    try file.setPermissions(io, private_file_permissions);
    return file.length(io);
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
    defer dir.close(io);
    try dir.setPermissions(io, private_dir_permissions);
}

fn restrictExisting(io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);
    try file.setPermissions(io, private_file_permissions);
}

fn existingSize(io: std.Io, path: []const u8) !u64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    return stat.size;
}

const private_dir_permissions: std.Io.Dir.Permissions = @enumFromInt(0o700);
const private_file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testPath(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![]const u8 {
    const root = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    return std.fs.path.join(gpa, &.{ root, sub_path });
}

fn testReadFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![]const u8 {
    return dir.readFileAlloc(io, sub_path, gpa, .limited(1024));
}

fn testPrepareInto(io: std.Io, path: []const u8, rotated: []const u8, result: *anyerror!u64) void {
    result.* = prepareAppend(io, path, rotated, 8);
}

fn testSetMode(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, mode: u32) !void {
    const path = try dir.realPathFileAlloc(io, sub_path, std.testing.allocator);
    defer std.testing.allocator.free(path);
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    if (std.c.chmod(path_z, @intCast(mode)) != 0) return error.ChmodFailed;
}

fn testMode(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !u32 {
    const stat = try dir.statFile(io, sub_path, .{});
    return @as(u32, @intCast(@intFromEnum(stat.permissions))) & 0o777;
}

test "log_file.prepareAppend: creates missing directories and an empty file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, io, tmp.dir, "state/logs/api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "state/logs/api.log.1");
    defer gpa.free(rotated);

    const size = try prepareAppend(io, path, rotated, 64);

    try std.testing.expectEqual(@as(u64, 0), size);
    const contents = try testReadFile(gpa, io, tmp.dir, "state/logs/api.log");
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("", contents);
}

test "log_file.prepareAppend: keeps a log below the rotation size" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = "previous run\n" });
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(rotated);

    const size = try prepareAppend(io, path, rotated, 64);

    try std.testing.expectEqual(@as(u64, "previous run\n".len), size);
    const contents = try testReadFile(gpa, io, tmp.dir, "api.log");
    defer gpa.free(contents);
    try std.testing.expectEqualStrings("previous run\n", contents);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "api.log.1", .{}));
}

test "log_file.prepareAppend: rotates a log at the rotation size over the older one" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = "12345678" });
    try tmp.dir.writeFile(io, .{ .sub_path = "api.log.1", .data = "oldest" });
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(rotated);

    const size = try prepareAppend(io, path, rotated, 8);

    try std.testing.expectEqual(@as(u64, 0), size);
    const kept = try testReadFile(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("12345678", kept);
}

test "log_file.prepareAppend: fails when the log directory cannot be created" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "state", .data = "not a directory" });
    const path = try testPath(gpa, io, tmp.dir, "state/logs/api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "state/logs/api.log.1");
    defer gpa.free(rotated);

    try std.testing.expectError(error.NotDir, prepareAppend(io, path, rotated, 64));
}

test "log_file.prepareAppend: makes an existing log and its directory owner-only" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "logs");
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log", .data = "previous run\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log.1", .data = "older run\n" });
    try testSetMode(io, tmp.dir, "logs", 0o755);
    try testSetMode(io, tmp.dir, "logs/api.log", 0o644);
    try testSetMode(io, tmp.dir, "logs/api.log.1", 0o644);
    const path = try testPath(gpa, io, tmp.dir, "logs/api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "logs/api.log.1");
    defer gpa.free(rotated);

    _ = try prepareAppend(io, path, rotated, 64);

    try std.testing.expectEqual(@as(u32, 0o700), try testMode(io, tmp.dir, "logs"));
    try std.testing.expectEqual(@as(u32, 0o600), try testMode(io, tmp.dir, "logs/api.log"));
    try std.testing.expectEqual(@as(u32, 0o600), try testMode(io, tmp.dir, "logs/api.log.1"));
}

test "log_file.prepareAppend: rotating a wide log keeps the moved log owner-only" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = "12345678" });
    try testSetMode(io, tmp.dir, "api.log", 0o644);
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(rotated);

    _ = try prepareAppend(io, path, rotated, 8);

    try std.testing.expectEqual(@as(u32, 0o600), try testMode(io, tmp.dir, "api.log.1"));
    try std.testing.expectEqual(@as(u32, 0o600), try testMode(io, tmp.dir, "api.log"));
}

test "log_file.prepareAppend: concurrent calls rotate one generation once" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(rotated);
    const previous = "previous generation";

    for (0..20) |_| {
        try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = previous });
        tmp.dir.deleteFile(io, "api.log.1") catch {};
        var results: [4]anyerror!u64 = undefined;
        var threads: [4]std.Thread = undefined;
        for (&threads, &results) |*thread, *result| {
            thread.* = try std.Thread.spawn(.{}, testPrepareInto, .{ io, path, rotated, result });
        }
        for (threads) |thread| thread.join();

        for (results) |result| _ = try result;
        const kept = try testReadFile(gpa, io, tmp.dir, "api.log.1");
        defer gpa.free(kept);
        try std.testing.expectEqualStrings(previous, kept);
    }
}
