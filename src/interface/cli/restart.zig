const std = @import("std");
const Context = @import("context.zig").Context;
const target = @import("target.zig");

pub const Options = struct {
    target: []const u8,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .target = target.normalize(args[0]) };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.restart(opts.target, ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options parse required target" {
    try std.testing.expectEqualStrings("api", (try Options.parse(&.{"api"})).target);
    try std.testing.expectEqualStrings("docker", (try Options.parse(&.{"--docker"})).target);
}

test "options reject invalid arity" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "extra" }));
}
