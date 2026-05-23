const std = @import("std");
const observations = @import("../model/observations.zig");
const runner = @import("runner.zig");

pub const Compose = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    dir: []const u8,
    file: []const u8,

    pub fn running(self: Compose) bool {
        const observation = self.observe();
        defer observation.deinit(self.gpa);
        return observation.state == .running;
    }

    pub fn observe(self: Compose) observations.ComposeObservation {
        const result = self.runningServices() catch return .{ .state = .unavailable };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return .{ .state = .unavailable };
        const services = parseServices(self.gpa, result.stdout) catch return .{ .state = .unavailable };
        if (services.len == 0) return .{ .state = .empty, .services = services };
        return .{ .state = .running, .services = services, .owned = true };
    }

    pub fn runningServices(self: Compose) !std.process.RunResult {
        return runner.captured(try self.runner.run(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running", "--format", "{{.Service}}" }, .{ .cwd = self.dir }));
    }

    pub fn runningTable(self: Compose) !std.process.RunResult {
        return runner.captured(try self.runner.run(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running" }, .{ .cwd = self.dir }));
    }

    pub fn down(self: Compose) !void {
        const result = runner.captured(try self.runner.run(&.{ "docker", "compose", "-f", self.file, "down" }, .{ .cwd = self.dir, .check = true }));
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    pub fn execInteractive(self: Compose, container: []const u8, command: []const u8) !void {
        const command_args = try splitCommand(self.gpa, command);
        defer freeArgs(self.gpa, command_args);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ "docker", "compose", "-f", self.file, "exec", container });
        try argv.appendSlice(self.gpa, command_args);
        _ = try self.runner.run(argv.items, .{ .cwd = self.dir, .interactive = true, .check = true });
    }
};

fn splitCommand(gpa: std.mem.Allocator, command: []const u8) ![][]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);
    var quote: ?u8 = null;
    var escaped = false;
    var in_token = false;

    var index: usize = 0;
    while (index < command.len) : (index += 1) {
        const byte = command[index];
        if (escaped) {
            try current.append(gpa, byte);
            escaped = false;
            in_token = true;
            continue;
        }
        if (byte == '\\' and quote != '\'' and index + 1 < command.len and command[index + 1] == '\n') {
            index += 1;
            continue;
        }
        if (byte == '\\' and quote == '"') {
            const next = if (index + 1 < command.len) command[index + 1] else 0;
            if (next == '$' or next == '`' or next == '"' or next == '\\' or next == '\n') {
                escaped = true;
            } else {
                try current.append(gpa, byte);
            }
            in_token = true;
            continue;
        }
        if (byte == '\\' and quote != '\'') {
            escaped = true;
            in_token = true;
            continue;
        }
        if (quote) |q| {
            if (byte == q) {
                quote = null;
            } else {
                try current.append(gpa, byte);
            }
            in_token = true;
            continue;
        }
        switch (byte) {
            '\'', '"' => {
                quote = byte;
                in_token = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (in_token) {
                    try args.append(gpa, try current.toOwnedSlice(gpa));
                    current = .empty;
                    in_token = false;
                }
            },
            else => {
                try current.append(gpa, byte);
                in_token = true;
            },
        }
    }
    if (escaped or quote != null) return error.InvalidCommand;
    if (in_token) try args.append(gpa, try current.toOwnedSlice(gpa));
    if (args.items.len == 0) return error.InvalidCommand;
    return args.toOwnedSlice(gpa);
}

fn freeArgs(gpa: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| gpa.free(arg);
    gpa.free(args);
}

fn parseServices(gpa: std.mem.Allocator, output: []const u8) ![]const []const u8 {
    var services: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (services.items) |service| gpa.free(service);
        services.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const service = std.mem.trim(u8, line, " \t\r");
        if (service.len == 0) continue;
        try services.append(gpa, try gpa.dupe(u8, service));
    }
    return services.toOwnedSlice(gpa);
}

test "runningServices uses compose working directory" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    const result = try compose.runningServices();
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualStrings("/tmp/demo/docker", recorder.commands.items[0].cwd.?);
    try std.testing.expectEqualStrings("compose.yaml", recorder.commands.items[0].argv[3]);
}

test "running ignores empty service output" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    try std.testing.expect(!compose.running());
}

test "running ignores failed compose command output" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("api\n", "docker unavailable", .{ .exited = 1 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    try std.testing.expect(!compose.running());
}

test "observe returns running services" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("api\ndb\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    const observation = compose.observe();
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.ComposeState.running, observation.state);
    try std.testing.expect(observation.contains("api"));
    try std.testing.expect(observation.contains("db"));
}

test "execInteractive passes configured command directly" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    try compose.execInteractive("db", "psql -c 'select 1'");

    const command = recorder.commands.items[0];
    try std.testing.expect(command.interactive);
    try std.testing.expectEqualStrings("psql", command.argv[6]);
    try std.testing.expectEqualStrings("-c", command.argv[7]);
    try std.testing.expectEqualStrings("select 1", command.argv[8]);
}

test "splitCommand handles shell-like quotes and whitespace" {
    const args = try splitCommand(std.testing.allocator, "sh\t-c \"echo hi\" 'literal value'");
    defer freeArgs(std.testing.allocator, args);

    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("sh", args[0]);
    try std.testing.expectEqualStrings("-c", args[1]);
    try std.testing.expectEqualStrings("echo hi", args[2]);
    try std.testing.expectEqualStrings("literal value", args[3]);
}

test "splitCommand preserves non-special backslash inside double quotes" {
    const args = try splitCommand(std.testing.allocator, "psql -c \"select '\\n'\"");
    defer freeArgs(std.testing.allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("psql", args[0]);
    try std.testing.expectEqualStrings("-c", args[1]);
    try std.testing.expectEqualStrings("select '\\n'", args[2]);
}

test "splitCommand removes backslash newline continuations" {
    const args = try splitCommand(std.testing.allocator, "psql \\\n-c 'select 1'");
    defer freeArgs(std.testing.allocator, args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("psql", args[0]);
    try std.testing.expectEqualStrings("-c", args[1]);
    try std.testing.expectEqualStrings("select 1", args[2]);
}

test "splitCommand drops trailing backslash newline without empty token" {
    const args = try splitCommand(std.testing.allocator, "foo \\\n");
    defer freeArgs(std.testing.allocator, args);

    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("foo", args[0]);
}

test "splitCommand rejects empty and incomplete input" {
    try std.testing.expectError(error.InvalidCommand, splitCommand(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidCommand, splitCommand(std.testing.allocator, "echo \\"));
    try std.testing.expectError(error.InvalidCommand, splitCommand(std.testing.allocator, "echo 'unterminated"));
}
