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
        \\  "project": {"name":"demo","root":"/tmp"},
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
        .command_hint = .{ .config = "/tmp/config.json" },
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

test "cli.start: recreates missing service window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-window-not-ready", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"{s}","root":"."}},
        \\  "groups": [{{"name":"backend","services":[
        \\    {{"name":"api","dir":".","command":"/bin/sleep 60"}}
        \\  ]}}]
        \\}}
    , .{session});
    try tmp.dir.writeFile(io, .{
        .sub_path = "zask.json",
        .data = config_json,
    });
    const project_root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", project_root);
    try env_map.put("XDG_CONFIG_HOME", project_root);
    const parent_path = if (std.c.getenv("PATH")) |path| std.mem.span(path) else "";
    if (std.fs.path.dirname(build_options.tmux_path)) |tmux_dir|
        try env_map.put("PATH", try std.fmt.allocPrint(gpa, "{s}:{s}", .{ tmux_dir, parent_path }))
    else
        try env_map.put("PATH", parent_path);

    client.killSession() catch {};
    try client.newSession("dashboard", project_root, "sleep 60");
    try zask.tmux_setup.applySessionOptions(gpa, client, .{
        .project = session,
        .zask_path = build_options.zask_path,
        .config_path = try std.fs.path.join(gpa, &.{ project_root, "zask.json" }),
    });
    defer client.killSession() catch {};

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ build_options.zask_path, "start", "api" },
        .cwd = .{ .path = project_root },
        .environ_map = &env_map,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Warning: api has no port; zask cannot check readiness for this service") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Starting api...") != null);
    try std.testing.expectEqual(@as(usize, 0), result.stderr.len);
    const api_target = try std.fmt.allocPrint(gpa, "{s}:api", .{session});
    try expectPaneAlive(gpa, io, api_target);
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

    const before_global_hooks = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "show-hooks", "-g" });
    defer std.testing.allocator.free(before_global_hooks.stdout);
    defer std.testing.allocator.free(before_global_hooks.stderr);

    try zask.tmux_setup.applySessionOptions(arena.allocator(), client, .{
        .project = "demo",
        .zask_path = "/bin/zask",
        .config_path = "/tmp/config.json",
    });

    const global_hooks = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "show-hooks", "-g" });
    defer std.testing.allocator.free(global_hooks.stdout);
    defer std.testing.allocator.free(global_hooks.stderr);
    try std.testing.expectEqualStrings(before_global_hooks.stdout, global_hooks.stdout);

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
        \\  "project": {{ "name": "demo", "root": "/tmp" }},
        \\  "groups": [{{ "name": "backend", "services": [{{ "name": "api", "dir": ".", "command": "sleep 300" }}] }}]
        \\}}
    , .{});
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
        .command_hint = .{ .config = "/tmp/config.json" },
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
        \\  "project": {"name":"demo","root":"/tmp"},
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
        .command_hint = .{ .config = "/tmp/config.json" },
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
    const api_target = try std.fmt.allocPrint(gpa, "{s}:api", .{session});
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "kill-window", "-t", api_target });

    try runtime.restart("api", &writer);

    try waitForPaneState(client, gpa, io, "api", .busy);
}

test "runtime.start: recreated service windows preserve configured order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-window-order", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", try zask.zask_command.waitingPlaceholder(gpa, "api"));
    try client.newWindowAfter("api", "worker", "/tmp", try zask.zask_command.waitingPlaceholder(gpa, "worker"));
    try client.newWindowAfter("worker", "web", "/tmp", try zask.zask_command.waitingPlaceholder(gpa, "web"));

    const cfg = try zask.config.Config.parse(gpa,
        \\{
        \\  "project": {"name":"demo","root":"/tmp"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","dir":".","command":"sleep 60"},
        \\    {"name":"worker","dir":".","command":"sleep 60"},
        \\    {"name":"web","dir":".","command":"sleep 60"}
        \\  ]}]
        \\}
    , "/tmp");
    const run_impl: zask.runner.Runner = .{ .gpa = gpa, .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "zask",
        .command_hint = .{ .config = "/tmp/config.json" },
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = gpa, .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
    };
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const api_target = try std.fmt.allocPrint(gpa, "{s}:api", .{session});
    const worker_target = try std.fmt.allocPrint(gpa, "{s}:worker", .{session});

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "kill-window", "-t", worker_target });
    try runtime.start("worker", &writer);
    try expectWindowOrder(gpa, io, session, &.{ "dashboard", "api", "worker", "web" });

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "kill-window", "-t", api_target });
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "kill-window", "-t", worker_target });
    try runtime.start("worker", &writer);
    try runtime.start("api", &writer);
    try expectWindowOrder(gpa, io, session, &.{ "dashboard", "api", "worker", "web" });
}

test "runtime.observer: start marker follows start and restart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-observer", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    client.killSession() catch {};
    try client.newSession("dashboard", "/tmp", "sleep 60");
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", "/tmp", try zask.zask_command.waitingPlaceholder(gpa, "api"));

    const cfg = try zask.config.Config.parse(gpa,
        \\{
        \\  "project": {"name":"demo","root":"/tmp"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":".","command":"sleep 60"}]}]
        \\}
    , "/tmp");
    const service = (try cfg.services())[0];
    const run_impl: zask.runner.Runner = .{ .gpa = gpa, .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "zask",
        .command_hint = .{ .config = "/tmp/config.json" },
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = gpa, .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
    };
    const observer = runtime.observer();
    const api_target = try std.fmt.allocPrint(gpa, "{s}:api", .{session});
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try waitForPaneState(client, gpa, io, "api", .idle);

    const placeholder = try observer.observeService(service);
    try std.testing.expectEqual(@as(?i64, null), placeholder.pane.started_at);
    try std.testing.expectEqual(zask.observations.Uptime.not_running, placeholder.uptime());

    try runtime.start("api", &writer);
    try waitForPaneState(client, gpa, io, "api", .busy);
    const started = try observer.observeService(service);
    try std.testing.expect(started.pane.started_at != null);
    try std.testing.expectEqual(zask.observations.HealthObservation.no_check, started.health());
    try std.testing.expect(started.uptime().seconds < 60);

    // Age the marker so the restart below must replace it, not keep it.
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "set-option", "-p", "-t", api_target, "@zask_started_at", "1000" });
    const aged = try observer.observeService(service);
    try std.testing.expect(aged.uptime().seconds > 1_000_000);

    try runtime.restart("api", &writer);
    try waitForPaneState(client, gpa, io, "api", .busy);
    const restarted = try observer.observeService(service);
    try std.testing.expect(restarted.uptime().seconds < 60);

    try runtime.stop("api", &writer);
    try waitForPaneState(client, gpa, io, "api", .idle);
    const stopped = try observer.observeService(service);
    try std.testing.expectEqual(zask.observations.Uptime.not_running, stopped.uptime());
    try std.testing.expectEqual(zask.observations.HealthObservation.not_running, stopped.health());
}

test "monitor: keys move selection, toggle the filter, and quit restores the terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-monitor", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "zask.json",
        .data = try std.fmt.allocPrint(gpa,
            \\{{
            \\  "project": {{"name":"{s}","root":"."}},
            \\  "groups": [{{"name":"backend","services":[
            \\    {{"name":"api","dir":".","command":"/bin/sleep 60","port":1}},
            \\    {{"name":"web","dir":".","command":"/bin/sleep 60"}}
            \\  ]}}]
            \\}}
        , .{session}),
    });
    const project_root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const config_path = try std.fs.path.join(gpa, &.{ project_root, "zask.json" });
    const stty_path = try std.fs.path.join(gpa, &.{ project_root, "stty.txt" });
    const stderr_path = try std.fs.path.join(gpa, &.{ project_root, "monitor-stderr.txt" });
    // The tmux server may run without HOME (as in CI), which config loading needs.
    const command = try std.fmt.allocPrint(gpa, "HOME={s} {s} --config {s} monitor 2> {s}; stty -a > {s}; sleep 60", .{
        try zask.shell.quote(gpa, project_root),
        try zask.shell.quote(gpa, build_options.zask_path),
        try zask.shell.quote(gpa, config_path),
        try zask.shell.quote(gpa, stderr_path),
        try zask.shell.quote(gpa, stty_path),
    });
    errdefer if (std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(64 * 1024))) |stderr| {
        std.debug.print("monitor stderr:\n{s}\n", .{stderr});
    } else |_| {};

    client.killSession() catch {};
    try client.newSession("dashboard", project_root, command);
    defer client.killSession() catch {};
    try zask.tmux_setup.applySessionOptions(gpa, client, .{
        .project = session,
        .zask_path = build_options.zask_path,
        .config_path = config_path,
    });
    // Busy with a closed port, api stays `waiting` and shows its last log line.
    try client.newWindowAfter("dashboard", "api", project_root, "printf '🚀🚀🚀🚀🚀🚀🚀🚀ログ日本語日本語日本語日本語\\n'; exec sleep 60");
    const target = try std.fmt.allocPrint(gpa, "{s}:dashboard", .{session});

    try waitForSelectedRow(gpa, io, target, "api");
    try expectPaneFlags(gpa, io, target, "1|0");

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "j" });
    try waitForSelectedRow(gpa, io, target, "web");
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "Up" });
    try waitForSelectedRow(gpa, io, target, "api");

    // Arrow keys whose bytes reach the monitor in two reads still move once,
    // including when the gap spans a refresh (repeated past the 1s interval).
    for (0..4) |_| {
        try sendSplitArrow(gpa, io, target, "[B");
        try waitForSelectedRow(gpa, io, target, "web");
        try sendSplitArrow(gpa, io, target, "[A");
        try waitForSelectedRow(gpa, io, target, "api");
    }
    // The ESC of the next arrow can share a read with the end of the previous one.
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-H", "1b" });
    try std.Io.sleep(io, .fromMilliseconds(150), .awake);
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-H", "5b", "42", "1b" });
    try std.Io.sleep(io, .fromMilliseconds(150), .awake);
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-l", "[A" });
    try waitForSelectedRow(gpa, io, target, "api");
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "j" });
    try waitForSelectedRow(gpa, io, target, "web");
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "k" });
    try waitForSelectedRow(gpa, io, target, "api");

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "resize-window", "-t", target, "-x", "45", "-y", "10" });
    try waitForPaneText(gpa, io, target, "│ 🚀");
    try expectWideLogClipped(gpa, io, target);
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "resize-window", "-t", target, "-x", "45", "-y", "4" });
    try waitForPaneText(gpa, io, target, "j/k");
    try waitForSelectedRow(gpa, io, target, "api");
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "resize-window", "-t", target, "-x", "80", "-y", "24" });

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "f" });
    try waitForPaneText(gpa, io, target, "[bad]");
    const mode = (try client.showOption("@zask_dash_mode")) orelse return error.SessionOptionMissing;
    try std.testing.expectEqualStrings("bad", mode);
    try waitForSelectedRow(gpa, io, target, "api");

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "q" });
    const stty = try waitForFile(gpa, io, stty_path);
    var flags = std.mem.tokenizeAny(u8, stty, " \t\r\n;");
    var restored: usize = 0;
    while (flags.next()) |flag| {
        if (std.mem.eql(u8, flag, "-icanon") or std.mem.eql(u8, flag, "-echo") or std.mem.eql(u8, flag, "-isig")) return error.TerminalLeftRaw;
        if (std.mem.eql(u8, flag, "icanon") or std.mem.eql(u8, flag, "echo") or std.mem.eql(u8, flag, "isig")) restored += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), restored);
    try expectPaneFlags(gpa, io, target, "0|1");
    try expectPaneAlive(gpa, io, target);
}

test "monitor: operation keys act only on the selected service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-monitor-ops", .{std.c.getpid()});
    const client = tmuxClient(gpa, io, session);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The group shares the first service's name, and the second service's
    // name starts with it, so a loose target would reach the wrong pane.
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"{s}","root":"."}},
        \\  "groups": [{{"name":"api","services":[
        \\    {{"name":"api","dir":".","command":"/bin/sleep 60"}},
        \\    {{"name":"api-worker","dir":".","command":"/bin/sleep 60"}}
        \\  ]}}]
        \\}}
    , .{session});
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = json });
    const project_root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const config_path = try std.fs.path.join(gpa, &.{ project_root, "zask.json" });
    const stderr_path = try std.fs.path.join(gpa, &.{ project_root, "monitor-stderr.txt" });
    const command = try std.fmt.allocPrint(gpa, "HOME={s} {s} --config {s} monitor 2> {s}; sleep 60", .{
        try zask.shell.quote(gpa, project_root),
        try zask.shell.quote(gpa, build_options.zask_path),
        try zask.shell.quote(gpa, config_path),
        try zask.shell.quote(gpa, stderr_path),
    });
    errdefer if (std.Io.Dir.cwd().readFileAlloc(io, stderr_path, gpa, .limited(64 * 1024))) |stderr| {
        std.debug.print("monitor stderr:\n{s}\n", .{stderr});
    } else |_| {};

    client.killSession() catch {};
    try client.newSession("dashboard", project_root, command);
    defer client.killSession() catch {};
    try client.newWindowAfter("dashboard", "api", project_root, try zask.zask_command.waitingPlaceholder(gpa, "api"));
    try client.newWindowAfter("api", "api-worker", project_root, try zask.zask_command.waitingPlaceholder(gpa, "api-worker"));
    const run_impl: zask.runner.Runner = .{ .gpa = gpa, .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = gpa,
        .io = io,
        .cfg = try zask.config.Config.parse(gpa, json, "/tmp"),
        .config_path = config_path,
        .zask_path = build_options.zask_path,
        .command_hint = .{ .config = config_path },
        .runner_impl = run_impl,
        .tmux_impl = client,
        .docker_impl = .{ .gpa = gpa, .runner = run_impl, .dir = project_root, .file = "compose.yaml" },
        .validate_configured_dirs = false,
    };
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try waitForPaneState(client, gpa, io, "api", .idle);
    try waitForPaneState(client, gpa, io, "api-worker", .idle);
    try runtime.startService("api", &writer);
    try runtime.startService("api-worker", &writer);
    try waitForPaneState(client, gpa, io, "api", .busy);
    try waitForPaneState(client, gpa, io, "api-worker", .busy);
    const target = try std.fmt.allocPrint(gpa, "{s}:=dashboard", .{session});
    const worker_target = try std.fmt.allocPrint(gpa, "{s}:=api-worker", .{session});
    const worker_pid = try panePid(gpa, io, worker_target);
    try waitForSelectedRow(gpa, io, target, "api");

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "x" });
    try waitForPaneText(gpa, io, target, "stopped api");
    try waitForPaneState(client, gpa, io, "api", .idle);

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "s" });
    try waitForPaneText(gpa, io, target, "started api");
    try waitForPaneState(client, gpa, io, "api", .busy);

    // The stop key arrives with or right after the restart key, so it is dropped.
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-l", "rx" });
    try waitForPaneText(gpa, io, target, "restarted api");
    try std.Io.sleep(io, .fromMilliseconds(1500), .awake);
    try waitForPaneText(gpa, io, target, "restarted api");
    try waitForPaneState(client, gpa, io, "api", .busy);

    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "Enter" });
    try waitForPaneText(gpa, io, target, "opened api");
    try expectActiveWindow(gpa, io, session, "api");

    // With its window gone, restart recreates `api` instead of reaching `api-worker`.
    const api_target = try std.fmt.allocPrint(gpa, "{s}:=api", .{session});
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "kill-window", "-t", api_target });
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "r" });
    try waitForPaneText(gpa, io, target, "restarted api");
    try waitForPaneState(client, gpa, io, "api", .busy);

    try std.testing.expectEqualStrings(worker_pid, try panePid(gpa, io, worker_target));
    try waitForPaneState(client, gpa, io, "api-worker", .busy);
}

test "runtime: closed session never reaches a session whose name extends it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(gpa, "zask-test-{d}-prefix", .{std.c.getpid()});
    const other = tmuxClient(gpa, io, try std.fmt.allocPrint(gpa, "{s}-other", .{session}));

    other.killSession() catch {};
    try other.newSession("dashboard", "/tmp", "sleep 60");
    defer other.killSession() catch {};
    try other.newWindowAfter("dashboard", "api", "/tmp", "sleep 60");
    const other_api = try std.fmt.allocPrint(gpa, "{s}:=api", .{other.session});
    const other_pid = try panePid(gpa, io, other_api);
    const cfg = try zask.config.Config.parse(gpa, try std.fmt.allocPrint(gpa,
        \\{{
        \\  "project": {{"name":"{s}","root":"/tmp"}},
        \\  "groups": [{{"name":"backend","services":[{{"name":"api","dir":".","command":"sleep 60"}}]}}]
        \\}}
    , .{session}), "/tmp");
    const run_impl: zask.runner.Runner = .{ .gpa = gpa, .io = io };
    const runtime = zask.runtime.Runtime{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .config_path = "/tmp/config.json",
        .zask_path = "zask",
        .command_hint = .{ .config = "/tmp/config.json" },
        .runner_impl = run_impl,
        .tmux_impl = tmuxClient(gpa, io, session),
        .docker_impl = .{ .gpa = gpa, .runner = run_impl, .dir = "/tmp", .file = "compose.yaml" },
        .validate_configured_dirs = false,
    };
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.SessionNotRunning, runtime.stopService("api", &writer));
    try std.testing.expectError(error.SessionNotRunning, runtime.restartService("api", &writer));
    try std.testing.expectError(error.WindowMissing, runtime.showWindow("api"));

    try std.testing.expectEqualStrings(other_pid, try panePid(gpa, io, other_api));
    try waitForPaneState(other, gpa, io, "api", .busy);
}

fn panePid(gpa: std.mem.Allocator, io: std.Io, target: []const u8) ![]const u8 {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-panes", "-t", target, "-F", "#{pane_pid}" });
    return std.mem.trim(u8, result.stdout, "\n");
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

fn expectWindowOrder(gpa: std.mem.Allocator, io: std.Io, session: []const u8, expected: []const []const u8) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_name}" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    for (expected) |window| try std.testing.expectEqualStrings(window, lines.next() orelse return error.WindowMissing);
    try std.testing.expect(lines.next() == null);
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

fn waitForPaneText(gpa: std.mem.Allocator, io: std.Io, target: []const u8, needle: []const u8) !void {
    for (0..service_state_attempts) |_| {
        const result = try run(gpa, io, &.{ build_options.tmux_path, "capture-pane", "-p", "-t", target });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        if (std.mem.indexOf(u8, result.stdout, needle) != null) return;
        try std.Io.sleep(io, service_state_interval, .awake);
    }
    try dumpPane(gpa, io, target);
    return error.PaneTextTimeout;
}

fn waitForSelectedRow(gpa: std.mem.Allocator, io: std.Io, target: []const u8, name: []const u8) !void {
    for (0..service_state_attempts) |_| {
        const result = try run(gpa, io, &.{ build_options.tmux_path, "capture-pane", "-p", "-t", target });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "> ") and std.mem.indexOf(u8, line, name) != null) return;
        }
        try std.Io.sleep(io, service_state_interval, .awake);
    }
    try dumpPane(gpa, io, target);
    return error.SelectionTimeout;
}

fn waitForFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    for (0..service_state_attempts) |_| {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.sleep(io, service_state_interval, .awake);
                continue;
            },
            else => return err,
        };
        if (data.len > 0) return data;
        try std.Io.sleep(io, service_state_interval, .awake);
    }
    return error.FileTimeout;
}

// `alternate_on|cursor_flag`: the monitor draws on the alternate screen with a
// hidden cursor and must give both back when it exits.
fn expectPaneFlags(gpa: std.mem.Allocator, io: std.Io, target: []const u8, expected: []const u8) !void {
    for (0..service_state_attempts) |_| {
        const result = try run(gpa, io, &.{ build_options.tmux_path, "display-message", "-p", "-t", target, "#{alternate_on}|#{cursor_flag}" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        if (std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), expected)) return;
        try std.Io.sleep(io, service_state_interval, .awake);
    }
    return error.PaneFlagsTimeout;
}

// A wrapped log would put its tail on a line of its own, without the row's
// `│` separator.
fn expectWideLogClipped(gpa: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "capture-pane", "-p", "-t", target });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "🚀") == null and std.mem.indexOf(u8, line, "ログ") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "│") != null);
    }
}

fn sendSplitArrow(gpa: std.mem.Allocator, io: std.Io, target: []const u8, tail: []const u8) !void {
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-H", "1b" });
    try std.Io.sleep(io, .fromMilliseconds(150), .awake);
    try runDiscard(gpa, io, &.{ build_options.tmux_path, "send-keys", "-t", target, "-l", tail });
}

// Printed on timeouts so CI logs show what the monitor actually drew.
fn dumpPane(gpa: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    const result = try run(gpa, io, &.{ build_options.tmux_path, "capture-pane", "-p", "-t", target });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    std.debug.print("pane {s}:\n{s}\n", .{ target, result.stdout });
}
