//! Records which services the user stopped, so the file watcher leaves them
//! stopped even while a stopping process still keeps its pane busy. Each mark
//! is an empty file named after the service under
//! `<runtime base>/<project>.stopped/`; service names are identifiers, so they
//! are safe as file names.

const std = @import("std");
const observations = @import("../model/observations.zig");
const paths = @import("paths.zig");

pub const StopMarks = struct {
    io: std.Io,
    /// Absolute directory holding the marks. Borrowed; must outlive this value.
    dir: []const u8,

    /// Returns the directory path owned by the caller in `.dir`; free it with
    /// `gpa` when the marks are no longer used.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, runtime_base: []const u8, project: []const u8) !StopMarks {
        const name = try std.fmt.allocPrint(gpa, "{s}.stopped", .{project});
        defer gpa.free(name);
        return .{ .io = io, .dir = try std.fs.path.join(gpa, &.{ runtime_base, name }) };
    }

    pub fn mark(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) !void {
        try paths.ensurePrivateDir(self.io, self.dir);
        const path = try self.markPath(gpa, service);
        defer gpa.free(path);
        try paths.writeFileMode(self.io, path, "", paths.private_file_permissions);
    }

    pub fn clear(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) !void {
        const path = try self.markPath(gpa, service);
        defer gpa.free(path);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    /// `unavailable` covers lookup failures other than a missing mark.
    pub fn observe(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) observations.StopMarkObservation {
        const path = self.markPath(gpa, service) catch return .unavailable;
        defer gpa.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .not_stopped,
            else => .unavailable,
        };
        return .stopped;
    }

    fn markPath(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) ![]const u8 {
        return std.fs.path.join(gpa, &.{ self.dir, service });
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "stop_marks: mark and clear toggle the observation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const marks = try StopMarks.init(std.testing.allocator, std.testing.io, base, "demo");
    defer std.testing.allocator.free(marks.dir);

    const before = marks.observe(std.testing.allocator, "api");
    try marks.mark(std.testing.allocator, "api");
    const marked = marks.observe(std.testing.allocator, "api");
    const other = marks.observe(std.testing.allocator, "web");
    try marks.clear(std.testing.allocator, "api");
    const cleared = marks.observe(std.testing.allocator, "api");

    try std.testing.expectEqual(observations.StopMarkObservation.not_stopped, before);
    try std.testing.expectEqual(observations.StopMarkObservation.stopped, marked);
    try std.testing.expectEqual(observations.StopMarkObservation.not_stopped, other);
    try std.testing.expectEqual(observations.StopMarkObservation.not_stopped, cleared);
}

test "stop_marks.clear: no-op without a mark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const marks = try StopMarks.init(std.testing.allocator, std.testing.io, base, "demo");
    defer std.testing.allocator.free(marks.dir);

    try marks.clear(std.testing.allocator, "api");
}
