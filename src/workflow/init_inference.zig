const std = @import("std");
const paths = @import("../platform/paths.zig");

pub const Input = struct {
    service: ?[]const u8 = null,
    compose_file_explicit: bool = false,
};

pub const Result = struct {
    service: ?DetectedService = null,
    compose_file: ?[]const u8 = null,
};

pub const DetectedService = struct {
    name: []const u8 = "web",
    command: []const u8,
    script: []const u8,
};

pub fn detect(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, input: Input) !Result {
    var result: Result = .{};
    if (input.service == null) result.service = try detectPackageService(gpa, io, cwd);
    if (!input.compose_file_explicit) result.compose_file = try detectComposeFile(gpa, io, cwd);
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

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testTmpPath(gpa: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, name });
}

test "initInference.detect: selects package dev script deterministically" {
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

    const result = try detect(arena.allocator(), threaded.io(), base, .{});

    try std.testing.expectEqualStrings("web", result.service.?.name);
    try std.testing.expectEqualStrings("pnpm run dev", result.service.?.command);
    try std.testing.expectEqualStrings("dev", result.service.?.script);
}

test "initInference.detect: falls back to package start script" {
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

    const result = try detect(arena.allocator(), threaded.io(), base, .{});

    try std.testing.expectEqualStrings("npm run start", result.service.?.command);
    try std.testing.expectEqualStrings("start", result.service.?.script);
}

test "initInference.detect: selects compose files in priority order" {
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

    const result = try detect(arena.allocator(), threaded.io(), base, .{});

    try std.testing.expectEqualStrings("compose.yaml", result.compose_file.?);
}

test "initInference.detect: infers compose file with explicit docker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const compose_yaml = try testTmpPath(arena.allocator(), tmp, "compose.yaml");

    try paths.writeFile(threaded.io(), compose_yaml, "services: {}\n");

    const result = try detect(arena.allocator(), threaded.io(), base, .{});

    try std.testing.expectEqualStrings("compose.yaml", result.compose_file.?);
}

test "initInference.detect: skips compose inference when compose file is explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init_single_threaded;
    const base = try std.fs.path.join(arena.allocator(), &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const compose_yaml = try testTmpPath(arena.allocator(), tmp, "compose.yaml");

    try paths.writeFile(threaded.io(), compose_yaml, "services: {}\n");

    const result = try detect(arena.allocator(), threaded.io(), base, .{ .compose_file_explicit = true });

    try std.testing.expect(result.compose_file == null);
}
