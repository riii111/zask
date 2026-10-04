const std = @import("std");
const env = @import("../platform/env.zig");
const paths = @import("../platform/paths.zig");

/// The schema of the config keys this binary accepts. It is installed under the
/// config base so generated `$schema` references resolve without network access
/// and follow the installed zask version.
pub const contents = @embedFile("config_schema");
pub const file_name = "zask.schema.json";
/// `$schema` value for a named config at `<config base>/<project>/config.json`.
pub const named_config_reference = "../" ++ file_name;

/// Writes the embedded schema to `<config base>/zask.schema.json` unless the
/// file already has the same contents. The file is replaced atomically so an
/// editor reading it never sees a partial schema.
pub fn install(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map) !void {
    const base = try paths.configBase(gpa, environ);
    defer gpa.free(base);
    const path = try std.fs.path.join(gpa, &.{ base, file_name });
    defer gpa.free(path);
    if (try isCurrent(gpa, io, path)) return;

    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, contents);
    try file.replace(io);
}

fn isCurrent(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const current = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(contents.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer gpa.free(current);
    return std.mem.eql(u8, current, contents);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testReadInstalled(gpa: std.mem.Allocator, io: std.Io, config_home: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ config_home, "zask", file_name });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
}

test "config_schema.contents: embeds the tracked schema file" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const tracked = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), "schema/zask.schema.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(tracked);

    try std.testing.expectEqualStrings(tracked, contents);
}

test "config_schema.install: writes missing and replaces stale schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const config_home = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);

    try install(std.testing.allocator, io, &environ);
    const first = try testReadInstalled(arena.allocator(), io, config_home);
    try tmp.dir.writeFile(io, .{ .sub_path = "zask/" ++ file_name, .data = "{\"stale\":true}" });
    try install(std.testing.allocator, io, &environ);
    const refreshed = try testReadInstalled(arena.allocator(), io, config_home);

    try std.testing.expectEqualStrings(contents, first);
    try std.testing.expectEqualStrings(contents, refreshed);
}
