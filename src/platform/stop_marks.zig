const std = @import("std");
const observations = @import("../model/observations.zig");
const paths = @import("paths.zig");

pub const StopMarks = struct {
    io: std.Io,
    dir: []const u8,

    pub fn forSession(gpa: std.mem.Allocator, io: std.Io, project: []const u8) !StopMarks {
        const base = try paths.runtimeBase(gpa, null);
        defer gpa.free(base);
        return init(gpa, io, base, project);
    }

    pub fn init(gpa: std.mem.Allocator, io: std.Io, runtime_base: []const u8, project: []const u8) !StopMarks {
        const name = try std.fmt.allocPrint(gpa, "{s}.stopped", .{project});
        defer gpa.free(name);
        return .{ .io = io, .dir = try std.fs.path.join(gpa, &.{ runtime_base, name }) };
    }

    pub fn mark(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) !void {
        const held = try self.hold(gpa, service);
        defer held.release();
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

    pub fn observe(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) observations.StopMarkObservation {
        const path = self.markPath(gpa, service) catch return .unavailable;
        defer gpa.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| return switch (err) {
            error.FileNotFound => .not_stopped,
            else => .unavailable,
        };
        return .stopped;
    }

    pub fn hold(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) !Held {
        try paths.ensurePrivateDir(self.io, self.dir);
        const name = try std.fmt.allocPrint(gpa, "{s}.lock", .{service});
        defer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ self.dir, name });
        defer gpa.free(path);
        const file = try std.Io.Dir.cwd().createFile(self.io, path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = paths.private_file_permissions,
        });
        return .{ .io = self.io, .file = file };
    }

    pub const Held = struct {
        io: std.Io,
        file: std.Io.File,

        pub fn release(self: Held) void {
            self.file.close(self.io);
        }
    };

    fn markPath(self: StopMarks, gpa: std.mem.Allocator, service: []const u8) ![]const u8 {
        return std.fs.path.join(gpa, &.{ self.dir, service });
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testMark(marks: StopMarks) void {
    marks.mark(std.testing.allocator, "api") catch |err| std.debug.panic("mark failed: {s}", .{@errorName(err)});
}

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

test "stop_marks.mark: waits while the service lock is held" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const marks = try StopMarks.init(std.testing.allocator, std.testing.io, base, "demo");
    defer std.testing.allocator.free(marks.dir);
    const held = try marks.hold(std.testing.allocator, "api");
    var released = false;
    defer if (!released) held.release();

    const thread = try std.Thread.spawn(.{}, testMark, .{marks});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
    const while_held = marks.observe(std.testing.allocator, "api");
    held.release();
    released = true;
    thread.join();

    try std.testing.expectEqual(observations.StopMarkObservation.not_stopped, while_held);
    try std.testing.expectEqual(observations.StopMarkObservation.stopped, marks.observe(std.testing.allocator, "api"));
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
