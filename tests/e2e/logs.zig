const std = @import("std");
const harness = @import("harness.zig");

const config_json =
    \\{"project":{"name":"demo","root":"."},"groups":[{"name":"backend","services":[{"name":"api","dir":".","command":"serve"},{"name":"web","dir":".","command":"serve"}]}]}
;

const saved_log = "=== zask: api started at 2026-09-21T14:13:20Z ===\nlistening\nboom\nexit 1\n";

test "logs: saved log is read without a tmux session" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct {
        name: []const u8,
        args: []const []const u8,
        stdout: []const u8,
    }{
        .{ .name = "whole log", .args = &.{ "--config", "config.json", "logs", "api", "--saved" }, .stdout = saved_log },
        .{ .name = "last lines", .args = &.{ "--config", "config.json", "logs", "api", "--saved", "--tail", "2" }, .stdout = "boom\nexit 1\n" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        try ws.writeProjectFile(io, "config.json", config_json);
        try ws.tmp.dir.createDirPath(io, "home/.local/state/zask/demo/logs");
        try ws.tmp.dir.writeFile(io, .{ .sub_path = "home/.local/state/zask/demo/logs/api.log", .data = saved_log });

        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
            .path = ws.elsewhere,
        }, case.args);
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(0));
        try std.testing.expectEqualStrings(case.stdout, res.stdout);
        try std.testing.expectEqualStrings("", res.stderr);
    }
}

test "logs: saved log path and missing output are reported per service" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "config.json", config_json);
    try ws.tmp.dir.createDirPath(io, "home/.local/state/zask/demo/logs");
    try ws.tmp.dir.writeFile(io, .{ .sub_path = "home/.local/state/zask/demo/logs/api.log", .data = saved_log });
    const web_log = try std.fs.path.join(gpa, &.{ ws.home, ".local/state/zask/demo/logs/web.log" });
    defer gpa.free(web_log);
    const opts: harness.SpawnOptions = .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home, .path = ws.elsewhere };

    var path_res = try harness.spawnZask(gpa, io, opts, &.{ "--config", "config.json", "logs", "web", "--path" });
    defer path_res.deinit(gpa);
    var saved_res = try harness.spawnZask(gpa, io, opts, &.{ "--config", "config.json", "logs", "web", "--saved" });
    defer saved_res.deinit(gpa);

    const expected_path = try std.fmt.allocPrint(gpa, "{s}\n", .{web_log});
    defer gpa.free(expected_path);
    try std.testing.expect(path_res.exitedWith(0));
    try std.testing.expectEqualStrings(expected_path, path_res.stdout);
    try std.testing.expectEqualStrings("", path_res.stderr);
    const expected_missing = try std.fmt.allocPrint(gpa, "No saved output for web yet; it is written to {s} once the service starts\n", .{web_log});
    defer gpa.free(expected_missing);
    try std.testing.expect(saved_res.exitedWith(1));
    try std.testing.expectEqualStrings("", saved_res.stdout);
    try std.testing.expectEqualStrings(expected_missing, saved_res.stderr);
}
