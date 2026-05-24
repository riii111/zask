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

    /// Takes ownership of all pane field slices.
    pub fn fromOwnedFields(state: PaneState, exit_code: []const u8, pid: []const u8, command: []const u8) PaneObservation {
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

    pub fn empty(state: ComposeState) ComposeObservation {
        return .{ .state = state };
    }

    /// Takes ownership of the services slice and each service name.
    pub fn fromOwnedServices(state: ComposeState, services: []const []const u8) ComposeObservation {
        return .{
            .state = state,
            .services = services,
        };
    }

    pub fn deinit(self: ComposeObservation, gpa: std.mem.Allocator) void {
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
    const observation = ComposeObservation.fromOwnedServices(.running, services);
    defer observation.deinit(std.testing.allocator);

    try std.testing.expect(observation.contains("api"));
    try std.testing.expect(!observation.contains("web"));
}

test "compose observation deinit is no-op for empty default services" {
    const observation = ComposeObservation.empty(.empty);
    observation.deinit(std.testing.allocator);
}

test "pane observation deinit is no-op for empty default fields" {
    const observation = PaneObservation.empty(.window_missing);
    observation.deinit(std.testing.allocator);
}

test "pane observation deinit frees exit_code pid and command" {
    const exit_code = try std.testing.allocator.dupe(u8, "130");
    const pid = try std.testing.allocator.dupe(u8, "12345");
    const command = try std.testing.allocator.dupe(u8, "node");
    const observation = PaneObservation.fromOwnedFields(.dead, exit_code, pid, command);
    defer observation.deinit(std.testing.allocator);

    try std.testing.expectEqual(PaneState.dead, observation.state);
    try std.testing.expectEqualStrings("130", observation.exit_code);
    try std.testing.expectEqualStrings("12345", observation.pid);
    try std.testing.expectEqualStrings("node", observation.command);
}
