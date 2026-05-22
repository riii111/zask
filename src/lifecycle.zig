const std = @import("std");
const config = @import("config.zig");
const config_value = @import("config_value.zig");
const docker_client = @import("infra/docker.zig");
const proc_runner = @import("infra/runner.zig");
const shell = @import("infra/shell.zig");
const tmux_client = @import("infra/tmux.zig");

pub const Lifecycle = struct {
    gpa: std.mem.Allocator,
    cfg: config.Config,
    runner: proc_runner.Runner,
    tmux: tmux_client.Client,
    docker: docker_client.Compose,

    pub fn startAll(self: Lifecycle, profile: []const u8, writer: *std.Io.Writer) !void {
        try self.runPrechecks(writer);
        if (self.cfg.dockerEnabled()) {
            try self.startDocker();
            self.waitForDocker(writer) catch {
                try writer.writeAll("Error: Docker failed to start\n");
                return error.DockerFailed;
            };
        }
        if (std.mem.eql(u8, profile, "docker")) return;
        const phases = self.cfg.phases();
        if (phases.len == 0) {
            for (try self.cfg.services()) |service| try self.startService(try config.Config.serviceName(service), writer);
            return;
        }
        for (phases) |phase| {
            if (phase != .object) continue;
            const phase_type = config_value.optionalObjectString(phase, "type", "");
            if (std.mem.eql(u8, phase_type, "docker")) continue;
            if (std.mem.eql(u8, phase_type, "command")) {
                try self.runCommandPhase(phase, profile, writer);
                continue;
            }
            if (phase.object.get("groups")) |groups| if (groups == .array) {
                for (groups.array.items) |group_value| {
                    if (group_value != .string) continue;
                    const group = self.cfg.resolvePhaseGroup(profile, group_value.string);
                    for (try self.cfg.resolveGroup(self.gpa, group)) |svc| try self.startService(svc, writer);
                }
            };
            if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
                for (ports.array.items) |port_value| if (port_value == .integer) try self.waitForPort(port_value.integer, 120);
            };
        }
    }

    pub fn stopAll(self: Lifecycle, writer: *std.Io.Writer) !void {
        const services = try self.cfg.services();
        var i = services.len;
        while (i > 0) {
            i -= 1;
            try self.stopService(try config.Config.serviceName(services[i]), writer);
        }
        try self.stopDocker();
    }

    pub fn startTarget(self: Lifecycle, target: ?[]const u8, writer: *std.Io.Writer) !void {
        if (!self.tmux.hasSession()) {
            try writer.writeAll("Session not running. Run 'hello' first.\n");
            return;
        }
        const t = target orelse "--all";
        if (std.mem.eql(u8, t, "--all")) return self.startAll("all", writer);
        if (std.mem.eql(u8, t, "docker")) return self.startDocker();
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.startService(svc, writer);
        } else |_| try self.startService(t, writer);
    }

    pub fn stopTarget(self: Lifecycle, target: ?[]const u8, writer: *std.Io.Writer) !void {
        const t = target orelse "--all";
        if (std.mem.eql(u8, t, "--all")) return self.stopAll(writer);
        if (std.mem.eql(u8, t, "docker")) return self.stopDocker();
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.stopService(svc, writer);
        } else |_| try self.stopService(t, writer);
    }

    pub fn restartTarget(self: Lifecycle, target: []const u8, writer: *std.Io.Writer) !void {
        if (std.mem.eql(u8, target, "docker")) {
            try self.stopDocker();
            try self.startDocker();
            return;
        }
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            for (services) |svc| try self.restartService(svc, writer);
        } else |_| try self.restartService(target, writer);
    }

    fn startService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        const value = try self.cfg.findService(service);
        try self.waitForWindow(service);
        if (self.tmux.paneRunning(service)) {
            try writer.print("{s} already running\n", .{service});
            return;
        }
        const target = try self.tmux.target(service);
        const cmd = try std.fmt.allocPrint(self.gpa, "cd {s} && {s}", .{ try shell.quote(self.gpa, try self.cfg.serviceDir(self.gpa, value)), try self.cfg.serviceStartCommand(self.gpa, value) });
        try writer.print("Starting {s}...\n", .{service});
        try self.tmux.sendKeys(target, &.{ cmd, "Enter" });
    }

    fn stopService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        _ = try self.cfg.findService(service);
        try writer.print("Stopping {s}...\n", .{service});
        try self.tmux.sendKeys(try self.tmux.target(service), &.{"C-c"});
        try self.waitForStopped(service);
    }

    fn restartService(self: Lifecycle, service: []const u8, writer: *std.Io.Writer) !void {
        try self.stopService(service, writer);
        try self.startService(service, writer);
    }

    fn startDocker(self: Lifecycle) !void {
        if (!self.cfg.dockerEnabled()) return;
        try self.waitForWindow("docker");
        try self.tmux.sendKeys(try self.tmux.target("docker"), &.{ try std.fmt.allocPrint(self.gpa, "cd {s} && docker compose -f {s} up", .{ try shell.quote(self.gpa, try self.cfg.dockerDir(self.gpa)), try shell.quote(self.gpa, self.cfg.dockerComposeFile()) }), "Enter" });
    }

    fn stopDocker(self: Lifecycle) !void {
        if (!self.cfg.dockerEnabled()) return;
        if (self.tmux.hasSession()) try self.tmux.sendKeys(try self.tmux.target("docker"), &.{"C-c"});
        self.docker.down() catch {};
    }

    fn runPrechecks(self: Lifecycle, writer: *std.Io.Writer) !void {
        const prechecks = self.cfg.value.object.get("prechecks") orelse return;
        if (prechecks != .array) return;
        for (prechecks.array.items) |check| {
            const name = config_value.optionalObjectString(check, "name", "precheck");
            const command = try config_value.requiredObjectString(check, "command");
            const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
            const dir = config_value.optionalObjectString(check, "dir", "");
            const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
            const result = self.runner.runCwd(&.{ "bash", "-c", command }, cwd) catch {
                if (std.mem.eql(u8, on_fail, "abort")) return error.PrecheckFailed;
                try writer.print("Warning: {s} check failed\n", .{name});
                continue;
            };
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
        }
    }

    fn runCommandPhase(self: Lifecycle, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
        const command = try self.cfg.commandPhaseCommand(phase, profile);
        const dir = config_value.optionalObjectString(phase, "dir", "");
        const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
        const result = self.runner.runCwd(&.{ "bash", "-c", command }, cwd) catch {
            if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
            try writer.writeAll("Warning: command phase failed\n");
            return;
        };
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    fn waitForDocker(self: Lifecycle, writer: *std.Io.Writer) !void {
        try writer.writeAll("Waiting for Docker containers...\n");
        var attempt: i64 = 0;
        const max_attempts = self.cfg.dockerWaitTimeout();
        while (attempt < max_attempts) : (attempt += 1) {
            const result = self.docker.runningTable() catch {
                _ = self.runner.run(&.{ "sleep", "1" }) catch {};
                continue;
            };
            defer self.gpa.free(result.stdout);
            defer self.gpa.free(result.stderr);

            if (result.term == .exited and result.term.exited == 0 and runningContainerCount(result.stdout) > 0) {
                _ = self.runner.run(&.{ "sleep", "2" }) catch {};
                try writer.writeAll("Docker containers ready\n");
                return;
            }
            _ = self.runner.run(&.{ "sleep", "1" }) catch {};
        }
        return error.DockerNotReady;
    }

    fn waitForPort(self: Lifecycle, port: i64, timeout: i64) !void {
        var elapsed: i64 = 0;
        while (elapsed < timeout) : (elapsed += 2) {
            if ((self.runner.run(&.{ "nc", "-z", "localhost", try std.fmt.allocPrint(self.gpa, "{d}", .{port}) }) catch null) != null) return;
            _ = self.runner.run(&.{ "sleep", "2" }) catch {};
        }
    }

    fn waitForWindow(self: Lifecycle, window: []const u8) !void {
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            if (self.tmux.windowExists(window)) return;
            _ = self.runner.run(&.{ "sleep", "0.3" }) catch {};
        }
        return error.WindowNotReady;
    }

    fn waitForStopped(self: Lifecycle, service: []const u8) !void {
        var attempt: usize = 0;
        while (attempt < 10) : (attempt += 1) {
            if (!self.tmux.paneRunning(service)) return;
            _ = self.runner.run(&.{ "sleep", "0.5" }) catch {};
        }
    }
};

fn runningContainerCount(output: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    if (count == 0) return 0;
    return count - 1;
}

test "counts running docker compose rows" {
    try std.testing.expectEqual(@as(usize, 0), runningContainerCount(""));
    try std.testing.expectEqual(@as(usize, 0), runningContainerCount("NAME SERVICE STATUS\n"));
    try std.testing.expectEqual(@as(usize, 2), runningContainerCount("NAME SERVICE STATUS\none api running\ntwo db running\n"));
}
