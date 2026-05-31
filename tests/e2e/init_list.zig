const std = @import("std");
const harness = @import("harness.zig");

const project_name = "demo";

test "init: writes config readable by list" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "compose.yaml", "services: {}\n");
    try ws.writeProjectFile(io, "package.json", "{\"scripts\":{\"dev\":\"vite\"}}\n");

    var init_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", project_name, "--root", "." });
    defer init_res.deinit(gpa);

    try std.testing.expect(init_res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), init_res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Created") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Detected Docker Compose file: compose.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Detected package script: dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Next: zask demo list") != null);

    const cfg_path = try ws.configPath(gpa, project_name);
    defer gpa.free(cfg_path);
    try std.Io.Dir.accessAbsolute(io, cfg_path, .{});

    var list_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.elsewhere,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ project_name, "list" });
    defer list_res.deinit(gpa);

    try std.testing.expect(list_res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), list_res.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, list_res.stdout, "demo\n"));
    try std.testing.expect(std.mem.indexOf(u8, list_res.stdout, "- web [frontend]") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_res.stdout, "- docker") != null);
}

test "init: writes inferred project config readable by command form" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "package.json", "{\"scripts\":{\"dev\":\"vite\"}}\n");

    var init_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", "--root", "." });
    defer init_res.deinit(gpa);

    try std.testing.expect(init_res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), init_res.stderr.len);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Next: zask list") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Next: zask open") != null);

    const cfg_path = try ws.configPath(gpa, "project");
    defer gpa.free(cfg_path);
    try std.Io.Dir.accessAbsolute(io, cfg_path, .{});

    var list_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"list"});
    defer list_res.deinit(gpa);

    try std.testing.expect(list_res.exitedWith(0));
    try std.testing.expectEqual(@as(usize, 0), list_res.stderr.len);
    try std.testing.expect(std.mem.startsWith(u8, list_res.stdout, "project\n"));
    try std.testing.expect(std.mem.indexOf(u8, list_res.stdout, "- web [frontend]") != null);
}

test "init: rejects re-init without --force" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    var first = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", project_name, "--root", "." });
    defer first.deinit(gpa);
    try std.testing.expect(first.exitedWith(0));

    var second = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", project_name, "--root", "." });
    defer second.deinit(gpa);

    try std.testing.expect(second.exitedWith(2));
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "Config already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "--force") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "panic") == null);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "stack trace") == null);
}

test "init: rejects malformed project identifier" {
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
    }, &.{ "init", "bad/name", "--root", "." });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "panic") == null);
}
