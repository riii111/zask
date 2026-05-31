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

pub fn waitForPort(ctx: anytype, port: i64, timeout: i64) !void {
    const port_text = try std.fmt.allocPrint(ctx.gpa, "{d}", .{port});
    defer ctx.gpa.free(port_text);
    var elapsed: i64 = 0;
    while (elapsed < timeout) : (elapsed += port_wait_interval_seconds) {
        if (ctx.runner.run(&.{ "nc", "-z", "localhost", port_text }, .{ .check = true, .discard = true })) |_| return else |_| {}
        ctx.runner.sleep(port_wait_interval);
    }
    return error.PortNotReady;
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
    try writeStopProgress(writer, service, 1);
    while (attempt < stop_attempts) : (attempt += 1) {
        const pane = ctx.tmux.observePane(service);
        defer pane.deinit(ctx.gpa);
        if (pane.state != .busy) {
            try writer.print("\r  {s} ... stopped\n", .{service});
            try writer.flush();
            return;
        }
        ctx.runner.sleep(stop_interval);
        try writeStopProgress(writer, service, (attempt % 3) + 1);
    }
    try writer.print("\r  {s} ... warning: may not have stopped completely\n", .{service});
    try writer.flush();
}

/// Polls every signaled service together, so the total wait is the slowest one,
/// not the sum. Callers broadcast C-c first, then hand the signaled set here.
pub fn waitForAllStopped(ctx: anytype, services: []const []const u8, writer: *std.Io.Writer) !void {
    if (services.len == 0) return;
    const stopped = try ctx.gpa.alloc(bool, services.len);
    defer ctx.gpa.free(stopped);
    @memset(stopped, false);

    var remaining = services.len;
    var attempt: usize = 0;
    while (attempt < stop_attempts) : (attempt += 1) {
        for (services, stopped) |service, *done| {
            if (done.*) continue;
            const pane = ctx.tmux.observePane(service);
            defer pane.deinit(ctx.gpa);
            if (pane.state != .busy) {
                done.* = true;
                remaining -= 1;
                try writeProgress(writer, "  {s} ... stopped\n", .{service});
            }
        }
        if (remaining == 0) return;
        ctx.runner.sleep(stop_interval);
    }
    for (services, stopped) |service, done| {
        if (!done) try writeProgress(writer, "  {s} ... warning: may not have stopped completely\n", .{service});
    }
}

pub fn waitForPaneIdle(ctx: anytype, window: []const u8) bool {
    var attempt: usize = 0;
    while (attempt < stop_attempts) : (attempt += 1) {
        const pane = ctx.tmux.observePane(window);
        defer pane.deinit(ctx.gpa);
        if (pane.state != .busy) return true;
        ctx.runner.sleep(stop_interval);
    }
    return false;
}

pub fn windowReadyAttempts() usize {
    return window_ready_attempts;
}

pub fn stopAttempts() usize {
    return stop_attempts;
}

fn writeProgress(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    try writer.print(fmt, args);
    try writer.flush();
}

fn writeStopProgress(writer: *std.Io.Writer, service: []const u8, dots: usize) !void {
    const text = switch (dots) {
        1 => ".  ",
        2 => ".. ",
        else => "...",
    };
    try writer.print("\r  {s} {s}", .{ service, text });
    try writer.flush();
}
