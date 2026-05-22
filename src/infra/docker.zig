const std = @import("std");
const runner = @import("runner.zig");

pub const Compose = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    dir: []const u8,
    file: []const u8,

    pub fn running(self: Compose) bool {
        const result = self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running" }, self.dir) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.stdout.len > 0;
    }

    pub fn runningServices(self: Compose) !std.process.RunResult {
        return self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running", "--format", "{{.Service}}" }, self.dir);
    }

    pub fn runningTable(self: Compose) !std.process.RunResult {
        return self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "ps", "--status", "running" }, self.dir);
    }

    pub fn down(self: Compose) !void {
        const result = try self.runner.runCwd(&.{ "docker", "compose", "-f", self.file, "down" }, self.dir);
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    pub fn execInteractive(self: Compose, container: []const u8, command: []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.appendSlice(self.gpa, &.{ "docker", "compose", "-f", self.file, "exec", container });
        var parts = std.mem.tokenizeScalar(u8, command, ' ');
        while (parts.next()) |part| try argv.append(self.gpa, part);
        _ = try self.runner.runInteractiveCwd(argv.items, self.dir);
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
