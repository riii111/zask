const std = @import("std");

const captured_output_limit = 1024 * 1024;

pub const Runner = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    recorder: ?*Recorder = null,

    pub fn run(self: Runner, argv: []const []const u8, options: RunOptions) !RunOutput {
        if (self.recorder) |recorder| {
            return self.recordedRun(recorder, argv, options);
        }
        if (options.interactive) {
            var child = if (options.cwd) |cwd|
                try std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = cwd } })
            else
                try std.process.spawn(self.io, .{ .argv = argv });
            const term = try child.wait(self.io);
            if (options.check) try checkTerm(term);
            return .{ .term = term };
        }
        const result = if (options.cwd) |cwd|
            try std.process.run(self.gpa, self.io, .{
                .argv = argv,
                .cwd = .{ .path = cwd },
                .stdout_limit = .limited(captured_output_limit),
                .stderr_limit = .limited(captured_output_limit),
            })
        else
            try std.process.run(self.gpa, self.io, .{
                .argv = argv,
                .stdout_limit = .limited(captured_output_limit),
                .stderr_limit = .limited(captured_output_limit),
            });
        errdefer self.gpa.free(result.stdout);
        errdefer self.gpa.free(result.stderr);
        if (options.check) try checkTerm(result.term);
        if (options.discard) {
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
            return .discarded;
        }
        return .{ .captured = result };
    }

    pub fn sleep(self: Runner, duration: std.Io.Duration) void {
        if (self.recorder) |recorder| {
            recorder.recordSleep(duration) catch return;
            return;
        }
        std.Io.sleep(self.io, duration, .awake) catch {};
    }

    fn recordedRun(self: Runner, recorder: *Recorder, argv: []const []const u8, options: RunOptions) !RunOutput {
        const result = try recorder.record(argv, options.cwd, options.interactive);
        errdefer self.gpa.free(result.stdout);
        errdefer self.gpa.free(result.stderr);
        if (options.check) try checkTerm(result.term);
        if (options.interactive) {
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
            return .{ .term = result.term };
        }
        if (options.discard) {
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
            return .discarded;
        }
        return .{ .captured = result };
    }
};

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    check: bool = false,
    discard: bool = false,
    interactive: bool = false,
};

pub const RunOutput = union(enum) {
    captured: std.process.RunResult,
    term: std.process.Child.Term,
    discarded,
};

pub fn captured(output: RunOutput) std.process.RunResult {
    return switch (output) {
        .captured => |result| result,
        else => @panic("captured() called on non-captured output"),
    };
}

fn checkTerm(term: std.process.Child.Term) !void {
    if (term == .exited and term.exited == 0) return;
    return error.CommandFailed;
}

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    commands: std.ArrayList(RecordedCommand),
    responses: std.ArrayList(RecordedResponse),
    sleeps: std.ArrayList(RecordedSleep),
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    term: std.process.Child.Term = .{ .exited = 0 },

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa, .commands = .empty, .responses = .empty, .sleeps = .empty };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.commands.items) |command| {
            for (command.argv) |arg| self.gpa.free(arg);
            self.gpa.free(command.argv);
            if (command.cwd) |cwd| self.gpa.free(cwd);
        }
        self.commands.deinit(self.gpa);
        for (self.responses.items) |response| {
            self.gpa.free(response.stdout);
            self.gpa.free(response.stderr);
        }
        self.responses.deinit(self.gpa);
        self.sleeps.deinit(self.gpa);
    }

    pub fn enqueue(self: *Recorder, stdout: []const u8, stderr: []const u8, term: std.process.Child.Term) !void {
        try self.responses.append(self.gpa, .{
            .stdout = try self.gpa.dupe(u8, stdout),
            .stderr = try self.gpa.dupe(u8, stderr),
            .term = term,
        });
    }

    pub fn recordSleep(self: *Recorder, duration: std.Io.Duration) !void {
        try self.sleeps.append(self.gpa, .{ .duration = duration, .command_count = self.commands.items.len });
    }

    fn record(self: *Recorder, argv: []const []const u8, cwd: ?[]const u8, interactive: bool) !std.process.RunResult {
        const owned_argv = try self.gpa.alloc([]const u8, argv.len);
        for (argv, 0..) |arg, index| owned_argv[index] = try self.gpa.dupe(u8, arg);
        try self.commands.append(self.gpa, .{
            .argv = owned_argv,
            .cwd = if (cwd) |value| try self.gpa.dupe(u8, value) else null,
            .interactive = interactive,
        });
        if (self.responses.items.len > 0) {
            const response = self.responses.orderedRemove(0);
            defer self.gpa.free(response.stdout);
            defer self.gpa.free(response.stderr);
            return .{
                .term = response.term,
                .stdout = try self.gpa.dupe(u8, response.stdout),
                .stderr = try self.gpa.dupe(u8, response.stderr),
            };
        }
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

pub const RecordedSleep = struct {
    duration: std.Io.Duration,
    command_count: usize,
};

const RecordedResponse = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
};

test "recorder captures commands without spawning processes" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const result = captured(try run.run(&.{ "echo", "ok" }, .{ .cwd = "/tmp/demo" }));
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(@as(usize, 1), recorder.commands.items.len);
    try std.testing.expectEqualStrings("echo", recorder.commands.items[0].argv[0]);
    try std.testing.expectEqualStrings("ok", recorder.commands.items[0].argv[1]);
    try std.testing.expectEqualStrings("/tmp/demo", recorder.commands.items[0].cwd.?);
    try std.testing.expect(!recorder.commands.items[0].interactive);

    _ = try run.run(&.{"zsh"}, .{ .interactive = true });
    try std.testing.expect(recorder.commands.items[1].interactive);

    run.sleep(std.Io.Duration.fromSeconds(2));
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(2), recorder.sleeps.items[0].duration);
    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items[0].command_count);
}

test "recorder returns queued responses in order" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("first", "", .{ .exited = 0 });
    try recorder.enqueue("second", "warn", .{ .exited = 1 });
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const first = captured(try run.run(&.{"one"}, .{}));
    defer std.testing.allocator.free(first.stdout);
    defer std.testing.allocator.free(first.stderr);
    const second = captured(try run.run(&.{"two"}, .{}));
    defer std.testing.allocator.free(second.stdout);
    defer std.testing.allocator.free(second.stderr);

    try std.testing.expectEqualStrings("first", first.stdout);
    try std.testing.expectEqualStrings("second", second.stdout);
    try std.testing.expectEqualStrings("warn", second.stderr);
    try std.testing.expectEqual(@as(u8, 1), second.term.exited);
}

test "checked runner rejects non-zero exits" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "failed", .{ .exited = 2 });
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    try std.testing.expectError(error.CommandFailed, run.run(&.{"false"}, .{ .check = true, .discard = true }));
}

test "checked interactive runner rejects non-zero exits" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    try std.testing.expectError(error.CommandFailed, run.run(&.{"tmux"}, .{ .interactive = true, .check = true }));
}
