const std = @import("std");
const config = @import("../../model/config.zig");
const Context = @import("context.zig").Context;
const open_progress = @import("open_progress.zig");

pub const Options = struct {
    profile_arg: ?[]const u8 = null,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len > 1) return error.InvalidArguments;
        return .{ .profile_arg = if (args.len == 0) null else args[0] };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const rt = try ctx.runtime();
    var progress = open_progress.Progress.init(ctx.base.gpa, rt.io, ctx.base.environ, ctx.writer);
    rt.openWithProgress(try resolveProfile(rt.cfg, opts), &progress) catch |err| {
        try progress.finishError();
        return err;
    };
    try progress.finishSuccess();
}

fn resolveProfile(cfg: config.Config, opts: Options) ![]const u8 {
    const profile_arg = opts.profile_arg orelse return "all";
    if (std.mem.eql(u8, profile_arg, "--docker")) return "docker";
    return cfg.resolveStartProfileOption(profile_arg) orelse error.InvalidArguments;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "open.Options: accepts optional profile" {
    try std.testing.expect((try Options.parse(&.{})).profile_arg == null);
    try std.testing.expectEqualStrings("--docker", (try Options.parse(&.{"--docker"})).profile_arg.?);
}

test "open.Options: rejects extra arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "--docker", "extra" }));
}

test "open.Options: resolves profile aliases" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "start_profiles": {"api": {"profile": "backend"}}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");

    try std.testing.expectEqualStrings("all", try resolveProfile(cfg, try Options.parse(&.{})));
    try std.testing.expectEqualStrings("docker", try resolveProfile(cfg, try Options.parse(&.{"--docker"})));
    try std.testing.expectEqualStrings("backend", try resolveProfile(cfg, try Options.parse(&.{"--api"})));
    try std.testing.expectError(error.InvalidArguments, resolveProfile(cfg, try Options.parse(&.{"--missing"})));
}
