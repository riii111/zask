const std = @import("std");
const config = @import("../../model/config.zig");
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
    const services = try rt.cfg.services();
    try ctx.writer.print("{s}\n", .{try rt.cfg.projectName()});
    for (services) |service| {
        try ctx.writer.print("- {s}", .{try config.Config.serviceName(service)});
        const group = config.Config.serviceGroup(service);
        if (group.len != 0) try ctx.writer.print(" [{s}]", .{group});
        if (config.Config.servicePort(service)) |port| try ctx.writer.print(" :{d}", .{port});
        try ctx.writer.writeByte('\n');
    }
    if (rt.cfg.dockerEnabled()) try ctx.writer.writeAll("- docker\n");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "options reject arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
