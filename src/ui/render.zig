const std = @import("std");
const config = @import("../config.zig");
const shell = @import("../infra/shell.zig");
const yaml = @import("../infra/yaml.zig");

pub fn renderTmuxp(cfg: config.Config, gpa: std.mem.Allocator, writer: *std.Io.Writer, zask_path: []const u8, config_path: []const u8) !void {
    const project = try cfg.projectName();
    const root = try cfg.projectRoot(gpa);
    const quoted_zask_path = try shell.quote(gpa, zask_path);
    const quoted_config_path = try shell.quote(gpa, config_path);
    const dashboard_command = try yaml.quote(gpa, try std.fmt.allocPrint(gpa, "{s} --config {s} dashboard", .{ quoted_zask_path, quoted_config_path }));
    const monitor_command = try yaml.quote(gpa, try std.fmt.allocPrint(gpa, "{s} --config {s} monitor", .{ quoted_zask_path, quoted_config_path }));
    try writer.print(
        \\session_name: {s}
        \\start_directory: {s}
        \\
        \\options:
        \\  prefix: C-q
        \\  status-left: "[{s}] Ctrl+q w:list | f:follow | ':number | z:zoom | [:scroll | d:detach "
        \\  status-left-length: 80
        \\  status-right: ""
        \\  remain-on-exit: on
        \\  automatic-rename: off
        \\
        \\windows:
        \\  - window_name: dashboard
        \\    layout: main-vertical
        \\    options:
        \\      main-pane-width: 50%
        \\    panes:
        \\      - shell_command:
        \\          - {s}
        \\      - shell_command:
        \\          - {s}
        \\
    , .{ try cfg.sessionName(), root, project, dashboard_command, monitor_command });

    for (try cfg.services()) |service| {
        const name = try config.Config.serviceName(service);
        const dir = try cfg.serviceDir(gpa, service);
        try writer.print(
            \\  - window_name: {s}
            \\    start_directory: {s}
            \\    panes:
            \\      - shell_command:
            \\          - echo "=== {s} ===" && echo "Waiting for start command..."
            \\
        , .{ name, dir, name });
    }

    if (cfg.dockerEnabled()) {
        try writer.print(
            \\  - window_name: docker
            \\    start_directory: {s}
            \\    panes:
            \\      - shell_command:
            \\          - echo "=== Docker Services ===" && echo "Waiting for start command..."
            \\
        , .{try cfg.dockerDir(gpa)});
    }
}

test "renders service and docker windows" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true},
        \\  "services": [{"name":"api","dir":"backend","command":"serve","group":"be"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderTmuxp(cfg, arena.allocator(), &out.writer, "zask path", "/tmp/demo config.json");
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "window_name: dashboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "'''zask path'' --config ''/tmp/demo config.json'' dashboard'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "'''zask path'' --config ''/tmp/demo config.json'' monitor'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "window_name: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "start_directory: /tmp/demo/backend") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "window_name: docker") != null);
}
