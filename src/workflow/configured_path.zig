const std = @import("std");
const pathing = @import("pathing.zig");

pub const Problem = struct {
    field: []const u8,
    service: ?[]const u8 = null,
    configured: []const u8,
    project_root: ?[]const u8 = null,
    path: []const u8,
};

pub fn ensureDir(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, problem: Problem) !void {
    const resolved = try pathing.absoluteForDisplay(gpa, io, problem.path);
    defer gpa.free(resolved);
    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try writeError(writer, "not found", problem, resolved);
            return error.ConfigPathNotFound;
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        try writeError(writer, "not a directory", problem, resolved);
        return error.ConfigPathNotFound;
    }
}

fn writeError(writer: *std.Io.Writer, reason: []const u8, problem: Problem, resolved: []const u8) !void {
    try writer.print("\nError: configured directory {s}\n", .{reason});
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
