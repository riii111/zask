const std = @import("std");
const env = @import("env.zig");

pub fn configBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_CONFIG_HOME")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fs.path.join(gpa, &.{ try home(environ), ".config", "zask" });
}

pub fn dataBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_DATA_HOME")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fs.path.join(gpa, &.{ try home(environ), ".local", "share", "zask" });
}

pub fn runtimeBase(gpa: std.mem.Allocator, environ: ?*const env.Map) ![]const u8 {
    if (env.get(environ, "XDG_RUNTIME_DIR")) |value| return std.fs.path.join(gpa, &.{ value, "zask" });
    return std.fs.path.join(gpa, &.{ "/tmp", "zask" });
}

pub fn home(environ: ?*const env.Map) ![]const u8 {
    return env.get(environ, "HOME") orelse error.HomeNotSet;
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

test "home requires HOME in environment map" {
    try std.testing.expectError(error.HomeNotSet, home(null));
}
