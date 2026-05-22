const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");
const config = @import("config.zig");
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
    help: ?[]const u8 = null,
    global: bool = false,
};

const command_specs = [_]CommandSpec{
    .{ .command = .version, .names = &.{"version"}, .help = "  version                      Print zask version", .global = true },
    .{ .command = .help, .names = &.{ "help", "--help", "-h" }, .help = "  help                         Print this help", .global = true },
    .{ .command = .render_session, .names = &.{"render-session"}, .help = "  render-session               Print generated tmuxp YAML" },
    .{ .command = .list, .names = &.{"list"}, .help = "  status | list                Show service state or config services" },
    .{ .command = .status, .names = &.{"status"} },
    .{ .command = .attach, .names = &.{"attach"}, .help = "  attach | detach | kill       Manage tmux session" },
    .{ .command = .detach, .names = &.{"detach"} },
    .{ .command = .logs, .names = &.{"logs"}, .help = "  logs <service>               Focus service window" },
    .{ .command = .follow, .names = &.{"follow"}, .help = "  follow <service>             Tail captured log in tmux popup" },
    .{ .command = .hello, .names = &.{"hello"}, .help = "  hello [--docker|--<profile>] Start session + services + attach" },
    .{ .command = .bye, .names = &.{"bye"}, .help = "  bye                         Graceful shutdown" },
    .{ .command = .kill, .names = &.{"kill"} },
    .{ .command = .re, .names = &.{"re"}, .help = "  re                          Restart session" },
    .{ .command = .up, .names = &.{"up"}, .help = "  up [--all|docker|name]       Start service, group, docker, or all" },
    .{ .command = .stop, .names = &.{"stop"}, .help = "  stop [--all|docker|name]     Stop service, group, docker, or all" },
    .{ .command = .restart, .names = &.{"restart"}, .help = "  restart <docker|name>        Restart service, group, or docker" },
    .{ .command = .exec, .names = &.{"exec"}, .help = "  exec <container> [--shell]   Enter Docker container" },
    .{ .command = .dashboard, .names = &.{"dashboard"} },
    .{ .command = .monitor, .names = &.{"monitor"} },
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
        .logs => rt.logs(try oneArg(parsed.args)),
        .follow => rt.follow(try oneArg(parsed.args), writer),
        .hello => rt.hello(try resolveHelloProfile(rt.cfg, parsed.args), writer),
        .bye => rt.bye(writer),
        .kill => rt.kill(writer),
        .re => rt.re(writer),
        .up => rt.up(if (parsed.args.len > 0) parsed.args[0] else null, writer),
        .stop => rt.stop(if (parsed.args.len > 0) parsed.args[0] else null, writer),
        .restart => rt.restart(try oneArg(parsed.args), writer),
        .exec => rt.exec(try oneArg(parsed.args), parsed.args.len > 1 and std.mem.eql(u8, parsed.args[1], "--shell"), writer),
        .dashboard => rt.dashboard(writer),
        .monitor => rt.monitorOnce(writer),
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
    for (command_specs) |spec| {
        if (spec.help) |line| try writer.print("{s}\n", .{line});
    }
    try writer.writeByte('\n');
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
    const path = try absoluteConfigPath(context.gpa, io, if (parsed.config_path) |p| p else try projectConfigPath(context.gpa, parsed.project orelse return error.ProjectRequired));
    const cfg = try config.loadPath(context.gpa, io, path, paths.home());
    return .{
        .gpa = context.gpa,
        .io = io,
        .cfg = cfg,
        .config_path = path,
        .zask_path = try absoluteExePath(context.gpa, io, context.argv0),
    };
}

fn projectConfigPath(gpa: std.mem.Allocator, project: []const u8) ![]const u8 {
    try validate.identifier(project);
    return std.fs.path.join(gpa, &.{ try paths.configBase(gpa), project, "config.json" });
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

test "command metadata parses aliases and global commands" {
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
    try std.testing.expectEqual(Command.render_session, parseCommand("render-session").?);
    try std.testing.expect(isGlobalCommand("--help"));
    try std.testing.expect(!isGlobalCommand("list"));
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
