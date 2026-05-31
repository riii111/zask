const std = @import("std");
const attach = @import("cli/attach.zig");
const close = @import("cli/close.zig");
const cli_context = @import("cli/context.zig");
const dashboard = @import("cli/dashboard.zig");
const help = @import("cli/help.zig");
const init_cmd = @import("cli/init.zig");
const list = @import("cli/list.zig");
const logs = @import("cli/logs.zig");
const monitor = @import("cli/monitor.zig");
const open = @import("cli/open.zig");
const preview_list = @import("cli/preview_list.zig");
const re = @import("cli/re.zig");
const restart = @import("cli/restart.zig");
const start = @import("cli/start.zig");
const status = @import("cli/status.zig");
const stop = @import("cli/stop.zig");
const sync_size = @import("cli/sync_size.zig");
const version = @import("cli/version.zig");
const root = @import("../root.zig");
const env = @import("../platform/env.zig");
const paths = @import("../platform/paths.zig");
const diagnostics = @import("../model/diagnostics.zig");

const CommandContext = cli_context.CommandContext;
const ParsedArgs = cli_context.ParsedArgs;

const Command = enum {
    version,
    help,
    init,
    list,
    status,
    attach,
    logs,
    open,
    close,
    re,
    start,
    stop,
    restart,
    dashboard,
    monitor,
    preview_list,
    sync_size,

    fn run(self: Command, context: *cli_context.Context) !void {
        return switch (self) {
            .version => runCommand(version, context),
            .help => runCommand(help, context),
            .init => runCommand(init_cmd, context),
            .list => runCommand(list, context),
            .status => runCommand(status, context),
            .attach => runCommand(attach, context),
            .logs => runCommand(logs, context),
            .open => runCommand(open, context),
            .close => runCommand(close, context),
            .re => runCommand(re, context),
            .start => runCommand(start, context),
            .stop => runCommand(stop, context),
            .restart => runCommand(restart, context),
            .dashboard => runCommand(dashboard, context),
            .monitor => runCommand(monitor, context),
            .preview_list => runCommand(preview_list, context),
            .sync_size => runCommand(sync_size, context),
        };
    }
};

const CommandSpec = struct {
    command: Command,
    names: []const []const u8,
    usage: []const u8 = "",
    description: []const u8 = "",
    global: bool = false,
    internal: bool = false,
    show_in_help: bool = true,
};

const command_specs = [_]CommandSpec{
    .{ .command = .open, .names = &.{"open"}, .usage = "open [--docker|--<profile>]", .description = "Open workspace and attach" },
    .{ .command = .close, .names = &.{"close"}, .usage = "close", .description = "Stop resources and close workspace" },
    .{ .command = .re, .names = &.{"re"}, .usage = "re", .description = "Restart session" },
    .{ .command = .attach, .names = &.{"attach"}, .usage = "attach", .description = "Attach to existing workspace" },
    .{ .command = .start, .names = &.{"start"}, .usage = "start <--all|svc|group|docker>", .description = "Start resources in existing workspace" },
    .{ .command = .stop, .names = &.{"stop"}, .usage = "stop <--all|svc|group|docker>", .description = "Stop resources, keeping workspace open" },
    .{ .command = .restart, .names = &.{"restart"}, .usage = "restart <svc|group|docker>", .description = "Restart service, group, or docker" },
    .{ .command = .list, .names = &.{"list"}, .usage = "list", .description = "List configured services" },
    .{ .command = .status, .names = &.{"status"}, .usage = "status", .description = "Show service state" },
    .{ .command = .logs, .names = &.{"logs"}, .usage = "logs <service>", .description = "Focus service window" },
    .{ .command = .init, .names = &.{"init"}, .usage = "init [project] [--root <path>] [--force]", .description = "Create project config", .global = true },
    .{ .command = .version, .names = &.{"version"}, .usage = "version", .description = "Print zask version", .global = true },
    .{ .command = .help, .names = &.{ "help", "--help", "-h" }, .usage = "help", .description = "Print this help", .global = true },
    .{ .command = .dashboard, .names = &.{"dashboard"}, .internal = true, .show_in_help = false },
    .{ .command = .monitor, .names = &.{"monitor"}, .internal = true, .show_in_help = false },
    .{ .command = .preview_list, .names = &.{"preview-list"}, .internal = true, .show_in_help = false },
    .{ .command = .sync_size, .names = &.{"sync-size"}, .internal = true, .show_in_help = false },
};

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var diags = diagnostics.Diagnostics.init(arena);
    var err_ctx: cli_context.ErrorContext = .{};
    const context: CommandContext = .{
        .gpa = arena,
        .io = init.io,
        .environ = init.environ_map,
        .argv0 = if (args.len > 0) args[0] else "zask",
        .diagnostics = &diags,
        .error_context = &err_ctx,
    };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    runWithArgs(context, if (args.len > 1) args[1..] else &.{}, stdout) catch |err| switch (err) {
        error.InvalidArguments, error.UnknownCommand, error.ProjectRequired, error.ConfigAlreadyExists => {
            try stdout.flush();
            std.process.exit(2);
        },
        error.ConfigNotFound => {
            try stdout.writeAll("Error: config not found\n");
            try renderDiscoveredConfig(stdout, err_ctx);
            try stdout.flush();
            std.process.exit(2);
        },
        error.AmbiguousConfig => {
            try stdout.writeAll("Error: both zask.json and .zask.json found\n");
            try stdout.writeAll("Use --config <file> to choose one.\n");
            try stdout.flush();
            std.process.exit(2);
        },
        error.InvalidConfigSyntax => {
            try stdout.writeAll("Error: config is not valid JSON\n");
            try renderDiscoveredConfig(stdout, err_ctx);
            try stdout.flush();
            std.process.exit(2);
        },
        error.InvalidConfig => {
            try stdout.writeAll("Error: invalid config\n");
            try renderDiscoveredConfig(stdout, err_ctx);
            try renderDiagnostics(stdout, diags);
            try stdout.flush();
            std.process.exit(2);
        },
        error.ConfigTooLarge => {
            try stdout.writeAll("Error: config file too large\n");
            try stdout.flush();
            std.process.exit(2);
        },
        error.SessionNotRunning, error.TmuxUnavailable, error.ServiceStopIncomplete, error.StartupFailed => {
            try stdout.flush();
            std.process.exit(1);
        },
        error.LockBusy => {
            try stdout.writeAll("Another zask command is already running\n");
            try stdout.flush();
            std.process.exit(1);
        },
        error.OutputTooLarge => {
            try stdout.writeAll("Error: command output too large\n");
            try stdout.flush();
            std.process.exit(1);
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
    const command = parseCommand(parsed.command, parsed.config_source == .explicit) orelse return error.UnknownCommand;
    var run_context: cli_context.Context = .{ .base = context, .parsed = parsed, .writer = writer, .print_help = printHelp };
    try command.run(&run_context);
}

fn printGreeting(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{root.greeting()});
}

fn renderDiagnostics(writer: *std.Io.Writer, diags: diagnostics.Diagnostics) !void {
    for (diags.slice()) |diagnostic| {
        if (diagnostic.path.len == 0) {
            try writer.print("  {s}\n", .{diagnostic.message});
        } else {
            try writer.print("  {s}: {s}\n", .{ diagnostic.path, diagnostic.message });
        }
    }
}

fn renderDiscoveredConfig(writer: *std.Io.Writer, err_ctx: cli_context.ErrorContext) !void {
    if (err_ctx.config_source != .discovered) return;
    if (err_ctx.config_path) |path| try writer.print("Config: {s}\n", .{path});
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zask <command>
        \\  zask <project> <command>
        \\  zask --config <file> <command>
        \\  <project-alias> <command>
        \\
        \\Commands:
        \\
    );
    const usage_width = maxHelpUsageWidth();
    for (command_specs) |spec| {
        if (!spec.show_in_help) continue;
        try writer.print("  {s}", .{spec.usage});
        try writeSpaces(writer, usage_width - spec.usage.len + 2);
        try writer.print("{s}\n", .{spec.description});
    }
    try writer.writeByte('\n');
}

fn runCommand(comptime module: type, context: *cli_context.Context) !void {
    const opts = module.Options.parse(context.parsed.args) catch |err| {
        if (err == error.InvalidArguments) context.help() catch {};
        return err;
    };
    defer opts.deinit();
    module.run(context, opts) catch |err| {
        if (err == error.InvalidArguments) context.help() catch {};
        return err;
    };
}

fn maxHelpUsageWidth() usize {
    var width: usize = 0;
    for (command_specs) |spec| {
        if (spec.show_in_help) width = @max(width, spec.usage.len);
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
        return .{ .config_path = args[1], .config_source = .explicit, .command = args[2], .args = args[3..] };
    }
    if (cli_context.isProjectAlias(context.argv0)) {
        const basename = std.fs.path.basename(context.argv0);
        return .{ .project = basename, .config_source = .named, .command = args[0], .args = args[1..] };
    }
    if (isGlobalCommand(args[0])) return .{ .command = args[0], .args = args[1..] };
    if (shouldUseNamedProject(context, args)) {
        return .{ .project = args[0], .config_source = .named, .command = args[1], .args = args[2..] };
    }
    if (isCommandForm(args[0])) return .{ .config_source = .discovered, .command = args[0], .args = args[1..] };
    if (args.len < 2) return error.ProjectRequired;
    return .{ .project = args[0], .config_source = .named, .command = args[1], .args = args[2..] };
}

fn shouldUseNamedProject(context: CommandContext, args: []const []const u8) bool {
    if (args.len < 2) return false;
    if (parseCommand(args[1], false) == null) return false;
    const io = context.io orelse return false;
    const path = cli_context.projectConfigPath(context.gpa, context.environ, args[0]) catch return false;
    defer context.gpa.free(path);
    return paths.exists(io, path);
}

fn isCommandForm(command: []const u8) bool {
    return !isGlobalCommand(command) and parseCommand(command, false) != null;
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

fn parseCommand(command: []const u8, allow_internal: bool) ?Command {
    for (command_specs) |spec| {
        if (spec.internal and !allow_internal) continue;
        for (spec.names) |name| {
            if (std.mem.eql(u8, command, name)) return spec.command;
        }
    }
    return null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "cli.command: parses public and internal names" {
    const command_cases = [_]struct {
        input: []const u8,
        expected: ?Command,
    }{
        .{ .input = "-h", .expected = .help },
        .{ .input = "--help", .expected = .help },
        .{ .input = "open", .expected = .open },
        .{ .input = "hello", .expected = null },
        .{ .input = "bye", .expected = null },
        .{ .input = "up", .expected = null },
        .{ .input = "kill", .expected = null },
        .{ .input = "exec", .expected = null },
        .{ .input = "list", .expected = .list },
        .{ .input = "detach", .expected = null },
        .{ .input = "dashboard", .expected = null },
        .{ .input = "preview-list", .expected = null },
        .{ .input = "sync-size", .expected = null },
        .{ .input = "render-session", .expected = null },
    };
    for (command_cases) |case| {
        try std.testing.expectEqual(case.expected, parseCommand(case.input, false));
    }
    try std.testing.expectEqual(Command.dashboard, parseCommand("dashboard", true));
    try std.testing.expectEqual(Command.preview_list, parseCommand("preview-list", true));
    try std.testing.expectEqual(Command.sync_size, parseCommand("sync-size", true));

    try std.testing.expect(isCommandForm("open"));
    try std.testing.expect(!isCommandForm("init"));
    try std.testing.expect(!isCommandForm("dashboard"));

    const global_cases = [_]struct {
        input: []const u8,
        expected: bool,
    }{
        .{ .input = "--help", .expected = true },
        .{ .input = "init", .expected = true },
        .{ .input = "version", .expected = true },
        .{ .input = "status", .expected = false },
    };
    for (global_cases) |case| {
        try std.testing.expectEqual(case.expected, isGlobalCommand(case.input));
    }
}

test "cli.version: prints package version" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator }, &.{"version"}, &writer);
    try std.testing.expectEqualStrings("zask 0.0.0\n", writer.buffered());
}

test "cli.help: prints public commands" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator }, &.{"help"}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage:\n  zask <command>"));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "zask <project> <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "zask --config <file> <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "<project-alias> <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "start <--all|svc|group|docker>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "stop <--all|svc|group|docker>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "restart <svc|group|docker>") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "init [project] [--root <path>] [--force]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "attach | detach") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "open [--docker|--<profile>]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "bye") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "up [") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "render-session") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "preview-list") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "exec <container>") == null);
}

test "cli.projectAlias: prints usage without command" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage:\n  zask <command>"));
}

test "cli.parseArgs: accepts project command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "demo", "status" });
    try std.testing.expectEqualStrings("demo", parsed.project.?);
    try std.testing.expectEqual(cli_context.ConfigSource.named, parsed.config_source.?);
    try std.testing.expectEqualStrings("status", parsed.command);
}

test "cli.parseArgs: accepts init as global command" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "init", "demo", "--root", "." });
    try std.testing.expect(parsed.project == null);
    try std.testing.expectEqualStrings("init", parsed.command);
    try std.testing.expectEqualStrings("demo", parsed.args[0]);
}

test "cli.parseArgs: accepts init without project" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{"init"});
    try std.testing.expect(parsed.project == null);
    try std.testing.expectEqualStrings("init", parsed.command);
    try std.testing.expectEqual(@as(usize, 0), parsed.args.len);
}

test "cli.parseArgs: accepts explicit config command form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "--config", "demo.json", "status" });
    try std.testing.expectEqualStrings("demo.json", parsed.config_path.?);
    try std.testing.expectEqual(cli_context.ConfigSource.explicit, parsed.config_source.?);
    try std.testing.expectEqualStrings("status", parsed.command);
    try std.testing.expectEqual(@as(usize, 0), parsed.args.len);
}

test "cli.parseArgs: project alias accepts explicit config form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{ "--config", "demo.json", "logs", "api" });
    try std.testing.expectEqualStrings("demo.json", parsed.config_path.?);
    try std.testing.expectEqualStrings("logs", parsed.command);
    try std.testing.expectEqualStrings("api", parsed.args[0]);
    try std.testing.expect(parsed.project == null);
}

test "cli.parseArgs: accepts argv0 project alias form" {
    const parsed = try parseArgs(.{ .gpa = std.testing.allocator, .argv0 = "sample" }, &.{"open"});
    try std.testing.expectEqualStrings("sample", parsed.project.?);
    try std.testing.expectEqual(cli_context.ConfigSource.named, parsed.config_source.?);
    try std.testing.expectEqualStrings("open", parsed.command);
}

test "cli.parseArgs: accepts command form for local config discovery" {
    const status_args = try parseArgs(.{ .gpa = std.testing.allocator }, &.{"status"});
    try std.testing.expect(status_args.project == null);
    try std.testing.expect(status_args.config_path == null);
    try std.testing.expectEqual(cli_context.ConfigSource.discovered, status_args.config_source.?);
    try std.testing.expectEqualStrings("status", status_args.command);

    const logs_args = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "logs", "api" });
    try std.testing.expect(logs_args.project == null);
    try std.testing.expectEqual(cli_context.ConfigSource.discovered, logs_args.config_source.?);
    try std.testing.expectEqualStrings("logs", logs_args.command);
    try std.testing.expectEqualStrings("api", logs_args.args[0]);
}

test "cli.parseArgs: prefers existing named project over command form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(gpa);
    defer environ.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(threaded.io(), "xdg/zask/open");
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "xdg/zask/open/config.json", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(threaded.io(), ".", gpa);
    const xdg = try std.fs.path.join(gpa, &.{ base, "xdg" });
    try environ.put("XDG_CONFIG_HOME", xdg);

    const parsed = try parseArgs(.{ .gpa = gpa, .io = threaded.io(), .environ = &environ }, &.{ "open", "status" });
    try std.testing.expectEqualStrings("open", parsed.project.?);
    try std.testing.expectEqual(cli_context.ConfigSource.named, parsed.config_source.?);
    try std.testing.expectEqualStrings("status", parsed.command);
}

test "cli.parseArgs: rejects incomplete forms" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(.{ .gpa = std.testing.allocator }, &.{"--config"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(.{ .gpa = std.testing.allocator }, &.{ "--config", "demo.json" }));
    try std.testing.expectError(error.ProjectRequired, parseArgs(.{ .gpa = std.testing.allocator }, &.{"demo"}));
}

test "cli.runWithArgs: prints usage for invalid arity" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidArguments, runWithArgs(.{ .gpa = std.testing.allocator }, &.{ "version", "extra" }, &writer));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage:\n  zask <command>"));
}

test "cli.runWithArgs: prints usage for incomplete config" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.InvalidArguments, runWithArgs(.{ .gpa = std.testing.allocator }, &.{"--config"}, &writer));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage:\n  zask <command>"));
}

test "cli.open: prints usage for invalid profile" {
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
    }, &.{ "--config", "testdata/synthetic.json", "open", "--missing" }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Usage:\n  zask <command>") != null);
}
