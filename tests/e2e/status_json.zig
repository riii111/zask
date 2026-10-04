const std = @import("std");
const harness = @import("harness.zig");

test "status --json: tmux unavailable writes JSON error and exits 1" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "config.json", "{\"project\":{\"name\":\"demo\",\"root\":\".\"},\"groups\":[]}");

    // The harness passes no PATH, so tmux cannot be spawned.
    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{ "--config", "config.json", "status", "--json" });
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(1));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tmux_unavailable", parsed.value.object.get("error").?.object.get("code").?.string);
}

test "status --json: config failures write one JSON error document" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cases = [_]struct {
        name: []const u8,
        contents: ?[]const u8,
        code: []const u8,
        diagnostic: ?[]const u8 = null,
    }{
        .{ .name = "missing", .contents = null, .code = "config_not_found" },
        .{ .name = "parse", .contents = "not json", .code = "invalid_config_syntax" },
        .{ .name = "validation", .contents = "{\"project\":{\"name\":\"bad name\",\"root\":\"/tmp/demo\"},\"groups\":[]}", .code = "invalid_config", .diagnostic = "project.name" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);

        if (case.contents) |contents| try ws.writeProjectFile(io, "config.json", contents);

        var res = try harness.spawnZask(gpa, io, .{
            .cwd = ws.project,
            .xdg_config_home = ws.xdg,
            .home = ws.home,
        }, &.{ "--config", "config.json", "status", "--json" });
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(2));
        try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
        try std.testing.expect(std.mem.endsWith(u8, res.stdout, "}\n"));
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, res.stdout, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("schema_version").?.integer);
        const body = parsed.value.object.get("error").?.object;
        try std.testing.expectEqualStrings(case.code, body.get("code").?.string);
        if (case.diagnostic) |path| {
            try std.testing.expectEqualStrings(path, body.get("diagnostics").?.array.items[0].object.get("path").?.string);
        }
    }
}
