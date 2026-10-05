const std = @import("std");

const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const tmux_client = @import("../platform/tmux.zig");
const tmux_options = @import("../model/tmux_options.zig");

pub const SessionOptions = struct {
    project: []const u8,
    zask_path: []const u8,
    config_path: []const u8,
};

pub fn applySessionOptions(gpa: std.mem.Allocator, tx: tmux_client.Client, opts: SessionOptions) !void {
    try tx.setOption("prefix", "C-q");
    try tx.setOption("status-left", try std.fmt.allocPrint(gpa, "[{s}] Ctrl+q w:list | ':number | z:zoom | [:scroll | d:detach ", .{opts.project}));
    try tx.setOption("status-left-length", "80");
    try tx.setOption("status-right", "");
    try tx.setOption("remain-on-exit", "on");
    try tx.setOption("automatic-rename", "off");
    try tx.setOption("status-format[0]", "#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}");
    try tx.setOption(tmux_options.dash_mode, tmux_options.dash_mode_all);
    try tx.setOption(tmux_options.zask_path, opts.zask_path);
    try tx.setOption(tmux_options.config_path, opts.config_path);
    try bindClientSizeHooks(gpa, tx);
}

pub fn bindClientSizeHooks(gpa: std.mem.Allocator, tx: tmux_client.Client) !void {
    try tx.setHook("client-active", try syncSizeCommand(gpa));
}

pub fn bindControlKeys(gpa: std.mem.Allocator, tx: tmux_client.Client) !void {
    try tx.bindRunShell("w", try std.fmt.allocPrint(gpa,
        \\session="#{{session_name}}";
        \\zask=$(tmux show-option -t "$session" -qv {s});
        \\config=$(tmux show-option -t "$session" -qv {s});
        \\"$zask" --config "$config" preview-list "#{{pane_id}}" "#{{client_width}}" "#{{client_height}}"
    , .{ tmux_options.zask_path, tmux_options.config_path }));
    try tx.bindRunShell("m", try std.fmt.allocPrint(gpa,
        \\session="#{{session_name}}";
        \\mode=$(tmux show-option -t "$session" -qv {[opt]s});
        \\if [ "$mode" = "{[all]s}" ]; then
        \\  tmux set-option -t "$session" {[opt]s} {[bad]s};
        \\else
        \\  tmux set-option -t "$session" {[opt]s} {[all]s};
        \\fi
    , .{ .opt = tmux_options.dash_mode, .all = tmux_options.dash_mode_all, .bad = tmux_options.dash_mode_bad }));
    try bindTreeNavigation(gpa, tx);
}

const tree_moves = [_]struct { key: []const u8, tree_key: []const u8 }{
    .{ .key = "C-v", .tree_key = "NPage" },
    .{ .key = "M-v", .tree_key = "PPage" },
    .{ .key = "M-<", .tree_key = "Home" },
    .{ .key = "M->", .tree_key = "End" },
};

const zask_tree_condition = "#{&&:#{==:#{pane_mode},tree-mode},#{" ++ tmux_options.zask_path ++ "}}";

pub fn bindTreeNavigation(gpa: std.mem.Allocator, tx: tmux_client.Client) !void {
    for (tree_moves) |move| {
        if (try tx.rootKeyBinding(move.key)) |existing| {
            defer tx.gpa.free(existing);
            if (std.mem.indexOf(u8, existing, tmux_options.zask_path) == null) continue;
        }
        const in_tree = try std.fmt.allocPrint(gpa, "send-keys {s}", .{move.tree_key});
        const elsewhere = try std.fmt.allocPrint(gpa, "send-keys {s}", .{move.key});
        try tx.bindRootKey(move.key, &.{ "if-shell", "-F", zask_tree_condition, in_tree, elsewhere });
    }
}

pub fn toggleDashMode(tx: tmux_client.Client) !tmux_options.DashMode {
    const current = try tx.showOption(tmux_options.dash_mode);
    defer if (current) |value| tx.gpa.free(value);
    const next = tmux_options.DashMode.parse(current).toggled();
    try tx.setOption(tmux_options.dash_mode, next.optionValue());
    return next;
}

fn syncSizeCommand(gpa: std.mem.Allocator) ![]const u8 {
    const command = try std.fmt.allocPrint(gpa,
        \\session="#{{session_name}}";
        \\zask=$(tmux show-option -t "$session" -qv {s});
        \\config=$(tmux show-option -t "$session" -qv {s});
        \\"$zask" --config "$config" sync-size "#{{client_width}}" "#{{client_height}}"
    , .{ tmux_options.zask_path, tmux_options.config_path });
    const quoted = try shell.quote(gpa, command);
    return try std.fmt.allocPrint(gpa, "run-shell {s}", .{quoted});
}

test "tmux_setup.bindControlKeys: list binding delegates preview sizing to zask command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try bindControlKeys(arena.allocator(), tx);

    const command = recorder.commands.items[0];
    try proc_runner.expectCommandArg(command, 1, "bind-key");
    try proc_runner.expectCommandArg(command, 4, "w");
    try proc_runner.expectCommandArg(command, 5, "run-shell");
    try proc_runner.expectCommandArgContains(command, 6, "preview-list");
    try proc_runner.expectCommandArgContains(command, 6, "#{pane_id}");
    try proc_runner.expectCommandArgContains(command, 6, "#{client_width}");
    try proc_runner.expectCommandArgContains(command, 6, "#{client_height}");
    try proc_runner.expectCommandArgNotContains(command, 6, "resize-window");
    try proc_runner.expectCommandArgNotContains(command, 6, "choose-tree");
}

test "tmux_setup.bindTreeNavigation: binds window list moves only for zask sessions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    for (tree_moves) |_| {
        try recorder.enqueue("", "", .{ .exited = 0 });
        try recorder.enqueue("", "", .{ .exited = 0 });
    }
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try bindTreeNavigation(arena.allocator(), tx);

    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "tmux", "bind-key", "-T", "root", "C-v", "if-shell", "-F", "#{&&:#{==:#{pane_mode},tree-mode},#{@zask_path}}", "send-keys NPage", "send-keys C-v" });
    try proc_runner.expectCommandArgv(recorder.commands.items[3], &.{ "tmux", "bind-key", "-T", "root", "M-v", "if-shell", "-F", "#{&&:#{==:#{pane_mode},tree-mode},#{@zask_path}}", "send-keys PPage", "send-keys M-v" });
    try proc_runner.expectCommandArgv(recorder.commands.items[5], &.{ "tmux", "bind-key", "-T", "root", "M-<", "if-shell", "-F", "#{&&:#{==:#{pane_mode},tree-mode},#{@zask_path}}", "send-keys Home", "send-keys M-<" });
    try proc_runner.expectCommandArgv(recorder.commands.items[7], &.{ "tmux", "bind-key", "-T", "root", "M->", "if-shell", "-F", "#{&&:#{==:#{pane_mode},tree-mode},#{@zask_path}}", "send-keys End", "send-keys M->" });
    try proc_runner.expectNoRemainingResponses(&recorder);
}

test "tmux_setup.bindTreeNavigation: keeps a root binding the user made" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const table = "bind-key -T root C-v send-keys -l hello\nbind-key -T root M-v if-shell -F \"#{&&:#{==:#{pane_mode},tree-mode},#{@zask_path}}\" { send-keys PPage } { send-keys M-v }\n";
    for (tree_moves) |_| try recorder.enqueue(table, "", .{ .exited = 0 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try bindTreeNavigation(arena.allocator(), tx);

    var bound: std.ArrayList([]const u8) = .empty;
    for (recorder.commands.items) |command| {
        if (std.mem.eql(u8, command.argv[1], "bind-key")) try bound.append(arena.allocator(), command.argv[4]);
    }
    try std.testing.expectEqual(@as(usize, 3), bound.items.len);
    for (bound.items) |key| try std.testing.expect(!std.mem.eql(u8, key, "C-v"));
}

test "tmux_setup.bindClientSizeHooks: runs sync command when client becomes active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try bindClientSizeHooks(arena.allocator(), tx);

    try proc_runner.expectCommandContaining(&recorder, "client-active");
    try proc_runner.expectCommandContaining(&recorder, "run-shell");
    try proc_runner.expectCommandContaining(&recorder, "sync-size");
    try proc_runner.expectCommandContaining(&recorder, "#{client_width}");
    try proc_runner.expectCommandContaining(&recorder, "#{client_height}");
}

test "tmux_setup.applySessionOptions: seeds prefix and dash mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try applySessionOptions(arena.allocator(), tx, .{ .project = "demo", .zask_path = "zask", .config_path = "/tmp/config.json" });

    const prefix = proc_runner.findCommandContaining(&recorder, "prefix") orelse return error.MissingPrefixOption;
    try proc_runner.expectCommandArg(prefix, 4, "prefix");
    try proc_runner.expectCommandArg(prefix, 5, "C-q");
    const dash = proc_runner.findCommandContaining(&recorder, tmux_options.dash_mode) orelse return error.MissingDashModeOption;
    try proc_runner.expectCommandArg(dash, 4, tmux_options.dash_mode);
    try proc_runner.expectCommandArg(dash, 5, tmux_options.dash_mode_all);
}

test "tmux_setup.toggleDashMode: flips the current session option" {
    const cases = [_]struct { current: []const u8, expected: tmux_options.DashMode }{
        .{ .current = "all\n", .expected = .bad },
        .{ .current = "bad\n", .expected = .all },
        .{ .current = "", .expected = .bad },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var recorder = proc_runner.Recorder.init(arena.allocator());
        defer recorder.deinit();
        try recorder.enqueue(case.current, "", .{ .exited = 0 });
        try recorder.enqueue("", "", .{ .exited = 0 });
        const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
        const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

        const next = try toggleDashMode(tx);

        try std.testing.expectEqual(case.expected, next);
        const set = proc_runner.findCommandContaining(&recorder, "set-option") orelse return error.MissingSetOption;
        try proc_runner.expectCommandArg(set, 4, tmux_options.dash_mode);
        try proc_runner.expectCommandArg(set, 5, case.expected.optionValue());
    }
}

test "tmux_setup.toggleDashMode: reports a failed option write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = proc_runner.Recorder.init(arena.allocator());
    defer recorder.deinit();
    try recorder.enqueue("all\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "no server running", .{ .exited = 1 });
    const run = proc_runner.Runner{ .gpa = arena.allocator(), .io = undefined, .recorder = &recorder };
    const tx = tmux_client.Client{ .gpa = arena.allocator(), .runner = run, .session = "demo" };

    try std.testing.expectError(error.CommandFailed, toggleDashMode(tx));
}
