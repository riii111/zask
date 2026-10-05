const std = @import("std");
const add = @import("cli/add.zig");
const attach = @import("cli/attach.zig");
const check = @import("cli/check.zig");
const close = @import("cli/close.zig");
const complete = @import("cli/complete.zig");
const completion = @import("cli/completion.zig");
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
const status_json = @import("cli/status_json.zig");
const stop = @import("cli/stop.zig");
const sync_size = @import("cli/sync_size.zig");
const version = @import("cli/version.zig");
const wait = @import("cli/wait.zig");
const watch = @import("cli/watch.zig");
const root = @import("../root.zig");
const env = @import("../platform/env.zig");
const diagnostics = @import("../model/diagnostics.zig");
const jsonc = @import("../model/jsonc.zig");

const CommandContext = cli_context.CommandContext;
const ParsedArgs = cli_context.ParsedArgs;

const Command = enum {
    version,
    help,
    init,
    completion,
    list,
    status,
    check,
    wait,
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
    add,
    watch,

    fn run(self: Command, context: *cli_context.Context) !void {
        return switch (self) {
            .version => runCommand(version, context),
            .help => runCommand(help, context),
            .init => runCommand(init_cmd, context),
            .completion => runCommand(completion, context),
            .list => runCommand(list, context),
            .status => runCommand(status, context),
            .check => runCommand(check, context),
            .wait => runCommand(wait, context),
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
            .add => runCommand(add, context),
            .watch => runCommand(watch, context),
        };
    }
};

const CommandSpec = struct {
    command: Command,
    names: []const []const u8,
    usage: []const u8 = "",
    description: []const u8 = "",
    completion: complete.ArgKind = .none,
    global: bool = false,
    internal: bool = false,
    show_in_help: bool = true,
};

/// Hidden entry for shell completion scripts: `zask __complete <words...>`,
/// where the last word is the one under the cursor (empty for a new word).
/// Selected before argv0 aliases and config selection so it works everywhere.
const completion_command = "__complete";

const command_specs = [_]CommandSpec{
    .{ .command = .open, .names = &.{"open"}, .usage = "open [--docker|--<profile>]", .description = "Open workspace and attach", .completion = .open_profile },
    .{ .command = .close, .names = &.{"close"}, .usage = "close", .description = "Stop resources and close workspace" },
    .{ .command = .re, .names = &.{"re"}, .usage = "re", .description = "Restart session" },
    .{ .command = .attach, .names = &.{"attach"}, .usage = "attach", .description = "Attach to existing workspace" },
    .{ .command = .start, .names = &.{"start"}, .usage = "start <--all|svc|group|docker>", .description = "Start resources in existing workspace", .completion = .start_target },
    .{ .command = .stop, .names = &.{"stop"}, .usage = "stop <--all|svc|group|docker>", .description = "Stop resources, keeping workspace open", .completion = .start_target },
    .{ .command = .restart, .names = &.{"restart"}, .usage = "restart <svc|group|docker>", .description = "Restart service, group, or docker", .completion = .restart_target },
    .{ .command = .list, .names = &.{"list"}, .usage = "list", .description = "List configured services" },
    .{ .command = .status, .names = &.{"status"}, .usage = "status [--json]", .description = "Show service state" },
    .{ .command = .check, .names = &.{"check"}, .usage = "check [--prechecks]", .description = "Check config and environment without opening a session" },
    .{ .command = .logs, .names = &.{"logs"}, .usage = "logs <service> [--tail <n>]", .description = "Focus service window, or print its last n lines", .completion = .service },
    .{ .command = .init, .names = &.{"init"}, .usage = "init [project] [--root <path>] [--from <Procfile>] [--force]", .description = "Create project config", .completion = .init_options, .global = true },
    .{ .command = .wait, .names = &.{"wait"}, .usage = "wait <svc|group>... [--timeout <sec>]", .description = "Wait until services are ready" },
    .{ .command = .completion, .names = &.{"completion"}, .usage = "completion [zsh|bash|fish]", .description = "Print shell completion script", .completion = .shell, .global = true },
    .{ .command = .add, .names = &.{"add"}, .usage = "add <svc> <command> [--group <group>] [--port <port>]", .description = "Add a service to the config" },
    .{ .command = .version, .names = &.{"version"}, .usage = "version", .description = "Print zask version", .global = true },
    .{ .command = .help, .names = &.{ "help", "--help", "-h" }, .usage = "help", .description = "Print this help", .global = true },
    .{ .command = .dashboard, .names = &.{"dashboard"}, .internal = true, .show_in_help = false },
    .{ .command = .monitor, .names = &.{"monitor"}, .internal = true, .show_in_help = false },
    .{ .command = .preview_list, .names = &.{"preview-list"}, .internal = true, .show_in_help = false },
    .{ .command = .sync_size, .names = &.{"sync-size"}, .internal = true, .show_in_help = false },
    .{ .command = .watch, .names = &.{"watch"}, .internal = true, .show_in_help = false },
};

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "_log-stream")) return root.log_stream.run(arena, init.io, args[2], args[3]);
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

    runWithArgs(context, if (args.len > 1) args[1..] else &.{}, stdout) catch |err| {
        if (err_ctx.json_output) return exitWithJsonError(arena, stdout, err, err_ctx, diags);
        return exitWithTextError(stdout, err, err_ctx, diags);
    };
    try stdout.flush();
}

fn exitWithJsonError(gpa: std.mem.Allocator, stdout: *std.Io.Writer, err: anyerror, err_ctx: cli_context.ErrorContext, diags: diagnostics.Diagnostics) !void {
    const failure = try status_json.writeError(gpa, stdout, err, .{ .config_path = err_ctx.config_path, .diagnostics = diags.slice() });
    try stdout.flush();
    if (failure) |known| std.process.exit(known.exit_code);
    return err;
}

fn exitWithTextError(stdout: *std.Io.Writer, err: anyerror, err_ctx: cli_context.ErrorContext, diags: diagnostics.Diagnostics) !void {
    switch (err) {
        error.InvalidArguments, error.UnknownCommand, error.ProjectRequired, error.ConfigAlreadyExists, error.InvalidProcfile, error.UnknownTarget, error.CommentedConfigNotEditable, error.ServiceAlreadyExists, error.GroupNotFound, error.GroupRequired, error.ServiceNotAdded => {
            try stdout.flush();
            std.process.exit(2);
        },
        error.ConfigNotFound => {
            try stdout.writeAll("Error: config not found\n");
            try stdout.flush();
            std.process.exit(2);
        },
        error.AmbiguousConfig => {
            try stdout.writeAll("Error: multiple config files found\n");
            for (err_ctx.conflicting_config_paths) |path| try stdout.print("  {s}\n", .{path});
            try stdout.writeAll("Use --config <file> to choose one.\n");
            try stdout.flush();
            std.process.exit(2);
        },
        error.InvalidConfigSyntax => {
            try stdout.print("Error: config is not valid {s}\n", .{configFormat(err_ctx).label()});
            try renderSelectedConfig(stdout, err_ctx);
            try renderDiagnostics(stdout, diags);
            try stdout.flush();
            std.process.exit(2);
        },
        error.InvalidConfig => {
            try stdout.writeAll("Error: invalid config\n");
            try renderSelectedConfig(stdout, err_ctx);
            try renderDiagnostics(stdout, diags);
            try stdout.flush();
            std.process.exit(2);
        },
        error.ConfigPathNotFound, error.CheckFailed => {
            try stdout.flush();
            std.process.exit(2);
        },
        error.ConfigTooLarge => {
            try stdout.writeAll("Error: config file too large\n");
            try stdout.flush();
            std.process.exit(2);
        },
        error.EnvironmentCheckFailed, error.SessionNotRunning, error.TmuxUnavailable, error.ServiceStopIncomplete, error.StartupFailed, error.WindowNotReady, error.ServiceNotFound, error.ServiceWindowMissing, error.LogOutputTooLarge, error.ServiceNotRunning, error.ReadinessUnavailable, error.WaitTimedOut => {
            try stdout.flush();
            std.process.exit(1);
        },
        error.ConfigChanged, error.ConfigConflict, error.ConfigWriteFailed => {
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
    }
}

pub fn runWithArgs(context: CommandContext, args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], completion_command)) return runCompletion(context, args[1..], writer);
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

/// Prints candidates for the last word. Config and argument problems only drop
/// candidates, so a broken config never interrupts the user's shell; only
/// output and allocation failures are returned.
fn runCompletion(context: CommandContext, words: []const []const u8, writer: *std.Io.Writer) !void {
    var quiet = context;
    quiet.diagnostics = null;
    quiet.error_context = null;
    const current = if (words.len == 0) "" else words[words.len - 1];
    const typed = if (words.len == 0) words else words[0 .. words.len - 1];

    var candidates = complete.Candidates.init(context.gpa, current);
    defer candidates.deinit();
    switch (completionPosition(quiet, typed)) {
        .none => {},
        .command => |scope| {
            try addCommandCandidates(&candidates);
            if (scope == .top_level) try candidates.add("--config");
        },
        .argument => |argument| {
            if (argument.or_project_command) try addCommandCandidates(&candidates);
            const cfg = if (argument.kind.needsConfig())
                cli_context.loadConfig(quiet, argument.parsed) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => null,
                }
            else
                null;
            try complete.collectArguments(argument.kind, argument.parsed.args, cfg, &candidates);
        },
    }
    try candidates.write(writer);
}

const CompletionPosition = union(enum) {
    none,
    command: enum { top_level, after_selection },
    argument: struct {
        parsed: ParsedArgs,
        kind: complete.ArgKind,
        /// The single typed word is also an existing named config, so the next
        /// word may instead be a command (`zask <project> <command>`).
        or_project_command: bool = false,
    },
};

/// Mirrors `parseArgs` on the words before the cursor so completion uses the
/// same command forms and config selection as a real invocation.
fn completionPosition(context: CommandContext, typed: []const []const u8) CompletionPosition {
    if (typed.len == 0) return .{ .command = .top_level };
    if (std.mem.eql(u8, typed[0], "--config")) {
        if (typed.len == 1) return .none;
        if (typed.len == 2) return .{ .command = .after_selection };
    }
    const parsed = parseArgs(context, typed) catch |err| switch (err) {
        error.ProjectRequired => return .{ .command = .after_selection },
        else => return .none,
    };
    const command = parseCommand(parsed.command, parsed.config_source == .explicit) orelse return .none;
    return .{ .argument = .{
        .parsed = parsed,
        .kind = commandSpec(command).completion,
        .or_project_command = typed.len == 1 and parsed.project == null and !isGlobalCommand(typed[0]) and
            (namedProjectExists(context, typed[0]) catch false),
    } };
}

fn addCommandCandidates(candidates: *complete.Candidates) !void {
    for (command_specs) |spec| {
        if (!spec.show_in_help) continue;
        for (spec.names) |name| try candidates.add(name);
    }
}

fn commandSpec(command: Command) CommandSpec {
    for (command_specs) |spec| {
        if (spec.command == command) return spec;
    }
    unreachable;
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

fn configFormat(err_ctx: cli_context.ErrorContext) jsonc.Format {
    return jsonc.Format.fromPath(err_ctx.config_path orelse return .json);
}

fn renderSelectedConfig(writer: *std.Io.Writer, err_ctx: cli_context.ErrorContext) !void {
    if (err_ctx.config_source != .discovered and err_ctx.config_source != .inferred_named) return;
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
    if (try shouldUseNamedProject(context, args)) {
        return .{ .project = args[0], .config_source = .named, .command = args[1], .args = args[2..] };
    }
    if (isCommandForm(args[0])) return .{ .command = args[0], .args = args[1..] };
    if (args.len < 2) return error.ProjectRequired;
    return .{ .project = args[0], .config_source = .named, .command = args[1], .args = args[2..] };
}

fn shouldUseNamedProject(context: CommandContext, args: []const []const u8) !bool {
    if (args.len < 2) return false;
    if (parseCommand(args[1], false) == null) return false;
    return namedProjectExists(context, args[0]);
}

fn namedProjectExists(context: CommandContext, project: []const u8) !bool {
    const io = context.io orelse return false;
    const path = try cli_context.projectConfigPath(context.gpa, io, context.environ, project, context.error_context);
    defer context.gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
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

fn testComplete(gpa: std.mem.Allocator, argv0: []const u8, words: []const []const u8) ![]const u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(gpa);
    try environ.put("HOME", "/home/me");
    const args = try std.mem.concat(gpa, []const u8, &.{ &.{completion_command}, words });
    var out: std.Io.Writer.Allocating = .init(gpa);
    try runWithArgs(.{ .gpa = gpa, .io = threaded.io(), .environ = &environ, .argv0 = argv0 }, args, &out.writer);
    return out.toOwnedSlice();
}

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
        .{ .input = "check", .expected = .check },
        .{ .input = "detach", .expected = null },
        .{ .input = "dashboard", .expected = null },
        .{ .input = "preview-list", .expected = null },
        .{ .input = "sync-size", .expected = null },
        .{ .input = "watch", .expected = null },
        .{ .input = "render-session", .expected = null },
    };
    for (command_cases) |case| {
        try std.testing.expectEqual(case.expected, parseCommand(case.input, false));
    }
    try std.testing.expectEqual(Command.dashboard, parseCommand("dashboard", true));
    try std.testing.expectEqual(Command.preview_list, parseCommand("preview-list", true));
    try std.testing.expectEqual(Command.sync_size, parseCommand("sync-size", true));
    try std.testing.expectEqual(Command.watch, parseCommand("watch", true));

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
    try std.testing.expectEqualStrings("zask 0.1.3\n", writer.buffered());
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
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "init [project] [--root <path>] [--from <Procfile>] [--force]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "wait <svc|group>... [--timeout <sec>]") != null);
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

test "cli.parseArgs: defers command form config resolution" {
    const status_args = try parseArgs(.{ .gpa = std.testing.allocator }, &.{"status"});
    try std.testing.expect(status_args.project == null);
    try std.testing.expect(status_args.config_path == null);
    try std.testing.expect(status_args.config_source == null);
    try std.testing.expectEqualStrings("status", status_args.command);

    const logs_args = try parseArgs(.{ .gpa = std.testing.allocator }, &.{ "logs", "api" });
    try std.testing.expect(logs_args.project == null);
    try std.testing.expect(logs_args.config_source == null);
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

test "cli.parseArgs: reports named project probe errors" {
    var threaded = std.Io.Threaded.init_single_threaded;

    try std.testing.expectError(error.HomeNotSet, parseArgs(.{
        .gpa = std.testing.allocator,
        .io = threaded.io(),
    }, &.{ "open", "status" }));
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

test "cli.status: --json routes config failures to JSON output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    try environ.put("HOME", "/home/me");
    const cases = [_]struct {
        args: []const []const u8,
        json_output: bool,
    }{
        .{ .args = &.{ "--config", "testdata/missing.json", "status", "--json" }, .json_output = true },
        .{ .args = &.{ "--config", "testdata/missing.json", "status" }, .json_output = false },
    };

    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        var err_ctx: cli_context.ErrorContext = .{};

        try std.testing.expectError(error.ConfigNotFound, runWithArgs(.{
            .gpa = arena.allocator(),
            .io = threaded.io(),
            .environ = &environ,
            .error_context = &err_ctx,
        }, case.args, &writer));

        try std.testing.expectEqual(case.json_output, err_ctx.json_output);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
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

/// Runs `check` with PATH limited to `<tmp>/bin`, which holds fake `tools`.
fn testRunCheck(gpa: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir, tools: []const []const u8, config_path: []const u8, writer: *std.Io.Writer) !void {
    try tmp.dir.createDirPath(io, "bin");
    for (tools) |tool| {
        const sub_path = try std.fs.path.join(gpa, &.{ "bin", tool });
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    }
    var environ = env.Map.init(gpa);
    try environ.put("HOME", "/home/me");
    try environ.put("PATH", try tmp.dir.realPathFileAlloc(io, "bin", gpa));
    var diags = diagnostics.Diagnostics.init(gpa);
    var err_ctx: cli_context.ErrorContext = .{};
    try runWithArgs(.{
        .gpa = gpa,
        .io = io,
        .environ = &environ,
        .diagnostics = &diags,
        .error_context = &err_ctx,
    }, &.{ "--config", config_path, "check" }, writer);
}

fn testWriteConfig(gpa: std.mem.Allocator, io: std.Io, tmp: std.testing.TmpDir, comptime body: []const u8) ![]const u8 {
    const project_root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const json = try std.fmt.allocPrint(gpa, "{{\"project\":{{\"name\":\"demo\",\"root\":\"{s}\"}},{s}}}", .{ project_root, body });
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = json });
    return std.fs.path.join(gpa, &.{ project_root, "zask.json" });
}

test "cli.check: reports success for a valid config with existing paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "backend");
    const config_path = try testWriteConfig(gpa, io, tmp,
        \\"groups":[{"name":"be","services":[{"name":"api","dir":"backend","command":"serve"}]}]
    );
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try testRunCheck(gpa, io, tmp, &.{ "tmux", "serve" }, config_path, &writer);

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa, "Config OK: {s}\nEnvironment OK\n", .{config_path}), writer.buffered());
}

test "cli.check: lists every validation problem and skips path checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try testWriteConfig(gpa, io, tmp,
        \\"groups":[{"name":"be","services":[{"name":"api","dir":"missing","comand":"serve"}]}],
        \\"startup_order":[{"group":"bee"}]
    );
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CheckFailed, testRunCheck(gpa, io, tmp, &.{}, config_path, &writer));

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa,
        \\Error: 3 config problems
        \\Config: {s}
        \\  groups[0].services[0].comand: unknown key; did you mean 'command'?
        \\  groups[0].services[0]: missing required string 'command'
        \\  startup_order[0].group: unknown group 'bee'; did you mean 'be'?
        \\Path and environment checks were skipped; fix the problems above and run check again.
        \\
    , .{config_path}), writer.buffered());
}

test "cli.check: lists every missing configured path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try testWriteConfig(gpa, io, tmp,
        \\"groups":[{"name":"be","services":[
        \\  {"name":"api","dir":"backend","command":"serve"},
        \\  {"name":"web","command":"dev","env_file":".env"}
        \\]}]
    );
    const project_root = std.fs.path.dirname(config_path).?;
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.CheckFailed, testRunCheck(gpa, io, tmp, &.{ "tmux", "dev" }, config_path, &writer));

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa,
        \\Error: 2 config problems
        \\Config: {s}
        \\  groups[be].services[api].dir: directory not found: {s}/backend
        \\  groups[be].services[web].env_file: file not found: {s}/.env
        \\Environment OK
        \\
    , .{ config_path, project_root, project_root }), writer.buffered());
}

test "cli.completion: lists public commands and config option at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expected = "open\nclose\nre\nattach\nstart\nstop\nrestart\nlist\nstatus\ncheck\nlogs\ninit\nwait\ncompletion\nadd\nversion\nhelp\n--help\n-h\n--config\n";

    try std.testing.expectEqualStrings(expected, try testComplete(arena.allocator(), "zask", &.{""}));
    try std.testing.expectEqualStrings(expected, try testComplete(arena.allocator(), "zask", &.{}));
    try std.testing.expectEqualStrings(expected, try testComplete(arena.allocator(), "sample", &.{""}));
    try std.testing.expectEqualStrings("re\nrestart\n", try testComplete(arena.allocator(), "zask", &.{"re"}));
}

test "cli.completion: lists project commands after config selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const expected = "open\nclose\nre\nattach\nstart\nstop\nrestart\nlist\nstatus\ncheck\nlogs\ninit\nwait\ncompletion\nadd\nversion\nhelp\n--help\n-h\n";

    try std.testing.expectEqualStrings(expected, try testComplete(arena.allocator(), "zask", &.{ "--config", "testdata/synthetic.json", "" }));
    try std.testing.expectEqualStrings(expected, try testComplete(arena.allocator(), "zask", &.{ "demo", "" }));
    try std.testing.expectEqualStrings("", try testComplete(arena.allocator(), "zask", &.{ "--config", "" }));
}

test "cli.completion: offers commands after named config sharing a command name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "xdg/zask/logs");
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/zask/logs/config.json", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    var environ = env.Map.init(gpa);
    try environ.put("XDG_CONFIG_HOME", try std.fs.path.join(gpa, &.{ base, "xdg" }));
    var out: std.Io.Writer.Allocating = .init(gpa);

    try runWithArgs(.{ .gpa = gpa, .io = io, .environ = &environ }, &.{ completion_command, "logs", "li" }, &out.writer);

    try std.testing.expectEqualStrings("list\n", out.written());
}

test "cli.completion: offers targets from explicit config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct { words: []const []const u8, expected: []const u8 }{
        .{ .words = &.{ "restart", "" }, .expected = "docker\nbackend\nfrontend\ncore-backend\napi\nworker\nweb\n" },
        .{ .words = &.{ "start", "" }, .expected = "--all\ndocker\nbackend\nfrontend\ncore-backend\napi\nworker\nweb\n" },
        .{ .words = &.{ "stop", "w" }, .expected = "worker\nweb\n" },
        .{ .words = &.{ "logs", "" }, .expected = "api\nworker\nweb\n" },
        .{ .words = &.{ "open", "--" }, .expected = "--docker\n--core\n" },
        .{ .words = &.{ "restart", "api", "" }, .expected = "" },
        .{ .words = &.{ "status", "" }, .expected = "" },
    };

    for (cases) |case| {
        const words = try std.mem.concat(gpa, []const u8, &.{ &.{ "--config", "testdata/synthetic.json" }, case.words });
        try std.testing.expectEqualStrings(case.expected, try testComplete(gpa, "zask", words));
    }
    try std.testing.expectEqualStrings("api\n", try testComplete(gpa, "sample", &.{ "--config", "testdata/synthetic.json", "logs", "a" }));
}

test "cli.completion: keeps static candidates when config cannot load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "syntax.json", .data = "not json" });
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "invalid.json", .data = "{\"foo\":1}" });
    const base = try tmp.dir.realPathFileAlloc(threaded.io(), ".", gpa);
    const configs = [_][]const u8{
        try std.fs.path.join(gpa, &.{ base, "syntax.json" }),
        try std.fs.path.join(gpa, &.{ base, "invalid.json" }),
        try std.fs.path.join(gpa, &.{ base, "missing.json" }),
    };

    for (configs) |path| {
        try std.testing.expectEqualStrings("--all\n", try testComplete(gpa, "zask", &.{ "--config", path, "start", "" }));
        try std.testing.expectEqualStrings("", try testComplete(gpa, "zask", &.{ "--config", path, "restart", "" }));
    }
}

test "cli.completion: offers init options without config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("--root\n--from\n--force\n", try testComplete(arena.allocator(), "zask", &.{ "init", "demo", "--" }));
    try std.testing.expectEqualStrings("", try testComplete(arena.allocator(), "zask", &.{ "init", "--root", "" }));
}

test "cli.completion: offers shell names for completion command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("zsh\nbash\nfish\n", try testComplete(arena.allocator(), "zask", &.{ "completion", "" }));
    try std.testing.expectEqualStrings("", try testComplete(arena.allocator(), "zask", &.{ "completion", "zsh", "" }));
}

test "cli.check: fails with environment problems after a clean config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config_path = try testWriteConfig(gpa, io, tmp,
        \\"prechecks":[{"name":"db","command":"pg_isready"}],
        \\"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]
    );
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.EnvironmentCheckFailed, testRunCheck(gpa, io, tmp, &.{ "serve", "bash" }, config_path, &writer));

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(gpa,
        \\Config OK: {s}
        \\Error: 1 environment problem
        \\  tmux: not found in PATH; zask runs every service in a tmux session
        \\    Fix: install tmux or add it to PATH
        \\Prechecks: 1 not run; add --prechecks to run them
        \\
    , .{config_path}), writer.buffered());
}
