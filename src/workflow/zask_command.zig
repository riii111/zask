const std = @import("std");
const shell = @import("../platform/shell.zig");

pub fn invoke(gpa: std.mem.Allocator, zask_path: []const u8, config_path: []const u8, command: []const u8) ![]const u8 {
    const quoted_zask_path = try shell.quote(gpa, zask_path);
    defer gpa.free(quoted_zask_path);
    const quoted_config_path = try shell.quote(gpa, config_path);
    defer gpa.free(quoted_config_path);
    return std.fmt.allocPrint(gpa, "{s} --config {s} {s}", .{ quoted_zask_path, quoted_config_path, command });
}

pub fn waitingPlaceholder(gpa: std.mem.Allocator, label: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "printf '=== {s} ===\\nWaiting for start command...\\n'; exec \"${{SHELL:-sh}}\"", .{label});
}

test "invoke quotes zask and config paths" {
    const command = try invoke(std.testing.allocator, "/tmp/zask path", "/tmp/demo config.json", "dashboard");
    defer std.testing.allocator.free(command);

    try std.testing.expectEqualStrings("'/tmp/zask path' --config '/tmp/demo config.json' dashboard", command);
}

test "waiting placeholder includes display label" {
    const command = try waitingPlaceholder(std.testing.allocator, "Docker Services");
    defer std.testing.allocator.free(command);

    try std.testing.expectEqualStrings("printf '=== Docker Services ===\\nWaiting for start command...\\n'; exec \"${SHELL:-sh}\"", command);
}
