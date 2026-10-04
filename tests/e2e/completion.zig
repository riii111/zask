const std = @import("std");
const harness = @import("harness.zig");

const demo_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "groups": [{"name":"backend","services":[
    \\    {"name":"api","command":"serve"},
    \\    {"name":"bff-dashboard","command":"dev"}
    \\  ]}],
    \\  "start_profiles": {"lite": {"profile": "lite"}}
    \\}
;

test "__complete: uses discovered and named config like commands" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", demo_config);
    try ws.writeNamedConfig(gpa, io, "demo", demo_config);
    const cases = [_]struct { cwd: []const u8, args: []const []const u8, expected: []const u8 }{
        .{ .cwd = ws.project, .args = &.{ "__complete", "restart", "bf" }, .expected = "bff-dashboard\n" },
        .{ .cwd = ws.project, .args = &.{ "__complete", "open", "--" }, .expected = "--lite\n" },
        .{ .cwd = ws.elsewhere, .args = &.{ "__complete", "demo", "restart", "bf" }, .expected = "bff-dashboard\n" },
    };

    for (cases) |case| {
        var res = try harness.spawnZask(gpa, io, .{ .cwd = case.cwd, .xdg_config_home = ws.xdg, .home = ws.home }, case.args);
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(0));
        try std.testing.expectEqualStrings(case.expected, res.stdout);
        try std.testing.expectEqualStrings("", res.stderr);
    }
}

test "__complete: exits cleanly with static candidates when config is unusable" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_]?[]const u8{ null, "not json", "{\"foo\":1}" };

    for (cases) |contents| {
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        if (contents) |data| try ws.writeProjectFile(io, "zask.json", data);

        var start = try harness.spawnZask(gpa, io, .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home }, &.{ "__complete", "start", "" });
        defer start.deinit(gpa);
        var top = try harness.spawnZask(gpa, io, .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home }, &.{ "__complete", "rest" });
        defer top.deinit(gpa);

        try std.testing.expect(start.exitedWith(0));
        try std.testing.expectEqualStrings("--all\n", start.stdout);
        try std.testing.expectEqualStrings("", start.stderr);
        try std.testing.expect(top.exitedWith(0));
        try std.testing.expectEqualStrings("restart\n", top.stdout);
        try std.testing.expectEqualStrings("", top.stderr);
    }
}
