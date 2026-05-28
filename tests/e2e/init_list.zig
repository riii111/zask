const std = @import("std");
const harness = @import("harness.zig");

test "e2e initList: init writes config and list reads it from a different cwd" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "compose.yaml", "services: {}\n");

    var init_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", "demo", "--root", "." });
    defer init_res.deinit(gpa);

    try std.testing.expect(init_res.exitedWith(0));
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Created") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_res.stdout, "Detected Docker Compose file: compose.yaml") != null);

    const cfg_path = try ws.configPath(gpa, "demo");
    defer gpa.free(cfg_path);
    try std.Io.Dir.accessAbsolute(io, cfg_path, .{});

    var list_res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.elsewhere,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "demo", "list" });
    defer list_res.deinit(gpa);

    try std.testing.expect(list_res.exitedWith(0));
    try std.testing.expect(std.mem.startsWith(u8, list_res.stdout, "demo\n"));
    try std.testing.expect(std.mem.indexOf(u8, list_res.stdout, "- docker") != null);
}

test "e2e initList: re-init without --force exits non-zero without stack trace" {
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
    }, &.{ "init", "demo", "--root", "." });
    defer first.deinit(gpa);
    try std.testing.expect(first.exitedWith(0));

    var second = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "init", "demo", "--root", "." });
    defer second.deinit(gpa);

    try std.testing.expect(!second.exitedWith(0));
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "Config already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "--force") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "panic") == null);
    try std.testing.expect(std.mem.indexOf(u8, second.stderr, "stack trace") == null);
}
