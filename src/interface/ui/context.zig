const std = @import("std");
const config = @import("../../model/config.zig");
const proc_runner = @import("../../platform/runner.zig");
const service_observation = @import("../../workflow/service_observation.zig");
const tmux_client = @import("../../platform/tmux.zig");

pub const RenderContext = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,

    pub fn observer(self: RenderContext) service_observation.Observer {
        return .{
            .gpa = self.gpa,
            .runner = self.runner,
            .tmux = self.tmux,
            .docker = .{
                .gpa = self.gpa,
                .runner = self.runner,
                .dir = self.cfg.dockerSubdir(),
                .file = self.cfg.dockerComposeFile(),
            },
        };
    }
};
