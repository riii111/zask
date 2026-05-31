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
    const runner: proc_runner.Runner = .{ .gpa = context.gpa, .io = io };
    return .{
        .gpa = context.gpa,
        .io = io,
        .environ = context.environ,
        .cfg = cfg,
        .config_path = resolved.path,
        .zask_path = try zaskExecutablePath(context.gpa, io, context.argv0),
        .runner_impl = runner,
        .tmux_impl = tmux_client.Client{ .gpa = context.gpa, .runner = runner, .session = try cfg.sessionName() },
        .docker_impl = docker_client.Compose{ .gpa = context.gpa, .runner = runner, .dir = try cfg.dockerDir(context.gpa), .file = cfg.dockerComposeFile() },
    };
}

const ResolvedConfigPath = struct {
    path: []const u8,
    source: ConfigSource,
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
        };
    }
    return .{ .path = try discoverConfigPath(gpa, io), .source = .discovered };
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
