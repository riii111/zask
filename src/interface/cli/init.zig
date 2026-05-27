const std = @import("std");
const config = @import("../../model/config.zig");
const env = @import("../../platform/env.zig");
const init_inference = @import("../../workflow/init_inference.zig");
const paths = @import("../../platform/paths.zig");
const validate = @import("../../model/validate.zig");
const cli_context = @import("context.zig");

const Context = cli_context.Context;

pub const Options = struct {
    project: ?[]const u8 = null,
    root: []const u8 = ".",
    force: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var opts: Options = .{};
        var i: usize = 0;
        if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) {
            opts.project = args[0];
            i = 1;
        }
        while (i < args.len) {
            try parseOption(args, &i, &opts);
            i += 1;
        }
        try validateOptions(opts);
        return opts;
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const io = ctx.base.io orelse return error.MissingIo;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", ctx.base.gpa);
    const project = opts.project orelse std.fs.path.basename(cwd);
    try validate.identifier(project);

    const config_path = try cli_context.projectConfigPath(ctx.base.gpa, ctx.base.environ, project);
    if (!opts.force and paths.exists(io, config_path)) {
        try ctx.writer.print("Config already exists: {s}\n", .{config_path});
        try ctx.writer.print("Re-run with --force to overwrite it.\n", .{});
        return error.ConfigAlreadyExists;
    }

    var detected = try applyDetections(ctx.base.gpa, io, cwd, opts);
    detected.opts.root = try resolveRootFromCwd(ctx.base.gpa, cwd, detected.opts.root);
    const json = try renderConfig(ctx.base.gpa, project, detected);
    defer ctx.base.gpa.free(json);
    _ = try config.Config.parse(ctx.base.gpa, json, try paths.home(ctx.base.environ));

    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, config_dir, @enumFromInt(0o755));
    try paths.writeFile(io, config_path, json);

    try ctx.writer.print("Created {s}\n", .{config_path});
    try writeReport(ctx.writer, project, detected);
    try ctx.writer.print("Next: zask {s} list\n", .{project});
    try ctx.writer.print("Next: zask {s} open\n", .{project});
}

const DetectedOptions = struct {
    opts: Options,
    service: ?init_inference.DetectedService = null,
    compose_file: ?[]const u8 = null,
};

fn validateOptions(opts: Options) !void {
    if (opts.project) |project| validate.identifier(project) catch return error.InvalidArguments;
    validateRoot(opts.root) catch return error.InvalidArguments;
}

fn validateRoot(root: []const u8) !void {
    if (std.fs.path.isAbsolute(root) or std.mem.startsWith(u8, root, "~")) return;
    try validate.relativeSubPath(root);
}

fn parseOption(args: []const []const u8, index: *usize, opts: *Options) !void {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--root")) {
        opts.root = try takeValue(args, index);
    } else if (std.mem.eql(u8, arg, "--force")) {
        opts.force = true;
    } else {
        return error.InvalidArguments;
    }
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn resolveRootFromCwd(gpa: std.mem.Allocator, cwd: []const u8, root: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(root) or std.mem.startsWith(u8, root, "~")) return root;
    return std.fs.path.resolve(gpa, &.{ cwd, root });
}

fn applyDetections(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, opts: Options) !DetectedOptions {
    var result = DetectedOptions{ .opts = opts };
    const detected = try init_inference.detect(gpa, io, cwd, .{
        .infer_service = true,
        .infer_compose_file = true,
    });
    result.service = detected.service;
    result.compose_file = detected.compose_file;
    return result;
}

fn renderConfig(gpa: std.mem.Allocator, project: []const u8, detected: DetectedOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var writer = &out.writer;
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try json.beginObject();
    try json.objectField("project");
    try json.beginObject();
    try json.objectField("name");
    try json.write(project);
    try json.objectField("root");
    try json.write(detected.opts.root);
    try json.endObject();
    if (detected.compose_file) |compose_file| {
        try json.objectField("docker");
        try json.beginObject();
        try json.objectField("compose");
        try json.write(compose_file);
        try json.endObject();
    }
    try json.objectField("groups");
    try json.beginArray();
    if (detected.service) |service| {
        try json.beginObject();
        try json.objectField("name");
        try json.write("frontend");
        try json.objectField("services");
        try json.beginArray();
        try json.beginObject();
        try json.objectField("name");
        try json.write(service.name);
        try json.objectField("command");
        try json.write(service.command);
        try json.endObject();
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn writeReport(writer: *std.Io.Writer, project: []const u8, detected: DetectedOptions) !void {
    try writer.print("Detected project.name: {s}\n", .{project});
    try writer.print("Detected project.root: {s}\n", .{detected.opts.root});
    if (detected.service) |service| {
        const script = service.script;
        try writer.print("Detected package script: {s}\n", .{script});
    }
    if (detected.compose_file) |compose_file| {
        try writer.print("Detected Docker Compose file: {s}\n", .{compose_file});
    }
    try writer.writeAll("Omitted defaults: project.session_name");
    if (detected.service != null) try writer.writeAll(", service.dir");
    if (detected.compose_file != null) try writer.writeAll(", docker.wait_timeout_seconds");
    try writer.writeByte('\n');
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

fn testTmpPath(gpa: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "init.options: parses scaffold flags" {
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--force" });

    try std.testing.expectEqualStrings("demo", opts.project.?);
    try std.testing.expectEqualStrings(".", opts.root);
    try std.testing.expect(opts.force);
}

test "init.options: accepts omitted project" {
    const opts = try Options.parse(&.{"--force"});

    try std.testing.expect(opts.project == null);
    try std.testing.expectEqualStrings(".", opts.root);
    try std.testing.expect(opts.force);
}

test "init.options: normalizes invalid input to invalid arguments" {
    const cases = [_][]const []const u8{
        &.{"bad/name"},
        &.{ "demo", "--root", "../x" },
        &.{ "demo", "--root" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(case));
    }
}

test "init.options: rejects removed service and docker flags" {
    const cases = [_][]const []const u8{
        &.{ "demo", "--service", "web" },
        &.{ "demo", "--command", "npm run dev" },
        &.{ "demo", "--dir", "backend" },
        &.{ "demo", "--port", "3000" },
        &.{ "demo", "--group", "app" },
        &.{ "demo", "--docker" },
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
    const json = try renderConfig(std.testing.allocator, "demo", .{ .opts = opts });
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings("demo", try cfg.sessionName());
    const project_root = try cfg.projectRoot(arena.allocator());
    try std.testing.expectEqualStrings(".", project_root);
    try std.testing.expectEqual(@as(usize, 0), (try cfg.services()).len);
    try std.testing.expect(std.mem.indexOf(u8, json, "session_name") == null);
}

test "init.config: renders service and docker config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const detected = DetectedOptions{
        .opts = try Options.parse(&.{ "demo", "--root", "." }),
        .service = .{ .name = "web", .command = "pnpm run dev", .script = "dev" },
        .compose_file = "infra/compose.yaml",
    };
    const json = try renderConfig(std.testing.allocator, "demo", detected);
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const services = try cfg.services();

    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("web", try config.Config.serviceName(services[0]));
    try std.testing.expectEqualStrings("frontend", config.Config.serviceGroup(services[0]));
    try std.testing.expectEqualStrings("pnpm run dev", try config.Config.serviceStartCommand(arena.allocator(), services[0]));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
    try std.testing.expectEqualStrings("./infra", try cfg.dockerDir(arena.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dir\": \".\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"group\"") == null);
}

test "init.config: omits docker when compose is not detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try Options.parse(&.{"demo"});
    const json = try renderConfig(std.testing.allocator, "demo", .{ .opts = opts });
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expect(!cfg.dockerEnabled());
    try std.testing.expect(std.mem.indexOf(u8, json, "\"docker\"") == null);
}

test "init.detect: infers compose file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const compose_yaml = try testTmpPath(arena.allocator(), tmp, "compose.yaml");

    try paths.writeFile(threaded.io(), compose_yaml, "services: {}\n");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));

    try std.testing.expectEqualStrings("compose.yaml", detected.compose_file.?);
}

test "init.detect: renders detected default compose file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const docker_compose = try testTmpPath(arena.allocator(), tmp, "docker-compose.yml");

    try paths.writeFile(threaded.io(), docker_compose, "services: {}\n");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));
    const json = try renderConfig(std.testing.allocator, "demo", detected);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("docker-compose.yml", detected.compose_file.?);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"compose\": \"docker-compose.yml\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "compose_file") == null);
}

test "init.detect: infers package script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const package_json = try testTmpPath(arena.allocator(), tmp, "package.json");

    try paths.writeFile(threaded.io(), package_json, "{\"scripts\":{\"dev\":\"vite\"}}\n");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));

    try std.testing.expectEqualStrings("web", detected.service.?.name);
    try std.testing.expectEqualStrings("npm run dev", detected.service.?.command);
    try std.testing.expectEqualStrings("dev", detected.service.?.script);
}

test "init.report: prints detected values and omitted defaults" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const detected = DetectedOptions{
        .opts = .{},
        .service = .{ .name = "web", .command = "npm run dev", .script = "dev" },
        .compose_file = "docker-compose.yml",
    };

    try writeReport(&writer, "demo", detected);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected project.name: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected package script: dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected Docker Compose file: docker-compose.yml") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "project.session_name, service.dir, docker.wait_timeout_seconds") != null);
}

test "init.root: validates project roots" {
    const cases = [_]struct {
        root: []const u8,
        valid: bool,
    }{
        .{ .root = ".", .valid = true },
        .{ .root = "backend", .valid = true },
        .{ .root = "/srv/demo", .valid = true },
        .{ .root = "~/projects/demo", .valid = true },
        .{ .root = "../escape", .valid = false },
    };
    for (cases) |case| {
        if (case.valid) {
            try validateRoot(case.root);
        } else {
            try std.testing.expectError(error.InvalidPath, validateRoot(case.root));
        }
    }
}

test "init.root: stabilizes default and explicit dot roots" {
    const default_opts = try Options.parse(&.{});
    const default_root = try resolveRootFromCwd(std.testing.allocator, "/work/demo", default_opts.root);
    defer std.testing.allocator.free(default_root);
    const dot_opts = try Options.parse(&.{ "demo", "--root", "." });
    const dot_root = try resolveRootFromCwd(std.testing.allocator, "/work/demo", dot_opts.root);
    defer std.testing.allocator.free(dot_root);

    try std.testing.expectEqualStrings("/work/demo", default_root);
    try std.testing.expectEqualStrings("/work/demo", dot_root);
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

    try run(&ctx, try Options.parse(&.{"demo"}));
    try run(&ctx, try Options.parse(&.{ "demo", "--force" }));

    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, arena.allocator(), .limited(4096));
    const cfg = try config.Config.parse(arena.allocator(), bytes, "/home/me");
    const project_root = try cfg.projectRoot(arena.allocator());
    const expected_root = try std.Io.Dir.cwd().realPathFileAlloc(threaded.io(), ".", arena.allocator());

    try std.testing.expectEqualStrings(expected_root, project_root);
    try std.testing.expectEqual(@as(usize, 0), (try cfg.services()).len);
}
