const std = @import("std");
const harness = @import("harness.zig");

test "check: reports success without opening a session" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "zask.json",
        \\{
        \\  "project": {"name":"demo","root":"."},
        \\  "groups": [{"name":"backend","services":[{"name":"api","command":"serve"}]}]
        \\}
    );

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"check"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(0));
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "Config OK: "));
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}

test "check: lists config and path problems together with exit code 2" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "zask.json",
        \\{
        \\  "project": {"name":"demo","root":"."},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":"backend","command":"serve"},
        \\    {"name":"web","dir":"frontend","command":"dev"}
        \\  ]}]
        \\}
    );

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
    }, &.{"check"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(2));
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "Error: 2 config problems\n"));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "groups[backend].services[api].dir: directory not found: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "groups[backend].services[web].dir: directory not found: ") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}
