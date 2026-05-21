const std = @import("std");

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn run(self: Runner, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    pub fn runCwd(self: Runner, argv: []const []const u8, cwd: []const u8) !std.process.RunResult {
        return std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    pub fn runInteractive(self: Runner, argv: []const []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.io, .{ .argv = argv });
        return child.wait(self.io);
    }

    pub fn runInteractiveCwd(self: Runner, argv: []const []const u8, cwd: []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
        return child.wait(self.io);
    }
};
