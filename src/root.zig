const std = @import("std");

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const config_value = @import("config_value.zig");
pub const dashboard = @import("ui/dashboard.zig");
pub const docker = @import("infra/docker.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const lock = @import("infra/lock.zig");
pub const log_session = @import("log_session.zig");
pub const observations = @import("observations.zig");
pub const phases = @import("phases.zig");
pub const paths = @import("infra/paths.zig");
pub const render = @import("ui/render.zig");
pub const runner = @import("infra/runner.zig");
pub const runtime = @import("runtime.zig");
pub const shell = @import("infra/shell.zig");
pub const tmux = @import("infra/tmux.zig");
pub const tmux_setup = @import("tmux_setup.zig");
pub const validate = @import("validate.zig");
pub const waits = @import("waits.zig");
pub const yaml = @import("infra/yaml.zig");

pub fn greeting() []const u8 {
    return "Hello from zask";
}

test "greeting returns the hello world message" {
    try std.testing.expectEqualStrings("Hello from zask", greeting());
}

test {
    std.testing.refAllDecls(@This());
}
