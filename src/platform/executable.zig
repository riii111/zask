const std = @import("std");

/// Resolves `name` the way a shell would before running it: names containing a
/// slash are taken as paths, others are searched in the colon-separated
/// `search_path`. Relative paths and PATH entries resolve under `cwd`.
/// Returns a caller-owned path, or null when no executable regular file
/// matches. Aliases, functions, and builtins are invisible here; callers
/// decide which names to skip.
pub fn find(gpa: std.mem.Allocator, io: std.Io, search_path: ?[]const u8, cwd: []const u8, name: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const path = if (std.fs.path.isAbsolute(name)) try gpa.dupe(u8, name) else try std.fs.path.join(gpa, &.{ cwd, name });
        errdefer gpa.free(path);
        if (try isExecutableFile(io, path)) return path;
        gpa.free(path);
        return null;
    }
    var dirs = std.mem.splitScalar(u8, search_path orelse return null, ':');
    while (dirs.next()) |dir| {
        // Empty and relative entries are looked up from the directory the
        // command runs in; POSIX treats an empty entry as ".".
        const path = if (std.fs.path.isAbsolute(dir))
            try std.fs.path.join(gpa, &.{ dir, name })
        else
            try std.fs.path.join(gpa, &.{ cwd, dir, name });
        errdefer gpa.free(path);
        if (try isExecutableFile(io, path)) return path;
        gpa.free(path);
    }
    return null;
}

fn isExecutableFile(io: std.Io, path: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied, error.NameTooLong, error.SymLinkLoop => return false,
        else => return err,
    };
    if (stat.kind != .file) return false;
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testWriteFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, executable: bool) !void {
    try dir.writeFile(io, .{
        .sub_path = sub_path,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = if (executable) .executable_file else .default_file },
    });
}

test "executable.find: searches PATH entries in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    try tmp.dir.createDirPath(io, "b/dir-tool");
    try testWriteFile(io, tmp.dir, "a/tool", false);
    try testWriteFile(io, tmp.dir, "b/tool", true);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const search_path = try std.fmt.allocPrint(gpa, "{s}/missing:{s}/a:{s}/b", .{ root, root, root });

    const found = try find(gpa, io, search_path, root, "tool");

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa, "{s}/b/tool", .{root}), found.?);
    try std.testing.expect(try find(gpa, io, search_path, root, "dir-tool") == null);
    try std.testing.expect(try find(gpa, io, null, root, "tool") == null);
}

test "executable.find: resolves relative PATH entries against cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "web/bin");
    try tmp.dir.createDirPath(io, "api/bin");
    try testWriteFile(io, tmp.dir, "web/bin/serve", true);
    try testWriteFile(io, tmp.dir, "api/run", true);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const web = try std.fs.path.join(gpa, &.{ root, "web" });
    const api = try std.fs.path.join(gpa, &.{ root, "api" });

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa, "{s}/bin/serve", .{web}), (try find(gpa, io, "bin", web, "serve")).?);
    try std.testing.expect(try find(gpa, io, "bin", api, "serve") == null);
    try std.testing.expect(try find(gpa, io, ":/nonexistent", api, "run") != null);
}

test "executable.find: resolves slash names against cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try testWriteFile(io, tmp.dir, "bin/server", true);
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);

    try std.testing.expect(try find(gpa, io, null, root, "./bin/server") != null);
    try std.testing.expect(try find(gpa, io, null, root, "./bin/missing") == null);
}
