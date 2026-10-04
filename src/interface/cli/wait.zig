const std = @import("std");
const Context = @import("context.zig").Context;
const readiness_wait = @import("../../workflow/readiness_wait.zig");

pub const Options = struct {
    targets: []const []const u8,
    timeout_seconds: u32 = readiness_wait.default_timeout_seconds,

    /// `--timeout <seconds>` may come before or after the targets.
    pub fn parse(args: []const []const u8) !Options {
        var targets = args;
        var timeout_seconds: u32 = readiness_wait.default_timeout_seconds;
        if (targets.len >= 2 and std.mem.eql(u8, targets[0], "--timeout")) {
            timeout_seconds = try parseTimeout(targets[1]);
            targets = targets[2..];
        } else if (targets.len >= 2 and std.mem.eql(u8, targets[targets.len - 2], "--timeout")) {
            timeout_seconds = try parseTimeout(targets[targets.len - 1]);
            targets = targets[0 .. targets.len - 2];
        }
        if (targets.len == 0) return error.InvalidArguments;
        for (targets) |target| {
            if (std.mem.startsWith(u8, target, "-")) return error.InvalidArguments;
        }
        return .{ .targets = targets, .timeout_seconds = timeout_seconds };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try readiness_wait.waitReady(rt.cfg, rt.observer(), opts.targets, opts.timeout_seconds, ctx.writer);
}

fn parseTimeout(arg: []const u8) !u32 {
    // Zero is rejected: every check is cut off at the deadline, so no check
    // could ever finish.
    const seconds = std.fmt.parseUnsigned(u32, arg, 10) catch return error.InvalidArguments;
    if (seconds == 0) return error.InvalidArguments;
    return seconds;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "wait.Options: accepts targets with optional timeout" {
    const cases = [_]struct {
        args: []const []const u8,
        targets: []const []const u8,
        timeout_seconds: u32,
    }{
        .{ .args = &.{"api"}, .targets = &.{"api"}, .timeout_seconds = readiness_wait.default_timeout_seconds },
        .{ .args = &.{ "api", "backend" }, .targets = &.{ "api", "backend" }, .timeout_seconds = readiness_wait.default_timeout_seconds },
        .{ .args = &.{ "--timeout", "30", "api" }, .targets = &.{"api"}, .timeout_seconds = 30 },
        .{ .args = &.{ "api", "web", "--timeout", "1" }, .targets = &.{ "api", "web" }, .timeout_seconds = 1 },
    };

    for (cases) |case| {
        const opts = try Options.parse(case.args);
        try std.testing.expectEqual(case.timeout_seconds, opts.timeout_seconds);
        try std.testing.expectEqual(case.targets.len, opts.targets.len);
        for (case.targets, opts.targets) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    }
}

test "wait.Options: rejects missing targets and malformed timeout" {
    const cases = [_][]const []const u8{
        &.{},
        &.{ "--timeout", "30" },
        &.{"--timeout"},
        &.{ "api", "--timeout" },
        &.{ "api", "--timeout", "-1" },
        &.{ "api", "--timeout", "0" },
        &.{ "api", "--timeout", "soon" },
        &.{ "--timeout", "5", "api", "--timeout", "6" },
        &.{ "api", "--all" },
    };

    for (cases) |args| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(args));
    }
}
