const std = @import("std");
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
    const rt = try ctx.runtime();
    try rt.detach(ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options reject arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
