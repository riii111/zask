const std = @import("std");
const build_options = @import("build_options");
const attach = @import("cli/attach.zig");
const bye = @import("cli/bye.zig");
const cli_context = @import("cli/context.zig");
const dashboard = @import("cli/dashboard.zig");
const detach = @import("cli/detach.zig");
const exec = @import("cli/exec.zig");
const follow = @import("cli/follow.zig");
const help = @import("cli/help.zig");
const hello = @import("cli/hello.zig");
const kill = @import("cli/kill.zig");
const list = @import("cli/list.zig");
const logs = @import("cli/logs.zig");
const re = @import("cli/re.zig");
const restart = @import("cli/restart.zig");
const status = @import("cli/status.zig");
const stop = @import("cli/stop.zig");
const up = @import("cli/up.zig");
const version = @import("cli/version.zig");
const root = @import("../root.zig");
const config = @import("../model/config.zig");
const dashboard_ui = @import("ui/dashboard.zig");
const env = @import("../platform/env.zig");
const Runtime = @import("../workflow/runtime.zig").Runtime;

const CommandContext = cli_context.CommandContext;
const ParsedArgs = cli_context.ParsedArgs;

const Command = enum {
    version,
    help,
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
    preview_list,
};

const CommandSpec = struct {
    command: Command,
    names: []const []const u8,
    usage: ?[]const u8 = null,
    description: []const u8 = "",
    global: bool = false,
    min_args: usize = 0,
    max_args: usize = 0,
};

const command_specs = [_]CommandSpec{
    .{ .command = .hello, .names = &.{"hello"}, .usage = "hello [--docker|--<profile>]", .description = "Start session + services + attach", .max_args = 1 },
    .{ .command = .bye, .names = &.{"bye"}, .usage = "bye", .description = "Graceful shutdown" },
    .{ .command = .re, .names = &.{"re"}, .usage = "re", .description = "Restart session" },
    .{ .command = .attach, .names = &.{"attach"}, .usage = "attach | detach | kill", .description = "Manage tmux session" },
    .{ .command = .detach, .names = &.{"detach"} },
    .{ .command = .kill, .names = &.{"kill"} },
    .{ .command = .up, .names = &.{"up"}, .usage = "up [--all|docker|name]", .description = "Start service, group, docker, or all", .max_args = 1 },
    .{ .command = .stop, .names = &.{"stop"}, .usage = "stop [--all|docker|name]", .description = "Stop service, group, docker, or all", .max_args = 1 },
    .{ .command = .restart, .names = &.{"restart"}, .usage = "restart <docker|name>", .description = "Restart service, group, or docker", .min_args = 1, .max_args = 1 },
    .{ .command = .status, .names = &.{"status"}, .usage = "status | list", .description = "Show service state or config services" },
    .{ .command = .list, .names = &.{"list"} },
    .{ .command = .logs, .names = &.{"logs"}, .usage = "logs <service>", .description = "Focus service window", .min_args = 1, .max_args = 1 },
    .{ .command = .follow, .names = &.{"follow"}, .usage = "follow <service>", .description = "Tail captured log in tmux popup", .min_args = 1, .max_args = 1 },
    .{ .command = .exec, .names = &.{"exec"}, .usage = "exec <container> [--shell]", .description = "Enter Docker container", .min_args = 1, .max_args = 2 },
    .{ .command = .version, .names = &.{"version"}, .usage = "version", .description = "Print zask version", .global = true },
    .{ .command = .help, .names = &.{ "help", "--help", "-h" }, .usage = "help", .description = "Print this help", .global = true },
    .{ .command = .dashboard, .names = &.{"dashboard"} },
    .{ .command = .monitor, .names = &.{"monitor"} },
    // Internal command invoked by tmux bindings; omitted from public help.
    .{ .command = .preview_list, .names = &.{"preview-list"}, .min_args = 3, .max_args = 3 },
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

    runWithArgs(context, if (args.len > 1) args[1..] else &.{}, stdout) catch |err| switch (err) {
        error.InvalidArguments, error.UnknownCommand, error.ProjectRequired => {
            try stdout.flush();
            std.process.exit(2);
        },
        else => return err,
    };
    try stdout.flush();
}

pub fn runWithArgs(context: CommandContext, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len == 0) {
        if (cli_context.isProjectAlias(context.argv0)) return printHelp(writer);
        return printGreeting(writer);
    }

    const parsed = parseArgs(context, args) catch |err| {
        if (err == error.InvalidArguments) try printHelp(writer);
        return err;
    };
    const command = parseCommand(parsed.command) orelse return error.UnknownCommand;
    validateArity(command, parsed.args) catch |err| {
        if (err == error.InvalidArguments) try printHelp(writer);
        return err;
    };
    var run_context: cli_context.Context = .{ .base = context, .parsed = parsed, .writer = writer, .print_help = printHelp };
    if (command == .version) return runCommand(version, &run_context);
    if (command == .help) return runCommand(help, &run_context);
    if (command == .list) return runCommand(list, &run_context);
    if (command == .status) return runCommand(status, &run_context);
    if (command == .attach) return runCommand(attach, &run_context);
    if (command == .detach) return runCommand(detach, &run_context);
    if (command == .logs) return runCommand(logs, &run_context);
    if (command == .follow) return runCommand(follow, &run_context);
    if (command == .hello) return runCommand(hello, &run_context);
    if (command == .bye) return runCommand(bye, &run_context);
    if (command == .kill) return runCommand(kill, &run_context);
    if (command == .re) return runCommand(re, &run_context);
    if (command == .up) return runCommand(up, &run_context);
    if (command == .stop) return runCommand(stop, &run_context);
    if (command == .restart) return runCommand(restart, &run_context);
    if (command == .exec) return runCommand(exec, &run_context);
    if (command == .dashboard) return runCommand(dashboard, &run_context);
    const rt = try run_context.runtime();
    dispatchRuntimeCommand(rt, command, parsed.args, writer) catch |err| {
        if (err == error.InvalidArguments) try printHelp(writer);
        return err;
    };
}

fn dispatchRuntimeCommand(rt: Runtime, command: Command, args: []const []const u8, writer: *std.Io.Writer) !void {
    return switch (command) {
        .version, .help => unreachable,
        .list => unreachable,
        .status => unreachable,
        .attach => unreachable,
        .detach => unreachable,
        .logs => unreachable,
        .follow => unreachable,
        .hello => unreachable,
        .bye => unreachable,
        .kill => unreachable,
        .re => unreachable,
        .up => unreachable,
        .stop => unreachable,
        .restart => unreachable,
        .exec => unreachable,
        .dashboard => unreachable,
        .monitor => dashboard_ui.runMonitor(rt.gpa, rt.io, rt.cfg, writer),
        .preview_list => rt.previewList(args[0], try parseSizeArg(args[1]), try parseSizeArg(args[2])),
    };
}

fn printGreeting(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{root.greeting()});
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

fn runCommand(comptime module: type, context: *cli_context.Context) !void {
    const opts = module.Options.parse(context.parsed.args) catch |err| {
        if (err == error.InvalidArguments) try context.help();
        return err;
    };
    defer opts.deinit();
    module.run(context, opts) catch |err| {
        if (err == error.InvalidArguments) try context.help();
        return err;
    };
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
    if (std.mem.eql(u8, args[0], "--config")) {
        if (args.len < 3) return error.InvalidArguments;
        return .{ .config_path = args[1], .command = args[2], .args = args[3..] };
    }
    if (cli_context.isProjectAlias(context.argv0)) {
        const basename = std.fs.path.basename(context.argv0);
        return .{ .project = basename, .command = args[0], .args = args[1..] };
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

fn commandSpec(command: Command) CommandSpec {
    for (command_specs) |spec| {
        if (spec.command == command) return spec;
    }
    unreachable;
}

fn validateArity(command: Command, args: []const []const u8) !void {
    const spec = commandSpec(command);
    if (args.len < spec.min_args or args.len > spec.max_args) return error.InvalidArguments;
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

fn parseSizeArg(arg: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, arg, 10) catch return error.InvalidArguments;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "command metadata parses aliases and global commands" {
    const command_cases = [_]struct {
        input: []const u8,
        expected: ?Command,
    }{
        .{ .input = "-h", .expected = .help },
        .{ .input = "--help", .expected = .help },
        .{ .input = "hello", .expected = .hello },
        .{ .input = "render-session", .expected = null },
    };
    for (command_cases) |case| {
        try std.testing.expectEqual(case.expected, parseCommand(case.input));
    }

    const global_cases = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "--help", .expected = true },
        .{ .input = "version", .expected = true },
        .{ .input = "list", .expected = false },
    };
    for (global_cases) |case| {
        try std.testing.expectEqual(case.expected, isGlobalCommand(case.input));
    }
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
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "render-session") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "preview-list") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "exec <container>") != null);
}

test "project alias without arguments prints usage" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
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

test "project alias accepts explicit config command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{ "--config", "demo.json", "follow", "api" });
    try std.testing.expectEqualStrings("demo.json", parsed.config_path.?);
    try std.testing.expectEqualStrings("follow", parsed.command);
    try std.testing.expectEqualStrings("api", parsed.args[0]);
    try std.testing.expect(parsed.project == null);
}

test "parses argv0 project alias form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{"hello"});
    try std.testing.expectEqualStrings("sample", parsed.project.?);
    try std.testing.expectEqualStrings("hello", parsed.command);
}

test "rejects incomplete config and project command forms" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(.{ .gpa = std.testing.allocator }, &.{"--config"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(.{ .gpa = std.testing.allocator }, &.{ "--config", "demo.json" }));
    try std.testing.expectError(error.ProjectRequired, parseArgs(.{ .gpa = std.testing.allocator }, &.{"list"}));
}

test "accepts valid command arity" {
    const cases = [_]struct {
        command: Command,
        args: []const []const u8,
    }{
        .{ .command = .hello, .args = &.{} },
        .{ .command = .hello, .args = &.{"--docker"} },
        .{ .command = .logs, .args = &.{"api"} },
        .{ .command = .exec, .args = &.{"api"} },
        .{ .command = .exec, .args = &.{ "api", "--shell" } },
        .{ .command = .preview_list, .args = &.{ "%1", "120", "40" } },
    };
    for (cases) |case| {
        try validateArity(case.command, case.args);
    }
}

test "rejects invalid command arity" {
    const cases = [_]struct {
        command: Command,
        args: []const []const u8,
    }{
        .{ .command = .hello, .args = &.{ "--docker", "extra" } },
        .{ .command = .logs, .args = &.{} },
        .{ .command = .logs, .args = &.{ "api", "extra" } },
        .{ .command = .up, .args = &.{ "api", "extra" } },
        .{ .command = .restart, .args = &.{} },
        .{ .command = .restart, .args = &.{ "api", "extra" } },
        .{ .command = .exec, .args = &.{ "api", "--shell", "extra" } },
        .{ .command = .preview_list, .args = &.{ "%1", "120" } },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, validateArity(case.command, case.args));
    }
}

test "normalizes docker target aliases" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "--docker", .expected = "docker" },
        .{ .input = "api", .expected = "api" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, normalizeTarget(case.input));
    }

    try std.testing.expectEqualStrings("docker", try requiredTarget(&.{"--docker"}));
    try std.testing.expect(optionalTarget(&.{}) == null);
}

test "invalid command arity prints usage before returning error" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidArguments, runWithArgs(.{ .gpa = std.testing.allocator }, &.{ "version", "extra" }, &writer));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
}

test "incomplete config form prints usage before returning error" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidArguments, runWithArgs(.{ .gpa = std.testing.allocator }, &.{"--config"}, &writer));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
}

test "invalid hello profile prints usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("HOME", "/home/me");

    try std.testing.expectError(error.InvalidArguments, runWithArgs(.{
        .gpa = arena.allocator(),
        .io = threaded.io(),
        .environ = &environ,
    }, &.{ "--config", "testdata/synthetic.json", "hello", "--missing" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Usage: zask <command>") != null);
}
