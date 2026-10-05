const std = @import("std");
const config = @import("../model/config.zig");

pub const dashboard_window = "dashboard";
pub const dashboard_pane_width_option = "main-pane-width";
pub const dashboard_pane_width_value = "50%";
pub const dashboard_layout = "main-vertical";

pub const docker_window = "docker";
pub const docker_placeholder_title = "Docker Services";

pub const watch_window = "zask-watch";

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "session_layout.watch_window: is reserved from service names" {
    for (config.reserved_service_names) |name| {
        if (std.mem.eql(u8, name, watch_window)) return;
    }
    return error.WatchWindowNotReserved;
}
