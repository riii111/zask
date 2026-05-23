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
        _ = try self.runner.runInteractiveCheckedCwd(&.{ "docker", "compose", "-f", self.file, "exec", container, "bash", "-lc", command }, self.dir);
    }
};

test "runningServices uses compose working directory" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = std.Io.null, .recorder = &recorder };
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
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = std.Io.null, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    try std.testing.expect(!compose.running());
}

test "execInteractive preserves command as shell string" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = std.Io.null, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    try compose.execInteractive("db", "psql -c 'select 1'");

    const command = recorder.commands.items[0];
    try std.testing.expect(command.interactive);
    try std.testing.expectEqualStrings("bash", command.argv[6]);
    try std.testing.expectEqualStrings("-lc", command.argv[7]);
    try std.testing.expectEqualStrings("psql -c 'select 1'", command.argv[8]);
}
