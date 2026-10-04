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

test "wait: a tmux call that never returns fails at the deadline" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // exec keeps the hung process the direct child, so the deadline kill reaches it.
    const cases = [_]struct {
        name: []const u8,
        script: []const u8,
    }{
        .{ .name = "output open", .script = "#!/bin/sh\nexec /bin/sleep 30\n" },
        .{ .name = "output closed", .script = "#!/bin/sh\nexec /bin/sleep 30 >/dev/null 2>&1\n" },
        // An ignored signal stays ignored across exec.
        .{ .name = "SIGTERM ignored", .script = "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        try ws.writeProjectFile(io, "config.json", config_json);
        const fake_tmux = try std.fs.path.join(gpa, &.{ ws.elsewhere, "tmux" });
        defer gpa.free(fake_tmux);
        var file = try std.Io.Dir.createFileAbsolute(io, fake_tmux, .{ .permissions = @enumFromInt(0o755) });
        try file.writeStreamingAll(io, case.script);
        file.close(io);
        const started = std.Io.Clock.awake.now(io);

        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
            .path = ws.elsewhere,
        }, &.{ "--config", "config.json", "wait", "api", "--timeout", "1" });
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(1));
        try std.testing.expectEqualStrings("Timed out after 1s waiting for:\n  api: not checked before the deadline\n", res.stdout);
        try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toSeconds() < 5);
    }
}
