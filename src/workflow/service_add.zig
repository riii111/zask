const std = @import("std");
const config = @import("../model/config.zig");
const config_edit = @import("../model/config_edit.zig");
const diagnostics = @import("../model/diagnostics.zig");

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
    /// The file changed after it was loaded.
    changed,
};

/// Serializes `zask add` runs on one config. Hold it from loading the config
/// until `addService` returns, so a concurrent run loads the result of this
/// one instead of overwriting it. Editors do not take the lock; `addService`
/// detects their changes instead.
pub const EditLock = struct {
    file: std.Io.File,

    /// Closing the file drops the OS lock; the kernel also drops it when the
    /// process exits, so a crashed run never leaves the config locked. The
    /// lock file itself stays in the lock directory for reuse.
    pub fn release(self: EditLock, io: std.Io) void {
        self.file.close(io);
    }
};

/// Waits for the exclusive edit lock of the real file behind `path`, using a
/// lock file under `lock_dir`.
pub fn lockConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8, lock_dir: []const u8) !EditLock {
    const lock_path = try editLockPath(gpa, io, path, lock_dir);
    defer gpa.free(lock_path);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, lock_dir, @enumFromInt(0o700));
    const file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .permissions = @enumFromInt(0o600) });
    errdefer file.close(io);
    try file.lock(io, .exclusive);
    return .{ .file = file };
}

/// Comment-preserving edits are not supported yet, so `.jsonc` configs are
/// left for the user to edit by hand.
pub fn ensureEditable(path: []const u8) error{CommentedConfigNotEditable}!void {
    if (std.mem.endsWith(u8, path, ".jsonc")) return error.CommentedConfigNotEditable;
}

/// Adds `service` to the config at `target.path`. The file is replaced only
/// when the edited config passes validation and the file still holds
/// `target.bytes`; otherwise it is left untouched. Callers hold `lockConfig`
/// around loading `target.bytes` and this call. Returned slices are allocated
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
    if (!try replaceIfUnchanged(gpa, io, target.path, target.bytes, added.bytes)) return .changed;
    return .{ .added = added };
}

/// Writes `contents` to a temporary file next to the real file behind `path`
/// and renames it over the original only if the original still equals
/// `expected`. A failure before the rename leaves the original as it was and
/// removes the temporary file. The original permissions are kept, and a
/// symlinked config keeps its link because the rename targets the real file.
fn replaceIfUnchanged(gpa: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8, contents: []const u8) !bool {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer gpa.free(real_path);
    var dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(real_path) orelse "/", .{});
    defer dir.close(io);
    const name = std.fs.path.basename(real_path);

    const stat = try dir.statFile(io, name, .{});
    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = stat.permissions, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, contents);

    // Checked after the temporary file is complete to keep the window for
    // editors between this read and the rename small.
    const current = dir.readFileAlloc(io, name, gpa, .limited(expected.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer gpa.free(current);
    if (!std.mem.eql(u8, current, expected)) return false;
    try atomic.replace(io);
    return true;
}

/// Keyed by the real path so every way of selecting the same file, including
/// symlinks, shares one lock. The returned path is owned by the caller.
fn editLockPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8, lock_dir: []const u8) ![]u8 {
    const real_path = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return err,
    };
    defer gpa.free(real_path);
    const name = try std.fmt.allocPrint(gpa, "config-{x:0>16}.lock", .{std.hash.Wyhash.hash(0, real_path)});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ lock_dir, name });
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

test "service_add.lockConfig: excludes other holders until released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var file = try testWriteConfig(gpa, io, test_config);
    defer file.tmp.cleanup();
    try file.tmp.dir.symLink(io, "zask.json", "link.json", .{});
    const lock_dir = try std.fs.path.join(gpa, &.{ file.dir_path, "locks" });
    const link = try std.fs.path.join(gpa, &.{ file.dir_path, "link.json" });
    const other = try std.Io.Dir.cwd().openFile(io, blk: {
        const held = try lockConfig(gpa, io, file.path, lock_dir);
        defer held.release(io);
        break :blk try editLockPath(gpa, io, link, lock_dir);
    }, .{});
    defer other.close(io);
    const held = try lockConfig(gpa, io, link, lock_dir);

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

test "service_add.ensureEditable: rejects jsonc paths" {
    try ensureEditable("/tmp/zask.json");
    try std.testing.expectError(error.CommentedConfigNotEditable, ensureEditable("/tmp/zask.jsonc"));
}
