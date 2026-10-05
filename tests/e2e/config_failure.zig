const std = @import("std");
const harness = @import("harness.zig");

test "list: missing explicit config exits cleanly" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "--config", "config.json", "list" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "config not found") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}

test "list: config syntax errors print the position" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_]struct {
        file: []const u8,
        contents: []const u8,
        heading: []const u8,
        detail: []const u8,
    }{
        .{ .file = "config.jsonc", .contents = "{\n  // note\n  \"groups\": [],\n}", .heading = "Error: config is not valid JSONC\n", .detail = "  line 3, column 15: trailing comma is not allowed\n" },
        .{ .file = "config.json", .contents = "{\n  // note\n}", .heading = "Error: config is not valid JSON\n", .detail = "  line 2, column 3: comments are allowed only in .jsonc config files\n" },
    };

    for (cases) |case| {
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        try ws.writeProjectFile(io, case.file, case.contents);

        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
        }, &.{ "--config", case.file, "list" });
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(2));
        try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, case.heading) != null);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, case.detail) != null);
    }
}

test "list: config validation prints every diagnostic with its field path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "config.json",
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo"},
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
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "project.name: must be a valid identifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "startup_order[0].group: unknown group 'workers'") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "group_aliases.frontend[0]: unknown service 'web'") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}
