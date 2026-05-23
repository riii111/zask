const std = @import("std");

const config = @import("config.zig");
const config_value = @import("config_value.zig");
const waits = @import("waits.zig");

pub const PhaseKind = enum {
    docker,
    command,
    services,
};

pub fn phaseKind(phase: std.json.Value) PhaseKind {
    const value = config_value.optionalObjectString(phase, "type", "");
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "command")) return .command;
    return .services;
}

pub fn runPrechecks(ctx: anytype, writer: *std.Io.Writer) !void {
    for (ctx.cfg.prechecks()) |check| {
        const name = config_value.optionalObjectString(check, "name", "precheck");
        const command = try config_value.requiredObjectString(check, "command");
        const on_fail = config_value.optionalObjectString(check, "on_fail", "warn");
        const dir = config_value.optionalObjectString(check, "dir", "");
        const cwd = try phaseCwd(ctx, dir);
        const result = ctx.runner.runCheckedCwd(&.{ "bash", "-c", command }, cwd) catch {
            if (std.mem.eql(u8, on_fail, "abort")) return error.PrecheckFailed;
            try writer.print("Warning: {s} check failed\n", .{name});
            continue;
        };
        ctx.gpa.free(result.stdout);
        ctx.gpa.free(result.stderr);
    }
}

pub fn runCommandPhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
    const command = try config.Config.commandPhaseCommand(phase, profile);
    const dir = config_value.optionalObjectString(phase, "dir", "");
    const cwd = try phaseCwd(ctx, dir);
    _ = ctx.runner.runInteractiveCheckedCwd(&.{ "bash", "-c", command }, cwd) catch {
        if (std.mem.eql(u8, config_value.optionalObjectString(phase, "on_fail", "abort"), "abort")) return error.CommandPhaseFailed;
        try writer.writeAll("Warning: command phase failed\n");
        return;
    };
}

pub fn runServicePhase(ctx: anytype, phase: std.json.Value, profile: []const u8, writer: *std.Io.Writer) !void {
    if (phase.object.get("groups")) |groups| if (groups == .array) {
        for (groups.array.items) |group_value| {
            if (group_value != .string) continue;
            const group = ctx.cfg.resolvePhaseGroup(profile, group_value.string);
            for (try ctx.cfg.resolveGroup(ctx.gpa, group)) |svc| try ctx.startService(svc, writer);
        }
    };
    if (phase.object.get("wait_ports")) |ports| if (ports == .array) {
        for (ports.array.items) |port_value| if (port_value == .integer) try waits.waitForPort(ctx, port_value.integer, 120, writer);
    };
}

fn phaseCwd(ctx: anytype, dir: []const u8) ![]const u8 {
    if (dir.len == 0) return ctx.cfg.projectRoot(ctx.gpa);
    return std.fs.path.join(ctx.gpa, &.{ try ctx.cfg.projectRoot(ctx.gpa), dir });
}

test "classifies lifecycle phase kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\[
        \\  {"type":"docker"},
        \\  {"type":"command"},
        \\  {"groups":["api"]}
        \\]
    , .{});

    try std.testing.expectEqual(PhaseKind.docker, phaseKind(parsed.array.items[0]));
    try std.testing.expectEqual(PhaseKind.command, phaseKind(parsed.array.items[1]));
    try std.testing.expectEqual(PhaseKind.services, phaseKind(parsed.array.items[2]));
}
