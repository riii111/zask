const std = @import("std");
const config = @import("../config.zig");
const proc_runner = @import("../infra/runner.zig");
const tmux_client = @import("../infra/tmux.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
};
