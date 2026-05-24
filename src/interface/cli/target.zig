const std = @import("std");

pub fn normalize(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "--docker")) return "docker";
    return target;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "normalize maps docker flag to target name" {
    try std.testing.expectEqualStrings("docker", normalize("--docker"));
    try std.testing.expectEqualStrings("api", normalize("api"));
}
