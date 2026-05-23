const std = @import("std");

pub const Map = std.process.Environ.Map;

pub fn get(map: ?*const Map, name: []const u8) ?[]const u8 {
    const m = map orelse return null;
    return m.get(name);
}

pub fn exists(map: ?*const Map, name: []const u8) bool {
    return get(map, name) != null;
}

test "missing environment variable returns null" {
    try std.testing.expect(get(null, "ZASK_ENV_TEST_SHOULD_NOT_EXIST") == null);
}
