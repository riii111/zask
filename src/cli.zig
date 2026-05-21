const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");
const config = @import("config.zig");
const Runtime = @import("runtime.zig").Runtime;
const runtime = @import("runtime.zig");

const ParsedArgs = struct {
    config_path: ?[]const u8 = null,
    project: ?[]const u8 = null,
    command: []const u8,
    args: []const []const u8,
};

pub const CommandContext = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    argv0: []const u8 = "zask",
};

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const context: CommandContext = .{
        .gpa = arena,
        .io = init.io,
        .argv0 = if (args.len > 0) args[0] else "zask",
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try runWithArgs(context, if (args.len > 1) args[1..] else &.{}, stdout);
    try stdout.flush();
}

pub fn runWithArgs(context: CommandContext, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len == 0) {
        return printGreeting(writer);
    }

    const parsed = try parseArgs(context, args);
    const command = parsed.command;
    if (std.mem.eql(u8, command, "version")) {
        return printVersion(writer);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        return printHelp(writer);
    }
    const rt = try loadRuntime(context, parsed);
    if (std.mem.eql(u8, command, "render-session")) return rt.renderSession(writer);
    if (std.mem.eql(u8, command, "list")) return rt.list(writer);
    if (std.mem.eql(u8, command, "status")) return rt.status(writer);
    if (std.mem.eql(u8, command, "attach")) return rt.attach();
    if (std.mem.eql(u8, command, "detach")) return rt.detach(writer);
    if (std.mem.eql(u8, command, "logs")) return rt.logs(try oneArg(parsed.args, "logs"));
    if (std.mem.eql(u8, command, "follow")) return rt.follow(try oneArg(parsed.args, "follow"), writer);
    if (std.mem.eql(u8, command, "hello")) return rt.hello(try resolveHelloProfile(rt.cfg, parsed.args), writer);
    if (std.mem.eql(u8, command, "bye")) return rt.bye(writer);
    if (std.mem.eql(u8, command, "kill")) return rt.kill(writer);
    if (std.mem.eql(u8, command, "re")) {
        try rt.bye(writer);
        return rt.hello("all", writer);
    }
    if (std.mem.eql(u8, command, "up")) return rt.up(if (parsed.args.len > 0) parsed.args[0] else null, writer);
    if (std.mem.eql(u8, command, "stop")) return rt.stop(if (parsed.args.len > 0) parsed.args[0] else null, writer);
    if (std.mem.eql(u8, command, "restart")) return rt.restart(try oneArg(parsed.args, "restart"), writer);
    if (std.mem.eql(u8, command, "exec")) return rt.exec(try oneArg(parsed.args, "exec"), parsed.args.len > 1 and std.mem.eql(u8, parsed.args[1], "--shell"), writer);
    if (std.mem.eql(u8, command, "dashboard")) return rt.dashboard(writer);
    if (std.mem.eql(u8, command, "monitor")) return rt.monitorOnce(writer);

    return error.UnknownCommand;
}

fn printGreeting(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{root.greeting()});
}

fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("zask {s}\n", .{build_options.version});
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zask <command>
        \\
        \\Commands:
        \\  hello [--docker|--<profile>] Start session + services + attach
        \\  bye                         Graceful shutdown
        \\  re                          Restart session
        \\  attach | detach | kill       Manage tmux session
        \\  up [--all|docker|name]       Start service, group, docker, or all
        \\  stop [--all|docker|name]     Stop service, group, docker, or all
        \\  restart <docker|name>        Restart service, group, or docker
        \\  status | list                Show service state or config services
        \\  logs <service>               Focus service window
        \\  follow <service>             Tail captured log in tmux popup
        \\  exec <container> [--shell]   Enter Docker container
        \\  render-session               Print generated tmuxp YAML
        \\  version                      Print zask version
        \\  help                         Print this help
        \\
    );
}

fn parseArgs(context: CommandContext, args: []const []const u8) !ParsedArgs {
    const basename = std.fs.path.basename(context.argv0);
    if (!std.mem.eql(u8, basename, "zask") and !std.mem.eql(u8, basename, "zask-debug")) {
        return .{ .project = basename, .command = args[0], .args = args[1..] };
    }
    if (std.mem.eql(u8, args[0], "--config")) {
        if (args.len < 3) return error.InvalidArguments;
        return .{ .config_path = args[1], .command = args[2], .args = args[3..] };
    }
    if (isGlobalCommand(args[0])) return .{ .command = args[0], .args = args[1..] };
    if (args.len < 2) return error.ProjectRequired;
    return .{ .project = args[0], .command = args[1], .args = args[2..] };
}

fn isGlobalCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h");
}

fn loadRuntime(context: CommandContext, parsed: ParsedArgs) !Runtime {
    const io = context.io orelse return error.MissingIo;
    const path = if (parsed.config_path) |p| p else try projectConfigPath(context.gpa, parsed.project orelse return error.ProjectRequired);
    const cfg = try config.loadPath(context.gpa, io, path, runtime.home());
    return .{
        .gpa = context.gpa,
        .io = io,
        .cfg = cfg,
        .config_path = path,
        .zask_path = "zask",
    };
}

fn projectConfigPath(gpa: std.mem.Allocator, project: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ try runtime.configBase(gpa), project, "config.json" });
}

fn oneArg(args: []const []const u8, command: []const u8) ![]const u8 {
    _ = command;
    if (args.len == 0) return error.InvalidArguments;
    return args[0];
}

fn resolveHelloProfile(cfg: config.Config, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return "all";
    if (std.mem.eql(u8, args[0], "--docker")) return "docker";
    return cfg.resolveStartProfileOption(args[0]) orelse error.InvalidArguments;
}

test "version prints package version" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator }, &.{"version"}, &writer);
    try std.testing.expectEqualStrings("zask 0.0.0\n", writer.buffered());
}

test "help prints usage" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator }, &.{"help"}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
}

test "parses project command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "demo", "list" });
    try std.testing.expectEqualStrings("demo", parsed.project.?);
    try std.testing.expectEqualStrings("list", parsed.command);
}
