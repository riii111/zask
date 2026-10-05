const std = @import("std");

pub fn prepareAppend(io: std.Io, path: []const u8, rotated_path: []const u8, rotate_at: u64) !u64 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try ensurePrivateDir(io, dir);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buffer, "{s}.lock", .{path}) catch return error.NameTooLong;
    var lock = try cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = private_file_permissions });
    defer lock.close(io);

    try restrictExisting(io, rotated_path);
    try restrictExisting(io, path);
    if (try existingSize(io, path) >= rotate_at) try cwd.rename(path, cwd, rotated_path, io);
    var file = try cwd.createFile(io, path, .{ .truncate = false, .permissions = private_file_permissions });
    defer file.close(io);
    return file.length(io);
}

pub fn appendText(gpa: std.mem.Allocator, io: std.Io, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try ensurePrivateDir(io, dir);
    var lock_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buffer, "{s}.lock", .{path}) catch return error.NameTooLong;
    var lock = try cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = private_file_permissions });
    defer lock.close(io);

    try restrictExisting(io, path);
    const cut_off = cut: {
        var file = try cwd.createFile(io, path, .{ .read = true, .truncate = false, .permissions = private_file_permissions });
        defer file.close(io);
        const length = try file.length(io);
        if (length == 0) break :cut false;
        var last: [1]u8 = undefined;
        break :cut try file.readPositionalAll(io, &last, length - 1) == 1 and last[0] != '\n';
    };
    const bytes = try std.mem.concat(gpa, u8, &.{ if (cut_off) "\n" else "", text });
    defer gpa.free(bytes);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    const written = std.c.write(fd, bytes.ptr, bytes.len);
    if (written < 0 or @as(usize, @intCast(written)) != bytes.len) return error.WriteFailed;
}

fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, private_dir_permissions);
}

fn restrictExisting(io: std.Io, path: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .file) return error.NotRegularFile;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
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

test "log_file.appendText: starts the text on its own line after cut-off output" {
    const cases = [_]struct { existing: ?[]const u8, want: []const u8 }{
        .{ .existing = null, .want = "note\n" },
        .{ .existing = "", .want = "note\n" },
        .{ .existing = "done\n", .want = "done\nnote\n" },
        .{ .existing = "panic: bo", .want = "panic: bo\nnote\n" },
    };

    for (cases) |case| {
        const gpa = std.testing.allocator;
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        if (case.existing) |data| {
            try tmp.dir.createDirPath(io, "logs");
            try tmp.dir.writeFile(io, .{ .sub_path = "logs/api.log", .data = data });
        }
        const path = try testPath(gpa, io, tmp.dir, "logs/api.log");
        defer gpa.free(path);

        try appendText(gpa, io, path, "note\n");

        const written = try testReadFile(gpa, io, tmp.dir, "logs/api.log");
        defer gpa.free(written);
        try std.testing.expectEqualStrings(case.want, written);
        try std.testing.expectEqual(@as(u32, 0o600), try testMode(io, tmp.dir, "logs/api.log"));
    }
}

fn testAppendLines(path: [*:0]const u8, count: usize) void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    for (0..count) |_| _ = std.c.write(fd, "output\n", 7);
}

test "log_file.appendText: keeps output another writer appends meanwhile" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = "" });
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const writer = try std.Thread.spawn(.{}, testAppendLines, .{ path_z.ptr, 5000 });
    for (0..200) |_| try appendText(gpa, io, path, "note\n");
    writer.join();

    const written = try tmp.dir.readFileAlloc(io, "api.log", gpa, .limited(1024 * 1024));
    defer gpa.free(written);
    try std.testing.expectEqual(@as(usize, 5000), std.mem.count(u8, written, "output\n"));
    try std.testing.expectEqual(@as(usize, 200), std.mem.count(u8, written, "note\n"));
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

test "log_file.prepareAppend: rejects a non-file log path without changing it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_]struct { log: []const u8, rotated: []const u8 }{
        .{ .log = "api.log", .rotated = "api.log.1" },
        .{ .log = "api.log.1", .rotated = "api.log" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = case.rotated, .data = "x" });
        try tmp.dir.createDirPath(io, case.log);
        try testSetMode(io, tmp.dir, case.log, 0o755);
        const path = try testPath(gpa, io, tmp.dir, "api.log");
        defer gpa.free(path);
        const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
        defer gpa.free(rotated);

        try std.testing.expectError(error.NotRegularFile, prepareAppend(io, path, rotated, 64));

        try std.testing.expectEqual(@as(u32, 0o755), try testMode(io, tmp.dir, case.log));
    }
}

test "log_file.prepareAppend: rejects a symlinked log without changing its target" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "shared.txt", .data = "not a log" });
    try testSetMode(io, tmp.dir, "shared.txt", 0o644);
    try tmp.dir.symLink(io, "shared.txt", "api.log", .{});
    const path = try testPath(gpa, io, tmp.dir, "api.log");
    defer gpa.free(path);
    const rotated = try testPath(gpa, io, tmp.dir, "api.log.1");
    defer gpa.free(rotated);

    try std.testing.expectError(error.NotRegularFile, prepareAppend(io, path, rotated, 64));

    try std.testing.expectEqual(@as(u32, 0o644), try testMode(io, tmp.dir, "shared.txt"));
}
