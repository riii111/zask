const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    client_width: u16,
    client_height: u16,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 2) return error.InvalidArguments;
        return .{
            .client_width = try parseSize(args[0]),
            .client_height = try parseSize(args[1]),
        };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.syncWindowSizes(opts.client_width, opts.client_height);
}

fn parseSize(arg: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, arg, 10) catch return error.InvalidArguments;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options parse client dimensions" {
    const opts = try Options.parse(&.{ "120", "40" });
    try std.testing.expectEqual(@as(u16, 120), opts.client_width);
    try std.testing.expectEqual(@as(u16, 40), opts.client_height);
}

test "options reject invalid client dimensions" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"120"}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "wide", "40" }));
}
