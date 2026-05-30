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
