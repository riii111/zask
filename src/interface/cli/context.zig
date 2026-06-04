const std = @import("std");

const config = @import("../../model/config.zig");
const diagnostics = @import("../../model/diagnostics.zig");
const docker_client = @import("../../platform/docker.zig");
const env = @import("../../platform/env.zig");
const paths = @import("../../platform/paths.zig");
const proc_runner = @import("../../platform/runner.zig");
const tmux_client = @import("../../platform/tmux.zig");
const validate = @import("../../model/validate.zig");
const Runtime = @import("../../workflow/runtime.zig").Runtime;

pub const ConfigSource = enum {
    explicit,
    named,
    discovered,
    inferred_named,
};

pub const ParsedArgs = struct {
    config_path: ?[]const u8 = null,
    config_source: ?ConfigSource = null,
    project: ?[]const u8 = null,
    command: []const u8,
    args: []const []const u8,
};

pub const ErrorContext = struct {
    /// Error output uses the resolved path, not the raw CLI argument.
    config_path: ?[]const u8 = null,
    /// Source is recorded after discovery so diagnostics only mention real selections.
    config_source: ?ConfigSource = null,
};

pub const CommandContext = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    environ: ?*const env.Map = null,
    argv0: []const u8 = "zask",
    diagnostics: ?*diagnostics.Diagnostics = null,
    error_context: ?*ErrorContext = null,
};

pub const Context = struct {
    base: CommandContext,
    parsed: ParsedArgs,
    writer: *std.Io.Writer,
    print_help: *const fn (*std.Io.Writer) anyerror!void,
    runtime_value: ?Runtime = null,

    pub fn help(self: *Context) !void {
        try self.print_help(self.writer);
    }

    pub fn runtime(self: *Context) !Runtime {
        if (self.runtime_value == null) {
            self.runtime_value = try loadRuntime(self.base, self.parsed);
        }
        return self.runtime_value.?;
    }
};

pub fn isProjectAlias(argv0: []const u8) bool {
    const basename = std.fs.path.basename(argv0);
    return !std.mem.eql(u8, basename, "zask") and !std.mem.eql(u8, basename, "zask-debug");
}

pub fn parseSize(arg: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, arg, 10) catch return error.InvalidArguments;
}

fn loadRuntime(context: CommandContext, parsed: ParsedArgs) !Runtime {
    const io = context.io orelse return error.MissingIo;
    const resolved = try resolveConfigPath(context.gpa, io, context, parsed);
    if (context.error_context) |err_ctx| {
        err_ctx.config_path = resolved.path;
        err_ctx.config_source = resolved.source;
    }
    const home = try paths.home(context.environ);
    const cfg = if (context.diagnostics) |diags|
        try config.loadPathWithDiagnostics(context.gpa, io, resolved.path, home, diags)
    else
        try config.loadPath(context.gpa, io, resolved.path, home);
    try validateSelectedProjectName(context, resolved, cfg);
    const runner: proc_runner.Runner = .{ .gpa = context.gpa, .io = io };
    return .{
        .gpa = context.gpa,
        .io = io,
        .environ = context.environ,
        .cfg = cfg,
        .config_path = resolved.path,
        .zask_path = try zaskExecutablePath(context.gpa, io, context.argv0),
        .runner_impl = runner,
        .tmux_impl = tmux_client.Client{ .gpa = context.gpa, .runner = runner, .session = try cfg.projectName() },
        .docker_impl = docker_client.Compose{ .gpa = context.gpa, .runner = runner, .dir = try cfg.dockerDir(context.gpa), .file = cfg.dockerComposeFile() },
    };
}

const ResolvedConfigPath = struct {
    path: []const u8,
    source: ConfigSource,
    project: ?[]const u8 = null,
};

fn resolveConfigPath(gpa: std.mem.Allocator, io: std.Io, context: CommandContext, parsed: ParsedArgs) !ResolvedConfigPath {
    if (parsed.config_path) |path| {
        return .{
            .path = try absoluteConfigPath(gpa, io, path),
            .source = parsed.config_source orelse .explicit,
        };
    }
    if (parsed.project) |project| {
        return .{
            .path = try absoluteConfigPath(gpa, io, try projectConfigPath(gpa, context.environ, project)),
            .source = .named,
            .project = project,
        };
    }
    const discovered_path = discoverConfigPath(gpa, io) catch |err| switch (err) {
        error.ConfigNotFound => return try inferNamedConfigPath(gpa, io, context.environ),
        else => return err,
    };
    return .{ .path = discovered_path, .source = .discovered };
}

pub fn projectConfigPath(gpa: std.mem.Allocator, environ: ?*const env.Map, project: []const u8) ![]const u8 {
    try validate.identifier(project);
    return std.fs.path.join(gpa, &.{ try paths.configBase(gpa, environ), project, "config.json" });
}

fn absoluteConfigPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return err,
    };
}

fn discoverConfigPath(gpa: std.mem.Allocator, io: std.Io) ![:0]const u8 {
    const candidates = [_][]const u8{ "zask.json", ".zask.json" };
    var found: ?[:0]const u8 = null;
    errdefer if (found) |path| gpa.free(path);

    for (candidates) |candidate| {
        const path = std.Io.Dir.cwd().realPathFileAlloc(io, candidate, gpa) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (found != null) {
            gpa.free(path);
            return error.AmbiguousConfig;
        }
        found = path;
    }
    return found orelse error.ConfigNotFound;
}

fn inferNamedConfigPath(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map) !ResolvedConfigPath {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);
    const project = std.fs.path.basename(cwd);
    validate.identifier(project) catch return error.ConfigNotFound;
    const project_name = try gpa.dupe(u8, project);
    const path = try projectConfigPath(gpa, environ, project);
    errdefer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return err,
    };
    return .{
        .path = try absoluteConfigPath(gpa, io, path),
        .source = .inferred_named,
        .project = project_name,
    };
}

fn validateSelectedProjectName(context: CommandContext, resolved: ResolvedConfigPath, cfg: config.Config) !void {
    const expected = resolved.project orelse return;
    const actual = try cfg.projectName();
    if (std.mem.eql(u8, expected, actual)) return;
    if (context.diagnostics) |diags| {
        try diags.addFmt("project.name", "must match named config '{s}'", .{expected});
    }
    return error.InvalidConfig;
}

fn absoluteExePath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    if (std.mem.indexOfScalar(u8, path, '/') != null) {
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa);
    }
    return path;
}

fn zaskExecutablePath(gpa: std.mem.Allocator, io: std.Io, argv0: []const u8) ![]const u8 {
    if (!isProjectAlias(argv0)) return absoluteExePath(gpa, io, argv0);
    if (std.mem.indexOfScalar(u8, argv0, '/') == null) return "zask";
    const sibling = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(argv0) orelse ".", "zask" });
    return absoluteExePath(gpa, io, sibling);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testWithCwd(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    const previous = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa);
    errdefer gpa.free(previous);
    try std.process.setCurrentPath(io, path);
    return previous;
}

test "cli.context.discoverConfigPath: finds zask.json" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const previous = try testWithCwd(gpa, io, base);
    defer {
        std.process.setCurrentPath(io, previous) catch unreachable;
        gpa.free(previous);
    }

    const path = try discoverConfigPath(gpa, io);
    defer gpa.free(path);

    try std.testing.expectEqualStrings("zask.json", std.fs.path.basename(path));
}

test "cli.context.discoverConfigPath: rejects ambiguous local configs" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zask.json", .data = "{}" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const previous = try testWithCwd(gpa, io, base);
    defer {
        std.process.setCurrentPath(io, previous) catch unreachable;
        gpa.free(previous);
    }

    try std.testing.expectError(error.AmbiguousConfig, discoverConfigPath(gpa, io));
}

test "cli.context.discoverConfigPath: rejects missing local config" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const previous = try testWithCwd(gpa, io, base);
    defer {
        std.process.setCurrentPath(io, previous) catch unreachable;
        gpa.free(previous);
    }

    try std.testing.expectError(error.ConfigNotFound, discoverConfigPath(gpa, io));
}

test "cli.context.loadRuntime: rejects named config with mismatched project name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var environ = env.Map.init(gpa);
    defer environ.deinit();
    var diags = diagnostics.Diagnostics.init(gpa);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const config_home = try std.fs.path.join(gpa, &.{ base, "xdg" });
    const config_dir = try std.fs.path.join(gpa, &.{ config_home, "zask", "demo" });
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, config_dir, @enumFromInt(0o755));
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    const config_path = try std.fs.path.join(gpa, &.{ config_dir, "config.json" });
    try paths.writeFile(io, config_path,
        \\{
        \\  "project": {"name":"other","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    );

    try std.testing.expectError(error.InvalidConfig, loadRuntime(.{
        .gpa = gpa,
        .io = io,
        .environ = &environ,
        .diagnostics = &diags,
    }, .{ .project = "demo", .config_source = .named, .command = "list", .args = &.{} }));
    try std.testing.expectEqualStrings("project.name", diags.slice()[0].path);
    try std.testing.expectEqualStrings("must match named config 'demo'", diags.slice()[0].message);
}
