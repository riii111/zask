const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");
const config = @import("config.zig");
const env = @import("infra/env.zig");
const paths = @import("infra/paths.zig");
const validate = @import("validate.zig");
const Runtime = @import("runtime.zig").Runtime;

const ParsedArgs = struct {
    config_path: ?[]const u8 = null,
    project: ?[]const u8 = null,
    command: []const u8,
    args: []const []const u8,
};

const Command = enum {
    version,
    help,
    render_session,
    list,
    status,
    attach,
    detach,
    logs,
    follow,
    hello,
    bye,
    kill,
    re,
    up,
    stop,
    restart,
    exec,
    dashboard,
    monitor,
};

const CommandSpec = struct {
    command: Command,
    names: []const []const u8,
    usage: ?[]const u8 = null,
    description: []const u8 = "",
    global: bool = false,
};

const command_specs = [_]CommandSpec{
    .{ .command = .hello, .names = &.{"hello"}, .usage = "hello [--docker|--<profile>]", .description = "Start session + services + attach" },
    .{ .command = .bye, .names = &.{"bye"}, .usage = "bye", .description = "Graceful shutdown" },
    .{ .command = .re, .names = &.{"re"}, .usage = "re", .description = "Restart session" },
    .{ .command = .attach, .names = &.{"attach"}, .usage = "attach | detach | kill", .description = "Manage tmux session" },
    .{ .command = .detach, .names = &.{"detach"} },
    .{ .command = .kill, .names = &.{"kill"} },
    .{ .command = .up, .names = &.{"up"}, .usage = "up [--all|docker|name]", .description = "Start service, group, docker, or all" },
    .{ .command = .stop, .names = &.{"stop"}, .usage = "stop [--all|docker|name]", .description = "Stop service, group, docker, or all" },
    .{ .command = .restart, .names = &.{"restart"}, .usage = "restart <docker|name>", .description = "Restart service, group, or docker" },
    .{ .command = .status, .names = &.{"status"}, .usage = "status | list", .description = "Show service state or config services" },
    .{ .command = .list, .names = &.{"list"} },
    .{ .command = .logs, .names = &.{"logs"}, .usage = "logs <service>", .description = "Focus service window" },
    .{ .command = .follow, .names = &.{"follow"}, .usage = "follow <service>", .description = "Tail captured log in tmux popup" },
    .{ .command = .exec, .names = &.{"exec"}, .usage = "exec <container> [--shell]", .description = "Enter Docker container" },
    .{ .command = .render_session, .names = &.{"render-session"}, .usage = "render-session", .description = "Print generated tmuxp YAML" },
    .{ .command = .version, .names = &.{"version"}, .usage = "version", .description = "Print zask version", .global = true },
    .{ .command = .help, .names = &.{ "help", "--help", "-h" }, .usage = "help", .description = "Print this help", .global = true },
    .{ .command = .dashboard, .names = &.{"dashboard"} },
    .{ .command = .monitor, .names = &.{"monitor"} },
};

pub const CommandContext = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    environ: ?*const env.Map = null,
    argv0: []const u8 = "zask",
};

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const context: CommandContext = .{
        .gpa = arena,
        .io = init.io,
        .environ = init.environ_map,
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
        if (isProjectAlias(context.argv0)) return printHelp(writer);
        return printGreeting(writer);
    }

    const parsed = try parseArgs(context, args);
    const command = parseCommand(parsed.command) orelse return error.UnknownCommand;
    if (command == .version) {
        return printVersion(writer);
    }
    if (command == .help) {
        return printHelp(writer);
    }
    const rt = try loadRuntime(context, parsed);
    return switch (command) {
        .version, .help => unreachable,
        .render_session => rt.renderSession(writer),
        .list => rt.list(writer),
        .status => rt.status(writer),
        .attach => rt.attach(),
        .detach => rt.detach(writer),
        .logs => rt.logs(try oneArg(parsed.args), writer),
        .follow => rt.follow(try oneArg(parsed.args), writer),
        .hello => rt.hello(try resolveHelloProfile(rt.cfg, parsed.args), writer),
        .bye => rt.bye(writer),
        .kill => rt.kill(writer),
        .re => rt.re(writer),
        .up => rt.up(optionalTarget(parsed.args), writer),
        .stop => rt.stop(optionalTarget(parsed.args), writer),
        .restart => rt.restart(try requiredTarget(parsed.args), writer),
        .exec => rt.exec(try oneArg(parsed.args), parsed.args.len > 1 and std.mem.eql(u8, parsed.args[1], "--shell"), writer),
        .dashboard => rt.dashboard(writer),
        .monitor => rt.monitor(writer),
    };
}

fn printGreeting(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{root.greeting()});
}

fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("zask {s}\n", .{build_options.version});
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll("Usage: zask <command>\n\nCommands:\n");
    const usage_width = maxHelpUsageWidth();
    for (command_specs) |spec| {
        if (spec.usage) |usage| {
            try writer.print("  {s}", .{usage});
            try writeSpaces(writer, usage_width - usage.len + 2);
            try writer.print("{s}\n", .{spec.description});
        }
    }
    try writer.writeByte('\n');
}

fn maxHelpUsageWidth() usize {
    var width: usize = 0;
    for (command_specs) |spec| {
        if (spec.usage) |usage| width = @max(width, usage.len);
    }
    return width;
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
}

fn parseArgs(context: CommandContext, args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.InvalidArguments;
    if (isProjectAlias(context.argv0)) {
        const basename = std.fs.path.basename(context.argv0);
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

fn isProjectAlias(argv0: []const u8) bool {
    const basename = std.fs.path.basename(argv0);
    return !std.mem.eql(u8, basename, "zask") and !std.mem.eql(u8, basename, "zask-debug");
}

fn isGlobalCommand(command: []const u8) bool {
    for (command_specs) |spec| {
        if (!spec.global) continue;
        for (spec.names) |name| {
            if (std.mem.eql(u8, command, name)) return true;
        }
    }
    return false;
}

fn parseCommand(command: []const u8) ?Command {
    for (command_specs) |spec| {
        for (spec.names) |name| {
            if (std.mem.eql(u8, command, name)) return spec.command;
        }
    }
    return null;
}

fn loadRuntime(context: CommandContext, parsed: ParsedArgs) !Runtime {
    const io = context.io orelse return error.MissingIo;
    const path = try absoluteConfigPath(context.gpa, io, if (parsed.config_path) |p| p else try projectConfigPath(context.gpa, context.environ, parsed.project orelse return error.ProjectRequired));
    const cfg = try config.loadPath(context.gpa, io, path, try paths.home(context.environ));
    return .{
        .gpa = context.gpa,
        .io = io,
        .environ = context.environ,
        .cfg = cfg,
        .config_path = path,
        .zask_path = try absoluteExePath(context.gpa, io, context.argv0),
    };
}

fn projectConfigPath(gpa: std.mem.Allocator, environ: ?*const env.Map, project: []const u8) ![]const u8 {
    try validate.identifier(project);
    return std.fs.path.join(gpa, &.{ try paths.configBase(gpa, environ), project, "config.json" });
}

fn absoluteConfigPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
}

fn absoluteExePath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    if (std.mem.indexOfScalar(u8, path, '/') != null) {
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    }
    return path;
}

fn oneArg(args: []const []const u8) ![]const u8 {
    if (args.len == 0) return error.InvalidArguments;
    return args[0];
}

fn optionalTarget(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    return normalizeTarget(args[0]);
}

fn requiredTarget(args: []const []const u8) ![]const u8 {
    return normalizeTarget(try oneArg(args));
}

fn normalizeTarget(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "--docker")) return "docker";
    return target;
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
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "render-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "exec <container>") != null);
}

test "project alias without arguments prints usage" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator, .argv0 = "nodex" }, &.{}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
}

test "command metadata parses aliases and global commands" {
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
    try std.testing.expectEqual(Command.render_session, parseCommand("render-session").?);
    try std.testing.expect(isGlobalCommand("--help"));
    try std.testing.expect(!isGlobalCommand("list"));
}

test "normalizes docker target aliases" {
    try std.testing.expectEqualStrings("docker", normalizeTarget("--docker"));
    try std.testing.expectEqualStrings("api", normalizeTarget("api"));
    try std.testing.expectEqualStrings("docker", (try requiredTarget(&.{"--docker"})));
    try std.testing.expect(optionalTarget(&.{}) == null);
}

test "parses project command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "demo", "list" });
    try std.testing.expectEqualStrings("demo", parsed.project.?);
    try std.testing.expectEqualStrings("list", parsed.command);
}

test "parses explicit config command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "--config", "demo.json", "list" });
    try std.testing.expectEqualStrings("demo.json", parsed.config_path.?);
    try std.testing.expectEqualStrings("list", parsed.command);
    try std.testing.expectEqual(@as(usize, 0), parsed.args.len);
}

test "parses argv0 project alias form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator, .argv0 = "nodex" }, &.{"hello"});
    try std.testing.expectEqualStrings("nodex", parsed.project.?);
    try std.testing.expectEqualStrings("hello", parsed.command);
}

test "resolves hello profiles" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [],
        \\  "start_profiles": {"api": {"profile": "backend"}}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expectEqualStrings("all", try resolveHelloProfile(cfg, &.{}));
    try std.testing.expectEqualStrings("docker", try resolveHelloProfile(cfg, &.{"--docker"}));
    try std.testing.expectEqualStrings("backend", try resolveHelloProfile(cfg, &.{"--api"}));
    try std.testing.expectError(error.InvalidArguments, resolveHelloProfile(cfg, &.{"--missing"}));
}
