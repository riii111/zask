const std = @import("std");
const executable = @import("../platform/executable.zig");
const paths = @import("../platform/paths.zig");
const proc_runner = @import("../platform/runner.zig");
const shell = @import("../platform/shell.zig");
const tmux_client = @import("../platform/tmux.zig");

pub const max_lines = 200;

pub const Outcome = enum {
    shown,
    empty,
    outside_tmux,
    no_client,
    window_missing,
    tmux_unavailable,
    popup_unavailable,
    pager_unavailable,
};

pub const Request = struct {
    window: []const u8,
    label: []const u8,
    pane: ?[]const u8,
    scratch_dir: []const u8,
    search_path: ?[]const u8,
};

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
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try paths.writeFileMode(io, path, lines, paths.private_file_permissions);
    const keys_path = try std.fmt.allocPrint(gpa, "{s}.lesskey", .{path});
    defer gpa.free(keys_path);
    defer std.Io.Dir.cwd().deleteFile(io, keys_path) catch {};
    try paths.writeFileMode(io, keys_path, emacs_keys, paths.private_file_permissions);
    const compiled_path = try std.fmt.allocPrint(gpa, "{s}.less", .{path});
    defer gpa.free(compiled_path);
    defer std.Io.Dir.cwd().deleteFile(io, compiled_path) catch {};
    const pager = try findPager(gpa, io, request.search_path) orelse return .pager_unavailable;
    defer pager.deinit(gpa);
    const keys = pagerKeys(tmux.runner, pager, keys_path, compiled_path) orelse return .pager_unavailable;

    const title = try std.fmt.allocPrint(gpa, " {s}: last {d} lines ", .{ request.label, max_lines });
    defer gpa.free(title);
    const command = try pagerCommand(gpa, pager.less, path, keys);
    defer gpa.free(command);
    tmux.displayPopup(client_name, title, command) catch |err| switch (err) {
        error.PopupUnavailable => return .popup_unavailable,
        error.TmuxUnavailable => return .tmux_unavailable,
        else => return err,
    };
    return .shown;
}

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

const PagerKeys = union(enum) {
    source: []const u8,
    compiled: []const u8,
};

const Pager = struct {
    less: []const u8,
    lesskey: ?[]const u8,

    fn deinit(self: Pager, gpa: std.mem.Allocator) void {
        gpa.free(self.less);
        if (self.lesskey) |path| gpa.free(path);
    }
};

fn findPager(gpa: std.mem.Allocator, io: std.Io, search_path: ?[]const u8) !?Pager {
    const less = try findAbsolute(gpa, io, search_path, "less") orelse return null;
    errdefer gpa.free(less);
    return .{ .less = less, .lesskey = try findAbsolute(gpa, io, search_path, "lesskey") };
}

fn findAbsolute(gpa: std.mem.Allocator, io: std.Io, search_path: ?[]const u8, name: []const u8) !?[]const u8 {
    const found = try executable.find(gpa, io, .spawn, search_path, ".", name) orelse return null;
    if (std.fs.path.isAbsolute(found)) return found;
    defer gpa.free(found);
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, found, gpa);
    defer gpa.free(absolute);
    return try gpa.dupe(u8, absolute);
}

fn pagerKeys(runner: proc_runner.Runner, pager: Pager, keys_path: []const u8, compiled_path: []const u8) ?PagerKeys {
    var option_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
    const option = std.fmt.bufPrint(&option_buffer, "--lesskey-src={s}", .{keys_path}) catch return null;
    if (succeeds(runner, &.{ pager.less, option, "-V" })) return .{ .source = keys_path };
    const lesskey = pager.lesskey orelse return null;
    if (succeeds(runner, &.{ lesskey, "-o", compiled_path, keys_path })) return .{ .compiled = compiled_path };
    return null;
}

fn succeeds(runner: proc_runner.Runner, argv: []const []const u8) bool {
    const result = proc_runner.captured(runner.run(argv, .{}) catch return false);
    defer runner.gpa.free(result.stdout);
    defer runner.gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn pagerCommand(gpa: std.mem.Allocator, less: []const u8, path: []const u8, keys: PagerKeys) ![]const u8 {
    const quoted = try shell.quote(gpa, path);
    defer gpa.free(quoted);
    const quoted_less = try shell.quote(gpa, less);
    defer gpa.free(quoted_less);
    return switch (keys) {
        .source => |source| {
            const quoted_keys = try shell.quote(gpa, source);
            defer gpa.free(quoted_keys);
            return std.fmt.allocPrint(gpa, "exec {s} --lesskey-src={s} -+E -+F +G -- {s}", .{ quoted_less, quoted_keys, quoted });
        },
        .compiled => |compiled| {
            const quoted_keys = try shell.quote(gpa, compiled);
            defer gpa.free(quoted_keys);
            return std.fmt.allocPrint(gpa, "exec {s} -k {s} -+E -+F +G -- {s}", .{ quoted_less, quoted_keys, quoted });
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
    bin_dir: []const u8,

    fn init(setup: *TestSetup) !void {
        setup.arena = .init(std.testing.allocator);
        setup.recorder = proc_runner.Recorder.init(setup.arena.allocator());
        setup.tmp = std.testing.tmpDir(.{});
        const root = try setup.tmp.dir.realPathFileAlloc(std.testing.io, ".", setup.arena.allocator());
        setup.scratch_dir = try std.fs.path.join(setup.arena.allocator(), &.{ root, "zask" });
        setup.bin_dir = try std.fs.path.join(setup.arena.allocator(), &.{ root, "bin" });
        try setup.tmp.dir.createDirPath(std.testing.io, "bin");
        for ([_][]const u8{ "bin/less", "bin/lesskey" }) |tool| {
            try setup.tmp.dir.writeFile(std.testing.io, .{ .sub_path = tool, .data = "#!/bin/sh\n", .flags = .{ .permissions = @enumFromInt(0o755) } });
        }
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
        return show(setup.arena.allocator(), std.testing.io, setup.client(), .{ .window = "api", .label = "api", .pane = pane, .scratch_dir = setup.scratch_dir, .search_path = setup.bin_dir });
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
    try proc_runner.expectCommandArgContains(popup, 11, try std.fmt.allocPrint(setup.arena.allocator(), "exec '{s}/less' --lesskey-src=", .{setup.bin_dir}));
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
        less_keys: bool = true,
        less_missing: bool = false,
        expected: Outcome,
    }{
        .{ .name = "outside tmux", .pane = null, .expected = .outside_tmux },
        .{ .name = "window missing", .capture_stdout = "", .capture_stderr = "can't find window: api", .capture_status = 1, .expected = .window_missing },
        .{ .name = "tmux unavailable", .capture_stdout = "", .capture_stderr = "error connecting to /tmp/tmux-501/default (Permission denied)", .capture_status = 1, .expected = .tmux_unavailable },
        .{ .name = "empty pane", .capture_stdout = "0\n\n\n", .expected = .empty },
        .{ .name = "no client on the pane", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%7|/dev/pts/1\n", .expected = .no_client },
        .{ .name = "popup refused", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .popup_stderr = "unknown command: display-popup", .expected = .popup_unavailable },
        .{ .name = "less without Ctrl+G", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .less_keys = false, .expected = .pager_unavailable },
        .{ .name = "less missing", .capture_stdout = "0\npanic: boom\n", .clients_stdout = "100|%3|/dev/pts/1\n", .less_missing = true, .expected = .pager_unavailable },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var setup: TestSetup = undefined;
        try setup.init();
        defer setup.deinit();
        if (case.capture_stdout) |stdout| try setup.recorder.enqueue(stdout, case.capture_stderr, .{ .exited = case.capture_status });
        if (case.clients_stdout) |stdout| try setup.recorder.enqueue(stdout, "", .{ .exited = 0 });
        if (case.less_missing) try setup.tmp.dir.deleteFile(std.testing.io, "bin/less");
        if (case.popup_stderr != null or !case.less_keys) {
            if (case.less_keys) {
                try setup.recorder.enqueue("less 668\n", "", .{ .exited = 0 });
            } else {
                try setup.recorder.enqueue("", "There is no lesskey-src option", .{ .exited = 1 });
                try setup.recorder.enqueue("", "lesskey: cannot open file", .{ .exited = 1 });
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
        .{ .keys = .{ .source = "/tmp/zask dir/k's.lesskey" }, .expected = "exec '/opt/bin/less' --lesskey-src='/tmp/zask dir/k'\\''s.lesskey' -+E -+F +G -- '/tmp/zask dir/demo'\\''s.txt'" },
        .{ .keys = .{ .compiled = "/tmp/zask dir/k's.less" }, .expected = "exec '/opt/bin/less' -k '/tmp/zask dir/k'\\''s.less' -+E -+F +G -- '/tmp/zask dir/demo'\\''s.txt'" },
    };
    for (cases) |case| {
        const command = try pagerCommand(std.testing.allocator, "/opt/bin/less", "/tmp/zask dir/demo's.txt", case.keys);
        defer std.testing.allocator.free(command);

        try std.testing.expectEqualStrings(case.expected, command);
    }
}

test "log_popup.findPager: resolves a relative PATH entry to an absolute path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin/less", .data = "#!/bin/sh\n", .flags = .{ .permissions = @enumFromInt(0o755) } });
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/bin", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);

    const pager = (try findPager(std.testing.allocator, std.testing.io, relative)) orelse return error.LessNotFound;
    defer pager.deinit(std.testing.allocator);

    try std.testing.expect(std.fs.path.isAbsolute(pager.less));
    try std.testing.expect(std.mem.endsWith(u8, pager.less, "/bin/less"));
    try std.testing.expectEqual(@as(?[]const u8, null), pager.lesskey);
}

test "log_popup.pagerKeys: compiles the keys for a less without lesskey sources" {
    var recorder = proc_runner.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    try recorder.enqueue("", "There is no lesskey-src option", .{ .exited = 1 });
    try recorder.enqueue("", "", .{ .exited = 0 });
    const runner: proc_runner.Runner = .{ .gpa = std.testing.allocator, .io = undefined, .recorder = &recorder };

    const keys = pagerKeys(runner, .{ .less = "/opt/bin/less", .lesskey = "/opt/bin/lesskey" }, "/tmp/k.lesskey", "/tmp/k.less");

    try std.testing.expectEqualDeep(@as(?PagerKeys, .{ .compiled = "/tmp/k.less" }), keys);
    try proc_runner.expectCommandArgv(recorder.commands.items[0], &.{ "/opt/bin/less", "--lesskey-src=/tmp/k.lesskey", "-V" });
    try proc_runner.expectCommandArgv(recorder.commands.items[1], &.{ "/opt/bin/lesskey", "-o", "/tmp/k.less", "/tmp/k.lesskey" });
}
