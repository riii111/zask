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
        const result = (if (options.cwd) |cwd|
            std.process.run(self.gpa, self.io, .{
                .argv = argv,
                .cwd = .{ .path = cwd },
                .stdout_limit = .limited(captured_output_limit),
                .stderr_limit = .limited(captured_output_limit),
            })
        else
            std.process.run(self.gpa, self.io, .{
                .argv = argv,
                .stdout_limit = .limited(captured_output_limit),
                .stderr_limit = .limited(captured_output_limit),
            })) catch |err| switch (err) {
            error.StreamTooLong => return error.OutputTooLarge,
            else => return err,
        };
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
            recorder.recordSleep(duration);
            return;
        }
        std.Io.sleep(self.io, duration, .awake) catch {};
    }

    fn recordedRun(self: Runner, recorder: *Recorder, argv: []const []const u8, options: RunOptions) !RunOutput {
        const result = recorder.record(argv, options.cwd, options.interactive) catch |err| switch (err) {
            error.StreamTooLong => return error.OutputTooLarge,
            else => return err,
        };
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

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    commands: std.ArrayList(RecordedCommand),
    responses: std.ArrayList(RecordedResponse),
    errors: std.ArrayList(anyerror),
    sleeps: std.ArrayList(RecordedSleep),
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    term: std.process.Child.Term = .{ .exited = 0 },

    pub fn init(gpa: std.mem.Allocator) Recorder {
        return .{ .gpa = gpa, .commands = .empty, .responses = .empty, .errors = .empty, .sleeps = .empty };
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
        self.errors.deinit(self.gpa);
        self.sleeps.deinit(self.gpa);
    }

    pub fn enqueue(self: *Recorder, stdout: []const u8, stderr: []const u8, term: std.process.Child.Term) !void {
        try self.responses.append(self.gpa, .{
            .stdout = try self.gpa.dupe(u8, stdout),
            .stderr = try self.gpa.dupe(u8, stderr),
            .term = term,
        });
    }

    /// Queues a spawn-time error after queued responses are consumed.
    pub fn enqueueError(self: *Recorder, err: anyerror) !void {
        try self.errors.append(self.gpa, err);
    }

    pub fn recordSleep(self: *Recorder, duration: std.Io.Duration) void {
        self.sleeps.append(self.gpa, .{ .duration = duration, .commands_before = self.commands.items.len }) catch |err|
            std.debug.panic("failed to record sleep: {s}", .{@errorName(err)});
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
        if (self.errors.items.len > 0) return self.errors.orderedRemove(0);
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
    commands_before: usize,
};

pub fn commandContains(command: RecordedCommand, needle: []const u8) bool {
    for (command.argv) |arg| {
        if (std.mem.indexOf(u8, arg, needle) != null) return true;
    }
    if (command.cwd) |cwd| return std.mem.indexOf(u8, cwd, needle) != null;
    return false;
}

pub fn findCommandContaining(recorder: *const Recorder, needle: []const u8) ?RecordedCommand {
    for (recorder.commands.items) |command| {
        if (commandContains(command, needle)) return command;
    }
    return null;
}

pub fn expectCommandContaining(recorder: *const Recorder, needle: []const u8) !void {
    try std.testing.expect(findCommandContaining(recorder, needle) != null);
}

pub fn expectCommandArgv(command: RecordedCommand, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, command.argv.len);
    for (expected, command.argv) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

pub fn expectCommandArgvStartsWith(command: RecordedCommand, expected: []const []const u8) !void {
    try std.testing.expect(command.argv.len >= expected.len);
    for (expected, command.argv[0..expected.len]) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

pub fn expectCommandArg(command: RecordedCommand, index: usize, expected: []const u8) !void {
    try std.testing.expect(command.argv.len > index);
    try std.testing.expectEqualStrings(expected, command.argv[index]);
}

pub fn expectCommandArgContains(command: RecordedCommand, index: usize, needle: []const u8) !void {
    try std.testing.expect(command.argv.len > index);
    try std.testing.expect(std.mem.indexOf(u8, command.argv[index], needle) != null);
}

pub fn expectCommandArgNotContains(command: RecordedCommand, index: usize, needle: []const u8) !void {
    try std.testing.expect(command.argv.len > index);
    try std.testing.expect(std.mem.indexOf(u8, command.argv[index], needle) == null);
}

pub fn expectCommandCwd(command: RecordedCommand, expected: []const u8) !void {
    try std.testing.expect(command.cwd != null);
    try std.testing.expectEqualStrings(expected, command.cwd.?);
}

pub fn expectCommandOrder(recorder: *const Recorder, before: []const u8, after: []const u8) !void {
    const before_index = findCommandIndexContaining(recorder, before, 0) orelse return error.CommandNotFound;
    const same_command = commandContains(recorder.commands.items[before_index], after);
    if (same_command) return error.SameCommandMatchesBothNeedles;
    const after_index = findCommandIndexContaining(recorder, after, 0) orelse return error.CommandNotFound;
    try std.testing.expect(before_index < after_index);
}

pub fn expectNoTmuxSizingCommands(recorder: *const Recorder) !void {
    for (recorder.commands.items) |command| {
        if (std.mem.eql(u8, command.argv[0], "tmux") and command.argv.len > 1) {
            try std.testing.expect(!std.mem.eql(u8, command.argv[1], "resize-window"));
            try std.testing.expect(!std.mem.eql(u8, command.argv[1], "resize-pane"));
            if (std.mem.eql(u8, command.argv[1], "set-option") or std.mem.eql(u8, command.argv[1], "set-window-option")) {
                for (command.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "window-size"));
            }
        }
    }
}

pub fn expectNoRemainingResponses(recorder: *const Recorder) !void {
    try std.testing.expectEqual(@as(usize, 0), recorder.responses.items.len);
    try std.testing.expectEqual(@as(usize, 0), recorder.errors.items.len);
}

fn findCommandIndexContaining(recorder: *const Recorder, needle: []const u8, start: usize) ?usize {
    for (recorder.commands.items[start..], start..) |command, index| {
        if (commandContains(command, needle)) return index;
    }
    return null;
}

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
    try expectCommandArgv(recorder.commands.items[0], &.{ "echo", "ok" });
    try expectCommandCwd(recorder.commands.items[0], "/tmp/demo");
    try std.testing.expect(!recorder.commands.items[0].interactive);

    _ = try run.run(&.{"zsh"}, .{ .interactive = true });
    try std.testing.expect(recorder.commands.items[1].interactive);

    run.sleep(std.Io.Duration.fromSeconds(2));
    try std.testing.expectEqual(@as(usize, 1), recorder.sleeps.items.len);
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(2), recorder.sleeps.items[0].duration);
    try std.testing.expectEqual(@as(usize, 2), recorder.sleeps.items[0].commands_before);
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

test "recorder returns queued responses before queued errors" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("first", "", .{ .exited = 0 });
    try recorder.enqueueError(error.FileNotFound);
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const first = captured(try run.run(&.{"one"}, .{}));
    defer std.testing.allocator.free(first.stdout);
    defer std.testing.allocator.free(first.stderr);

    try std.testing.expectEqualStrings("first", first.stdout);
    try std.testing.expectError(error.FileNotFound, run.run(&.{"two"}, .{}));
    try std.testing.expectEqual(@as(usize, 2), recorder.commands.items.len);
    try expectNoRemainingResponses(&recorder);
}

test "run maps stream-too-long to output-too-large" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueueError(error.StreamTooLong);
    const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    try std.testing.expectError(error.OutputTooLarge, run.run(&.{"docker"}, .{}));
}

test "checked runner rejects non-zero exits" {
    const cases = [_]struct {
        argv: []const []const u8,
        options: RunOptions,
        term: std.process.Child.Term,
        stderr: []const u8 = "",
    }{
        .{ .argv = &.{"false"}, .options = .{ .check = true, .discard = true }, .term = .{ .exited = 2 }, .stderr = "failed" },
        .{ .argv = &.{"tmux"}, .options = .{ .interactive = true, .check = true }, .term = .{ .exited = 1 } },
    };

    for (cases) |case| {
        var recorder = Recorder.init(std.testing.allocator);
        defer recorder.deinit();
        try recorder.enqueue("", case.stderr, case.term);
        const run = Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

        try std.testing.expectError(error.CommandFailed, run.run(case.argv, case.options));
    }
}
