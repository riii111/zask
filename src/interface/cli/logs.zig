const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    service: []const u8,
    /// Set by `--tail <n>`: print the last n lines instead of focusing the window.
    tail: ?u32 = null,

    pub fn parse(args: []const []const u8) !Options {
        var service: ?[]const u8 = null;
        var tail: ?u32 = null;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--tail")) {
                if (tail != null) return error.InvalidArguments;
                index += 1;
                if (index == args.len) return error.InvalidArguments;
                tail = try parseLineCount(args[index]);
            } else if (std.mem.startsWith(u8, arg, "-") or service != null) {
                return error.InvalidArguments;
            } else {
                service = arg;
            }
        }
        return .{ .service = service orelse return error.InvalidArguments, .tail = tail };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    const max_lines = opts.tail orelse return rt.logs(opts.service, ctx.writer);
    // Diagnostics go to stderr so stdout carries nothing but log lines.
    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), rt.io, &stderr_buffer);
    try rt.logsTail(opts.service, max_lines, ctx.writer, &stderr_writer.interface);
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

test "logs.Options: rejects invalid arity" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "extra" }));
}

test "logs.Options: rejects invalid tail" {
    const cases = [_][]const []const u8{
        &.{ "api", "--tail" },
        &.{ "--tail", "100" },
        &.{ "api", "--tail", "0" },
        &.{ "api", "--tail", "-5" },
        &.{ "api", "--tail", "ten" },
        &.{ "api", "--tail", "4294967296" },
        &.{ "api", "--tail", "1", "--tail", "2" },
        &.{ "api", "--follow" },
    };

    for (cases) |args| {
        try std.testing.expectError(error.InvalidArguments, Options.parse(args));
    }
}
