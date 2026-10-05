const std = @import("std");
const config_check = @import("../../workflow/config_check.zig");
const diagnostics = @import("../../model/diagnostics.zig");
const env = @import("../../platform/env.zig");
const environment_check = @import("../../workflow/environment_check.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    run_prechecks: bool = false,

    pub fn parse(args: []const []const u8) !Options {
        var opts: Options = .{};
        for (args) |arg| {
            if (!std.mem.eql(u8, arg, "--prechecks") or opts.run_prechecks) return error.InvalidArguments;
            opts.run_prechecks = true;
        }
        return opts;
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    var local_diags = diagnostics.Diagnostics.init(ctx.base.gpa);
    defer local_diags.deinit();
    const diags = ctx.base.diagnostics orelse &local_diags;

    const rt = ctx.runtime() catch |err| switch (err) {
        error.InvalidConfig => {
            const config_path = if (ctx.base.error_context) |err_ctx| err_ctx.config_path else null;
            try writeProblems(ctx.writer, config_path, diags.*);
            try ctx.writer.writeAll("Path and environment checks were skipped; fix the problems above and run check again.\n");
            return error.CheckFailed;
        },
        else => return err,
    };

    try config_check.collectPathProblems(ctx.base.gpa, rt.io, rt.cfg, diags);
    if (diags.isEmpty()) {
        try ctx.writer.print("Config OK: {s}\n", .{rt.config_path});
    } else {
        try writeProblems(ctx.writer, rt.config_path, diags.*);
    }

    var report = environment_check.Report.init(ctx.base.gpa);
    defer report.deinit();
    try environment_check.collect(.{
        .gpa = ctx.base.gpa,
        .io = rt.io,
        .cfg = rt.cfg,
        .runner = rt.runner_impl,
        .tmux = rt.tmux_impl,
        .docker = rt.docker_impl,
        .search_path = env.get(rt.environ, "PATH"),
    }, .{ .run_prechecks = opts.run_prechecks }, &report);
    try writeReport(ctx.writer, report);

    if (!diags.isEmpty()) return error.CheckFailed;
    if (report.count(.problem) > 0) return error.EnvironmentCheckFailed;
}

fn writeProblems(writer: *std.Io.Writer, config_path: ?[]const u8, diags: diagnostics.Diagnostics) !void {
    const count = diags.slice().len;
    try writer.print("Error: {d} config problem{s}\n", .{ count, plural(count) });
    if (config_path) |path| try writer.print("Config: {s}\n", .{path});
    for (diags.slice()) |diagnostic| {
        if (diagnostic.path.len == 0) {
            try writer.print("  {s}\n", .{diagnostic.message});
        } else {
            try writer.print("  {s}: {s}\n", .{ diagnostic.path, diagnostic.message });
        }
    }
}

fn writeReport(writer: *std.Io.Writer, report: environment_check.Report) !void {
    if (report.findings.items.len == 0) try writer.writeAll("Environment OK\n");
    try writeFindings(writer, report, .problem, "Error", "environment problem");
    try writeFindings(writer, report, .warning, "Warning", "environment warning");
    try writeFindings(writer, report, .unverified, "Not verified", "item");
    try writePrechecks(writer, report);
}

fn writeFindings(writer: *std.Io.Writer, report: environment_check.Report, severity: environment_check.Severity, label: []const u8, noun: []const u8) !void {
    var count: usize = 0;
    for (report.findings.items) |finding| {
        if (finding.severity == severity) count += 1;
    }
    if (count == 0) return;
    try writer.print("{s}: {d} {s}{s}\n", .{ label, count, noun, plural(count) });
    for (report.findings.items) |finding| {
        if (finding.severity != severity) continue;
        try writer.print("  {s}: {s}\n", .{ finding.subject, finding.message });
        if (finding.fix.len > 0) try writer.print("    Fix: {s}\n", .{finding.fix});
    }
}

fn writePrechecks(writer: *std.Io.Writer, report: environment_check.Report) !void {
    if (report.skipped_prechecks > 0) {
        try writer.print("Prechecks: {d} not run; add --prechecks to run them\n", .{report.skipped_prechecks});
        return;
    }
    if (report.prechecks.items.len == 0) return;
    try writer.writeAll("Prechecks:\n");
    for (report.prechecks.items) |result| {
        try writer.print("  {s}: {s}", .{ result.name, precheckStatusText(result.status) });
        if (result.status != .passed) try writer.print(" ({s})", .{severityText(result.severity)});
        try writer.writeByte('\n');
        if (result.status == .passed) continue;
        try writer.print("    command: {s}\n", .{result.command});
        if (result.detail.len > 0) try writer.print("    {s}\n", .{result.detail});
        if (result.hint.len > 0) try writer.print("    Hint: {s}\n", .{result.hint});
    }
}

fn precheckStatusText(status: environment_check.PrecheckStatus) []const u8 {
    return switch (status) {
        .passed => "passed",
        .failed => "failed",
        .timed_out => "timed out",
        .output_too_large => "failed",
        .not_run => "not run",
    };
}

fn severityText(severity: environment_check.Severity) []const u8 {
    return switch (severity) {
        .problem => "error",
        .warning => "warning",
        .unverified => "not verified",
    };
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "check.Options: accepts --prechecks once" {
    try std.testing.expect(!(try Options.parse(&.{})).run_prechecks);
    try std.testing.expect((try Options.parse(&.{"--prechecks"})).run_prechecks);
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"extra"}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "--prechecks", "--prechecks" }));
}

test "check.writeReport: lists findings by severity and failed prechecks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report = environment_check.Report.init(arena.allocator());
    try report.findings.append(arena.allocator(), .{ .severity = .unverified, .subject = "groups[be].services[web].command", .message = "compound shell command; not checked" });
    try report.findings.append(arena.allocator(), .{ .severity = .problem, .subject = "tmux", .message = "not found in PATH", .fix = "install tmux" });
    try report.prechecks.append(arena.allocator(), .{ .name = "node", .command = "node -v", .status = .passed, .severity = .problem });
    try report.prechecks.append(arena.allocator(), .{ .name = "db", .command = "pg_isready", .status = .failed, .severity = .warning, .detail = "exit code 2: no response", .hint = "start db" });
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeReport(&writer, report);

    try std.testing.expectEqualStrings(
        \\Error: 1 environment problem
        \\  tmux: not found in PATH
        \\    Fix: install tmux
        \\Not verified: 1 item
        \\  groups[be].services[web].command: compound shell command; not checked
        \\Prechecks:
        \\  node: passed
        \\  db: failed (warning)
        \\    command: pg_isready
        \\    exit code 2: no response
        \\    Hint: start db
        \\
    , writer.buffered());
}
