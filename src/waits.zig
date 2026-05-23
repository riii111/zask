const std = @import("std");

const window_ready_attempts = 20;
const window_ready_interval = std.Io.Duration.fromMilliseconds(300);
const stop_attempts = 10;
const stop_interval = std.Io.Duration.fromMilliseconds(500);
pub const docker_ready_interval = std.Io.Duration.fromSeconds(1);
pub const docker_ready_settle = std.Io.Duration.fromSeconds(2);
const port_wait_interval_seconds = 2;
const port_wait_interval = std.Io.Duration.fromSeconds(port_wait_interval_seconds);

pub fn ensureDockerReady(ctx: anytype, writer: *std.Io.Writer) !void {
    try writer.writeAll("Waiting for Docker containers...\n");
    var attempt: i64 = 0;
    const max_attempts = ctx.cfg.dockerWaitTimeout();
    while (attempt < max_attempts) : (attempt += 1) {
        const compose = ctx.docker.observe();
        defer compose.deinit(ctx.gpa);
        if (compose.state == .running) {
            ctx.runner.sleep(docker_ready_settle);
            try writer.writeAll("Docker containers ready\n");
            return;
        }
        ctx.runner.sleep(docker_ready_interval);
    }
    return error.DockerNotReady;
}

pub fn waitForPort(ctx: anytype, port: i64, timeout: i64, writer: *std.Io.Writer) !void {
    const port_text = try std.fmt.allocPrint(ctx.gpa, "{d}", .{port});
    defer ctx.gpa.free(port_text);
    var elapsed: i64 = 0;
    while (elapsed < timeout) : (elapsed += port_wait_interval_seconds) {
        if (ctx.runner.runCheckedDiscard(&.{ "nc", "-z", "localhost", port_text })) |_| return else |_| {}
        ctx.runner.sleep(port_wait_interval);
    }
    try writeProgress(writer, "Warning: port {d} did not become ready within {d}s\n", .{ port, timeout });
}

pub fn ensureWindowReady(ctx: anytype, window: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < window_ready_attempts) : (attempt += 1) {
        switch (ctx.tmux.observeWindow(window)) {
            .present => return,
            .missing => {},
            .unavailable => return error.TmuxUnavailable,
        }
        ctx.runner.sleep(window_ready_interval);
    }
    return error.WindowNotReady;
}

pub fn waitForStopped(ctx: anytype, service: []const u8, writer: *std.Io.Writer) !void {
    var attempt: usize = 0;
    while (attempt < stop_attempts) : (attempt += 1) {
        const pane = ctx.tmux.observePane(service);
        defer pane.deinit(ctx.gpa);
        if (pane.state != .busy) return;
        ctx.runner.sleep(stop_interval);
    }
    try writeProgress(writer, "Warning: {s} may not have stopped completely\n", .{service});
}

pub fn windowReadyAttempts() usize {
    return window_ready_attempts;
}

fn writeProgress(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.flush();
}
