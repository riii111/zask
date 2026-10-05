const std = @import("std");
const paths = @import("../platform/paths.zig");
const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const tmux_client = @import("../platform/tmux.zig");

/// Enough history to scroll back past a typical stack trace.
pub const max_lines = 200;

pub const Outcome = enum {
    /// The popup was shown and has been closed.
    shown,
    /// The window exists but has printed nothing yet.
    empty,
    /// The caller does not run in a tmux pane, so no client is showing it.
    outside_tmux,
    /// No attached client currently shows the caller's pane.
    no_client,
    window_missing,
    tmux_unavailable,
    /// tmux refused the popup, e.g. tmux older than 3.3.
    popup_unavailable,
};

pub const Request = struct {
    /// tmux window to capture.
    window: []const u8,
    /// Shown in the popup title.
    label: []const u8,
    /// The caller's own pane (`$TMUX_PANE`); the popup opens on the client
    /// showing it. Null outside tmux.
    pane: ?[]const u8,
    /// Absolute directory for the captured text; created private when missing.
    scratch_dir: []const u8,
};

/// Captures the window's recent lines once and pages them in a popup, blocking
/// until the popup closes. The text is a snapshot: output written while the
/// popup is open, or after the service exits, is not added. The captured file
/// is removed before returning, including when the popup is refused.
pub fn show(gpa: std.mem.Allocator, io: std.Io, tmux: tmux_client.Client, request: Request) !Outcome {
    const pane = request.pane orelse return .outside_tmux;
    const lines = tmux.captureRecentLines(request.window, max_lines) catch |err| switch (err) {
        error.WindowMissing => return .window_missing,
        error.TmuxUnavailable => return .tmux_unavailable,
        else => return err,
    };
    defer gpa.free(lines);
    if (lines.len == 0) return .empty;
    const client_name = tmux.clientShowingPane(pane) catch |err| switch (err) {
        error.TmuxUnavailable => return .tmux_unavailable,
        else => return err,
    } orelse return .no_client;
    defer gpa.free(client_name);

    try paths.ensurePrivateDir(io, request.scratch_dir);
    const name = try std.fmt.allocPrint(gpa, "{s}-logs-{d}.txt", .{ tmux.session, std.c.getpid() });
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ request.scratch_dir, name });
    defer gpa.free(path);
    // Registered before writing so a partly written file is removed too.
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try paths.writeFileMode(io, path, lines, paths.private_file_permissions);

    const title = try std.fmt.allocPrint(gpa, " {s}: last {d} lines ", .{ request.label, max_lines });
    defer gpa.free(title);
    const command = try pagerCommand(gpa, path);
    defer gpa.free(command);
    tmux.displayPopup(client_name, title, command) catch |err| switch (err) {
        error.PopupUnavailable => return .popup_unavailable,
        error.TmuxUnavailable => return .tmux_unavailable,
        else => return err,
    };
    return .shown;
}

/// Caller owns the returned shell command. Starts at the end of the log and
/// cancels LESS options that would quit at the end of the text (-E / -F) and
/// so close the popup before it is read.
fn pagerCommand(gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const quoted = try shell.quote(gpa, path);
    defer gpa.free(quoted);
    return std.fmt.allocPrint(gpa, "exec less -+E -+F +G -- {s}", .{quoted});
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestSetup = struct {
    arena: std.heap.ArenaAllocator,
    recorder: proc_runner.Recorder,
    tmp: std.testing.TmpDir,
    scratch_dir: []const u8,

    fn init(setup: *TestSetup) !void {
        setup.arena = .init(std.testing.allocator);
        setup.recorder = proc_runner.Recorder.init(setup.arena.allocator());
        setup.tmp = std.testing.tmpDir(.{});
        const root = try setup.tmp.dir.realPathFileAlloc(std.testing.io, ".", setup.arena.allocator());
        setup.scratch_dir = try std.fs.path.join(setup.arena.allocator(), &.{ root, "zask" });
    }

    fn deinit(setup: *TestSetup) void {
        setup.tmp.cleanup();
        setup.recorder.deinit();
        setup.arena.deinit();
    }

    fn client(setup: *TestSetup) tmux_client.Client {
        const runner: proc_runner.Runner = .{ .gpa = setup.arena.allocator(), .io = undefined, .recorder = &setup.recorder };
        return .{ .gpa = setup.arena.allocator(), .runner = runner, .session = "demo" };
    }

    fn showApi(setup: *TestSetup, pane: ?[]const u8) !Outcome {
        return show(setup.arena.allocator(), std.testing.io, setup.client(), .{ .window = "api", .label = "api", .pane = pane, .scratch_dir = setup.scratch_dir });
    }

    fn scratchFiles(setup: *TestSetup) !usize {
        var dir = std.Io.Dir.openDirAbsolute(std.testing.io, setup.scratch_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(std.testing.io);
        var count: usize = 0;
        var entries = dir.iterate();
        while (try entries.next(std.testing.io)) |_| count += 1;
        return count;
    }
};

test "log_popup.show: pages the captured lines on the client showing the pane" {
    var setup: TestSetup = undefined;
    try setup.init();
    defer setup.deinit();
    try setup.recorder.enqueue("0\nbooting\npanic: boom\n", "", .{ .exited = 0 });
    try setup.recorder.enqueue("100|%3|/dev/pts/1\n", "", .{ .exited = 0 });
    try setup.recorder.enqueue("", "", .{ .exited = 0 });

    const outcome = try setup.showApi("%3");

    try std.testing.expectEqual(Outcome.shown, outcome);
    const popup = setup.recorder.commands.items[2];
    try proc_runner.expectCommandArgvStartsWith(popup, &.{ "tmux", "display-popup", "-c", "/dev/pts/1", "-EE" });
    try proc_runner.expectCommandArgContains(popup, 10, "api: last 200 lines");
    try proc_runner.expectCommandArgContains(popup, 11, "exec less -+E -+F +G -- ");
    try proc_runner.expectCommandArgContains(popup, 11, setup.scratch_dir);
    try std.testing.expectEqual(@as(usize, 0), try setup.scratchFiles());
    try proc_runner.expectNoRemainingResponses(&setup.recorder);
}

test "log_popup.show: reports why no popup was shown" {
    const cases = [_]struct {
        name: []const u8,
        pane: ?[]const u8 = "%3",
        capture_stdout: ?[]const u8 = null,
        capture_stderr: []const u8 = "",
        capture_status: u8 = 0,
        clients_stdout: ?[]const u8 = null,
        popup_stderr: ?[]const u8 = null,
        expected: Outcome,
    }{
        .{ .name = "outside tmux", .pane = null, .expected = .outside_tmux },
        .{ .name = "window missing", .capture_stdout = "", .capture_stderr = "can't find window: api", .capture_status = 1, .expected = .window_missing },
        .{ .name = "tmux unavailable", .capture_stdout = "", .capture_stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .capture_status = 1, .expected = .tmux_unavailable },
        .{ .name = "empty pane", .capture_stdout = "0\n\n\n", .expected = .empty },
        .{ .name = "no client on the pane", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%7|/dev/pts/1\n", .expected = .no_client },
        .{ .name = "popup refused", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .popup_stderr = "unknown command: display-popup", .expected = .popup_unavailable },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var setup: TestSetup = undefined;
        try setup.init();
        defer setup.deinit();
        if (case.capture_stdout) |stdout| try setup.recorder.enqueue(stdout, case.capture_stderr, .{ .exited = case.capture_status });
        if (case.clients_stdout) |stdout| try setup.recorder.enqueue(stdout, "", .{ .exited = 0 });
        if (case.popup_stderr) |stderr| try setup.recorder.enqueue("", stderr, .{ .exited = 1 });

        const outcome = try setup.showApi(case.pane);

        try std.testing.expectEqual(case.expected, outcome);
        if (case.popup_stderr == null) try std.testing.expect(proc_runner.findCommandContaining(&setup.recorder, "display-popup") == null);
        try std.testing.expectEqual(@as(usize, 0), try setup.scratchFiles());
        try proc_runner.expectNoRemainingResponses(&setup.recorder);
    }
}

test "log_popup.pagerCommand: quotes the captured file path" {
    const command = try pagerCommand(std.testing.allocator, "/tmp/zask dir/demo's.txt");
    defer std.testing.allocator.free(command);

    try std.testing.expectEqualStrings("exec less -+E -+F +G -- '/tmp/zask dir/demo'\\''s.txt'", command);
}
