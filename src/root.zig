const std = @import("std");

pub const cli = @import("interface/cli.zig");
pub const clock = @import("platform/clock.zig");
pub const config = @import("model/config.zig");
pub const config_schema = @import("workflow/config_schema.zig");
pub const config_edit = @import("model/config_edit.zig");
pub const config_value = @import("model/config_value.zig");
pub const diagnostics = @import("model/diagnostics.zig");
pub const dashboard = @import("interface/ui/dashboard.zig");
pub const docker = @import("platform/docker.zig");
pub const lifecycle = @import("workflow/lifecycle.zig");
pub const init_inference = @import("workflow/init_inference.zig");
pub const jsonc = @import("model/jsonc.zig");
pub const file_scan = @import("platform/file_scan.zig");
pub const file_swap = @import("platform/file_swap.zig");
pub const file_watch = @import("workflow/file_watch.zig");
pub const lock = @import("platform/lock.zig");
pub const observations = @import("model/observations.zig");
pub const phases = @import("workflow/phases.zig");
pub const paths = @import("platform/paths.zig");
pub const procfile = @import("workflow/procfile.zig");
pub const process_probe = @import("platform/process_probe.zig");
pub const readiness_wait = @import("workflow/readiness_wait.zig");
pub const runner = @import("platform/runner.zig");
pub const runtime = @import("workflow/runtime.zig");
pub const service_observation = @import("workflow/service_observation.zig");
pub const service_add = @import("workflow/service_add.zig");
pub const shell = @import("platform/shell.zig");
pub const terminal = @import("platform/terminal.zig");
pub const tmux = @import("platform/tmux.zig");
pub const tmux_setup = @import("workflow/tmux_setup.zig");
pub const validate = @import("model/validate.zig");
pub const watch = @import("model/watch.zig");
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
