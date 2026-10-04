const std = @import("std");
const harness = @import("harness.zig");

const config_json =
    \\{"project":{"name":"demo","root":"."},"groups":[{"name":"backend","services":[{"name":"api","dir":".","command":"serve","port":3000}]}]}
;

test "wait: exit codes separate usage errors from runtime failures" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct {
        name: []const u8,
        args: []const []const u8,
        exit_code: u8,
        stdout: []const u8,
    }{
        .{ .name = "unknown target", .args = &.{ "--config", "config.json", "wait", "api", "missing" }, .exit_code = 2, .stdout = "Unknown service or group: missing\n" },
        .{ .name = "missing target", .args = &.{ "--config", "config.json", "wait", "--timeout", "5" }, .exit_code = 2, .stdout = "Usage:" },
        .{ .name = "tmux unavailable", .args = &.{ "--config", "config.json", "wait", "backend" }, .exit_code = 1, .stdout = "tmux unavailable\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        try ws.writeProjectFile(io, "config.json", config_json);

        // An empty directory as PATH keeps tmux from being spawned on any host.
        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
            .path = ws.elsewhere,
        }, case.args);
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(case.exit_code));
        try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
        try std.testing.expect(std.mem.startsWith(u8, res.stdout, case.stdout));
    }
}
