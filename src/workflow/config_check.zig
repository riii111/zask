const std = @import("std");
const config = @import("../model/config.zig");
const config_value = @import("../model/config_value.zig");
const diagnostics = @import("../model/diagnostics.zig");
const configured_path = @import("configured_path.zig");
const pathing = @import("pathing.zig");

/// Records every configured path that `open` / `start` would reject, without
/// stopping at the first one. `cfg` must already be validated. Diagnostic
/// strings are allocated from `gpa`, so pass the same arena that owns `diags`.
/// Labels follow the authored config, naming groups and services instead of
/// array indexes because the normalized config no longer carries them.
pub fn collectPathProblems(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, diags: *diagnostics.Diagnostics) !void {
    var checker: Checker = .{ .gpa = gpa, .io = io, .diags = diags, .reported = .init(gpa) };
    defer checker.reported.deinit();

    const project_root = try cfg.projectRoot(gpa);
    // Every relative path below resolves under the root, so a missing root
    // would repeat as one problem per entry.
    if (!try checker.check("project.root", project_root, .directory)) return;

    for (try cfg.services()) |service| {
        const label = try serviceLabel(gpa, service);
        const dir_ok = try checker.check(try joinLabel(gpa, label, "dir"), try cfg.serviceDir(gpa, service), .directory);
        for (try config.Config.serviceEnvFiles(gpa, service)) |env_file| {
            if (!dir_ok and dependsOnServiceDir(env_file)) continue;
            const env_label = switch (env_file.scope) {
                .project => "env_file",
                .group => try std.fmt.allocPrint(gpa, "groups[{s}].env_file", .{config.Config.serviceGroup(service)}),
                .service => try joinLabel(gpa, label, "env_file"),
            };
            _ = try checker.check(env_label, try cfg.serviceEnvFilePath(gpa, service, env_file), .file);
        }
    }

    if (cfg.dockerEnabled()) {
        const docker_dir = try cfg.dockerDir(gpa);
        if (try checker.check("docker.compose", docker_dir, .directory)) {
            const compose_file = try std.fs.path.join(gpa, &.{ docker_dir, cfg.dockerComposeFile() });
            _ = try checker.check("docker.compose", compose_file, .file);
        }
    }

    for (cfg.phases(), 0..) |phase, index| {
        const dir = commandPhaseDir(phase) orelse continue;
        const label = try std.fmt.allocPrint(gpa, "startup_order[{d}].dir", .{index});
        _ = try checker.check(label, try std.fs.path.join(gpa, &.{ project_root, dir }), .directory);
    }

    for (cfg.prechecks(), 0..) |precheck, index| {
        const dir = config_value.optionalObjectString(precheck, "dir", "");
        if (dir.len == 0) continue;
        const label = try std.fmt.allocPrint(gpa, "prechecks[{d}].dir", .{index});
        _ = try checker.check(label, try std.fs.path.join(gpa, &.{ project_root, dir }), .directory);
    }
}

/// Names a service the way it is authored, e.g. `groups[be].services[api]`.
pub fn serviceLabel(gpa: std.mem.Allocator, service: std.json.Value) ![]const u8 {
    return std.fmt.allocPrint(gpa, "groups[{s}].services[{s}]", .{ config.Config.serviceGroup(service), try config.Config.serviceName(service) });
}

const Checker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    diags: *diagnostics.Diagnostics,
    /// Inherited env files resolve to the same path for every service; report
    /// each label/path pair once.
    reported: std.StringHashMap(void),

    fn check(self: *Checker, label: []const u8, path: []const u8, kind: configured_path.Kind) !bool {
        const issue = try configured_path.inspect(self.io, path, kind) orelse return true;
        const resolved = try pathing.absoluteForDisplay(self.gpa, self.io, path);
        const key = try std.fmt.allocPrint(self.gpa, "{s}\x00{s}", .{ label, resolved });
        const entry = try self.reported.getOrPut(key);
        if (entry.found_existing) return false;
        switch (issue) {
            .not_found => try self.diags.addFmt(label, "{s} not found: {s}", .{ kind.label(), resolved }),
            .wrong_kind => try self.diags.addFmt(label, "{s}: {s}", .{ issue.reason(kind), resolved }),
        }
        return false;
    }
};

// Mirrors Config.serviceEnvFilePath: absolute and `~` entries ignore the service dir.
fn dependsOnServiceDir(env_file: config.Config.EnvFile) bool {
    if (env_file.base != .service) return false;
    return !std.fs.path.isAbsolute(env_file.path) and !std.mem.startsWith(u8, env_file.path, "~");
}

fn commandPhaseDir(phase: std.json.Value) ?[]const u8 {
    if (phase != .object) return null;
    const kind = phase.object.get("type") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "command")) return null;
    const dir = phase.object.get("dir") orelse return null;
    if (dir != .string or dir.string.len == 0) return null;
    return dir.string;
}

fn joinLabel(gpa: std.mem.Allocator, parent: []const u8, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ parent, key });
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestProject = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(gpa: std.mem.Allocator, io: std.Io) !TestProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(io, ".", gpa) };
    }

    fn deinit(self: *TestProject) void {
        self.tmp.cleanup();
    }

    fn parse(self: TestProject, gpa: std.mem.Allocator, comptime body: []const u8) !config.Config {
        const json = try std.fmt.allocPrint(gpa, "{{\"project\":{{\"name\":\"demo\",\"root\":\"{s}\"}},{s}}}", .{ self.root, body });
        return config.Config.parse(gpa, json, "/home/me");
    }
};

fn testExpectDiagnostics(expected: []const diagnostics.Diagnostic, actual: []const diagnostics.Diagnostic) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqualStrings(want.path, got.path);
        try std.testing.expectEqualStrings(want.message, got.message);
    }
}

test "config_check.collectPathProblems: accepts existing paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io);
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, "backend");
    try project.tmp.dir.writeFile(io, .{ .sub_path = "backend/.env", .data = "" });
    try project.tmp.dir.writeFile(io, .{ .sub_path = "compose.yml", .data = "" });
    const cfg = try project.parse(gpa,
        \\"docker":{"compose":"compose.yml"},
        \\"groups":[{"name":"be","services":[{"name":"api","dir":"backend","command":"serve","env_file":".env"}]}],
        \\"startup_order":[{"command":"setup","dir":"backend"}]
    );
    var diags = diagnostics.Diagnostics.init(gpa);

    try collectPathProblems(gpa, io, cfg, &diags);

    try std.testing.expect(diags.isEmpty());
}

test "config_check.collectPathProblems: reports every missing path once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var project = try TestProject.init(gpa, io);
    defer project.deinit();
    try project.tmp.dir.createDirPath(io, "web");
    try project.tmp.dir.writeFile(io, .{ .sub_path = "notdir", .data = "" });
    const cfg = try project.parse(gpa,
        \\"env_file":".env",
        \\"docker":{"compose":"notdir/compose.yml"},
        \\"groups":[{"name":"be","env_file":"be.env","services":[
        \\  {"name":"api","dir":"backend","command":"serve","env_file":[".env.local","/nonexistent/zask-check.env"]},
        \\  {"name":"web","dir":"web","command":"dev","env_file":".env.local"}
        \\]}],
        \\"startup_order":[{"group":"be"},{"command":"setup","dir":"scripts"}],
        \\"prechecks":[{"command":"true"},{"command":"lint","dir":"tools"}]
    );
    var diags = diagnostics.Diagnostics.init(gpa);

    try collectPathProblems(gpa, io, cfg, &diags);

    const r = project.root;
    try testExpectDiagnostics(&.{
        .{ .path = "groups[be].services[api].dir", .message = try std.fmt.allocPrint(gpa, "directory not found: {s}/backend", .{r}) },
        .{ .path = "env_file", .message = try std.fmt.allocPrint(gpa, "file not found: {s}/.env", .{r}) },
        .{ .path = "groups[be].env_file", .message = try std.fmt.allocPrint(gpa, "file not found: {s}/be.env", .{r}) },
        .{ .path = "groups[be].services[api].env_file", .message = "file not found: /nonexistent/zask-check.env" },
        .{ .path = "groups[be].services[web].env_file", .message = try std.fmt.allocPrint(gpa, "file not found: {s}/web/.env.local", .{r}) },
        .{ .path = "docker.compose", .message = try std.fmt.allocPrint(gpa, "not a directory: {s}/notdir", .{r}) },
        .{ .path = "startup_order[1].dir", .message = try std.fmt.allocPrint(gpa, "directory not found: {s}/scripts", .{r}) },
        .{ .path = "prechecks[1].dir", .message = try std.fmt.allocPrint(gpa, "directory not found: {s}/tools", .{r}) },
    }, diags.slice());
}

test "config_check.collectPathProblems: follows symlinks before parent references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/.env", .data = "" });
    try tmp.dir.symLink(io, "real/inner", "link", .{ .is_directory = true });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const json = try std.fmt.allocPrint(gpa,
        \\{{"project":{{"name":"demo","root":"{s}/link/.."}},"env_file":".env",
        \\ "groups":[{{"name":"be","services":[{{"name":"api","command":"serve"}}]}}]}}
    , .{base});
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    var diags = diagnostics.Diagnostics.init(gpa);

    try collectPathProblems(gpa, io, cfg, &diags);

    try std.testing.expect(diags.isEmpty());
}

test "config_check.collectPathProblems: reports a missing root behind parent references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const json = try std.fmt.allocPrint(gpa,
        \\{{"project":{{"name":"demo","root":"{s}/absent/.."}},
        \\ "groups":[{{"name":"be","services":[{{"name":"api","command":"serve"}}]}}]}}
    , .{base});
    const cfg = try config.Config.parse(gpa, json, "/home/me");
    var diags = diagnostics.Diagnostics.init(gpa);

    try collectPathProblems(gpa, io, cfg, &diags);

    try std.testing.expectEqual(@as(usize, 1), diags.slice().len);
    try std.testing.expectEqualStrings("project.root", diags.slice()[0].path);
}

test "config_check.collectPathProblems: stops at a missing project root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const cfg = try config.Config.parse(gpa,
        \\{"project":{"name":"demo","root":"/nonexistent/zask-check-root"},
        \\ "groups":[{"name":"be","services":[{"name":"api","dir":"backend","command":"serve"}]}]}
    , "/home/me");
    var diags = diagnostics.Diagnostics.init(gpa);

    try collectPathProblems(gpa, io, cfg, &diags);

    try testExpectDiagnostics(&.{
        .{ .path = "project.root", .message = "directory not found: /nonexistent/zask-check-root" },
    }, diags.slice());
}
