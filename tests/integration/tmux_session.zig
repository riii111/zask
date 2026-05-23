const std = @import("std");
const build_options = @import("tmux_integration_options");

test "direct session construction keeps dashboard selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const session = try std.fmt.allocPrint(arena.allocator(), "zask-test-{d}", .{std.c.getpid()});

    try runDiscard(std.testing.allocator, io, &.{ build_options.tmux_path, "new-session", "-d", "-s", session, "-n", "dashboard", "-c", "/tmp", "sleep 60" });
    defer runDiscard(std.testing.allocator, io, &.{ build_options.tmux_path, "kill-session", "-t", session }) catch {};
    try runDiscard(std.testing.allocator, io, &.{ build_options.tmux_path, "new-window", "-d", "-t", session, "-n", "api", "-c", "/tmp", "sleep 60" });
    try runDiscard(std.testing.allocator, io, &.{ build_options.tmux_path, "select-window", "-t", try std.fmt.allocPrint(arena.allocator(), "{s}:dashboard", .{session}) });

    const result = try run(std.testing.allocator, io, &.{ build_options.tmux_path, "list-windows", "-t", session, "-F", "#{window_name}:#{window_active}" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "dashboard:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "api:0") != null);
}

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return error.CommandFailed;
    }
    return result;
}

fn runDiscard(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try run(gpa, io, argv);
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}
