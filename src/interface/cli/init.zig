const std = @import("std");
const config = @import("../../model/config.zig");
const diagnostics = @import("../../model/diagnostics.zig");
const config_schema = @import("../../workflow/config_schema.zig");
const env = @import("../../platform/env.zig");
const init_inference = @import("../../workflow/init_inference.zig");
const paths = @import("../../platform/paths.zig");
const procfile = @import("../../workflow/procfile.zig");
const validate = @import("../../model/validate.zig");
const cli_context = @import("context.zig");

const Context = cli_context.Context;

pub const Options = struct {
    project: ?[]const u8 = null,
    root: []const u8 = ".",
    from: ?[]const u8 = null,
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
    defer ctx.base.gpa.free(cwd);
    const project = opts.project orelse std.fs.path.basename(cwd);
    try validate.identifier(project);

    const config_path = try cli_context.projectConfigPath(ctx.base.gpa, io, ctx.base.environ, project, ctx.base.error_context);
    defer ctx.base.gpa.free(config_path);
    if (!opts.force and paths.exists(io, config_path)) {
        try ctx.writer.print("Config already exists: {s}\n", .{config_path});
        try ctx.writer.print("Re-run with --force to overwrite it.\n", .{});
        return error.ConfigAlreadyExists;
    }

    var detected = try applyDetections(ctx.base.gpa, io, cwd, opts);
    defer detected.deinit(ctx.base.gpa);
    const resolved_root = try resolveRootFromCwd(ctx.base.gpa, cwd, detected.opts.root);
    const resolved_root_owned = resolved_root.ptr != detected.opts.root.ptr;
    defer if (resolved_root_owned) ctx.base.gpa.free(resolved_root);
    detected.opts.root = resolved_root;
    var import_arena = std.heap.ArenaAllocator.init(ctx.base.gpa);
    defer import_arena.deinit();
    if (opts.from) |from| {
        detected.procfile = try importProcfile(import_arena.allocator(), io, ctx.base.environ, ctx.writer, cwd, resolved_root, from);
    }
    const json = try renderConfig(ctx.base.gpa, project, detected);
    defer ctx.base.gpa.free(json);
    var validation_arena = std.heap.ArenaAllocator.init(ctx.base.gpa);
    defer validation_arena.deinit();
    _ = try config.Config.parse(validation_arena.allocator(), json, try paths.home(ctx.base.environ));

    try config_schema.install(ctx.base.gpa, io, ctx.base.environ);
    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, config_dir, @enumFromInt(0o755));
    try paths.writeFile(io, config_path, json);

    try ctx.writer.print("Created {s}\n", .{config_path});
    try writeReport(ctx.writer, project, detected);
    if (std.mem.eql(u8, project, std.fs.path.basename(cwd))) {
        try ctx.writer.print("Next: zask list\n", .{});
        try ctx.writer.print("Next: zask open\n", .{});
    } else {
        try ctx.writer.print("Next: zask {s} list\n", .{project});
        try ctx.writer.print("Next: zask {s} open\n", .{project});
    }
}

const DetectedOptions = struct {
    opts: Options,
    service: ?init_inference.DetectedService = null,
    procfile: ?ProcfileImport = null,
    compose_file: ?[]const u8 = null,

    /// Takes ownership of owned detection outputs from `init_inference.Result`.
    fn fromOwnedDetectionResult(opts: Options, detected: init_inference.Result) DetectedOptions {
        return .{
            .opts = opts,
            .service = detected.service,
            .compose_file = detected.compose_file,
        };
    }

    /// Frees owned values copied from detection helpers.
    pub fn deinit(self: DetectedOptions, gpa: std.mem.Allocator) void {
        if (self.service) |service| gpa.free(service.command);
    }
};

const ProcfileImport = struct {
    source: []const u8,
    services: []const procfile.Service,
    dir: ?[]const u8 = null,
};

const ServiceGroup = struct {
    name: []const u8,
    services: []const GroupService,
};

const GroupService = struct {
    name: []const u8,
    command: []const u8,
    dir: ?[]const u8 = null,
};

fn validateOptions(opts: Options) !void {
    if (opts.project) |project| validate.identifier(project) catch return error.InvalidArguments;
    validateRoot(opts.root) catch return error.InvalidArguments;
    if (opts.from) |from| if (from.len == 0) return error.InvalidArguments;
}

fn validateRoot(root: []const u8) !void {
    if (std.fs.path.isAbsolute(root) or std.mem.startsWith(u8, root, "~")) return;
    try validate.relativeSubPath(root);
}

fn parseOption(args: []const []const u8, index: *usize, opts: *Options) !void {
    const arg = args[index.*];
    if (std.mem.eql(u8, arg, "--root")) {
        opts.root = try takeValue(args, index);
    } else if (std.mem.eql(u8, arg, "--from")) {
        opts.from = try takeValue(args, index);
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
    const detected = try init_inference.detect(gpa, io, cwd, .{
        .infer_service = opts.from == null,
        .infer_compose_file = true,
    });
    return DetectedOptions.fromOwnedDetectionResult(opts, detected);
}

fn importProcfile(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: ?*const env.Map,
    writer: *std.Io.Writer,
    cwd: []const u8,
    root: []const u8,
    from: []const u8,
) !ProcfileImport {
    const path = try std.fs.path.resolve(arena, &.{ cwd, from });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("Error: Procfile not found: {s}\n", .{from});
            return error.InvalidProcfile;
        },
        error.StreamTooLong => {
            try writer.print("Error: Procfile too large: {s}\n", .{from});
            return error.InvalidProcfile;
        },
        else => return err,
    };
    var diags = diagnostics.Diagnostics.init(arena);
    const services = procfile.parse(arena, from, bytes, &diags) catch |err| switch (err) {
        error.InvalidProcfile => {
            try writer.print("Error: invalid Procfile: {s}\n", .{from});
            for (diags.slice()) |diagnostic| try writer.print("  {s}: {s}\n", .{ diagnostic.path, diagnostic.message });
            return err;
        },
        else => return err,
    };
    const root_path = if (std.mem.eql(u8, root, "~") or std.mem.startsWith(u8, root, "~/"))
        try std.fs.path.join(arena, &.{ try paths.home(environ), root[1..] })
    else
        root;
    return .{
        .source = from,
        .services = services,
        .dir = try serviceDirFromRoot(arena, cwd, root_path, std.fs.path.dirname(path) orelse path),
    };
}

fn serviceDirFromRoot(gpa: std.mem.Allocator, cwd: []const u8, root: []const u8, procfile_dir: []const u8) !?[]const u8 {
    const relative = try std.fs.path.relativePosix(gpa, cwd, root, procfile_dir);
    if (relative.len == 0) return null;
    validate.relativeSubPath(relative) catch return procfile_dir;
    return relative;
}

fn serviceGroup(gpa: std.mem.Allocator, detected: DetectedOptions) !?ServiceGroup {
    if (detected.procfile) |imported| {
        const services = try gpa.alloc(GroupService, imported.services.len);
        for (imported.services, services) |service, *grouped| {
            grouped.* = .{ .name = service.name, .command = service.command, .dir = imported.dir };
        }
        return .{ .name = "procfile", .services = services };
    }
    if (detected.service) |service| {
        const services = try gpa.alloc(GroupService, 1);
        services[0] = .{ .name = service.name, .command = service.command };
        return .{ .name = "frontend", .services = services };
    }
    return null;
}

fn renderConfig(gpa: std.mem.Allocator, project: []const u8, detected: DetectedOptions) ![]u8 {
    var group_arena = std.heap.ArenaAllocator.init(gpa);
    defer group_arena.deinit();
    const group = try serviceGroup(group_arena.allocator(), detected);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var writer = &out.writer;
    var json: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try json.beginObject();
    try json.objectField(config.keys.schema);
    try json.write(config_schema.named_config_reference);
    try json.objectField(config.keys.project);
    try json.beginObject();
    try json.objectField(config.keys.name);
    try json.write(project);
    try json.objectField(config.keys.root);
    try json.write(detected.opts.root);
    try json.endObject();
    if (detected.compose_file) |compose_file| {
        try json.objectField(config.keys.docker);
        try json.beginObject();
        try json.objectField(config.keys.compose);
        try json.write(compose_file);
        try json.endObject();
    }
    // Scaffold an explicit order when both Docker and a service exist: open no
    // longer waits for Docker implicitly, so the service would otherwise race it.
    if (detected.compose_file != null and group != null) {
        try json.objectField(config.keys.startup_order);
        try json.beginArray();
        try json.beginObject();
        try json.objectField(config.keys.name);
        try json.write("Docker");
        try json.objectField(config.keys.docker);
        try json.write(true);
        try json.endObject();
        try json.beginObject();
        try json.objectField(config.keys.name);
        try json.write(group.?.name);
        try json.objectField(config.keys.group);
        try json.write(group.?.name);
        try json.endObject();
        try json.endArray();
    }
    try json.objectField(config.keys.groups);
    try json.beginArray();
    if (group) |service_group| {
        try json.beginObject();
        try json.objectField(config.keys.name);
        try json.write(service_group.name);
        try json.objectField(config.keys.services);
        try json.beginArray();
        for (service_group.services) |service| {
            try json.beginObject();
            try json.objectField(config.keys.name);
            try json.write(service.name);
            if (service.dir) |dir| {
                try json.objectField(config.keys.dir);
                try json.write(dir);
            }
            try json.objectField(config.keys.command);
            try json.write(service.command);
            try json.endObject();
        }
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
    if (detected.procfile) |imported| {
        try writer.print("Imported services from {s}:", .{imported.source});
        for (imported.services) |service| try writer.print(" {s}", .{service.name});
        try writer.writeByte('\n');
    }
    if (detected.compose_file) |compose_file| {
        try writer.print("Detected Docker Compose file: {s}\n", .{compose_file});
    }
    const omits_service_dir = detected.service != null or (detected.procfile != null and detected.procfile.?.dir == null);
    if (omits_service_dir or detected.compose_file != null) {
        try writer.writeAll("Omitted defaults: ");
        var wrote = false;
        if (omits_service_dir) {
            try writer.writeAll("service.dir");
            wrote = true;
        }
        if (detected.compose_file != null) {
            if (wrote) try writer.writeAll(", ");
            try writer.writeAll("docker.wait_timeout_seconds");
        }
        try writer.writeByte('\n');
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_config_head = "{\n  \"$schema\": \"" ++ config_schema.named_config_reference ++ "\",\n";

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

fn testDetectedServiceOnly(gpa: std.mem.Allocator) !DetectedOptions {
    const command = try gpa.dupe(u8, "pnpm run dev");
    errdefer gpa.free(command);
    return .{
        .opts = try Options.parse(&.{ "demo", "--root", "." }),
        .service = .{ .name = "web", .command = command, .script = "dev" },
    };
}

fn testDetectedServiceAndDocker(gpa: std.mem.Allocator) !DetectedOptions {
    var detected = try testDetectedServiceOnly(gpa);
    detected.compose_file = "infra/compose.yaml";
    return detected;
}

const test_procfile_services = [_]procfile.Service{
    .{ .name = "web", .command = "bin/rails server -b 0.0.0.0:3000", .line = 1 },
    .{ .name = "worker", .command = "bundle exec  sidekiq", .line = 2 },
};

fn testDetectedProcfile(dir: ?[]const u8) !DetectedOptions {
    return .{
        .opts = try Options.parse(&.{ "demo", "--from", "Procfile.dev" }),
        .procfile = .{ .source = "Procfile.dev", .services = &test_procfile_services, .dir = dir },
    };
}

fn testConfigHome(gpa: std.mem.Allocator, tmp: std.testing.TmpDir, environ: *env.Map) ![]const u8 {
    const config_home = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    return config_home;
}

test "init.detectedOptions.deinit: empty result is a no-op" {
    const detected: DetectedOptions = .{ .opts = .{} };

    detected.deinit(std.testing.allocator);
}

test "init.options: parses scaffold flags" {
    const opts = try Options.parse(&.{ "demo", "--root", ".", "--force" });

    try std.testing.expectEqualStrings("demo", opts.project.?);
    try std.testing.expectEqualStrings(".", opts.root);
    try std.testing.expect(opts.force);
}

test "init.options: parses procfile source" {
    const opts = try Options.parse(&.{ "--from", "Procfile.dev" });

    try std.testing.expect(opts.project == null);
    try std.testing.expectEqualStrings("Procfile.dev", opts.from.?);
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
        &.{ "demo", "--from" },
        &.{ "demo", "--from", "" },
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

test "init.config: renders minimal config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const opts = try Options.parse(&.{"demo"});

    const json = try renderConfig(std.testing.allocator, "demo", .{ .opts = opts });
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "groups": []
        \\}
        \\
    , json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings(".", try cfg.projectRoot(arena.allocator()));
    try std.testing.expect(!cfg.dockerEnabled());
    try std.testing.expectEqual(@as(usize, 0), (try cfg.services()).len);
}

test "init.config: renders service and docker config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const detected = try testDetectedServiceAndDocker(std.testing.allocator);
    defer detected.deinit(std.testing.allocator);

    const json = try renderConfig(std.testing.allocator, "demo", detected);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "docker": {
        \\    "compose": "infra/compose.yaml"
        \\  },
        \\  "startup_order": [
        \\    {
        \\      "name": "Docker",
        \\      "docker": true
        \\    },
        \\    {
        \\      "name": "frontend",
        \\      "group": "frontend"
        \\    }
        \\  ],
        \\  "groups": [
        \\    {
        \\      "name": "frontend",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "command": "pnpm run dev"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const services = try cfg.services();
    try std.testing.expectEqual(@as(usize, 1), services.len);
    try std.testing.expectEqualStrings("web", try config.Config.serviceName(services[0]));
    try std.testing.expectEqualStrings("frontend", config.Config.serviceGroup(services[0]));
    try std.testing.expectEqualStrings("pnpm run dev", try config.Config.serviceStartCommand(arena.allocator(), services[0]));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
    try std.testing.expectEqualStrings("./infra", try cfg.dockerDir(arena.allocator()));
    try std.testing.expectEqual(@as(usize, 2), cfg.phases().len);
}

test "init.config: renders service-only config verbatim" {
    const detected = try testDetectedServiceOnly(std.testing.allocator);
    defer detected.deinit(std.testing.allocator);
    const json = try renderConfig(std.testing.allocator, "demo", detected);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "groups": [
        \\    {
        \\      "name": "frontend",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "command": "pnpm run dev"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , json);
}

test "init.config: renders procfile and docker config verbatim" {
    var detected = try testDetectedProcfile(null);
    detected.compose_file = "compose.yaml";
    const json = try renderConfig(std.testing.allocator, "demo", detected);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "docker": {
        \\    "compose": "compose.yaml"
        \\  },
        \\  "startup_order": [
        \\    {
        \\      "name": "Docker",
        \\      "docker": true
        \\    },
        \\    {
        \\      "name": "procfile",
        \\      "group": "procfile"
        \\    }
        \\  ],
        \\  "groups": [
        \\    {
        \\      "name": "procfile",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "command": "bin/rails server -b 0.0.0.0:3000"
        \\        },
        \\        {
        \\          "name": "worker",
        \\          "command": "bundle exec  sidekiq"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , json);
}

test "init.config: renders procfile dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json = try renderConfig(std.testing.allocator, "demo", try testDetectedProcfile("backend"));
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "groups": [
        \\    {
        \\      "name": "procfile",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "dir": "backend",
        \\          "command": "bin/rails server -b 0.0.0.0:3000"
        \\        },
        \\        {
        \\          "name": "worker",
        \\          "dir": "backend",
        \\          "command": "bundle exec  sidekiq"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , json);
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
    const services = try cfg.services();
    try std.testing.expectEqual(test_procfile_services.len, services.len);
    for (test_procfile_services, services) |want, got| {
        try std.testing.expectEqualStrings(want.name, try config.Config.serviceName(got));
        try std.testing.expectEqualStrings("procfile", config.Config.serviceGroup(got));
        try std.testing.expectEqualStrings(want.command, try config.Config.serviceStartCommand(arena.allocator(), got));
        try std.testing.expectEqualStrings("./backend", try cfg.serviceDir(arena.allocator(), got));
    }
}

test "init.procfileDir: maps the procfile directory onto the project root" {
    const cases = [_]struct {
        root: []const u8,
        procfile_dir: []const u8,
        expected: ?[]const u8,
    }{
        .{ .root = "/work/demo", .procfile_dir = "/work/demo", .expected = null },
        .{ .root = "/work/demo", .procfile_dir = "/work/demo/backend/api", .expected = "backend/api" },
        .{ .root = "/work/demo/backend", .procfile_dir = "/work/demo", .expected = "/work/demo" },
        .{ .root = "/work/demo", .procfile_dir = "/work/other", .expected = "/work/other" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const dir = try serviceDirFromRoot(arena.allocator(), "/", case.root, case.procfile_dir);

        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, dir.?);
        } else {
            try std.testing.expect(dir == null);
        }
    }
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
    try std.testing.expectEqualStrings(test_config_head ++
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "."
        \\  },
        \\  "docker": {
        \\    "compose": "docker-compose.yml"
        \\  },
        \\  "groups": []
        \\}
        \\
    , json);
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
    var detected = try testDetectedServiceOnly(std.testing.allocator);
    defer detected.deinit(std.testing.allocator);
    detected.compose_file = "docker-compose.yml";

    try writeReport(&writer, "demo", detected);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected project.name: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected package script: dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected Docker Compose file: docker-compose.yml") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service.dir, docker.wait_timeout_seconds") != null);
}

test "init.report: lists imported procfile services" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var detected = try testDetectedProcfile(null);
    detected.compose_file = "compose.yaml";

    try writeReport(&writer, "demo", detected);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Imported services from Procfile.dev: web worker\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Detected Docker Compose file: compose.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service.dir, docker.wait_timeout_seconds") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "package script") == null);
}

test "init.report: omits service.dir default only when procfile is at root" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeReport(&writer, "demo", try testDetectedProcfile("backend"));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Omitted defaults") == null);
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

test "init.run: rejects existing config.jsonc without creating config.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    try tmp.dir.createDirPath(io, "zask/demo");
    try tmp.dir.writeFile(io, .{ .sub_path = "zask/demo/config.jsonc", .data = "// keep\n{}" });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(arena.allocator(), io, &environ, &writer);

    try std.testing.expectError(error.ConfigAlreadyExists, run(&ctx, try Options.parse(&.{"demo"})));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "config.jsonc") != null);
    try std.testing.expect(!paths.exists(io, try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" })));
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

test "init.run: keeps configs untouched when the schema cannot be installed" {
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
    try tmp.dir.createDirPath(threaded.io(), "zask/" ++ config_schema.file_name ++ "/blocker");
    try tmp.dir.createDirPath(threaded.io(), "zask/kept");
    try tmp.dir.writeFile(threaded.io(), .{ .sub_path = "zask/kept/config.json", .data = "original" });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(arena.allocator(), threaded.io(), &environ, &writer);

    try std.testing.expect(std.meta.isError(run(&ctx, try Options.parse(&.{"fresh"}))));
    try std.testing.expect(std.meta.isError(run(&ctx, try Options.parse(&.{ "kept", "--force" }))));

    try std.testing.expectError(error.FileNotFound, tmp.dir.access(threaded.io(), "zask/fresh/config.json", .{}));
    const kept = try tmp.dir.readFileAlloc(threaded.io(), "zask/kept/config.json", arena.allocator(), .limited(64));
    try std.testing.expectEqualStrings("original", kept);
}

test "init.run: releases temporary allocations on success" {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa_state.deinit() == .ok) catch @panic("leak");
    const gpa = gpa_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(gpa);
    defer environ.deinit();
    const base = try tmp.dir.realPathFileAlloc(threaded.io(), ".", gpa);
    defer gpa.free(base);
    const config_home = try std.fs.path.join(gpa, &.{ base, "xdg" });
    defer gpa.free(config_home);
    const package_json = try std.fs.path.join(gpa, &.{ base, "package.json" });
    defer gpa.free(package_json);
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_CONFIG_HOME", config_home);
    try paths.writeFile(threaded.io(), package_json, "{\"scripts\":{\"dev\":\"vite\"}}\n");
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(gpa, threaded.io(), &environ, &writer);

    try run(&ctx, try Options.parse(&.{"demo"}));
}

test "init.run: imports procfile services into the written config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try testConfigHome(arena.allocator(), tmp, &environ);
    const procfile_path = try testTmpPath(arena.allocator(), tmp, "Procfile.dev");
    try paths.writeFile(threaded.io(), procfile_path, "# dev\nweb: bin/rails server -p 3000\nworker: bundle exec sidekiq\n");
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(std.testing.allocator, threaded.io(), &environ, &writer);

    try run(&ctx, try Options.parse(&.{ "demo", "--from", procfile_path }));

    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, arena.allocator(), .limited(4096));
    const cfg = try config.Config.parse(arena.allocator(), bytes, "/home/me");
    const services = try cfg.services();
    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("web", try config.Config.serviceName(services[0]));
    try std.testing.expectEqualStrings("bin/rails server -p 3000", try config.Config.serviceStartCommand(arena.allocator(), services[0]));
    try std.testing.expectEqualStrings("worker", try config.Config.serviceName(services[1]));
    try std.testing.expectEqualStrings(std.fs.path.dirname(procfile_path).?, config.Config.serviceDirValue(services[1]));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), ": web worker\n") != null);
}

test "init.run: stops on invalid procfile without writing config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try testConfigHome(arena.allocator(), tmp, &environ);
    const procfile_path = try testTmpPath(arena.allocator(), tmp, "Procfile.dev");
    try paths.writeFile(threaded.io(), procfile_path, "web: npm run dev\nweb: npm start\n");
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(std.testing.allocator, threaded.io(), &environ, &writer);

    try std.testing.expectError(error.InvalidProcfile, run(&ctx, try Options.parse(&.{ "demo", "--from", procfile_path })));

    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    const location = try std.fmt.allocPrint(arena.allocator(), "  {s}:2: duplicate service 'web' (first defined at line 1)\n", .{procfile_path});
    try std.testing.expect(!paths.exists(threaded.io(), config_path));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), location) != null);
}

test "init.run: reports missing procfile without writing config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try testConfigHome(arena.allocator(), tmp, &environ);
    const procfile_path = try testTmpPath(arena.allocator(), tmp, "Procfile.missing");
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(std.testing.allocator, threaded.io(), &environ, &writer);

    try std.testing.expectError(error.InvalidProcfile, run(&ctx, try Options.parse(&.{ "demo", "--from", procfile_path })));

    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    try std.testing.expect(!paths.exists(threaded.io(), config_path));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Error: Procfile not found") != null);
}

test "init.run: rejects existing config without force" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    var environ = env.Map.init(arena.allocator());
    defer environ.deinit();
    const config_home = try testConfigHome(arena.allocator(), tmp, &environ);
    const procfile_path = try testTmpPath(arena.allocator(), tmp, "Procfile.dev");
    try paths.writeFile(threaded.io(), procfile_path, "web: npm run dev\n");
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var ctx = testContext(arena.allocator(), threaded.io(), &environ, &writer);
    try run(&ctx, try Options.parse(&.{"demo"}));
    const config_path = try std.fs.path.join(arena.allocator(), &.{ config_home, "zask", "demo", "config.json" });
    const before = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, arena.allocator(), .limited(4096));

    try std.testing.expectError(error.ConfigAlreadyExists, run(&ctx, try Options.parse(&.{ "demo", "--from", procfile_path })));

    const after = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), config_path, arena.allocator(), .limited(4096));
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Re-run with --force") != null);
}
