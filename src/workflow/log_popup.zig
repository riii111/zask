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
    /// less can take neither a lesskey source (582+) nor a file compiled by
    /// `lesskey`, so the popup could not close with Ctrl+G; it is not opened.
    pager_keys_unavailable,
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
    const keys_path = try std.fmt.allocPrint(gpa, "{s}.lesskey", .{path});
    defer gpa.free(keys_path);
    defer std.Io.Dir.cwd().deleteFile(io, keys_path) catch {};
    try paths.writeFileMode(io, keys_path, emacs_keys, paths.private_file_permissions);
    const compiled_path = try std.fmt.allocPrint(gpa, "{s}.less", .{path});
    defer gpa.free(compiled_path);
    defer std.Io.Dir.cwd().deleteFile(io, compiled_path) catch {};
    const keys = pagerKeys(tmux.runner, keys_path, compiled_path) orelse return .pager_keys_unavailable;

    const title = try std.fmt.allocPrint(gpa, " {s}: last {d} lines ", .{ request.label, max_lines });
    defer gpa.free(title);
    const command = try pagerCommand(gpa, path, keys);
    defer gpa.free(command);
    tmux.displayPopup(client_name, title, command) catch |err| switch (err) {
        error.PopupUnavailable => return .popup_unavailable,
        error.TmuxUnavailable => return .tmux_unavailable,
        else => return err,
    };
    return .shown;
}

/// Emacs moves for the popup, in lesskey source form. less binds all but
/// Ctrl+G this way already; listing them keeps them when the user's own
/// lesskey rebinds them. Ctrl+G closes the popup, as it closes the window list.
const emacs_keys =
    \\#command
    \\^N forw-line
    \\^P back-line
    \\^V forw-screen
    \\\ev back-screen
    \\\e< goto-line
    \\\e> goto-end
    \\^G quit
    \\
;

/// How less gets `emacs_keys`; both paths borrow from the caller.
const PagerKeys = union(enum) {
    /// less 582+ reads the source with `--lesskey-src`.
    source: []const u8,
    /// Older less reads a file compiled by `lesskey` with `-k`.
    compiled: []const u8,
};

/// Asks the local less which form it takes, compiling the keys to
/// `compiled_path` for an older less. Null when neither works. The popup runs
/// the same less, found the same way, on this machine.
fn pagerKeys(runner: proc_runner.Runner, keys_path: []const u8, compiled_path: []const u8) ?PagerKeys {
    var option_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const option = std.fmt.bufPrint(&option_buffer, "--lesskey-src={s}", .{keys_path}) catch return null;
    if (succeeds(runner, &.{ "less", option, "-V" })) return .{ .source = keys_path };
    if (succeeds(runner, &.{ "lesskey", "-o", compiled_path, keys_path })) return .{ .compiled = compiled_path };
    return null;
}

fn succeeds(runner: proc_runner.Runner, argv: []const []const u8) bool {
    const result = proc_runner.captured(runner.run(argv, .{}) catch return false);
    defer runner.gpa.free(result.stdout);
    defer runner.gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

/// Caller owns the returned shell command. Starts at the end of the log and
/// cancels LESS options that would quit at the end of the text (-E / -F) and
/// so close the popup before it is read. The keys apply to this run only,
/// never to the user's lesskey.
fn pagerCommand(gpa: std.mem.Allocator, path: []const u8, keys: PagerKeys) ![]const u8 {
    const quoted = try shell.quote(gpa, path);
    defer gpa.free(quoted);
    return switch (keys) {
        .source => |source| {
            const quoted_keys = try shell.quote(gpa, source);
            defer gpa.free(quoted_keys);
            return std.fmt.allocPrint(gpa, "exec less --lesskey-src={s} -+E -+F +G -- {s}", .{ quoted_keys, quoted });
        },
        .compiled => |compiled| {
            const quoted_keys = try shell.quote(gpa, compiled);
            defer gpa.free(quoted_keys);
            return std.fmt.allocPrint(gpa, "exec less -k {s} -+E -+F +G -- {s}", .{ quoted_keys, quoted });
        },
    };
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
    try setup.recorder.enqueue("less 668\n", "", .{ .exited = 0 });
    try setup.recorder.enqueue("", "", .{ .exited = 0 });

    const outcome = try setup.showApi("%3");

    try std.testing.expectEqual(Outcome.shown, outcome);
    const popup = setup.recorder.commands.items[3];
    try proc_runner.expectCommandArgvStartsWith(popup, &.{ "tmux", "display-popup", "-c", "/dev/pts/1", "-EE" });
    try proc_runner.expectCommandArgContains(popup, 10, "api: last 200 lines");
    try proc_runner.expectCommandArgContains(popup, 11, "exec less --lesskey-src=");
    try proc_runner.expectCommandArgContains(popup, 11, " -+E -+F +G -- ");
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
        /// Whether less takes the keys, once the popup gets that far.
        less_keys: bool = true,
        expected: Outcome,
    }{
        .{ .name = "outside tmux", .pane = null, .expected = .outside_tmux },
        .{ .name = "window missing", .capture_stdout = "", .capture_stderr = "can't find window: api", .capture_status = 1, .expected = .window_missing },
        .{ .name = "tmux unavailable", .capture_stdout = "", .capture_stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .capture_status = 1, .expected = .tmux_unavailable },
        .{ .name = "empty pane", .capture_stdout = "0\n\n\n", .expected = .empty },
        .{ .name = "no client on the pane", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%7|/dev/pts/1\n", .expected = .no_client },
        .{ .name = "popup refused", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .popup_stderr = "unknown command: display-popup", .expected = .popup_unavailable },
        .{ .name = "less without Ctrl+G", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .less_keys = false, .expected = .pager_keys_unavailable },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var setup: TestSetup = undefined;
        try setup.init();
        defer setup.deinit();
        if (case.capture_stdout) |stdout| try setup.recorder.enqueue(stdout, case.capture_stderr, .{ .exited = case.capture_status });
        if (case.clients_stdout) |stdout| try setup.recorder.enqueue(stdout, "", .{ .exited = 0 });
        if (case.popup_stderr != null or !case.less_keys) {
            if (case.less_keys) {
                try setup.recorder.enqueue("less 668\n", "", .{ .exited = 0 });
            } else {
                try setup.recorder.enqueue("", "There is no lesskey-src option", .{ .exited = 1 });
                try setup.recorder.enqueueError(error.FileNotFound);
            }
        }
        if (case.popup_stderr) |stderr| try setup.recorder.enqueue("", stderr, .{ .exited = 1 });

        const outcome = try setup.showApi(case.pane);

        try std.testing.expectEqual(case.expected, outcome);
        if (case.popup_stderr == null) try std.testing.expect(proc_runner.findCommandContaining(&setup.recorder, "display-popup") == null);
        try std.testing.expectEqual(@as(usize, 0), try setup.scratchFiles());
        try proc_runner.expectNoRemainingResponses(&setup.recorder);
    }
}

test "log_popup.pagerCommand: quotes the captured file and key paths" {
    const cases = [_]struct { keys: PagerKeys, expected: []const u8 }{
        .{ .keys = .{ .source = "/tmp/zask dir/k's.lesskey" }, .expected = "exec less --lesskey-src='/tmp/zask dir/k'\\''s.lesskey' -+E -+F +G -- '/tmp/zask dir/demo'\\''s.txt'" },
        .{ .keys = .{ .compiled = "/tmp/zask dir/k's.less" }, .expected = "exec less -k '/tmp/zask dir/k'\\''s.less' -+E -+F +G -- '/tmp/zask dir/demo'\\''s.txt'" },
    };
    for (cases) |case| {
        const command = try pagerCommand(std.testing.allocator, "/tmp/zask dir/demo's.txt", case.keys);
        defer std.testing.allocator.free(command);

        try std.testing.expectEqualStrings(case.expected, command);
    }
}

test "log_popup.pagerKeys: compiles the keys for a less without lesskey sources" {
    var recorder = proc_runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "There is no lesskey-src option", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const keys = pagerKeys(runner, "/tmp/k.lesskey", "/tmp/k.less");

    try std.testing.expectEqualDeep(@as(?PagerKeys, .{ .compiled = "/tmp/k.less" }), keys);
    try proc_runner.expectCommandArgv(recorder.commands.items[0], &.{ "less", "--lesskey-src=/tmp/k.lesskey", "-V" });
    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "lesskey", "-o", "/tmp/k.less", "/tmp/k.lesskey" });
}
