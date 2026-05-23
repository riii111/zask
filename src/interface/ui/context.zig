const std = @import("std");
const config = @import("../../model/config.zig");
const proc_runner = @import("../../platform/runner.zig");
const tmux_client = @import("../../platform/tmux.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
};
