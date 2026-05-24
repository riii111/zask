const std = @import("std");
const shell = @import("../platform/shell.zig");

const dashboard_command = "dashboard";
const monitor_command = "monitor";

/// Returns a shell command string owned by the caller.
pub fn invoke(gpa: std.mem.Allocator, zask_path: []const u8, config_path: []const u8, command: []const u8) ![]const u8 {
    const quoted_zask_path = try shell.quote(gpa, zask_path);
    defer gpa.free(quoted_zask_path);
    const quoted_config_path = try shell.quote(gpa, config_path);
    defer gpa.free(quoted_config_path);
    return std.fmt.allocPrint(gpa, "{s} --config {s} {s}", .{ quoted_zask_path, quoted_config_path, command });
}

/// Returns a shell command string owned by the caller.
pub fn invokeDashboard(gpa: std.mem.Allocator, zask_path: []const u8, config_path: []const u8) ![]const u8 {
    return invoke(gpa, zask_path, config_path, dashboard_command);
}

/// Returns a shell command string owned by the caller.
pub fn invokeMonitor(gpa: std.mem.Allocator, zask_path: []const u8, config_path: []const u8) ![]const u8 {
    return invoke(gpa, zask_path, config_path, monitor_command);
}

/// Returns a shell command string owned by the caller.
pub fn waitingPlaceholder(gpa: std.mem.Allocator, label: []const u8) ![]const u8 {
    const quoted_label = try shell.quote(gpa, label);
    defer gpa.free(quoted_label);
    return std.fmt.allocPrint(gpa, "printf '=== %s ===\\nWaiting for start command...\\n' {s}; exec \"${{SHELL:-sh}}\"", .{quoted_label});
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "invoke quotes zask and config paths" {
    const command = try invoke(std.testing.allocator, "/tmp/zask path", "/tmp/demo config.json", "dashboard");
    defer std.testing.allocator.free(command);

    try std.testing.expectEqualStrings("'/tmp/zask path' --config '/tmp/demo config.json' dashboard", command);
}

test "waiting placeholder formats and quotes display label" {
    const cases = [_]struct {
        label: []const u8,
        expected: []const u8,
    }{
        .{
            .label = "Docker Services",
            .expected = "printf '=== %s ===\\nWaiting for start command...\\n' 'Docker Services'; exec \"${SHELL:-sh}\"",
        },
        .{
            .label = "bad'$(touch nope)",
            .expected = "printf '=== %s ===\\nWaiting for start command...\\n' 'bad'\\''$(touch nope)'; exec \"${SHELL:-sh}\"",
        },
    };

    for (cases) |case| {
        const command = try waitingPlaceholder(std.testing.allocator, case.label);
        defer std.testing.allocator.free(command);
        try std.testing.expectEqualStrings(case.expected, command);
    }
}
