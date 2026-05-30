const std = @import("std");
const ansi = @import("ansi.zig");
const config = @import("../../model/config.zig");
const env = @import("../../platform/env.zig");
const monitor = @import("monitor.zig");
const proc_runner = @import("../../platform/runner.zig");
const tmux_client = @import("../../platform/tmux.zig");
const Context = @import("context.zig").Context;

pub fn runLauncher(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map, cfg: config.Config, writer: *std.Io.Writer) !void {
    const run: proc_runner.Runner = .{ .gpa = gpa, .io = io };
    const ctx: Context = .{ .gpa = gpa, .cfg = cfg, .runner = run, .tmux = .{ .gpa = gpa, .runner = run, .session = try cfg.sessionName() } };
    try writer.writeAll(ansi.clear_screen);
    try renderLauncher(ctx, writer);
    try writer.flush();
    const shell = env.get(environ, "SHELL") orelse "sh";
    _ = try ctx.runner.run(&.{shell}, .{ .interactive = true });
}

pub fn runMonitor(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, writer: *std.Io.Writer) !void {
    try monitor.run(gpa, io, cfg, writer);
}

const reset = ansi.reset;
const bold = ansi.bold;
const dim = ansi.dim;
const green = ansi.green;
const yellow = ansi.yellow;
const blue = ansi.blue;
const cyan = ansi.cyan;
const launcher_width = 46;
const service_name_width = 15;
const service_port_width = 6;

fn renderLauncher(ctx: Context, writer: *std.Io.Writer) !void {
    try writer.writeAll("\n");
    const title = try std.fmt.allocPrint(ctx.gpa, "{s} - Development TUI", .{try ctx.cfg.projectName()});
    try writer.print("{s}{s}", .{ bold, cyan });
    try writeRule(writer, "╔", "═", "╗", launcher_width);
    try writer.print("{s}\n", .{reset});
    try writer.print("{s}{s}║", .{ bold, cyan });
    try writeCentered(writer, title, launcher_width);
    try writer.print("║{s}\n", .{reset});
    try writer.print("{s}{s}", .{ bold, cyan });
    try writeRule(writer, "╚", "═", "╝", launcher_width);
    try writer.print("{s}\n\n", .{reset});

    try writer.print("{s}Navigate: {s}{s}Ctrl+q w{s}{s} (list) {s}{s}Ctrl+q '{s}{s} (number) {s}{s}Ctrl+q m{s}{s} (toggle){s}\n\n", .{ dim, reset, bold, reset, dim, reset, bold, reset, dim, reset, bold, reset, dim, reset });

    if (ctx.cfg.dockerEnabled()) {
        try writer.print("{s}{s}[docker]{s}\n", .{ bold, blue, reset });
        try writer.print("  {s}", .{green});
        try writePadded(writer, "docker", service_name_width);
        try writer.print("{s} {s}", .{ reset, dim });
        try writePadded(writer, "compose", 7);
        try writer.print("{s}  docker compose up\n\n", .{reset});
    }

    const groups = try serviceGroups(ctx);
    defer ctx.gpa.free(groups);
    for (groups) |group| {
        try writer.print("{s}{s}[{s}]{s}\n", .{ bold, yellow, group, reset });
        for (try ctx.cfg.services()) |service| {
            if (!std.mem.eql(u8, config.Config.serviceGroup(service), group)) continue;
            const name = try config.Config.serviceName(service);
            const port = config.Config.servicePort(service);
            const command = try config.Config.serviceStartCommand(ctx.gpa, service);
            try writer.print("  {s}", .{green});
            try writePadded(writer, name, service_name_width);
            try writer.print("{s} {s}", .{ reset, dim });
            if (port) |p| {
                const port_text = try std.fmt.allocPrint(ctx.gpa, ":{d}", .{p});
                try writePadded(writer, port_text, service_port_width);
            } else {
                try writePadded(writer, ":N/A", service_port_width);
            }
            try writer.print("{s}  {s}\n", .{ reset, command });
        }
        try writer.writeAll("\n");
    }

    try writer.print("{s}", .{dim});
    try writeRule(writer, "", "─", "", launcher_width + 2);
    try writer.print("{s}\n", .{reset});
    try writer.print("{s}Commands:{s}\n", .{ bold, reset });
    const project = try ctx.cfg.projectName();
    try writeCommandHelp(writer, project);
    try writer.writeByte('\n');
}

const LauncherCommand = struct {
    usage: []const u8,
    description: []const u8,
};

const launcher_commands = [_]LauncherCommand{
    .{ .usage = "open", .description = "Open workspace and attach" },
    .{ .usage = "open --<profile>", .description = "Open configured profile" },
    .{ .usage = "open --docker", .description = "Open docker only" },
    .{ .usage = "close", .description = "Stop resources and close workspace" },
    .{ .usage = "re", .description = "Restart session" },
    .{ .usage = "attach", .description = "Attach to existing workspace" },
    .{ .usage = "start <svc|group|docker>", .description = "Start a resource" },
    .{ .usage = "start --all", .description = "Start all resources" },
    .{ .usage = "stop <svc|group|docker>", .description = "Stop a resource" },
    .{ .usage = "stop --all", .description = "Stop all resources" },
    .{ .usage = "restart <svc|group|docker>", .description = "Restart a resource" },
    .{ .usage = "logs <svc>", .description = "Jump to window" },
    .{ .usage = "status", .description = "Show all status" },
};

fn writeCommandHelp(writer: *std.Io.Writer, project: []const u8) !void {
    const usage_width = launcherCommandWidth(project);
    for (launcher_commands) |command| {
        try writer.print("  {s}{s} {s}{s}", .{ green, project, command.usage, reset });
        try writeSpaces(writer, usage_width - project.len - 1 - command.usage.len + 2);
        try writer.print("{s}\n", .{command.description});
    }
}

fn launcherCommandWidth(project: []const u8) usize {
    var width: usize = 0;
    for (launcher_commands) |command| {
        width = @max(width, project.len + 1 + command.usage.len);
    }
    return width;
}

fn serviceGroups(ctx: Context) ![][]const u8 {
    var groups: std.ArrayList([]const u8) = .empty;
    errdefer groups.deinit(ctx.gpa);
    for (try ctx.cfg.services()) |service| {
        const group = config.Config.serviceGroup(service);
        var seen = false;
        for (groups.items) |item| {
            if (std.mem.eql(u8, item, group)) {
                seen = true;
                break;
            }
        }
        if (!seen) try groups.append(ctx.gpa, group);
    }
    return groups.toOwnedSlice(ctx.gpa);
}

fn writeCentered(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const text_width = text.len;
    if (text_width >= width) {
        try writer.writeAll(text);
        return;
    }
    const left = (width - text_width) / 2;
    const right = width - text_width - left;
    try writeSpaces(writer, left);
    try writer.writeAll(text);
    try writeSpaces(writer, right);
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writeSpaces(writer, width - text.len);
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
}

fn writeRule(writer: *std.Io.Writer, left: []const u8, fill: []const u8, right: []const u8, width: usize) !void {
    try writer.writeAll(left);
    var i: usize = 0;
    while (i < width) : (i += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
}

test "dashboard.renderLauncher: renders launcher frame with grouped services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml"},
        \\  "groups": [
        \\    {"name":"backend","services":[
        \\      {"name":"api","dir":"backend","command":"serve","port":18080}
        \\    ]},
        \\    {"name":"frontend","services":[
        \\      {"name":"web","dir":"frontend","runtime":"npm","command":"run dev"}
        \\    ]}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const ctx: Context = .{
        .gpa = arena.allocator(),
        .cfg = cfg,
        .runner = .{ .gpa = arena.allocator(), .io = undefined },
        .tmux = .{ .gpa = arena.allocator(), .runner = .{ .gpa = arena.allocator(), .io = undefined }, .session = "demo" },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try renderLauncher(ctx, &out.writer);
    const body = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, body, "demo - Development TUI") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[docker]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[backend]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ":18080") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "npm run dev") != null);
}
