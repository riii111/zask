const std = @import("std");
const command_progress = @import("command_progress.zig");
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
    var progress = command_progress.Progress.init(ctx.base.gpa, rt.io, ctx.base.environ, ctx.writer);
    rt.reWithProgress(&progress) catch |err| {
        try progress.finishError();
        return err;
    };
    try progress.finishSuccess();
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "re.Options: rejects arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
