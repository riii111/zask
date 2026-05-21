const std = @import("std");
const build_options = @import("build_options");
const root = @import("root.zig");

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try runWithArgs(if (args.len > 1) args[1..] else &.{}, stdout);
    try stdout.flush();
}

pub fn runWithArgs(args: []const []const u8, writer: *std.Io.Writer) !void {
    if (args.len == 0) {
        return printGreeting(writer);
    }

    const command = args[0];
    if (std.mem.eql(u8, command, "version")) {
        return printVersion(writer);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        return printHelp(writer);
    }

    return error.UnknownCommand;
}

fn printGreeting(writer: *std.Io.Writer) !void {
    try writer.print("{s}\n", .{root.greeting()});
}

fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("zask {s}\n", .{build_options.version});
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zask <command>
        \\
        \\Commands:
        \\  version    Print zask version
        \\  help       Print this help
        \\
    );
}

test "version prints package version" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(&.{"version"}, &writer);
    try std.testing.expectEqualStrings("zask 0.0.0\n", writer.buffered());
}

test "help prints usage" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try runWithArgs(&.{"help"}, &writer);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Usage: zask <command>"));
}
