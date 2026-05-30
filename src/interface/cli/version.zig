const std = @import("std");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;

pub const Options = struct {
    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 0) return error.InvalidArguments;
        return .{};
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    _ = opts;
    try ctx.writer.print("zask {s}\n", .{build_options.version});
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "version.Options: rejects arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
