const std = @import("std");
const config = @import("../model/config.zig");
const config_edit = @import("../model/config_edit.zig");
const diagnostics = @import("../model/diagnostics.zig");
const file_swap = @import("../platform/file_swap.zig");

pub const NewService = config_edit.NewService;

pub const Target = struct {
    /// Path of the selected config; symlinks are followed when writing.
    path: []const u8,
    /// The exact content the selected config was loaded from.
    bytes: []const u8,
    home: []const u8,
};

pub const Outcome = union(enum) {
    added: config_edit.AddedService,
    duplicate: []const u8,
    group_not_found: []const []const u8,
    group_required: []const []const u8,
    /// The edited config fails validation; the diagnostics hold the reasons.
    invalid,
    /// The edited config would exceed the size zask loads.
    too_large,
    /// The file changed after it was loaded; nothing was written.
    changed,
    /// The file changed while it was being replaced. The version that was
    /// replaced is kept at this path for the user to compare.
    conflict: []const u8,
};

/// Serializes `zask add` runs. Hold it from selecting the config until
/// `addService` returns, so a concurrent run loads the result of this one
/// instead of overwriting it. The lock covers every config rather than one
/// file: on macOS, `realpath` of a config can return the temporary name of a
/// file that another run is swapping in, so no run may resolve its config
/// while another one writes. Editors do not take the lock; `addService`
/// detects their saves instead.
pub const EditLock = struct {
    file: std.Io.File,

    /// Closing the file drops the OS lock; the kernel also drops it when the
    /// process exits, so a crashed run never leaves zask add locked. The lock
    /// file itself stays in the lock directory for reuse.
    pub fn release(self: EditLock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Waits for the exclusive edit lock, using a lock file under `lock_dir`.
pub fn lockConfigEdits(gpa: std.mem.Allocator, io: std.Io, lock_dir: []const u8) !EditLock {
    const lock_path = try std.fs.path.join(gpa, &.{ lock_dir, edit_lock_name });
    defer gpa.free(lock_path);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .permissions = @enumFromInt(0o600) });
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    return .{ .file = file };
}

const edit_lock_name = "config-edit.lock";

/// Comment-preserving edits are not supported yet, so `.jsonc` configs are
/// left for the user to edit by hand.
pub fn ensureEditable(path: []const u8) error{CommentedConfigNotEditable}!void {
    if (std.mem.endsWith(u8, path, ".jsonc")) return error.CommentedConfigNotEditable;
}

/// Adds `service` to the config at `target.path`. The file is replaced only
/// when the edited config passes validation and the file still holds
/// `target.bytes`; otherwise it is left untouched. Callers hold
/// `lockConfigEdits` from selecting the config until this call returns. Returned slices are allocated
/// from `gpa`; pass an arena.
pub fn addService(gpa: std.mem.Allocator, io: std.Io, target: Target, group: ?[]const u8, service: NewService, diags: *diagnostics.Diagnostics) !Outcome {
    const source = try config.parseJsonBytes(gpa, target.bytes);
    const added = switch (try config_edit.addService(gpa, target.bytes, source, group, service)) {
        .added => |added| added,
        .duplicate => |holder| return .{ .duplicate = holder },
        .group_not_found => |names| return .{ .group_not_found = names },
        .group_required => |names| return .{ .group_required = names },
    };
    if (!config.fitsLoadLimit(added.bytes.len)) return .too_large;
    _ = config.Config.parseWithDiagnostics(gpa, added.bytes, target.home, diags) catch |err| switch (err) {
        error.InvalidConfig => return .invalid,
        else => return err,
    };
    return switch (try replaceIfUnchanged(gpa, io, target.path, target.bytes, added.bytes)) {
        .replaced => .{ .added = added },
        .changed => .changed,
        .conflict => |kept| .{ .conflict = kept },
    };
}

/// Result of writing the edited config.
const Replacement = union(enum) {
    replaced,
    /// The config changed before the write; nothing was written.
    changed,
    /// The config changed while it was being replaced. The version that was
    /// replaced is kept at this path; see `PendingWrite.restoreDisplaced`.
    conflict: []const u8,
};

/// Writes `contents` over the real file behind `path` only if that file
/// still holds `expected`.
///
/// Editors do not take `lockConfigEdits`, and a rename cannot check what it
/// replaces, so the new file is exchanged with the config instead of renamed
/// over it. The file it displaces stays at the temporary path and is checked
/// afterwards; a displaced file that is not `expected` is put back, or kept
/// on disk when that cannot be confirmed. No version of the config is
/// deleted without being compared first. Filesystems without an atomic
/// exchange fail with error.ExchangeUnsupported before anything is written.
fn replaceIfUnchanged(gpa: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8, contents: []const u8) !Replacement {
    const pending = (try PendingWrite.stage(gpa, io, path, expected, contents)) orelse return .changed;
    errdefer pending.discard(io);
    if (!try pending.targetUnchanged(gpa, io)) {
        pending.discard(io);
        return .changed;
    }
    if (try pending.swapIn(gpa, io)) return .replaced;
    return pending.restoreDisplaced(gpa, io);
}

/// New config content written to a temporary file next to the real config,
/// with the original permissions. A symlinked config keeps its link because
/// every step works on the real path.
const PendingWrite = struct {
    real_path: []const u8,
    temp_path: []const u8,
    expected: []const u8,
    contents: []const u8,

    /// Returns null when the config no longer exists.
    fn stage(gpa: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8, contents: []const u8) !?PendingWrite {
        const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const stat = try std.Io.Dir.cwd().statFile(io, real_path, .{});
        const temp = try createTempFile(gpa, io, real_path);
        errdefer std.Io.Dir.deleteFileAbsolute(io, temp.path) catch {};
        defer temp.file.close(io);
        try temp.file.writeStreamingAll(io, contents);
        try temp.file.setPermissions(io, stat.permissions);
        try temp.file.sync(io);
        return .{ .real_path = real_path, .temp_path = temp.path, .expected = expected, .contents = contents };
    }

    fn targetUnchanged(self: PendingWrite, gpa: std.mem.Allocator, io: std.Io) !bool {
        return fileEquals(gpa, io, self.real_path, self.expected);
    }

    /// Exchanges the new file with the config. Returns true when the
    /// displaced file is the expected one, which is then deleted; otherwise
    /// it stays at `temp_path` for `restoreDisplaced`.
    fn swapIn(self: PendingWrite, gpa: std.mem.Allocator, io: std.Io) !bool {
        try file_swap.exchange(gpa, self.temp_path, self.real_path);
        if (!try fileEquals(gpa, io, self.temp_path, self.expected)) return false;
        self.discard(io);
        return true;
    }

    /// Puts a displaced file that someone else saved back at the config, so
    /// their save wins and this edit is dropped. The temporary file is
    /// deleted only when it is confirmed to hold this edit; otherwise it is
    /// kept and reported, because it may be the only copy of another save.
    fn restoreDisplaced(self: PendingWrite, gpa: std.mem.Allocator, io: std.Io) !Replacement {
        file_swap.exchange(gpa, self.temp_path, self.real_path) catch return .{ .conflict = self.temp_path };
        if (!try fileEquals(gpa, io, self.temp_path, self.contents)) return .{ .conflict = self.temp_path };
        self.discard(io);
        return .changed;
    }

    fn discard(self: PendingWrite, io: std.Io) void {
        std.Io.Dir.deleteFileAbsolute(io, self.temp_path) catch {};
    }
};

const TempFile = struct { file: std.Io.File, path: []const u8 };

/// Creates `.<name>.zask-add-<pid>[-n]` next to `real_path`. The path is
/// allocated from `gpa`.
fn createTempFile(gpa: std.mem.Allocator, io: std.Io, real_path: []const u8) !TempFile {
    const dir = std.fs.path.dirname(real_path) orelse "/";
    const name = std.fs.path.basename(real_path);
    const pid = std.c.getpid();
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const temp_name = if (attempt == 0)
            try std.fmt.allocPrint(gpa, ".{s}.zask-add-{d}", .{ name, pid })
        else
            try std.fmt.allocPrint(gpa, ".{s}.zask-add-{d}-{d}", .{ name, pid, attempt });
        const path = try std.fs.path.join(gpa, &.{ dir, temp_name });
        const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => if (attempt < 100) continue else return err,
            else => return err,
        };
        return .{ .file = file, .path = path };
    }
}

fn fileEquals(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !bool {
    const current = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(bytes.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer gpa.free(current);
    return std.mem.eql(u8, current, bytes);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_config =
    \\{
    \\  "project": {"name": "demo", "root": "/tmp/demo"},
    \\  "groups": [{"name": "backend", "services": {
    \\    "worker": "work"
    \\  }}]
    \\}
    \\
;

const TestFile = struct {
    tmp: std.testing.TmpDir,
    dir_path: []const u8,
    path: []const u8,

    fn target(self: TestFile, path: []const u8, bytes: []const u8) Target {
        _ = self;
        return .{ .path = path, .bytes = bytes, .home = "/home/me" };
    }
};

fn testWriteConfig(gpa: std.mem.Allocator, io: std.Io, contents: []const u8) !TestFile {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = contents });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    return .{
        .tmp = tmp,
        .dir_path = dir_path,
        .path = try std.fs.path.join(gpa, &.{ dir_path, "zask.json" }),
    };
}

fn testRead(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(config.max_config_bytes));
}

test "service_add.addService: writes the edited config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    var diags = diagnostics.Diagnostics.init(gpa);

    const outcome = try addService(gpa, io, file.target(file.path, test_config), null, .{ .name = "api", .command = "cargo run" }, &diags);

    try std.testing.expect(outcome == .added);
    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": {
        \\    "worker": "work",
        \\    "api": "cargo run"
        \\  }}]
        \\}
        \\
    , try testRead(gpa, io, file.path));
}

test "service_add.addService: leaves the file when the result is invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    var diags = diagnostics.Diagnostics.init(gpa);

    const outcome = try addService(gpa, io, file.target(file.path, test_config), null, .{ .name = "bad name", .command = "x" }, &diags);

    try std.testing.expect(outcome == .invalid);
    try std.testing.expectEqualStrings("groups[0].services.bad name", diags.slice()[0].path);
    try std.testing.expectEqualStrings(test_config, try testRead(gpa, io, file.path));
}

test "service_add.addService: leaves the file when it changed after loading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const edited_elsewhere = test_config ++ "\n";
    var file = try testWriteConfig(gpa, io, edited_elsewhere);
    defer file.tmp.cleanup();
    var diags = diagnostics.Diagnostics.init(gpa);

    const outcome = try addService(gpa, io, file.target(file.path, test_config), null, .{ .name = "api", .command = "x" }, &diags);

    try std.testing.expect(outcome == .changed);
    try std.testing.expectEqualStrings(edited_elsewhere, try testRead(gpa, io, file.path));
}

test "service_add.addService: keeps the original on write failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    var diags = diagnostics.Diagnostics.init(gpa);
    try std.Io.Dir.cwd().setFilePermissions(io, file.dir_path, @enumFromInt(0o555), .{});
    defer std.Io.Dir.cwd().setFilePermissions(io, file.dir_path, @enumFromInt(0o755), .{}) catch {};

    const result = addService(gpa, io, file.target(file.path, test_config), null, .{ .name = "api", .command = "x" }, &diags);

    try std.testing.expectError(error.AccessDenied, result);
    try std.testing.expectEqualStrings(test_config, try testRead(gpa, io, file.path));
}

test "service_add.addService: updates the target of a symlinked config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    try file.tmp.dir.symLink(io, "zask.json", "link.json", .{});
    const link = try std.fs.path.join(gpa, &.{ file.dir_path, "link.json" });
    var diags = diagnostics.Diagnostics.init(gpa);

    const outcome = try addService(gpa, io, file.target(link, test_config), null, .{ .name = "api", .command = "x" }, &diags);

    try std.testing.expect(outcome == .added);
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try file.tmp.dir.readLink(io, "link.json", &target_buf);
    try std.testing.expectEqualStrings("zask.json", target_buf[0..target_len]);
    try std.testing.expectEqualStrings(outcome.added.bytes, try testRead(gpa, io, file.path));
}

test "service_add.lockConfigEdits: excludes other holders until released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const lock_dir = try std.fs.path.join(gpa, &.{ base, "locks" });
    const held = try lockConfigEdits(gpa, io, lock_dir);
    const other = try std.Io.Dir.cwd().openFile(io, try std.fs.path.join(gpa, &.{ lock_dir, edit_lock_name }), .{});
    defer other.close(io);

    const while_held = try other.tryLock(io, .exclusive);
    held.release(io);
    const after_release = try other.tryLock(io, .exclusive);

    try std.testing.expect(!while_held);
    try std.testing.expect(after_release);
}

test "service_add.addService: refuses results the loader would reject as too large" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const service: NewService = .{ .name = "api", .command = "x" };
    var probe = try testWriteConfig(gpa, io, test_config);
    defer probe.tmp.cleanup();
    var probe_diags = diagnostics.Diagnostics.init(gpa);
    const growth = (try addService(gpa, io, probe.target(probe.path, test_config), null, service, &probe_diags)).added.bytes.len - test_config.len;
    const cases = [_]struct { result_len: usize, added: bool }{
        .{ .result_len = config.max_config_bytes - 1, .added = true },
        .{ .result_len = config.max_config_bytes, .added = false },
    };

    for (cases) |case| {
        const padded = try std.mem.concat(gpa, u8, &.{ test_config, try testSpaces(gpa, case.result_len - growth - test_config.len) });
        var file = try testWriteConfig(gpa, io, padded);
        defer file.tmp.cleanup();
        var diags = diagnostics.Diagnostics.init(gpa);

        const outcome = try addService(gpa, io, file.target(file.path, padded), null, service, &diags);

        if (case.added) {
            try std.testing.expectEqual(case.result_len, outcome.added.bytes.len);
            _ = try config.loadPath(gpa, io, file.path, "/home/me");
        } else {
            try std.testing.expect(outcome == .too_large);
            try std.testing.expect(std.mem.eql(u8, padded, try testRead(gpa, io, file.path)));
        }
    }
}

fn testSpaces(gpa: std.mem.Allocator, len: usize) ![]u8 {
    const spaces = try gpa.alloc(u8, len);
    @memset(spaces, ' ');
    return spaces;
}

test "service_add.replaceIfUnchanged: puts back an editor save made before the swap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    const pending = (try PendingWrite.stage(gpa, io, file.path, test_config, "ours\n")).?;
    try std.testing.expect(try pending.targetUnchanged(gpa, io));

    try testEditorSave(file, io, "editor\n");
    const swapped_expected = try pending.swapIn(gpa, io);
    const result = try pending.restoreDisplaced(gpa, io);

    try std.testing.expect(!swapped_expected);
    try std.testing.expect(result == .changed);
    try std.testing.expectEqualStrings("editor\n", try testRead(gpa, io, file.path));
    try testExpectOnlyConfig(file, io);
}

test "service_add.replaceIfUnchanged: keeps a save made while putting one back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    const pending = (try PendingWrite.stage(gpa, io, file.path, test_config, "ours\n")).?;
    try std.testing.expect(try pending.targetUnchanged(gpa, io));
    try testEditorSave(file, io, "first save\n");
    try std.testing.expect(!try pending.swapIn(gpa, io));

    try testEditorSave(file, io, "second save\n");
    const result = try pending.restoreDisplaced(gpa, io);

    try std.testing.expectEqualStrings("first save\n", try testRead(gpa, io, file.path));
    try std.testing.expectEqualStrings("second save\n", try testRead(gpa, io, result.conflict));
}

test "service_add.replaceIfUnchanged: deletes the displaced config it expected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();

    const result = try replaceIfUnchanged(gpa, io, file.path, test_config, "ours\n");

    try std.testing.expect(result == .replaced);
    try std.testing.expectEqualStrings("ours\n", try testRead(gpa, io, file.path));
    try testExpectOnlyConfig(file, io);
}

/// Saves like editors that write a temporary file and rename it over the
/// config, replacing the file instead of rewriting it.
fn testEditorSave(file: TestFile, io: std.Io, contents: []const u8) !void {
    try file.tmp.dir.writeFile(io, .{ .sub_path = ".editor-save", .data = contents });
    try file.tmp.dir.rename(".editor-save", file.tmp.dir, "zask.json", io);
}

fn testExpectOnlyConfig(file: TestFile, io: std.Io) !void {
    var dir = try file.tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        try std.testing.expectEqualStrings("zask.json", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "service_add.ensureEditable: rejects jsonc paths" {
    try ensureEditable("/tmp/zask.json");
    try std.testing.expectError(error.CommentedConfigNotEditable, ensureEditable("/tmp/zask.jsonc"));
}
