const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    target: []const u8,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 1) return error.InvalidArguments;
        return .{ .target = normalizeTarget(args[0]) };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.restart(opts.target, ctx.writer);
}

fn normalizeTarget(target: []const u8) []const u8 {
    if (std.mem.eql(u8, target, "--docker")) return "docker";
    return target;
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
