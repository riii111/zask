const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    target: []const u8,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len != 1) return error.InvalidArguments;
        if (std.mem.startsWith(u8, args[0], "--") and !std.mem.eql(u8, args[0], "--all")) return error.InvalidArguments;
        return .{ .target = args[0] };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.stop(opts.target, ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "stop.Options: accepts required target" {
    try std.testing.expectEqualStrings("api", (try Options.parse(&.{"api"})).target);
    try std.testing.expectEqualStrings("docker", (try Options.parse(&.{"docker"})).target);
    try std.testing.expectEqualStrings("--all", (try Options.parse(&.{"--all"})).target);
}

test "stop.Options: rejects invalid target shape" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"--docker"}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "extra" }));
}
