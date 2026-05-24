const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    container: []const u8,
    use_shell: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len == 0 or args.len > 2) return error.InvalidArguments;
        if (args.len == 2 and !std.mem.eql(u8, args[1], "--shell")) return error.InvalidArguments;
        return .{ .container = args[0], .use_shell = args.len == 2 };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.exec(opts.container, opts.use_shell, ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options parse shell flag after container" {
    const plain = try Options.parse(&.{"api"});
    try std.testing.expectEqualStrings("api", plain.container);
    try std.testing.expect(!plain.use_shell);

    const shell = try Options.parse(&.{ "api", "--shell" });
    try std.testing.expectEqualStrings("api", shell.container);
    try std.testing.expect(shell.use_shell);
}

test "options reject invalid shell flag position" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "foo" }));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "api", "--shell", "extra" }));
}
