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

test "preview list resizes stale detached windows before tree mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}-preview", .{std.c.getpid()});
    const client = tmuxClient(arena.allocator(), io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", "sleep 60");
    try client.newWindowAfter("api", "docker", "/tmp", "sleep 60");
    try client.resizeWindow(try std.fmt.allocPrint(arena.allocator(), "{s}:api", .{session}), 80, 24);

    const cfg = try zask.config.Config.parse(arena.allocator(),
        \\{
        \\  "project": {"name":"demo","root":"/tmp","session_name":"demo"},
        \\  "services": []
        \\}
    , "/tmp");
    const run_impl: zask.runner.Runner = .{ .gpa = arena.allocator(), .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = arena.allocator(),
        .io = io,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "zask",
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = arena.allocator(), .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
    };
    const pane_id = try firstPaneId(arena.allocator(), io, session);

    try runtime.previewList(pane_id, 120, 40);

    try expectWindowSizes(std.testing.allocator, io, session, 120, 39);
    try expectWindowAutoSize(std.testing.allocator, io, session);
    const mode = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-panes", "-t", pane_id, "-F", "#{pane_in_mode}|#{pane_mode}" });
    defer std.testing.allocator.free(mode.stdout);
    defer std.testing.allocator.free(mode.stderr);
    try std.testing.expect(std.mem.indexOf(u8, mode.stdout, "1|tree-mode") != null);
}

test "session setup refreshes stale list binding in existing session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}-binding", .{std.c.getpid()});
    const client = tmuxClient(arena.allocator(), io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try runDiscard(arena.allocator(), io, &.{ build_options.tmux_path, "bind-key", "-T", "prefix", "w", "run-shell", "tmux choose-tree -Zw" });

    try zask.tmux_setup.bindControlKeys(arena.allocator(), client);

    const binding = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-keys", "-T", "prefix", "w" });
    defer std.testing.allocator.free(binding.stdout);
    defer std.testing.allocator.free(binding.stderr);
    try std.testing.expect(std.mem.indexOf(u8, binding.stdout, "preview-list") != null);
    try std.testing.expect(std.mem.indexOf(u8, binding.stdout, "#{pane_id}") != null);
    try std.testing.expect(std.mem.indexOf(u8, binding.stdout, "#{client_width}") != null);
    try std.testing.expect(std.mem.indexOf(u8, binding.stdout, "#{client_height}") != null);
}

fn tmuxClient(gpa: std.mem.Allocator, io: std.Io, session: []const u8) zask.tmux.Client {
    return .{
        .gpa = gpa,
        .runner = .{ .gpa = gpa, .io = io },
        .session = session,
        .tmux_path = build_options.tmux_path,
    };
}

fn firstPaneId(gpa: std.mem.Allocator, io: std.Io, session: []const u8) ![]const u8 {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-panes", "-t", session, "-F", "#{pane_id}" });
    defer gpa.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn expectWindowSizes(gpa: std.mem.Allocator, io: std.Io, session: []const u8, width: u16, height: u16) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_width}|#{window_height}" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const expected = try std.fmt.allocPrint(gpa, "{d}|{d}", .{ width, height });
    defer gpa.free(expected);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expectEqualStrings(expected, line);
    }
}

fn expectWindowAutoSize(gpa: std.mem.Allocator, io: std.Io, session: []const u8) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_id}" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |window_id| {
        if (window_id.len == 0) continue;
        const option = try run(gpa, io, &.{ build_options.tmux_path, "show-options", "-w", "-t", window_id, "-v", "window-size" });
        defer gpa.free(option.stdout);
        defer gpa.free(option.stderr);
        try std.testing.expectEqualStrings("latest", std.mem.trim(u8, option.stdout, " \t\r\n"));
    }
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

fn runDiscard(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try run(gpa, io, argv);
    gpa.free(result.stdout);
    gpa.free(result.stderr);
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
