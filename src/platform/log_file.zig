const std = @import("std");

/// Readies `path` for appending without truncating it: creates the parent
/// directory (owner-only, since logs may hold secrets), moves an existing file
/// of at least `rotate_at` bytes to `rotated_path` (replacing what was there),
/// and creates the file when missing. Opening the file for writing here is the
/// writability check, so a log that cannot be written fails before the caller
/// relies on it. Returns the size of the file left at `path`.
pub fn prepareAppend(io: std.Io, path: []const u8, rotated_path: []const u8, rotate_at: u64) !u64 {
    if (std.fs.path.dirname(path)) |dir| _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, private_dir_permissions);
    if (try existingSize(io, path) >= rotate_at) try std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), rotated_path, io);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .permissions = private_file_permissions });
    defer file.close(io);
    return file.length(io);
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
