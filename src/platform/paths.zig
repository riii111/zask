const std = @import("std");
const env = @import("env.zig");

pub const private_dir_permissions: std.Io.Dir.Permissions = @enumFromInt(0o700);
pub const private_file_permissions: std.Io.File.Permissions = @enumFromInt(0o600);

pub fn configBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_CONFIG_HOME")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fs.path.join(gpa, &.{ try home(environ), ".config", "zask" });
}

pub fn dataBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_DATA_HOME")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fs.path.join(gpa, &.{ try home(environ), ".local", "share", "zask" });
}

pub fn stateBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_STATE_HOME")) |value| {
        if (std.fs.path.isAbsolute(value)) return std.fs.path.join(gpa, &.{ value, "zask" });
    }
    return std.fs.path.join(gpa, &.{ try home(environ), ".local", "state", "zask" });
}

pub fn runtimeBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_RUNTIME_DIR")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fmt.allocPrint(gpa, "/tmp/zask-{d}", .{std.c.getuid()});
}

pub fn home(environ: ?*const env.Map) ![]const u8 {
    return env.get(environ, "HOME") orelse error.HomeNotSet;
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn ensurePrivateDir(io: std.Io, path: []const u8) !void {
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, private_dir_permissions);
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try dir.setPermissions(io, private_dir_permissions);
}

pub fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    return writeFileMode(io, path, contents, .default_file);
}

pub fn writeFileMode(io: std.Io, path: []const u8, contents: []const u8, permissions: std.Io.File.Permissions) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{ .permissions = permissions })
    else
        try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "paths.home: requires HOME in environment map" {
    try std.testing.expectError(error.HomeNotSet, home(null));
}

test "paths.stateBase: ignores empty and relative XDG_STATE_HOME" {
    const cases = [_][]const u8{ "", "state" };
    for (cases) |value| {
        var environ = env.Map.init(std.testing.allocator);
        defer environ.deinit();
        try environ.put("HOME", "/home/me");
        try environ.put("XDG_STATE_HOME", value);

        const path = try stateBase(std.testing.allocator, &environ);
        defer std.testing.allocator.free(path);

        try std.testing.expectEqualStrings("/home/me/.local/state/zask", path);
    }
}

test "paths.runtimeBase: fallback is scoped by uid" {
    const path = try runtimeBase(std.testing.allocator, null);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zask-{d}", .{std.c.getuid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}
