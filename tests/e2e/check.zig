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
    const bin = try ws.toolDir(gpa, io, &.{ "tmux", "serve" }, &.{});
    defer gpa.free(bin);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
        .path = bin,
    }, &.{"check"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(0));
    try std.testing.expect(std.mem.startsWith(u8, res.stdout, "Config OK: "));
    try std.testing.expect(std.mem.endsWith(u8, res.stdout, "\nEnvironment OK\n"));
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

test "check: reports environment problems with exit code 1" {
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
    const bin = try ws.toolDir(gpa, io, &.{"tmux"}, &.{});
    defer gpa.free(bin);

    var res = try harness.spawnZask(gpa, io, .{
        .cwd = ws.project,
        .xdg_config_home = ws.xdg,
        .home = ws.home,
        .path = bin,
    }, &.{"check"});
    defer res.deinit(gpa);

    try std.testing.expect(res.exitedWith(1));
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "Error: 1 environment problem\n  groups[backend].services[api].command: 'serve' not found in PATH\n") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}

test "check: runs prechecks only with --prechecks" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);

    try ws.writeProjectFile(io, "zask.json",
        \\{
        \\  "project": {"name":"demo","root":"."},
        \\  "prechecks": [
        \\    {"name":"ready","command":"true"},
        \\    {"name":"db","command":"echo down >&2; exit 3","on_fail":"abort","hint":"start db"}
        \\  ],
        \\  "groups": [{"name":"backend","services":[{"name":"api","command":"serve"}]}]
        \\}
    );
    const bin = try ws.toolDir(gpa, io, &.{ "tmux", "serve" }, &.{"/bin/bash"});
    defer gpa.free(bin);
    const opts: harness.SpawnOptions = .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home, .path = bin };

    var skipped = try harness.spawnZask(gpa, io, opts, &.{"check"});
    defer skipped.deinit(gpa);
    var ran = try harness.spawnZask(gpa, io, opts, &.{ "check", "--prechecks" });
    defer ran.deinit(gpa);

    try std.testing.expect(skipped.exitedWith(0));
    try std.testing.expect(std.mem.endsWith(u8, skipped.stdout, "Prechecks: 2 not run; add --prechecks to run them\n"));
    try std.testing.expect(ran.exitedWith(1));
    try std.testing.expect(std.mem.endsWith(u8, ran.stdout,
        \\Prechecks:
        \\  ready: passed
        \\  db: failed (error)
        \\    command: echo down >&2; exit 3
        \\    exit code 3: down
        \\    Hint: start db
        \\
    ));
}
