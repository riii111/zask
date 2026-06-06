const std = @import("std");
const runner_mod = @import("runner.zig");

pub const ListenPortState = enum {
    ports,
    none,
    unavailable,
};

pub const ListenPorts = struct {
    state: ListenPortState,
    ports: []const i64 = &.{},

    pub fn empty(state: ListenPortState) ListenPorts {
        return .{ .state = state };
    }

    pub fn fromOwned(ports: []const i64) ListenPorts {
        return .{ .state = .ports, .ports = ports };
    }

    pub fn deinit(self: ListenPorts, gpa: std.mem.Allocator) void {
        gpa.free(self.ports);
    }

    pub fn contains(self: ListenPorts, port: i64) bool {
        for (self.ports) |item| {
            if (item == port) return true;
        }
        return false;
    }
};

pub fn observeDescendantListenPorts(gpa: std.mem.Allocator, runner: runner_mod.Runner, root_pid: []const u8) !ListenPorts {
    const pids = collectDescendantPids(gpa, runner, root_pid) catch return ListenPorts.empty(.unavailable);
    defer {
        for (pids) |pid| gpa.free(pid);
        gpa.free(pids);
    }
    if (pids.len == 0) return ListenPorts.empty(.unavailable);

    const pid_arg = try joinPids(gpa, pids);
    defer gpa.free(pid_arg);
    const output = runner_mod.captured(runner.run(&.{ "lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pid_arg }, .{}) catch return ListenPorts.empty(.unavailable));
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);

    const ports = try parseListenPorts(gpa, output.stdout);
    if (ports.len > 0) return ListenPorts.fromOwned(ports);
    gpa.free(ports);

    if (output.term == .exited and output.term.exited == 0) return ListenPorts.empty(.none);
    if (std.mem.trim(u8, output.stderr, " \t\r\n").len == 0) return ListenPorts.empty(.none);
    return ListenPorts.empty(.unavailable);
}

fn collectDescendantPids(gpa: std.mem.Allocator, runner: runner_mod.Runner, root_pid: []const u8) ![][]const u8 {
    var pids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pids.items) |pid| gpa.free(pid);
        pids.deinit(gpa);
    }
    const root = std.mem.trim(u8, root_pid, " \t\r\n");
    if (root.len == 0 or std.mem.eql(u8, root, "0")) return pids.toOwnedSlice(gpa);
    try pids.append(gpa, try gpa.dupe(u8, root));

    var index: usize = 0;
    while (index < pids.items.len) : (index += 1) {
        try appendChildPids(gpa, runner, &pids, pids.items[index]);
    }
    return pids.toOwnedSlice(gpa);
}

fn appendChildPids(gpa: std.mem.Allocator, runner: runner_mod.Runner, pids: *std.ArrayList([]const u8), parent: []const u8) !void {
    const output = runner_mod.captured(runner.run(&.{ "pgrep", "-P", parent }, .{}) catch return error.ProcessProbeUnavailable);
    defer gpa.free(output.stdout);
    defer gpa.free(output.stderr);
    if (output.term != .exited) return error.ProcessProbeUnavailable;
    if (output.term.exited != 0) return;

    var lines = std.mem.splitScalar(u8, output.stdout, '\n');
    while (lines.next()) |line| {
        const child = std.mem.trim(u8, line, " \t\r\n");
        if (child.len == 0 or containsPid(pids.items, child)) continue;
        try pids.append(gpa, try gpa.dupe(u8, child));
    }
}

fn joinPids(gpa: std.mem.Allocator, pids: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (pids, 0..) |pid, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(pid);
    }
    return out.toOwnedSlice();
}

fn containsPid(pids: []const []const u8, pid: []const u8) bool {
    for (pids) |item| {
        if (std.mem.eql(u8, item, pid)) return true;
    }
    return false;
}

fn parseListenPorts(gpa: std.mem.Allocator, output: []const u8) ![]i64 {
    var ports: std.ArrayList(i64) = .empty;
    errdefer ports.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "(LISTEN)") == null) continue;
        const marker = std.mem.indexOf(u8, line, " (LISTEN)") orelse line.len;
        const endpoint = std.mem.trim(u8, line[0..marker], " \t\r\n");
        const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse continue;
        const port_text = endpoint[colon + 1 ..];
        const parsed = std.fmt.parseInt(i64, port_text, 10) catch continue;
        if (!containsPort(ports.items, parsed)) try ports.append(gpa, parsed);
    }
    return ports.toOwnedSlice(gpa);
}

fn containsPort(ports: []const i64, port: i64) bool {
    for (ports) |item| {
        if (item == port) return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "process_probe.observeDescendantListenPorts: finds ports from grandchildren" {
    var recorder = runner_mod.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("200\n", "", .{ .exited = 0 });
    try recorder.enqueue("300\n", "", .{ .exited = 0 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue(
        \\COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        \\node    300 me  7u IPv4 0x123      0t0  TCP *:15432 (LISTEN)
        \\
    , "", .{ .exited = 0 });
    const runner = runner_mod.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const ports = try observeDescendantListenPorts(std.testing.allocator, runner, "100");
    defer ports.deinit(std.testing.allocator);

    try std.testing.expectEqual(ListenPortState.ports, ports.state);
    try std.testing.expectEqual(@as(usize, 1), ports.ports.len);
    try std.testing.expectEqual(@as(i64, 15432), ports.ports[0]);
    try runner_mod.expectCommandArg(recorder.commands.items[3], 6, "100,200,300");
}

test "process_probe.observeDescendantListenPorts: classifies empty lsof result as none" {
    var recorder = runner_mod.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 1 });
    const runner = runner_mod.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const ports = try observeDescendantListenPorts(std.testing.allocator, runner, "100");
    defer ports.deinit(std.testing.allocator);

    try std.testing.expectEqual(ListenPortState.none, ports.state);
}

test "process_probe.observeDescendantListenPorts: classifies lsof errors as unavailable" {
    var recorder = runner_mod.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "", .{ .exited = 1 });
    try recorder.enqueue("", "permission denied\n", .{ .exited = 1 });
    const runner = runner_mod.Runner{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const ports = try observeDescendantListenPorts(std.testing.allocator, runner, "100");
    defer ports.deinit(std.testing.allocator);

    try std.testing.expectEqual(ListenPortState.unavailable, ports.state);
}

test "process_probe.parseListenPorts: parses unique lsof listen ports" {
    const output =
        \\COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        \\node    12345 me     7u  IPv4 0x123      0t0  TCP *:15432 (LISTEN)
        \\node    12346 me     8u  IPv6 0x456      0t0  TCP [::1]:3000 (LISTEN)
        \\node    12346 me     9u  IPv6 0x456      0t0  TCP [::1]:3000 (LISTEN)
        \\
    ;
    const ports = try parseListenPorts(std.testing.allocator, output);
    defer std.testing.allocator.free(ports);

    try std.testing.expectEqual(@as(usize, 2), ports.len);
    try std.testing.expectEqual(@as(i64, 15432), ports[0]);
    try std.testing.expectEqual(@as(i64, 3000), ports[1]);
}
