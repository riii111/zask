const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    pane_id: []const u8,
    client_width: u16,
    client_height: u16,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 3) return error.InvalidArguments;
        return .{
            .pane_id = args[0],
            .client_width = try parseSize(args[1]),
            .client_height = try parseSize(args[2]),
        };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.previewList(opts.pane_id, opts.client_width, opts.client_height);
}

fn parseSize(arg: []const u8) !u16 {
    return std.fmt.parseUnsigned(u16, arg, 10) catch return error.InvalidArguments;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options parse preview dimensions" {
    const opts = try Options.parse(&.{ "%1", "120", "40" });
    try std.testing.expectEqualStrings("%1", opts.pane_id);
    try std.testing.expectEqual(@as(u16, 120), opts.client_width);
    try std.testing.expectEqual(@as(u16, 40), opts.client_height);
}

test "options reject invalid preview dimensions" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "%1", "120" }));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "%1", "wide", "40" }));
}
