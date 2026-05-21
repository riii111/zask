const std = @import("std");
const config = @import("config.zig");
const dashboard_ui = @import("dashboard.zig");
const render = @import("render.zig");

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    config_path: []const u8,
    zask_path: []const u8,

    pub fn renderSession(self: Runtime, writer: *std.Io.Writer) !void {
        try render.renderTmuxp(self.cfg, self.gpa, writer, self.zask_path, self.config_path);
    }

    pub fn list(self: Runtime, writer: *std.Io.Writer) !void {
        if (self.cfg.dockerEnabled()) try writer.writeAll("docker\n");
        for (try self.cfg.services()) |service| {
            try writer.print("{s}\n", .{try config.Config.serviceName(service)});
        }
    }

    pub fn status(self: Runtime, writer: *std.Io.Writer) !void {
        if (!try self.sessionExists()) {
            try writer.print("Session '{s}' is not running\n", .{try self.cfg.sessionName()});
            return;
        }
        try writer.print("{s} Service Status\n", .{try self.cfg.projectName()});
        if (self.cfg.dockerEnabled()) {
            try writer.print("  docker-compose: {s}\n", .{if (try self.dockerRunning()) "running" else "stopped"});
        }
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            try writer.print("  {s} {s} [{s}]\n", .{ name, if (try self.serviceRunning(name)) "running" else "stopped", config.Config.serviceGroup(service) });
        }
    }

    pub fn attach(self: Runtime) !void {
        if (try self.inTmux()) {
            _ = try self.run(&.{ "tmux", "switch-client", "-t", try self.cfg.sessionName() });
        } else {
            _ = try self.runInteractive(&.{ "tmux", "attach-session", "-t", try self.cfg.sessionName() });
        }
    }

    pub fn detach(self: Runtime, writer: *std.Io.Writer) !void {
        if (try self.inTmux()) {
            _ = try self.run(&.{ "tmux", "detach-client" });
        } else {
            try writer.writeAll("Not in tmux session\n");
        }
    }

    pub fn logs(self: Runtime, service: []const u8) !void {
        try self.validateService(service);
        if (try self.inTmux()) {
            _ = try self.run(&.{ "tmux", "switch-client", "-t", try self.cfg.sessionName() });
        }
        _ = try self.run(&.{ "tmux", "select-window", "-t", try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), service }) });
        if (!try self.inTmux()) try self.attach();
    }

    pub fn follow(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        try self.validateService(service);
        const log_file = try std.fs.path.join(self.gpa, &.{ try self.logDir(), try std.fmt.allocPrint(self.gpa, "{s}.log", .{service}) });
        if (!try self.pathExists(log_file)) try writer.print("Warning: Log file not found yet: {s}\n", .{log_file});
        _ = try self.run(&.{ "tmux", "popup", "-w", self.cfg.popupWidth(), "-h", self.cfg.popupHeight(), "-E", try std.fmt.allocPrint(self.gpa, "nvim -c 'terminal tail -F {s}'", .{log_file}) });
    }

    pub fn hello(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
        if (try self.sessionExists()) {
            try self.startAll(profile, writer);
            try self.attach();
            return;
        }
        const session_file = try self.writeSessionFile();
        _ = try self.run(&.{ "tmuxp", "load", "-d", session_file });
        _ = try self.run(&.{ "tmux", "set-option", "-t", try self.cfg.sessionName(), "prefix", "C-q" });
        _ = try self.run(&.{ "tmux", "set-option", "-t", try self.cfg.sessionName(), "status-format[0]", "#[align=left]#{T;=/#{status-left-length}:status-left}#[align=right]#{T;=/#{status-right-length}:status-right}" });
        _ = try self.run(&.{ "tmux", "set-option", "-t", try self.cfg.sessionName(), "@mux_dash_mode", "all" });
        _ = try self.run(&.{ "tmux", "bind-key", "-T", "prefix", "m", "run-shell", "mode=$(tmux show-option -qv @mux_dash_mode); if [ \"$mode\" = \"all\" ]; then tmux set-option @mux_dash_mode bad; else tmux set-option @mux_dash_mode all; fi" });
        _ = try self.run(&.{ "tmux", "bind-key", "-T", "prefix", "f", "run-shell", try std.fmt.allocPrint(self.gpa, "{s} --config {s} follow \"#{{window_name}}\"", .{ self.zask_path, self.config_path }) });
        try self.initLogDir();
        try self.setupPipePane();
        try self.startAll(profile, writer);
        try self.attach();
    }

    pub fn bye(self: Runtime, writer: *std.Io.Writer) !void {
        if (!try self.sessionExists()) {
            try writer.writeAll("Session not running\n");
            return;
        }
        try self.stopAll(writer);
        try self.cleanupPipePane();
        _ = try self.run(&.{ "tmux", "kill-session", "-t", try self.cfg.sessionName() });
    }

    pub fn kill(self: Runtime, writer: *std.Io.Writer) !void {
        try self.stopDocker();
        try self.cleanupPipePane();
        if (try self.sessionExists()) {
            _ = try self.run(&.{ "tmux", "kill-session", "-t", try self.cfg.sessionName() });
        } else {
            try writer.writeAll("Session not running\n");
        }
    }

    pub fn up(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        const t = target orelse "--all";
        if (std.mem.eql(u8, t, "--all")) return self.startAll("all", writer);
        if (std.mem.eql(u8, t, "docker")) return self.startDocker();
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.startService(svc, writer);
        } else |_| try self.startService(t, writer);
    }

    pub fn stop(self: Runtime, target: ?[]const u8, writer: *std.Io.Writer) !void {
        const t = target orelse "--all";
        if (std.mem.eql(u8, t, "--all")) return self.stopAll(writer);
        if (std.mem.eql(u8, t, "docker")) return self.stopDocker();
        if (self.cfg.resolveGroup(self.gpa, t)) |services| {
            for (services) |svc| try self.stopService(svc, writer);
        } else |_| try self.stopService(t, writer);
    }

    pub fn restart(self: Runtime, target: []const u8, writer: *std.Io.Writer) !void {
        if (std.mem.eql(u8, target, "docker")) {
            try self.stopDocker();
            try self.startDocker();
            return;
        }
        if (self.cfg.resolveGroup(self.gpa, target)) |services| {
            for (services) |svc| try self.restartService(svc, writer);
        } else |_| try self.restartService(target, writer);
    }

    pub fn exec(self: Runtime, container: []const u8, use_shell: bool, writer: *std.Io.Writer) !void {
        if (!self.cfg.dockerEnabled()) return error.DockerDisabled;
        const running = try self.run(&.{ "docker", "compose", "-f", self.cfg.dockerComposeFile(), "ps", "--status", "running", "--format", "{{.Service}}" });
        defer self.gpa.free(running.stdout);
        defer self.gpa.free(running.stderr);
        if (std.mem.indexOf(u8, running.stdout, container) == null) {
            try writer.print("Container '{s}' is not running\n", .{container});
            return error.ContainerNotRunning;
        }
        const exec_cmd = if (use_shell) "bash" else self.cfg.dockerExecDefault(container);
        var argv = std.array_list.Managed([]const u8).init(self.gpa);
        try argv.appendSlice(&.{ "docker", "compose", "-f", self.cfg.dockerComposeFile(), "exec", container });
        var parts = std.mem.tokenizeScalar(u8, exec_cmd, ' ');
        while (parts.next()) |part| try argv.append(part);
        _ = try self.runInteractiveCwd(argv.items, try self.cfg.dockerDir(self.gpa));
    }

    pub fn dashboard(self: Runtime, writer: *std.Io.Writer) !void {
        try dashboard_ui.runLauncher(self.gpa, self.io, self.cfg, writer);
    }

    pub fn monitorOnce(self: Runtime, writer: *std.Io.Writer) !void {
        try dashboard_ui.runMonitor(self.gpa, self.io, self.cfg, writer);
    }

    fn startAll(self: Runtime, profile: []const u8, writer: *std.Io.Writer) !void {
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
            const phase_type = optionalObjectString(phase, "type", "");
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

    fn stopAll(self: Runtime, writer: *std.Io.Writer) !void {
        const services = try self.cfg.services();
        var i = services.len;
        while (i > 0) {
            i -= 1;
            try self.stopService(try config.Config.serviceName(services[i]), writer);
        }
        try self.stopDocker();
    }

    fn startService(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        const value = try self.cfg.findService(service);
        const target = try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), service });
        const cmd = try std.fmt.allocPrint(self.gpa, "cd '{s}' && {s}", .{ try self.cfg.serviceDir(self.gpa, value), try self.cfg.serviceStartCommand(self.gpa, value) });
        try writer.print("Starting {s}...\n", .{service});
        _ = try self.run(&.{ "tmux", "send-keys", "-t", target, cmd, "Enter" });
    }

    fn stopService(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        try self.validateService(service);
        try writer.print("Stopping {s}...\n", .{service});
        _ = try self.run(&.{ "tmux", "send-keys", "-t", try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), service }), "C-c" });
    }

    fn restartService(self: Runtime, service: []const u8, writer: *std.Io.Writer) !void {
        try self.stopService(service, writer);
        try self.startService(service, writer);
    }

    fn startDocker(self: Runtime) !void {
        if (!self.cfg.dockerEnabled()) return;
        _ = try self.run(&.{ "tmux", "send-keys", "-t", try std.fmt.allocPrint(self.gpa, "{s}:docker", .{try self.cfg.sessionName()}), try std.fmt.allocPrint(self.gpa, "cd '{s}' && docker compose -f '{s}' up", .{ try self.cfg.dockerDir(self.gpa), self.cfg.dockerComposeFile() }), "Enter" });
    }

    fn stopDocker(self: Runtime) !void {
        if (!self.cfg.dockerEnabled()) return;
        if (try self.sessionExists()) _ = try self.run(&.{ "tmux", "send-keys", "-t", try std.fmt.allocPrint(self.gpa, "{s}:docker", .{try self.cfg.sessionName()}), "C-c" });
        _ = self.runCwd(&.{ "docker", "compose", "-f", self.cfg.dockerComposeFile(), "down" }, try self.cfg.dockerDir(self.gpa)) catch {};
    }

    fn runPrechecks(self: Runtime, writer: *std.Io.Writer) !void {
        const prechecks = self.cfg.value.object.get("prechecks") orelse return;
        if (prechecks != .array) return;
        for (prechecks.array.items) |check| {
            const name = optionalObjectString(check, "name", "precheck");
            const command = try requiredObjectString(check, "command");
            const on_fail = optionalObjectString(check, "on_fail", "warn");
            const dir = optionalObjectString(check, "dir", "");
            const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
            const result = self.runCwd(&.{ "bash", "-c", command }, cwd) catch {
                if (std.mem.eql(u8, on_fail, "abort")) return error.PrecheckFailed;
                try writer.print("Warning: {s} check failed\n", .{name});
                continue;
            };
            self.gpa.free(result.stdout);
            self.gpa.free(result.stderr);
        }
    }

    fn runCommandPhase(self: Runtime, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
        const command = try self.cfg.commandPhaseCommand(phase, profile);
        const dir = optionalObjectString(phase, "dir", "");
        const cwd = if (dir.len == 0) try self.cfg.projectRoot(self.gpa) else try std.fs.path.join(self.gpa, &.{ try self.cfg.projectRoot(self.gpa), dir });
        const result = self.runCwd(&.{ "bash", "-c", command }, cwd) catch {
            if (std.mem.eql(u8, optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
            try writer.writeAll("Warning: command phase failed\n");
            return;
        };
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }

    fn writeSessionFile(self: Runtime) ![]const u8 {
        const dir = try std.fs.path.join(self.gpa, &.{ try configBase(self.gpa), try self.cfg.projectName() });
        const mkdir_result = try self.run(&.{ "mkdir", "-p", dir });
        self.gpa.free(mkdir_result.stdout);
        self.gpa.free(mkdir_result.stderr);
        const path = try std.fs.path.join(self.gpa, &.{ dir, "session.yml" });
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try self.renderSession(&out.writer);
        try writeFile(self.io, path, out.writer.buffered());
        return path;
    }

    fn initLogDir(self: Runtime) !void {
        const dir = try self.logDir();
        const result = try self.run(&.{ "mkdir", "-p", dir });
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
        _ = try self.run(&.{ "tmux", "set-option", "-t", try self.cfg.sessionName(), "@mux_log_session_id", "current" });
    }

    fn setupPipePane(self: Runtime) !void {
        const dir = try self.logDir();
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            _ = self.run(&.{ "tmux", "pipe-pane", "-t", try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), name }), try std.fmt.allocPrint(self.gpa, "cat >> '{s}/{s}.log'", .{ dir, name }) }) catch {};
        }
    }

    fn cleanupPipePane(self: Runtime) !void {
        if (!try self.sessionExists()) return;
        for (try self.cfg.services()) |service| {
            const name = try config.Config.serviceName(service);
            _ = self.run(&.{ "tmux", "pipe-pane", "-t", try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), name }) }) catch {};
        }
    }

    fn waitForDocker(self: Runtime, writer: *std.Io.Writer) !void {
        try writer.writeAll("Waiting for Docker containers...\n");
        var attempt: i64 = 0;
        const max_attempts = self.cfg.dockerWaitTimeout();
        while (attempt < max_attempts) : (attempt += 1) {
            const result = self.runCwd(&.{ "docker", "compose", "-f", self.cfg.dockerComposeFile(), "ps", "--status", "running" }, try self.cfg.dockerDir(self.gpa)) catch {
                _ = self.run(&.{ "sleep", "1" }) catch {};
                continue;
            };
            defer self.gpa.free(result.stdout);
            defer self.gpa.free(result.stderr);

            if (result.term == .exited and result.term.exited == 0 and runningContainerCount(result.stdout) > 0) {
                try writer.writeAll("Docker containers ready\n");
                return;
            }
            _ = self.run(&.{ "sleep", "1" }) catch {};
        }
        return error.DockerNotReady;
    }

    fn waitForPort(self: Runtime, port: i64, timeout: i64) !void {
        var elapsed: i64 = 0;
        while (elapsed < timeout) : (elapsed += 2) {
            if ((self.run(&.{ "nc", "-z", "localhost", try std.fmt.allocPrint(self.gpa, "{d}", .{port}) }) catch null) != null) return;
            _ = self.run(&.{ "sleep", "2" }) catch {};
        }
    }

    fn sessionExists(self: Runtime) !bool {
        const result = self.run(&.{ "tmux", "has-session", "-t", try self.cfg.sessionName() }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.term == .exited and result.term.exited == 0;
    }

    fn serviceRunning(self: Runtime, service: []const u8) !bool {
        const result = self.run(&.{ "tmux", "list-panes", "-t", try std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ try self.cfg.sessionName(), service }), "-F", "#{pane_pid}" }) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.stdout.len > 0;
    }

    fn dockerRunning(self: Runtime) !bool {
        const result = self.runCwd(&.{ "docker", "compose", "-f", self.cfg.dockerComposeFile(), "ps", "--status", "running" }, try self.cfg.dockerDir(self.gpa)) catch return false;
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);
        return result.stdout.len > 0;
    }

    fn inTmux(self: Runtime) !bool {
        _ = self;
        return std.c.getenv("TMUX") != null;
    }

    fn validateService(self: Runtime, service: []const u8) !void {
        _ = try self.cfg.findService(service);
    }

    fn logDir(self: Runtime) ![]const u8 {
        return std.fs.path.join(self.gpa, &.{ try dataBase(self.gpa), try self.cfg.projectName(), "logs", "current" });
    }

    fn pathExists(self: Runtime, path: []const u8) !bool {
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    fn run(self: Runtime, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.gpa, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    }

    fn runCwd(self: Runtime, argv: []const []const u8, cwd: []const u8) !std.process.RunResult {
        return std.process.run(self.gpa, self.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    }

    fn runInteractive(self: Runtime, argv: []const []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.io, .{ .argv = argv });
        return child.wait(self.io);
    }

    fn runInteractiveCwd(self: Runtime, argv: []const []const u8, cwd: []const u8) !std.process.Child.Term {
        var child = try std.process.spawn(self.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
        return child.wait(self.io);
    }
};

fn requiredObjectString(node: std.json.Value, key: []const u8) ![]const u8 {
    if (node != .object) return error.InvalidConfig;
    const value = node.object.get(key) orelse return error.InvalidConfig;
    if (value != .string) return error.InvalidConfig;
    return value.string;
}

fn optionalObjectString(node: std.json.Value, key: []const u8, default: []const u8) []const u8 {
    if (node != .object) return default;
    const value = node.object.get(key) orelse return default;
    return if (value == .string) value.string else default;
}

fn runningContainerCount(output: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    if (count == 0) return 0;
    return count - 1;
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

pub fn configBase(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |value| return std.fs.path.join(gpa, &.{ std.mem.span(value), "zask" });
    return std.fs.path.join(gpa, &.{ home(), ".config", "zask" });
}

pub fn dataBase(gpa: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |value| return std.fs.path.join(gpa, &.{ std.mem.span(value), "zask" });
    return std.fs.path.join(gpa, &.{ home(), ".local", "share", "zask" });
}

pub fn home() []const u8 {
    if (std.c.getenv("HOME")) |value| return std.mem.span(value);
    return "";
}

test "counts running docker compose rows" {
    try std.testing.expectEqual(@as(usize, 0), runningContainerCount(""));
    try std.testing.expectEqual(@as(usize, 0), runningContainerCount("NAME SERVICE STATUS\n"));
    try std.testing.expectEqual(@as(usize, 2), runningContainerCount("NAME SERVICE STATUS\none api running\ntwo db running\n"));
}
