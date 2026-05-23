const std = @import("std");

const tmux_client = @import("../platform/tmux.zig");
const tmux_options = @import("../model/tmux_options.zig");

pub fn applySessionOptions(tx: tmux_client.Client, zask_path: []const u8, config_path: []const u8) !void {
    try tx.setOption("prefix", "C-q");
    try tx.setOption("status-format[0]", "#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}");
    try tx.setOption(tmux_options.dash_mode, "all");
    try tx.setOption(tmux_options.zask_path, zask_path);
    try tx.setOption(tmux_options.config_path, config_path);
}

pub fn bindControlKeys(gpa: std.mem.Allocator, tx: tmux_client.Client) !void {
    try tx.bindRunShell("m", try std.fmt.allocPrint(gpa,
        \\session="#{{session_name}}";
        \\mode=$(tmux show-option -t "$session" -qv {s});
        \\if [ "$mode" = "all" ]; then
        \\  tmux set-option -t "$session" {s} bad;
        \\else
        \\  tmux set-option -t "$session" {s} all;
        \\fi
    , .{ tmux_options.dash_mode, tmux_options.dash_mode, tmux_options.dash_mode }));
    try tx.bindRunShell("f", try std.fmt.allocPrint(gpa,
        \\session="#{{session_name}}";
        \\zask=$(tmux show-option -t "$session" -qv {s});
        \\config=$(tmux show-option -t "$session" -qv {s});
        \\"$zask" --config "$config" follow "#{{window_name}}"
    , .{ tmux_options.zask_path, tmux_options.config_path }));
}
