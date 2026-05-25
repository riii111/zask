const std = @import("std");
const config = @import("../../model/config.zig");
const docker_client = @import("../../platform/docker.zig");
const env = @import("../../platform/env.zig");
const proc_runner = @import("../../platform/runner.zig");
const tmux_client = @import("../../platform/tmux.zig");
const Context = @import("context.zig").Context;
const Runtime = @import("../../workflow/runtime.zig").Runtime;

pub const Options = struct {
    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 0) return error.InvalidArguments;
        return .{};
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    _ = opts;
    const rt = try ctx.runtime();
    const services = try rt.cfg.services();
    try ctx.writer.print("{s}\n", .{try rt.cfg.projectName()});
    for (services) |service| {
        try ctx.writer.print("- {s}", .{try config.Config.serviceName(service)});
        const group = config.Config.serviceGroup(service);
        if (group.len != 0) try ctx.writer.print(" [{s}]", .{group});
        if (config.Config.servicePort(service)) |port| try ctx.writer.print(" :{d}", .{port});
        try ctx.writer.writeByte('\n');
    }
    if (rt.cfg.dockerEnabled()) try ctx.writer.writeAll("- docker\n");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options reject arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}

test "list.run: prints services and docker section" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "dir": "infra", "compose_file": "compose.yaml"},
        \\  "services": [
        \\    {"name":"api","dir":"backend","command":"serve","port":18080,"group":"backend"},
        \\    {"name":"worker","dir":"backend","command":"work","group":"backend"}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("HOME", "/home/me");
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const gpa = arena.allocator();
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    const run_impl = proc_runner.Runner{ .gpa = gpa, .io = threaded.io() };
    var ctx: Context = .{
        .base = .{ .gpa = gpa, .io = threaded.io(), .environ = &environ },
        .parsed = .{ .command = "list", .project = "demo", .args = &.{} },
        .writer = &writer,
        .print_help = testPrintHelp,
        .runtime_value = Runtime{
            .gpa = gpa,
            .io = threaded.io(),
            .environ = &environ,
            .cfg = cfg,
            .config_path = "/tmp/config.json",
            .zask_path = "zask",
            .runner_impl = run_impl,
            .tmux_impl = tmux_client.Client{ .gpa = gpa, .runner = run_impl, .session = "demo" },
            .docker_impl = docker_client.Compose{ .gpa = gpa, .runner = run_impl, .dir = "/tmp/demo/infra", .file = "compose.yaml" },
        },
    };

    try run(&ctx, .{});
    try std.testing.expectEqualStrings(
        \\demo
        \\- api [backend] :18080
        \\- worker [backend]
        \\- docker
        \\
    , writer.buffered());
}

fn testPrintHelp(writer: *std.Io.Writer) !void {
    _ = writer;
}
