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
