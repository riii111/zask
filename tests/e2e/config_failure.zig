const std = @import("std");
const harness = @import("harness.zig");

test "list: config load failures exit cleanly without stack traces" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct {
        name: []const u8,
        contents: ?[]const u8,
        message: []const u8,
    }{
        .{ .name = "missing", .contents = null, .message = "config not found" },
        .{ .name = "parse", .contents = "not json", .message = "not valid JSON" },
        .{ .name = "validation", .contents = "{\"foo\":1}", .message = "invalid config" },
    };

    for (cases) |case| {
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);

        if (case.contents) |contents| try ws.writeProjectFile(io, "config.json", contents);

        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
        }, &.{ "--config", "config.json", "list" });
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(2));
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, case.message) != null);
        try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "panic") == null);
    }
}

test "list: config validation prints diagnostic detail lines with field paths" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "config.json",
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    );

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "--config", "config.json", "list" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "invalid config") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "project.name: must be a valid identifier") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "panic") == null);
}

test "list: config validation prints unresolved reference diagnostics" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "config.json",
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","command":"serve"}
        \\  ]}],
        \\  "group_aliases": {"frontend":["web"]},
        \\  "startup_order": [{"group":"workers"}]
        \\}
    );

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "--config", "config.json", "list" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "invalid config") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "startup_order[0].group: unknown group 'workers'") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "group_aliases.frontend[0]: unknown service 'web'") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "panic") == null);
}

test "start: window not ready exits cleanly after diagnostics" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    const project = "demo_window_not_ready";

    const config_json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"{s}","root":"."}},
        \\  "groups": [{{"name":"backend","services":[
        \\    {{"name":"api","dir":".","command":"serve"}}
        \\  ]}}]
        \\}}
    , .{project});
    defer gpa.free(config_json);
    try ws.writeProjectFile(io, "zask.json", config_json);

    createTmuxSession(gpa, io, project) catch return error.SkipZigTest;
    defer killTmuxSession(gpa, io, project) catch {};

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "start", "api" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(1));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Error: api window is not ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "zask close") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "WindowNotReady") == null);
}

fn createTmuxSession(gpa: std.mem.Allocator, io: std.Io, session: []const u8) !void {
    killTmuxSession(gpa, io, session) catch {};
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "tmux", "new-session", "-d", "-s", session, "-n", "dashboard" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return error.SkipZigTest;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.SkipZigTest;
}

fn killTmuxSession(gpa: std.mem.Allocator, io: std.Io, session: []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "tmux", "kill-session", "-t", session },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
}
