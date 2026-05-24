const std = @import("std");

pub const SessionObservation = enum {
    active,
    missing,
    unavailable,
};

pub const WindowObservation = enum {
    present,
    missing,
    unavailable,
};

pub const PaneState = enum {
    window_missing,
    idle,
    busy,
    dead,
    tmux_unavailable,
};

pub const PaneObservation = struct {
    state: PaneState,
    exit_code: []const u8 = "",
    pid: []const u8 = "",
    command: []const u8 = "",

    pub fn empty(state: PaneState) PaneObservation {
        return .{ .state = state };
    }

    pub fn fromOwned(state: PaneState, exit_code: []const u8, pid: []const u8, command: []const u8) PaneObservation {
        return .{
            .state = state,
            .exit_code = exit_code,
            .pid = pid,
            .command = command,
        };
    }

    pub fn deinit(self: PaneObservation, gpa: std.mem.Allocator) void {
        gpa.free(self.exit_code);
        gpa.free(self.pid);
        gpa.free(self.command);
    }

    pub fn running(self: PaneObservation) bool {
        return self.state == .busy;
    }
};

pub const ComposeState = enum {
    unavailable,
    empty,
    running,
};

pub const ComposeObservation = struct {
    state: ComposeState,
    services: []const []const u8 = &.{},
    owned: bool = false,

    pub fn deinit(self: ComposeObservation, gpa: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.services) |service| gpa.free(service);
        gpa.free(self.services);
    }

    pub fn contains(self: ComposeObservation, name: []const u8) bool {
        for (self.services) |service| {
            if (std.mem.eql(u8, service, name)) return true;
        }
        return false;
    }
};

pub const HealthObservation = enum {
    no_check,
    waiting,
    ready,
    degraded,
};

pub const ServiceObservation = struct {
    pane: PaneObservation,
    health: HealthObservation,

    pub fn deinit(self: ServiceObservation, gpa: std.mem.Allocator) void {
        self.pane.deinit(gpa);
    }
};

test "compose observation reports contained services" {
    const services = try std.testing.allocator.alloc([]const u8, 2);
    services[0] = try std.testing.allocator.dupe(u8, "api");
    services[1] = try std.testing.allocator.dupe(u8, "db");
    const observation = ComposeObservation{ .state = .running, .services = services, .owned = true };
    defer observation.deinit(std.testing.allocator);

    try std.testing.expect(observation.contains("api"));
    try std.testing.expect(!observation.contains("web"));
}

test "compose observation deinit accepts unowned empty services" {
    const observation = ComposeObservation{ .state = .empty };
    observation.deinit(std.testing.allocator);
}

test "pane observation deinit accepts empty observation" {
    const observation = PaneObservation.empty(.window_missing);
    observation.deinit(std.testing.allocator);
}

test "pane observation owns pane fields" {
    const exit_code = try std.testing.allocator.dupe(u8, "130");
    const pid = try std.testing.allocator.dupe(u8, "12345");
    const command = try std.testing.allocator.dupe(u8, "node");
    const observation = PaneObservation.fromOwned(.dead, exit_code, pid, command);
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(PaneState.dead, observation.state);
    try std.testing.expectEqualStrings("130", observation.exit_code);
    try std.testing.expectEqualStrings("12345", observation.pid);
    try std.testing.expectEqualStrings("node", observation.command);
}
