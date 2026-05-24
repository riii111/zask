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
        const result = self.runningServices() catch return observations.ComposeObservation.empty(.unavailable);
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return observations.ComposeObservation.empty(.unavailable);
        const services = parseServices(self.gpa, result.stdout) catch return observations.ComposeObservation.empty(.unavailable);
        if (services.len == 0) return observations.ComposeObservation.fromOwned(.empty, services);
        return observations.ComposeObservation.fromOwned(.running, services);
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
};

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

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "runningServices uses compose working directory" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    const result = try compose.runningServices();
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try runner.expectCommandCwd(recorder.commands.items[0], "/tmp/demo/docker");
    try runner.expectCommandArg(recorder.commands.items[0], 3, "compose.yaml");
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

test "observe returns empty state and frees parsed services" {
    var recorder = runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("\n\n", "", .{ .exited = 0 });
    const run = runner.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };
    const compose = Compose{ .gpa = std.testing.allocator, .runner = run, .dir = "/tmp/demo/docker", .file = "compose.yaml" };

    const observation = compose.observe();
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(observations.ComposeState.empty, observation.state);
    try std.testing.expectEqual(@as(usize, 0), observation.services.len);
}
