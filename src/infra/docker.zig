const std = @import("std");
const runner = @import("runner.zig");

pub const Compose = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    dir: []const u8,
    file: []const u8,

    pub fn running(self: Compose) bool {
        const result = self.runningServices() catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return false;
        return std.mem.trim(u8, result.stdout, " \t\r\n").len > 0;
    }

    pub fn runningServices(self: Compose) !std.process.RunResult {
        return self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running", "--format", "{{.Service}}" }, self.dir);
    }

    pub fn runningTable(self: Compose) !std.process.RunResult {
        return self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running" }, self.dir);
    }

    pub fn down(self: Compose) !void {
        const result = try self.runner.runCheckedCwd(&.{ "docker", "compose", "-f", self.file, "down" }, self.dir);
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
        _ = try self.runner.runInteractiveCheckedCwd(argv.items, self.dir);
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

    for (command) |byte| {
        if (escaped) {
            try current.append(gpa, byte);
            escaped = false;
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
