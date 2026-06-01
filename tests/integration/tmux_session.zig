const std = @import("std");
const zask = @import("zask");
const build_options = @import("tmux_integration_options");

const pane_ready_attempts = 40;
const pane_ready_interval = std.Io.Duration.fromMilliseconds(50);
const service_state_attempts = 60;
const service_state_interval = std.Io.Duration.fromMilliseconds(50);

test "tmux.newSession: direct construction keeps dashboard selected" {
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

test "zask_command.waitingPlaceholder: keeps placeholder windows alive for later commands" {
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

test "runtime.previewList: resizes stale detached windows before tree mode" {
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
        \\  "groups": []
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

test "tmux_setup.bindControlKeys: refreshes stale list binding in existing session" {
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

test "tmux_setup.applySessionOptions: keeps global attach hook while refreshing size hook" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}-hooks", .{std.c.getpid()});
    const client = tmuxClient(arena.allocator(), io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try runDiscard(arena.allocator(), io, &.{ build_options.tmux_path, "set-hook", "-g", "client-attached", "display-message global" });

    try zask.tmux_setup.applySessionOptions(arena.allocator(), client, .{
        .project = "demo",
        .zask_path = "/bin/zask",
        .config_path = "/tmp/config.json",
    });

    const global_hooks = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "show-hooks", "-g" });
    defer std.testing.allocator.free(global_hooks.stdout);
    defer std.testing.allocator.free(global_hooks.stderr);
    try std.testing.expect(std.mem.indexOf(u8, global_hooks.stdout, "client-attached[0] display-message global") != null);

    const hooks = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "show-hooks", "-t", session });
    defer std.testing.allocator.free(hooks.stdout);
    defer std.testing.allocator.free(hooks.stderr);
    try std.testing.expect(std.mem.indexOf(u8, hooks.stdout, "client-active") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks.stdout, "sync-size") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks.stdout, "#{client_width}") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks.stdout, "#{client_height}") != null);

    const prefix = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "show-option", "-t", session, "-qv", "prefix" });
    defer std.testing.allocator.free(prefix.stdout);
    defer std.testing.allocator.free(prefix.stderr);
    try std.testing.expectEqualStrings("C-q\n", prefix.stdout);
}

test "runtime: open, status, close build, report, then remove workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(a, "zask-test-{d}-workspace", .{std.c.getpid()});
    const client = tmuxClient(a, io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 300");
    defer client.killSession() catch {};
    try zask.tmux_setup.applySessionOptions(a, client, .{
        .project = "demo",
        .zask_path = "/bin/zask",
        .config_path = "/tmp/config.json",
    });
    try client.splitWindow("dashboard", "/tmp", "sleep 300");
    try client.newWindowAfter("dashboard", "api", "/tmp", try zask.zask_command.waitingPlaceholder(a, "api"));
    try client.selectWindow("dashboard");

    const windows = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_name}:#{window_active}" });
    defer std.testing.allocator.free(windows.stdout);
    defer std.testing.allocator.free(windows.stderr);
    try std.testing.expect(std.mem.indexOf(u8, windows.stdout, "dashboard:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, windows.stdout, "api:0") != null);

    const dashboard_target = try std.fmt.allocPrint(a, "{s}:dashboard", .{session});
    const panes = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-panes", "-t", dashboard_target, "-F", "#{pane_id}" });
    defer std.testing.allocator.free(panes.stdout);
    defer std.testing.allocator.free(panes.stderr);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, panes.stdout, "%"));

    const dash_mode = (try client.showOption("@zask_dash_mode")) orelse return error.SessionOptionMissing;
    try std.testing.expectEqualStrings("all", dash_mode);

    const cfg_json = try std.fmt.allocPrint(a,
        \\{{
        \\  "project": {{ "name": "demo", "root": "/tmp", "session_name": "{s}" }},
        \\  "groups": [{{ "name": "backend", "services": [{{ "name": "api", "dir": ".", "command": "sleep 300" }}] }}]
        \\}}
    , .{session});
    const cfg = try zask.config.Config.parse(a, cfg_json, "/tmp");
    const run_impl: zask.runner.Runner = .{ .gpa = a, .io = io };
    const runtime_base = try std.fmt.allocPrint(a, "/tmp/zask-test-{d}-runtime", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, runtime_base) catch {};
    var environ = std.process.Environ.Map.init(a);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", runtime_base);
    const runtime = zask.runtime.Runtime{
        .gpa = a,
        .io = io,
        .environ = &environ,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "/bin/zask",
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = a, .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
    };

    var status_buffer: [512]u8 = undefined;
    var status_writer: std.Io.Writer = .fixed(&status_buffer);
    try runtime.status(&status_writer);
    const status_out = status_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, status_out, "demo Service Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_out, "api stopped [backend]") != null);

    var close_buffer: [512]u8 = undefined;
    var close_writer: std.Io.Writer = .fixed(&close_buffer);
    try runtime.close(&close_writer);

    try std.testing.expect(!client.hasSession());
}

test "runtime: start, logs, stop, restart move service pane through its lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-lifecycle", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", try zask.zask_command.waitingPlaceholder(gpa, "api"));

    const cfg = try zask.config.Config.parse(gpa,
        \\{
        \\  "project": {"name":"demo","root":"/tmp","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":".","command":"sleep 60"}]}]
        \\}
    , "/tmp");
    const run_impl: zask.runner.Runner = .{ .gpa = gpa, .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "zask",
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = gpa, .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
    };
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    // The placeholder is an interactive shell; let it settle to idle before starting.
    try waitForPaneState(client, gpa, io, "api", .idle);

    try runtime.start("api", &writer);

    try waitForPaneState(client, gpa, io, "api", .busy);

    // runtime.logs attaches when run outside tmux, so assert the window focus it drives.
    try client.selectWindow("api");

    try expectActiveWindow(gpa, io, session, "api");

    try runtime.stop("api", &writer);

    try waitForPaneState(client, gpa, io, "api", .idle);

    try runtime.restart("api", &writer);

    try waitForPaneState(client, gpa, io, "api", .busy);
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

fn waitForPaneState(client: zask.tmux.Client, gpa: std.mem.Allocator, io: std.Io, window: []const u8, expected: zask.observations.PaneState) !void {
    for (0..service_state_attempts) |_| {
        const pane = client.observePane(window);
        defer pane.deinit(gpa);

        if (pane.state == expected) return;
        try std.Io.sleep(io, service_state_interval, .awake);
    }
    return error.PaneStateTimeout;
}

fn expectActiveWindow(gpa: std.mem.Allocator, io: std.Io, session: []const u8, name: []const u8) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_name}:#{window_active}" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const expected = try std.fmt.allocPrint(gpa, "{s}:1", .{name});
    defer gpa.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected) != null);
}
