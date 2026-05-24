const std = @import("std");
const config = @import("../../model/config.zig");
const env = @import("../../platform/env.zig");
const paths = @import("../../platform/paths.zig");
const validate = @import("../../model/validate.zig");
const cli_context = @import("context.zig");

const Context = cli_context.Context;

pub const Options = struct {
    project: []const u8,
    root: ?[]const u8 = null,
    service: ?[]const u8 = null,
    command: ?[]const u8 = null,
    dir: []const u8 = ".",
    port: ?i64 = null,
    group: []const u8 = "app",
    docker: bool = false,
    docker_dir: []const u8 = "",
    compose_file: []const u8 = "docker-compose.yml",
    force: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len == 0) return error.InvalidArguments;
        var opts: Options = .{ .project = args[0] };
        var flags: OptionFlags = .{};
        var i: usize = 1;
        while (i < args.len) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--root")) {
                opts.root = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--service")) {
                opts.service = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--command")) {
                opts.command = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--dir")) {
                flags.dir = true;
                opts.dir = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--port")) {
                flags.port = true;
                opts.port = std.fmt.parseInt(i64, try takeValue(args, &i), 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, arg, "--group")) {
                flags.group = true;
                opts.group = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--docker")) {
                opts.docker = true;
            } else if (std.mem.eql(u8, arg, "--docker-dir")) {
                flags.docker_dir = true;
                opts.docker_dir = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--compose-file")) {
                flags.compose_file = true;
                opts.compose_file = try takeValue(args, &i);
            } else if (std.mem.eql(u8, arg, "--force")) {
                opts.force = true;
            } else {
                return error.InvalidArguments;
            }
            i += 1;
        }
        try validateOptions(opts, flags);
        return opts;
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

const OptionFlags = struct {
    dir: bool = false,
    port: bool = false,
    group: bool = false,
    docker_dir: bool = false,
    compose_file: bool = false,
};

pub fn run(ctx: *Context, opts: Options) !void {
    const io = ctx.base.io orelse return error.MissingIo;
    const config_path = try cli_context.projectConfigPath(ctx.base.gpa, ctx.base.environ, opts.project);
    if (!opts.force and paths.exists(io, config_path)) {
        try ctx.writer.print("Config already exists: {s}\n", .{config_path});
        try ctx.writer.print("Re-run with --force to overwrite it.\n", .{});
        return error.ConfigAlreadyExists;
    }

    const json = try renderConfig(ctx.base.gpa, opts);
    defer ctx.base.gpa.free(json);
    _ = try config.Config.parse(ctx.base.gpa, json, try paths.home(ctx.base.environ));

    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, config_dir, @enumFromInt(0o755));
    try paths.writeFile(io, config_path, json);

    try ctx.writer.print("Created {s}\n", .{config_path});
    try ctx.writer.print("Next: zask {s} list\n", .{opts.project});
    try ctx.writer.print("Next: zask {s} open\n", .{opts.project});
}

fn validateOptions(opts: Options, flags: OptionFlags) !void {
    validate.identifier(opts.project) catch return error.InvalidArguments;
    if (opts.service) |name| validate.identifier(name) catch return error.InvalidArguments;
    if (opts.service != null and opts.command == null) return error.InvalidArguments;
    if (opts.service == null and opts.command != null) return error.InvalidArguments;
    if (opts.service == null and (flags.dir or flags.port or flags.group)) return error.InvalidArguments;
    if (!opts.docker and (flags.docker_dir or flags.compose_file)) return error.InvalidArguments;
    if (opts.port) |port| {
        if (port <= 0 or port > 65535) return error.InvalidArguments;
    }
    validate.relativeSubPath(opts.dir) catch return error.InvalidArguments;
    validate.relativeSubPath(opts.docker_dir) catch return error.InvalidArguments;
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn renderConfig(gpa: std.mem.Allocator, opts: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var writer = &out.writer;
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
    const default_root = try std.fmt.allocPrint(gpa, "~/projects/{s}", .{opts.project});
    defer gpa.free(default_root);

    try json.beginObject();
    try json.objectField("project");
    try json.beginObject();
    try json.objectField("name");
    try json.write(opts.project);
    try json.objectField("root");
    try json.write(opts.root orelse default_root);
    try json.objectField("session_name");
    try json.write(opts.project);
    try json.endObject();
    if (opts.docker) {
        try json.objectField("docker");
        try json.beginObject();
        try json.objectField("enabled");
        try json.write(true);
        if (opts.docker_dir.len != 0) {
            try json.objectField("dir");
            try json.write(opts.docker_dir);
        }
        try json.objectField("compose_file");
        try json.write(opts.compose_file);
        try json.endObject();
    }
    try json.objectField("services");
    try json.beginArray();
    if (opts.service) |service_name| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(service_name);
        try json.objectField("dir");
        try json.write(opts.dir);
        try json.objectField("command");
        try json.write(opts.command.?);
        if (opts.port) |port| {
            try json.objectField("port");
            try json.write(port);
        }
        try json.objectField("group");
        try json.write(opts.group);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testContext(gpa: std.mem.Allocator, io: std.Io, environ: *const env.Map, writer: *std.Io.Writer) Context {
    return .{
        .base = .{ .gpa = gpa, .io = io, .environ = environ },
        .parsed = .{ .command = "init", .args = &.{} },
        .writer = writer,
        .print_help = testPrintHelp,
    };
}

fn testPrintHelp(writer: *std.Io.Writer) !void {
    _ = writer;
}

test "init.options: parses service and docker flags" {
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--service", "web", "--command", "npm run dev", "--port", "3000", "--docker", "--docker-dir", "infra", "--compose-file", "compose.yaml" });
    try std.testing.expectEqualStrings("demo", opts.project);
    try std.testing.expectEqualStrings(".", opts.root.?);
    try std.testing.expectEqualStrings("web", opts.service.?);
    try std.testing.expectEqualStrings("npm run dev", opts.command.?);
    try std.testing.expectEqual(@as(i64, 3000), opts.port.?);
    try std.testing.expect(opts.docker);
    try std.testing.expectEqualStrings("infra", opts.docker_dir);
    try std.testing.expectEqualStrings("compose.yaml", opts.compose_file);
}

test "init.options: normalizes invalid input to invalid arguments" {
    const cases = [_][]const []const u8{
        &.{"bad/name"},
        &.{ "demo", "--service", "bad/name", "--command", "npm run dev" },
        &.{ "demo", "--service", "web", "--command", "npm run dev", "--dir", "../x" },
        &.{ "demo", "--service", "web", "--command", "npm run dev", "--port", "abc" },
        &.{ "demo", "--service", "web", "--command", "npm run dev", "--port", "70000" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(case));
    }
}

test "init.options: rejects options without their parent section" {
    const cases = [_][]const []const u8{
        &.{ "demo", "--dir", "backend" },
        &.{ "demo", "--port", "3000" },
        &.{ "demo", "--group", "app" },
        &.{ "demo", "--docker-dir", "infra" },
        &.{ "demo", "--compose-file", "compose.yaml" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(case));
    }
}

test "init.config: renders parseable minimal config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try Options.parse(&.{"demo"});
    const json = try renderConfig(std.testing.allocator, opts);
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings("demo", try cfg.sessionName());
    const project_root = try cfg.projectRoot(arena.allocator());
    try std.testing.expectEqualStrings("/home/me/projects/demo", project_root);
    try std.testing.expectEqual(@as(usize, 0), (try cfg.services()).len);
}

test "init.config: renders service and docker config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--service", "web", "--command", "npm run dev", "--port", "3000", "--docker", "--docker-dir", "infra", "--compose-file", "compose.yaml" });
    const json = try renderConfig(std.testing.allocator, opts);
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const services = try cfg.services();

    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("web", try config.Config.serviceName(services[0]));
    try std.testing.expectEqualStrings("app", config.Config.serviceGroup(services[0]));
    try std.testing.expectEqual(@as(?i64, 3000), config.Config.servicePort(services[0]));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
}

test "init.run: rejects existing config without force" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(arena.allocator(), threaded.io(), &environ, &writer);

    try run(&ctx, try Options.parse(&.{"demo"}));
    try std.testing.expectError(error.ConfigAlreadyExists, run(&ctx, try Options.parse(&.{"demo"})));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Re-run with --force") != null);
}

test "init.run: overwrites existing config with force" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(arena.allocator(), threaded.io(), &environ, &writer);

    try run(&ctx, try Options.parse(&.{ "demo", "--service", "web", "--command", "npm run dev" }));
    try run(&ctx, try Options.parse(&.{ "demo", "--force" }));

    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, arena.allocator(), .limited(4096));
    const cfg = try config.Config.parse(arena.allocator(), bytes, "/home/me");
    try std.testing.expectEqual(@as(usize, 0), (try cfg.services()).len);
}
