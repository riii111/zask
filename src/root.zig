const std = @import("std");

pub const cli = @import("interface/cli.zig");
pub const config = @import("model/config.zig");
pub const config_value = @import("model/config_value.zig");
pub const diagnostics = @import("model/diagnostics.zig");
pub const dashboard = @import("interface/ui/dashboard.zig");
pub const docker = @import("platform/docker.zig");
pub const lifecycle = @import("workflow/lifecycle.zig");
pub const init_inference = @import("workflow/init_inference.zig");
pub const lock = @import("platform/lock.zig");
pub const observations = @import("model/observations.zig");
pub const phases = @import("workflow/phases.zig");
pub const paths = @import("platform/paths.zig");
pub const process = @import("platform/process.zig");
pub const runner = @import("platform/runner.zig");
pub const runtime = @import("workflow/runtime.zig");
pub const shell = @import("platform/shell.zig");
pub const tmux = @import("platform/tmux.zig");
pub const tmux_setup = @import("workflow/tmux_setup.zig");
pub const validate = @import("model/validate.zig");
pub const waits = @import("workflow/waits.zig");
pub const zask_command = @import("workflow/zask_command.zig");

pub fn greeting() []const u8 {
    return "Hello from zask";
}

test "root.greeting: returns the hello world message" {
    try std.testing.expectEqualStrings("Hello from zask", greeting());
}

test {
    std.testing.refAllDecls(@This());
}
