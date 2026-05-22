const std = @import("std");

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    recorder: ?*Recorder = null,

    pub fn run(self: Runner, argv: []const []const u8) !std.process.RunResult {
        if (self.recorder) |recorder| return recorder.record(argv, null, false);
        return std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    pub fn runCwd(self: Runner, argv: []const []const u8, cwd: []const u8) !std.process.RunResult {
        if (self.recorder) |recorder| return recorder.record(argv, cwd, false);
        return std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        });
    }

    pub fn runInteractive(self: Runner, argv: []const []const u8) !std.process.Child.Term {
        if (self.recorder) |recorder| {
            _ = try recorder.record(argv, null, true);
            return .{ .exited = 0 };
        }
        var child = try std.process.spawn(self.io, .{ .argv = argv });
        return child.wait(self.io);
    }

    pub fn runInteractiveCwd(self: Runner, argv: []const []const u8, cwd: []const u8) !std.process.Child.Term {
        if (self.recorder) |recorder| {
            _ = try recorder.record(argv, cwd, true);
            return .{ .exited = 0 };
        }
        var child = try std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
        return child.wait(self.io);
    }
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    commands: std.array_list.Managed(RecordedCommand),
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    term: std.process.Child.Term = .{ .exited = 0 },

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa, .commands = .init(gpa) };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.commands.items) |command| {
            for (command.argv) |arg| self.gpa.free(arg);
            self.gpa.free(command.argv);
            if (command.cwd) |cwd| self.gpa.free(cwd);
        }
        self.commands.deinit();
    }

    fn record(self: *Recorder, argv: []const []const u8, cwd: ?[]const u8, interactive: bool) !std.process.RunResult {
        const owned_argv = try self.gpa.alloc([]const u8, argv.len);
        for (argv, 0..) |arg, index| owned_argv[index] = try self.gpa.dupe(u8, arg);
        try self.commands.append(.{
            .argv = owned_argv,
            .cwd = if (cwd) |value| try self.gpa.dupe(u8, value) else null,
            .interactive = interactive,
        });
        return .{
            .term = self.term,
            .stdout = try self.gpa.dupe(u8, self.stdout),
            .stderr = try self.gpa.dupe(u8, self.stderr),
        };
    }
};

pub const RecordedCommand = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    interactive: bool,
};

test "recorder captures commands without spawning processes" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = Runner{ .gpa = std.testing.allocator, .io = std.Io.null, .recorder = &recorder };

    const result = try run.runCwd(&.{ "echo", "ok" }, "/tmp/demo");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqualStrings("echo", recorder.commands.items[0].argv[0]);
    try std.testing.expectEqualStrings("ok", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("/tmp/demo", recorder.commands.items[0].cwd.?);
    try std.testing.expect(!recorder.commands.items[0].interactive);

    _ = try run.runInteractive(&.{"zsh"});
    try std.testing.expect(recorder.commands.items[1].interactive);
}
