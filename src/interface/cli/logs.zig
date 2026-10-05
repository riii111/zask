const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    service: []const u8,
    /// Set by `--tail <n>`: print the last n lines instead of focusing the window.
    tail: ?u32 = null,
    /// Set by `--saved`: read the saved log instead of the tmux pane.
    saved: bool = false,
    /// Set by `--path`: print where the saved log is kept, and nothing else.
    path: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var service: ?[]const u8 = null;
        var tail: ?u32 = null;
        var saved = false;
        var path = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--tail")) {
                if (tail != null) return error.InvalidArguments;
                index += 1;
                if (index == args.len) return error.InvalidArguments;
                tail = try parseLineCount(args[index]);
            } else if (std.mem.eql(u8, arg, "--saved")) {
                if (saved) return error.InvalidArguments;
                saved = true;
            } else if (std.mem.eql(u8, arg, "--path")) {
                if (path) return error.InvalidArguments;
                path = true;
            } else if (std.mem.startsWith(u8, arg, "-") or service != null) {
                return error.InvalidArguments;
            } else {
                service = arg;
            }
        }
        if (path and (saved or tail != null)) return error.InvalidArguments;
        return .{ .service = service orelse return error.InvalidArguments, .tail = tail, .saved = saved, .path = path };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    if (!opts.path and !opts.saved and opts.tail == null) return rt.logs(opts.service, ctx.writer);
    // Diagnostics go to stderr so stdout carries nothing but log lines or the path.
    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), rt.io, &stderr_buffer);
    const diag = &stderr_writer.interface;
    if (opts.path) return rt.logsPath(opts.service, ctx.writer, diag);
    if (opts.saved) return rt.logsSaved(opts.service, opts.tail, ctx.writer, diag);
    try rt.logsTail(opts.service, opts.tail.?, ctx.writer, diag);
}

fn parseLineCount(text: []const u8) !u32 {
    const count = std.fmt.parseUnsigned(u32, text, 10) catch return error.InvalidArguments;
    if (count == 0) return error.InvalidArguments;
    return count;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "logs.Options: parses service" {
    const opts = try Options.parse(&.{"api"});
    try std.testing.expectEqualStrings("api", opts.service);
    try std.testing.expectEqual(@as(?u32, null), opts.tail);
}

test "logs.Options: parses tail before or after service" {
    const cases = [_][]const []const u8{
        &.{ "api", "--tail", "100" },
        &.{ "--tail", "100", "api" },
    };

    for (cases) |args| {
        const opts = try Options.parse(args);

        try std.testing.expectEqualStrings("api", opts.service);
        try std.testing.expectEqual(@as(?u32, 100), opts.tail);
    }
}

test "logs.Options: parses saved log reads" {
    const cases = [_]struct {
        args: []const []const u8,
        tail: ?u32,
        saved: bool,
        path: bool,
    }{
        .{ .args = &.{ "api", "--saved" }, .tail = null, .saved = true, .path = false },
        .{ .args = &.{ "--saved", "api", "--tail", "5" }, .tail = 5, .saved = true, .path = false },
        .{ .args = &.{ "--path", "api" }, .tail = null, .saved = false, .path = true },
    };

    for (cases) |case| {
        const opts = try Options.parse(case.args);

        try std.testing.expectEqualStrings("api", opts.service);
        try std.testing.expectEqual(case.tail, opts.tail);
        try std.testing.expectEqual(case.saved, opts.saved);
        try std.testing.expectEqual(case.path, opts.path);
    }
}

test "logs.Options: rejects invalid arity" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "extra" }));
}

test "logs.Options: rejects invalid options" {
    const cases = [_][]const []const u8{
        &.{ "api", "--tail" },
        &.{ "--tail", "100" },
        &.{ "api", "--tail", "0" },
        &.{ "api", "--tail", "-5" },
        &.{ "api", "--tail", "ten" },
        &.{ "api", "--tail", "4294967296" },
        &.{ "api", "--tail", "1", "--tail", "2" },
        &.{ "api", "--follow" },
        &.{ "api", "--saved", "--saved" },
        &.{ "api", "--path", "--path" },
        &.{ "api", "--path", "--saved" },
        &.{ "api", "--path", "--tail", "5" },
        &.{ "--saved", "--tail", "5" },
    };

    for (cases) |args| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(args));
    }
}
