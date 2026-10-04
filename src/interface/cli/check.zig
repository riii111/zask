const std = @import("std");
const config_check = @import("../../workflow/config_check.zig");
const diagnostics = @import("../../model/diagnostics.zig");
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
    var local_diags = diagnostics.Diagnostics.init(ctx.base.gpa);
    defer local_diags.deinit();
    const diags = ctx.base.diagnostics orelse &local_diags;

    const rt = ctx.runtime() catch |err| switch (err) {
        error.InvalidConfig => {
            const config_path = if (ctx.base.error_context) |err_ctx| err_ctx.config_path else null;
            try writeProblems(ctx.writer, config_path, diags.*);
            // Path checks need a normalized config, which only exists once validation passes.
            try ctx.writer.writeAll("Path checks were skipped; fix the problems above and run check again.\n");
            return error.CheckFailed;
        },
        else => return err,
    };

    try config_check.collectPathProblems(ctx.base.gpa, rt.io, rt.cfg, diags);
    if (!diags.isEmpty()) {
        try writeProblems(ctx.writer, rt.config_path, diags.*);
        return error.CheckFailed;
    }
    try ctx.writer.print("Config OK: {s}\n", .{rt.config_path});
}

fn writeProblems(writer: *std.Io.Writer, config_path: ?[]const u8, diags: diagnostics.Diagnostics) !void {
    const count = diags.slice().len;
    try writer.print("Error: {d} config problem{s}\n", .{ count, if (count == 1) "" else "s" });
    if (config_path) |path| try writer.print("Config: {s}\n", .{path});
    for (diags.slice()) |diagnostic| {
        if (diagnostic.path.len == 0) {
            try writer.print("  {s}\n", .{diagnostic.message});
        } else {
            try writer.print("  {s}: {s}\n", .{ diagnostic.path, diagnostic.message });
        }
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "check.Options: rejects arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
}
