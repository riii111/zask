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
    /// The file changed after it was loaded.
    changed,
};

/// Comment-preserving edits are not supported yet, so `.jsonc` configs are
/// left for the user to edit by hand.
pub fn ensureEditable(path: []const u8) error{CommentedConfigNotEditable}!void {
    if (std.mem.endsWith(u8, path, ".jsonc")) return error.CommentedConfigNotEditable;
}

/// Adds `service` to the config at `target.path`. The file is replaced only
/// when the edited config passes validation and the file still holds
/// `target.bytes`; otherwise it is left untouched. Returned slices are
/// allocated from `gpa`; pass an arena.
pub fn addService(gpa: std.mem.Allocator, io: std.Io, target: Target, group: ?[]const u8, service: NewService, diags: *diagnostics.Diagnostics) !Outcome {
    const source = try config.parseJsonBytes(gpa, target.bytes);
    const added = switch (try config_edit.addService(gpa, target.bytes, source, group, service)) {
        .added => |added| added,
        .duplicate => |holder| return .{ .duplicate = holder },
        .group_not_found => |names| return .{ .group_not_found = names },
        .group_required => |names| return .{ .group_required = names },
    };
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

    // Checked after the temporary file is complete to keep the window
    // between this read and the rename small.
    const current = dir.readFileAlloc(io, name, gpa, .limited(expected.len + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return false,
        else => return err,
    };
    defer gpa.free(current);
    if (!std.mem.eql(u8, current, expected)) return false;
    try atomic.replace(io);
    return true;
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
};

fn testWriteConfig(gpa: std.mem.Allocator, io: std.Io, contents: []const u8) !TestFile {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zask.json", .data = contents });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    return .{ .tmp = tmp, .dir_path = dir_path, .path = try std.fs.path.join(gpa, &.{ dir_path, "zask.json" }) };
}

fn testRead(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
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

    const outcome = try addService(gpa, io, .{ .path = file.path, .bytes = test_config, .home = "/home/me" }, null, .{ .name = "api", .command = "cargo run" }, &diags);

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

    const outcome = try addService(gpa, io, .{ .path = file.path, .bytes = test_config, .home = "/home/me" }, null, .{ .name = "bad name", .command = "x" }, &diags);

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

    const outcome = try addService(gpa, io, .{ .path = file.path, .bytes = test_config, .home = "/home/me" }, null, .{ .name = "api", .command = "x" }, &diags);

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

    const result = addService(gpa, io, .{ .path = file.path, .bytes = test_config, .home = "/home/me" }, null, .{ .name = "api", .command = "x" }, &diags);

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

    const outcome = try addService(gpa, io, .{ .path = link, .bytes = test_config, .home = "/home/me" }, null, .{ .name = "api", .command = "x" }, &diags);

    try std.testing.expect(outcome == .added);
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try file.tmp.dir.readLink(io, "link.json", &target_buf);
    try std.testing.expectEqualStrings("zask.json", target_buf[0..target_len]);
    try std.testing.expectEqualStrings(outcome.added.bytes, try testRead(gpa, io, file.path));
}

test "service_add.ensureEditable: rejects jsonc paths" {
    try ensureEditable("/tmp/zask.json");
    try std.testing.expectError(error.CommentedConfigNotEditable, ensureEditable("/tmp/zask.jsonc"));
}
