const std = @import("std");
const Context = @import("context.zig").Context;
const status_json = @import("status_json.zig");

pub const Options = struct {
    json: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len == 0) return .{};
        if (args.len == 1 and std.mem.eql(u8, args[0], "--json")) return .{ .json = true };
        return error.InvalidArguments;
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    if (opts.json) return runJson(ctx);
    const rt = try ctx.runtime();
    try rt.status(ctx.writer);
}

fn runJson(ctx: *Context) !void {
    // Set before loading the config so config failures are rendered as JSON too.
    ctx.useJsonOutput();
    const rt = try ctx.runtime();
    try status_json.writeStatus(ctx.writer, try status_json.collect(rt.cfg, rt.observer()));
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "status.Options: accepts --json" {
    try std.testing.expect(!(try Options.parse(&.{})).json);
    try std.testing.expect((try Options.parse(&.{"--json"})).json);
}

test "status.Options: rejects other arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "--json", "--json" }));
}
