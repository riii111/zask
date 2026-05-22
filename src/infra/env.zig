const std = @import("std");

pub fn get(comptime name: [:0]const u8) ?[]const u8 {
    const raw = std.mem.span(std.c.environ);
    const environ: std.process.Environ = .{ .block = .{ .slice = @ptrCast(raw) } };
    return std.process.Environ.getPosix(environ, name);
}

pub fn exists(comptime name: [:0]const u8) bool {
    return get(name) != null;
}

test "missing environment variable returns null" {
    try std.testing.expect(get("ZASK_ENV_TEST_SHOULD_NOT_EXIST") == null);
}
