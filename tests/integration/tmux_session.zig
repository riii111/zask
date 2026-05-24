const std = @import("std");
const zask = @import("zask");
const build_options = @import("tmux_integration_options");

const pane_ready_attempts = 40;
const pane_ready_interval = std.Io.Duration.fromMilliseconds(50);

test "direct session construction keeps dashboard selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}", .{std.c.getpid()});
    const client = tmuxClient(arena.allocator(), io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", try zask.zask_command.waitingPlaceholder(arena.allocator(), "Dashboard"));
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", "sleep 60");
    try client.newWindowAfter("api", "worker", "/tmp", "sleep 60");
    try client.selectWindow("dashboard");

    const result = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_name}:#{window_active}" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dashboard:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "api:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "worker:0") != null);
}

test "placeholder windows stay alive for later commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}-placeholder", .{std.c.getpid()});
    const client = tmuxClient(arena.allocator(), io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", try zask.zask_command.waitingPlaceholder(arena.allocator(), "Dashboard"));
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", try zask.zask_command.waitingPlaceholder(arena.allocator(), "api"));

    try expectPaneAlive(std.testing.allocator, io, try std.fmt.allocPrint(arena.allocator(), "{s}:api", .{session}));
}

fn tmuxClient(gpa: std.mem.Allocator, io: std.Io, session: []const u8) zask.tmux.Client {
    return .{
        .gpa = gpa,
        .runner = .{ .gpa = gpa, .io = io },
        .session = session,
        .tmux_path = build_options.tmux_path,
    };
}

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return error.CommandFailed;
    }
    return result;
}

fn expectPaneAlive(gpa: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    for (0..pane_ready_attempts) |_| {
        const result = try run(gpa, io, &.{ build_options.tmux_path, "list-panes", "-t", target, "-F", "#{pane_dead}|#{pane_current_command}" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        if (std.mem.startsWith(u8, result.stdout, "0|")) return;
        try std.Io.sleep(io, pane_ready_interval, .awake);
    }
    return error.PaneNotAlive;
}
