const std = @import("std");

pub fn configBase(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value| return std.fs.path.join(gpa, &.{ std.mem.span(value), "zask" });
    return std.fs.path.join(gpa, &.{ home(), ".config", "zask" });
}

pub fn dataBase(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |value| return std.fs.path.join(gpa, &.{ std.mem.span(value), "zask" });
    return std.fs.path.join(gpa, &.{ home(), ".local", "share", "zask" });
}

pub fn runtimeBase(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |value| return std.fs.path.join(gpa, &.{ std.mem.span(value), "zask" });
    return std.fs.path.join(gpa, &.{ "/tmp", "zask" });
}

pub fn home() []const u8 {
    if (std.c.getenv("HOME")) |value| return std.mem.span(value);
    return "";
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
