const std = @import("std");
const Context = @import("context.zig").Context;

pub const Options = struct {
    fast: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var opts: Options = .{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--fast")) {
                opts.fast = true;
            } else return error.InvalidArguments;
        }
        return opts;
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    try rt.close(opts.fast, ctx.writer);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "close.Options: defaults to graceful stop" {
    try std.testing.expect(!(try Options.parse(&.{})).fast);
}

test "close.Options: accepts --fast" {
    try std.testing.expect((try Options.parse(&.{"--fast"})).fast);
}

test "close.Options: rejects unknown arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
