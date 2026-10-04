const std = @import("std");
const pathing = @import("pathing.zig");

pub const Problem = struct {
    field: []const u8,
    service: ?[]const u8 = null,
    configured: []const u8,
    project_root: ?[]const u8 = null,
    path: []const u8,
};

pub const Kind = enum {
    directory,
    file,

    pub fn label(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub const Issue = enum {
    not_found,
    wrong_kind,

    pub fn reason(self: Issue, kind: Kind) []const u8 {
        return switch (self) {
            .not_found => "not found",
            .wrong_kind => switch (kind) {
                .directory => "not a directory",
                .file => "not a file",
            },
        };
    }
};

pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, problem: Problem) !void {
    try ensure(gpa, io, writer, problem, .directory);
}

pub fn ensureFile(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, problem: Problem) !void {
    try ensure(gpa, io, writer, problem, .file);
}

/// Returns null when `path` exists with the expected kind. Errors other than a
/// missing entry stay errors so callers do not report them as config mistakes.
/// Pass the configured path, not a display form: lexical `..` cleanup can
/// point at a different entry when a component is a symlink.
pub fn inspect(io: std.Io, path: []const u8, kind: Kind) !?Issue {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        else => return err,
    };
    const expected: std.Io.File.Kind = switch (kind) {
        .directory => .directory,
        .file => .file,
    };
    return if (stat.kind == expected) null else .wrong_kind;
}

fn ensure(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, problem: Problem, kind: Kind) !void {
    const issue = try inspect(io, problem.path, kind) orelse return;
    const resolved = try pathing.absoluteForDisplay(gpa, io, problem.path);
    defer gpa.free(resolved);
    try writeError(writer, kind.label(), issue.reason(kind), problem, resolved);
    return error.ConfigPathNotFound;
}

fn writeError(writer: *std.Io.Writer, kind: []const u8, reason: []const u8, problem: Problem, resolved: []const u8) !void {
    try writer.print("\nError: configured {s} {s}\n", .{ kind, reason });
    try writer.print("  field: {s}\n", .{problem.field});
    if (problem.service) |service| try writer.print("  service: {s}\n", .{service});
    if (problem.project_root) |project_root| try writer.print("  project.root: {s}\n", .{project_root});
    try writer.print("  configured: {s}\n", .{problem.configured});
    try writer.print("  resolved: {s}\n", .{resolved});
    try writer.flush();
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "configured_path.ensureDir: reports missing directory details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConfigPathNotFound, ensureDir(arena.allocator(), threaded.io(), &writer, .{
        .field = "service.dir",
        .service = "api",
        .configured = "missing",
        .project_root = ".",
        .path = "missing",
    }));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "field: service.dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "project.root: .") != null);
}

test "configured_path.ensureDir: rejects regular files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-dir", .data = "" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ base, "not-dir" });
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConfigPathNotFound, ensureDir(arena.allocator(), io, &writer, .{
        .field = "project.root",
        .configured = "not-dir",
        .path = path,
    }));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "not a directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "field: project.root") != null);
}

test "configured_path.ensureFile: reports missing file details" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init_single_threaded;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(error.ConfigPathNotFound, ensureFile(arena.allocator(), threaded.io(), &writer, .{
        .field = "env_file",
        .service = "api",
        .configured = ".env.local",
        .project_root = ".",
        .path = ".env.local",
    }));

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "field: env_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "service: api") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "configured: .env.local") != null);
}
