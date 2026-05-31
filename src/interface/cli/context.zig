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

pub const ParsedArgs = struct {
    config_path: ?[]const u8 = null,
    project: ?[]const u8 = null,
    command: []const u8,
    args: []const []const u8,
};

pub const CommandContext = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io = null,
    environ: ?*const env.Map = null,
    argv0: []const u8 = "zask",
    diagnostics: ?*diagnostics.Diagnostics = null,
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
    const path = try absoluteConfigPath(context.gpa, io, if (parsed.config_path) |p| p else try projectConfigPath(context.gpa, context.environ, parsed.project orelse return error.ProjectRequired));
    const home = try paths.home(context.environ);
    const cfg = if (context.diagnostics) |diags|
        try config.loadPathWithDiagnostics(context.gpa, io, path, home, diags)
    else
        try config.loadPath(context.gpa, io, path, home);
    const runner: proc_runner.Runner = .{ .gpa = context.gpa, .io = io };
    return .{
        .gpa = context.gpa,
        .io = io,
        .environ = context.environ,
        .cfg = cfg,
        .config_path = path,
        .zask_path = try zaskExecutablePath(context.gpa, io, context.argv0),
        .runner_impl = runner,
        .tmux_impl = tmux_client.Client{ .gpa = context.gpa, .runner = runner, .session = try cfg.sessionName() },
        .docker_impl = docker_client.Compose{ .gpa = context.gpa, .runner = runner, .dir = try cfg.dockerDir(context.gpa), .file = cfg.dockerComposeFile() },
    };
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
