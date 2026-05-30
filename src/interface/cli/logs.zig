const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    service: []const u8,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .service = args[0] };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.logs(opts.service, ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "logs.Options: parses service" {
    const opts = try Options.parse(&.{"api"});
    try std.testing.expectEqualStrings("api", opts.service);
}

test "logs.Options: rejects invalid arity" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "extra" }));
}
