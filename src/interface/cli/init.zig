const std = @import("std");
const config = @import("../../model/config.zig");
const env = @import("../../platform/env.zig");
const paths = @import("../../platform/paths.zig");
const validate = @import("../../model/validate.zig");
const cli_context = @import("context.zig");

const Context = cli_context.Context;

pub const Options = struct {
    project: ?[]const u8 = null,
    root: []const u8 = ".",
    service: ?[]const u8 = null,
    command: ?[]const u8 = null,
    dir: []const u8 = ".",
    port: ?i64 = null,
    group: []const u8 = "",
    docker: bool = false,
    docker_dir: []const u8 = "",
    compose_file: []const u8 = "docker-compose.yml",
    force: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var opts: Options = .{};
        var flags: OptionFlags = .{};
        var i: usize = 0;
        if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) {
            opts.project = args[0];
            i = 1;
        }
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

const DetectedOptions = struct {
    opts: Options,
    package_script: ?[]const u8 = null,
    compose_file: ?[]const u8 = null,
};

const DetectedService = struct {
    name: []const u8 = "web",
    command: []const u8,
    script: []const u8,
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

    const detected = try applyDetections(ctx.base.gpa, io, cwd, opts);
    const json = try renderConfig(ctx.base.gpa, project, detected.opts);
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

fn validateOptions(opts: Options, flags: OptionFlags) !void {
    if (opts.project) |project| validate.identifier(project) catch return error.InvalidArguments;
    validateRoot(opts.root) catch return error.InvalidArguments;
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

fn validateRoot(root: []const u8) !void {
    if (std.fs.path.isAbsolute(root) or std.mem.startsWith(u8, root, "~")) return;
    try validate.relativeSubPath(root);
}

fn takeValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    return args[index.*];
}

fn applyDetections(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, opts: Options) !DetectedOptions {
    var result = DetectedOptions{ .opts = opts };
    if (opts.service == null) {
        if (try detectPackageService(gpa, io, cwd)) |service| {
            result.opts.service = service.name;
            result.opts.command = service.command;
            result.package_script = service.script;
        }
    }
    if (!opts.docker) {
        if (try detectComposeFile(gpa, io, cwd)) |compose_file| {
            result.opts.docker = true;
            result.opts.compose_file = compose_file;
            result.compose_file = compose_file;
        }
    }
    return result;
}

fn detectPackageService(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !?DetectedService {
    const path = try std.fs.path.join(gpa, &.{ cwd, "package.json" });
    defer gpa.free(path);
    if (!paths.exists(io, path)) return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch return null;
    const package = std.json.parseFromSliceLeaky(std.json.Value, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    if (package != .object) return null;
    const scripts = package.object.get("scripts") orelse return null;
    if (scripts != .object) return null;

    const script_names = [_][]const u8{ "dev", "start", "serve" };
    for (script_names) |script_name| {
        const value = scripts.object.get(script_name) orelse continue;
        if (value != .string) continue;
        return .{
            .command = try std.fmt.allocPrint(gpa, "{s} run {s}", .{ try detectPackageManager(gpa, io, cwd), script_name }),
            .script = script_name,
        };
    }
    return null;
}

fn detectPackageManager(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]const u8 {
    const lockfiles = [_]struct {
        file: []const u8,
        manager: []const u8,
    }{
        .{ .file = "pnpm-lock.yaml", .manager = "pnpm" },
        .{ .file = "bun.lock", .manager = "bun" },
        .{ .file = "bun.lockb", .manager = "bun" },
        .{ .file = "yarn.lock", .manager = "yarn" },
        .{ .file = "package-lock.json", .manager = "npm" },
    };
    for (lockfiles) |lockfile| {
        if (try fileExistsIn(gpa, io, cwd, lockfile.file)) return lockfile.manager;
    }
    return "npm";
}

fn detectComposeFile(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]const u8 {
    const candidates = [_][]const u8{ "compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml" };
    for (candidates) |candidate| {
        if (try fileExistsIn(gpa, io, cwd, candidate)) return candidate;
    }
    return null;
}

fn fileExistsIn(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) !bool {
    const path = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(path);
    return paths.exists(io, path);
}

fn renderConfig(gpa: std.mem.Allocator, project: []const u8, opts: Options) ![]u8 {
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
    try json.write(opts.root);
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
        if (!std.mem.eql(u8, opts.compose_file, "docker-compose.yml")) {
            try json.objectField("compose_file");
            try json.write(opts.compose_file);
        }
        try json.endObject();
    }
    try json.objectField("services");
    try json.beginArray();
    if (opts.service) |service_name| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(service_name);
        if (!std.mem.eql(u8, opts.dir, ".")) {
            try json.objectField("dir");
            try json.write(opts.dir);
        }
        try json.objectField("command");
        try json.write(opts.command.?);
        if (opts.port) |port| {
            try json.objectField("port");
            try json.write(port);
        }
        if (opts.group.len != 0) {
            try json.objectField("group");
            try json.write(opts.group);
        }
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
    if (detected.package_script) |script| {
        try writer.print("Detected package script: {s}\n", .{script});
    }
    if (detected.compose_file) |compose_file| {
        try writer.print("Detected Docker Compose file: {s}\n", .{compose_file});
    }
    try writer.writeAll("Omitted defaults: project.session_name");
    if (detected.opts.service != null) {
        if (std.mem.eql(u8, detected.opts.dir, ".")) try writer.writeAll(", service.dir");
        if (detected.opts.group.len == 0) try writer.writeAll(", service.group");
    }
    if (detected.opts.docker) {
        if (detected.opts.docker_dir.len == 0) try writer.writeAll(", docker.dir");
        if (std.mem.eql(u8, detected.opts.compose_file, "docker-compose.yml")) try writer.writeAll(", docker.compose_file");
    }
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

test "init.options: parses service and docker flags" {
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--service", "web", "--command", "npm run dev", "--port", "3000", "--docker", "--docker-dir", "infra", "--compose-file", "compose.yaml" });
    try std.testing.expectEqualStrings("demo", opts.project.?);
    try std.testing.expectEqualStrings(".", opts.root);
    try std.testing.expectEqualStrings("web", opts.service.?);
    try std.testing.expectEqualStrings("npm run dev", opts.command.?);
    try std.testing.expectEqual(@as(i64, 3000), opts.port.?);
    try std.testing.expect(opts.docker);
    try std.testing.expectEqualStrings("infra", opts.docker_dir);
    try std.testing.expectEqualStrings("compose.yaml", opts.compose_file);
}

test "init.options: accepts omitted project" {
    const opts = try Options.parse(&.{ "--service", "web", "--command", "npm run dev" });

    try std.testing.expect(opts.project == null);
    try std.testing.expectEqualStrings(".", opts.root);
    try std.testing.expectEqualStrings("web", opts.service.?);
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
    const json = try renderConfig(std.testing.allocator, "demo", opts);
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
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--service", "web", "--command", "npm run dev", "--port", "3000", "--docker", "--docker-dir", "infra", "--compose-file", "compose.yaml" });
    const json = try renderConfig(std.testing.allocator, "demo", opts);
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const services = try cfg.services();

    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("web", try config.Config.serviceName(services[0]));
    try std.testing.expectEqualStrings("", config.Config.serviceGroup(services[0]));
    try std.testing.expectEqual(@as(?i64, 3000), config.Config.servicePort(services[0]));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
    try std.testing.expect(std.mem.indexOf(u8, json, "\"dir\": \".\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"group\"") == null);
}

test "init.config: omits default docker compose file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try Options.parse(&.{ "demo", "--docker" });
    const json = try renderConfig(std.testing.allocator, "demo", opts);
    defer std.testing.allocator.free(json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("docker-compose.yml", cfg.dockerComposeFile());
    try std.testing.expect(std.mem.indexOf(u8, json, "compose_file") == null);
}

test "init.detect: selects package dev script deterministically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const package_path = try testTmpPath(arena.allocator(), tmp, "package.json");
    const lock_path = try testTmpPath(arena.allocator(), tmp, "pnpm-lock.yaml");

    try paths.writeFile(threaded.io(), package_path,
        \\{"scripts":{"start":"vite --host","dev":"vite","serve":"vite preview"}}
    );
    try paths.writeFile(threaded.io(), lock_path, "");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));

    try std.testing.expectEqualStrings("web", detected.opts.service.?);
    try std.testing.expectEqualStrings("pnpm run dev", detected.opts.command.?);
    try std.testing.expectEqualStrings("dev", detected.package_script.?);
}

test "init.detect: falls back to package start script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const package_path = try testTmpPath(arena.allocator(), tmp, "package.json");

    try paths.writeFile(threaded.io(), package_path,
        \\{"scripts":{"start":"next start"}}
    );

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));

    try std.testing.expectEqualStrings("npm run start", detected.opts.command.?);
    try std.testing.expectEqualStrings("start", detected.package_script.?);
}

test "init.detect: selects compose files in priority order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const compose_yaml = try testTmpPath(arena.allocator(), tmp, "compose.yaml");
    const docker_compose = try testTmpPath(arena.allocator(), tmp, "docker-compose.yml");

    try paths.writeFile(threaded.io(), docker_compose, "services: {}\n");
    try paths.writeFile(threaded.io(), compose_yaml, "services: {}\n");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));

    try std.testing.expect(detected.opts.docker);
    try std.testing.expectEqualStrings("compose.yaml", detected.opts.compose_file);
    try std.testing.expectEqualStrings("compose.yaml", detected.compose_file.?);
}

test "init.detect: omits default compose file after detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const docker_compose = try testTmpPath(arena.allocator(), tmp, "docker-compose.yml");

    try paths.writeFile(threaded.io(), docker_compose, "services: {}\n");

    const detected = try applyDetections(arena.allocator(), threaded.io(), base, try Options.parse(&.{"demo"}));
    const json = try renderConfig(std.testing.allocator, "demo", detected.opts);
    defer std.testing.allocator.free(json);

    try std.testing.expect(detected.opts.docker);
    try std.testing.expectEqualStrings("docker-compose.yml", detected.opts.compose_file);
    try std.testing.expect(std.mem.indexOf(u8, json, "compose_file") == null);
}

test "init.report: prints detected values and omitted defaults" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const detected = DetectedOptions{
        .opts = .{ .service = "web", .command = "npm run dev", .docker = true, .compose_file = "docker-compose.yml" },
        .package_script = "dev",
        .compose_file = "docker-compose.yml",
    };

    try writeReport(&writer, "demo", detected);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected project.name: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected package script: dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected Docker Compose file: docker-compose.yml") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "project.session_name, service.dir, service.group, docker.dir, docker.compose_file") != null);
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
