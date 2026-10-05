const std = @import("std");

pub fn absolute(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPathFile(io, path, &buffer);
    return gpa.dupe(u8, buffer[0..len]);
}

pub fn absoluteForDisplay(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return withoutCurrentDirParts(gpa, path);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path });
}

fn withoutCurrentDirParts(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (!std.mem.eql(u8, part, ".")) try parts.append(gpa, part);
    }
    const joined = try std.mem.join(gpa, "/", parts.items);
    defer gpa.free(joined);
    return std.fmt.allocPrint(gpa, "/{s}", .{joined});
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "pathing.absolute: resolves relative paths from cwd" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const actual = try absolute(std.testing.allocator, io, ".");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(cwd, actual);
}

test "pathing.absoluteForDisplay: resolves paths without requiring the target" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ cwd, "missing-zask-dir" });
    defer std.testing.allocator.free(expected);
    const actual = try absoluteForDisplay(std.testing.allocator, io, "missing-zask-dir");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "pathing.absoluteForDisplay: drops current-dir parts but keeps parent references" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const actual = try absoluteForDisplay(std.testing.allocator, threaded.io(), "/srv/./app/../.env");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("/srv/app/../.env", actual);
}
