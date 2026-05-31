const std = @import("std");
const harness = @import("harness.zig");

const valid_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
    \\  "groups": [
    \\    {"name":"backend","services":[
    \\      {"name":"api","dir":"backend","command":"serve","port":18080}
    \\    ]}
    \\  ]
    \\}
;

test "list: discovers zask.json in current project" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", valid_config);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"list"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "demo\n"));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "- api [backend] :18080") != null);
}

test "list: rejects ambiguous local config files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", valid_config);
    try ws.writeProjectFile(io, ".zask.json", valid_config);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"list"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "both zask.json and .zask.json found") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Use --config <file>") != null);
}

test "list: explicit config wins over ambiguous local files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", "{\"foo\":1}");
    try ws.writeProjectFile(io, ".zask.json", "{\"foo\":1}");
    try ws.writeProjectFile(io, "config.json", valid_config);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "--config", "config.json", "list" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "demo\n"));
}

test "list: named project wins over command-form discovery" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeNamedConfig(gpa, io, "list", valid_config);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "list", "list" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "demo\n"));
}

test "list: discovered config validation reports selected file" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", "{\"foo\":1}");

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"list"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "invalid config") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Config:") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "zask.json") != null);
}
