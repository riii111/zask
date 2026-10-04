const std = @import("std");
const harness = @import("harness.zig");

test "add: adds a service that list reads" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json",
        \\{
        \\  "project": {"name": "demo", "root": "."},
        \\  "groups": [{"name": "backend", "services": {"worker": "work"}}]
        \\}
        \\
    );
    const opts: harness.SpawnOptions = .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home };

    var add_res = try harness.spawnZask(gpa, io, opts, &.{ "add", "api", "cargo run", "--port", "8080" });
    defer add_res.deinit(gpa);

    try std.testing.expect(add_res.exitedWith(0));
    try std.testing.expect(std.mem.startsWith(u8, add_res.stdout, "Added service 'api' to group 'backend'\n"));

    var dup_res = try harness.spawnZask(gpa, io, opts, &.{ "add", "api", "other" });
    defer dup_res.deinit(gpa);

    try std.testing.expect(dup_res.exitedWith(2));
    try std.testing.expect(std.mem.startsWith(u8, dup_res.stdout, "Error: service 'api' already exists in group 'backend'\n"));

    var list_res = try harness.spawnZask(gpa, io, opts, &.{"list"});
    defer list_res.deinit(gpa);

    try std.testing.expect(list_res.exitedWith(0));
    try std.testing.expectEqualStrings(
        \\demo
        \\- worker [backend]
        \\- api [backend] :8080
        \\
    , list_res.stdout);
}
