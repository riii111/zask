const std = @import("std");
const watch = @import("../model/watch.zig");

const Dir = std.Io.Dir;

pub const max_entries = 100_000;

pub const Root = struct {
    path: []const u8,
    label: []const u8,
};

pub const Entry = struct {
    path: []const u8,
    kind: std.Io.File.Kind,
    inode: std.Io.File.INode,
    size: u64,
    mtime_ns: i96,

    pub fn sameState(a: Entry, b: Entry) bool {
        return a.kind == b.kind and a.inode == b.inode and a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

pub const FailureReason = enum {
    missing,
    access_denied,
    too_many_files,
    io_error,
};

pub const Failure = struct {
    reason: FailureReason,
    path: []const u8,

    pub fn deinit(self: Failure, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

pub const MissingRoot = enum {
    fail,
    empty,
};

pub const Options = struct {
    missing_root: MissingRoot,
    max_entries: usize = max_entries,
};

pub const Result = union(enum) {
    ok: Snapshot,
    failed: Failure,
};

pub fn scan(gpa: std.mem.Allocator, io: std.Io, roots: []const Root, spec: watch.Spec, options: Options) error{OutOfMemory}!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var scanner: Scanner = .{ .arena = arena.allocator(), .io = io, .spec = spec, .options = options };
    for (roots) |root| {
        scanner.scanRoot(root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ScanFailed => {
                const failure: Failure = .{ .reason = scanner.failure_reason, .path = try gpa.dupe(u8, scanner.failure_path) };
                arena.deinit();
                return .{ .failed = failure };
            },
        };
    }
    return .{ .ok = .{ .arena = arena, .entries = sortUnique(scanner.entries.items) } };
}

const ScanError = error{ OutOfMemory, ScanFailed };

const Scanner = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    spec: watch.Spec,
    options: Options,
    entries: std.ArrayList(Entry) = .empty,
    rel_path: std.ArrayList(u8) = .empty,
    root_path: []const u8 = "",
    failure_reason: FailureReason = .io_error,
    failure_path: []const u8 = "",

    fn scanRoot(self: *Scanner, root: Root) ScanError!void {
        const stat = Dir.cwd().statFile(self.io, root.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return self.missingRoot(root),
            else => return self.fail(reasonFor(err), root.path),
        };
        self.root_path = root.path;
        if (rootExcluded(self.spec, root.label)) return;
        if (stat.kind != .directory) return self.append(try self.arena.dupe(u8, root.label), stat);

        var dir = Dir.cwd().openDir(self.io, root.path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return self.missingRoot(root),
            else => return self.fail(reasonFor(err), root.path),
        };
        defer dir.close(self.io);
        self.rel_path.clearRetainingCapacity();
        try self.walk(dir, root);
    }

    fn missingRoot(self: *Scanner, root: Root) ScanError!void {
        switch (self.options.missing_root) {
            .empty => return,
            .fail => return self.fail(.missing, root.path),
        }
    }

    fn walk(self: *Scanner, dir: Dir, root: Root) ScanError!void {
        var it = dir.iterate();
        while (it.next(self.io) catch |err| return self.failAt(err, root)) |item| {
            const parent_len = self.rel_path.items.len;
            defer self.rel_path.shrinkRetainingCapacity(parent_len);
            if (parent_len > 0) try self.rel_path.append(self.arena, '/');
            try self.rel_path.appendSlice(self.arena, item.name);
            const rel = self.rel_path.items;

            const stat = dir.statFile(self.io, item.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return self.failAt(err, root),
            };
            if (stat.kind == .directory) {
                if (self.spec.skipsDir(rel)) continue;
                var child = dir.openDir(self.io, item.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => continue,
                    else => return self.failAt(err, root),
                };
                defer child.close(self.io);
                try self.walk(child, root);
                continue;
            }
            if (!self.spec.watchesFile(rel)) continue;
            try self.append(try displayPath(self.arena, root.label, rel), stat);
        }
    }

    fn append(self: *Scanner, path: []const u8, stat: std.Io.File.Stat) ScanError!void {
        if (self.entries.items.len >= self.options.max_entries) return self.fail(.too_many_files, self.root_path);
        try self.entries.append(self.arena, .{
            .path = path,
            .kind = stat.kind,
            .inode = stat.inode,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
        });
    }

    fn failAt(self: *Scanner, err: anyerror, root: Root) ScanError {
        const path = if (self.rel_path.items.len == 0)
            root.path
        else
            try std.fs.path.join(self.arena, &.{ root.path, self.rel_path.items });
        return self.fail(reasonFor(err), path);
    }

    fn fail(self: *Scanner, reason: FailureReason, path: []const u8) ScanError {
        self.failure_reason = reason;
        self.failure_path = path;
        return error.ScanFailed;
    }
};

fn rootExcluded(spec: watch.Spec, label: []const u8) bool {
    const name = std.mem.trimEnd(u8, label, "/");
    const base = std.fs.path.basenamePosix(name);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return false;
    return spec.excludes(name);
}

fn reasonFor(err: anyerror) FailureReason {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_denied,
        error.FileNotFound => .missing,
        else => .io_error,
    };
}

fn displayPath(arena: std.mem.Allocator, label: []const u8, rel: []const u8) ![]const u8 {
    if (std.mem.eql(u8, label, ".")) return arena.dupe(u8, rel);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, label, "/"), rel });
}

fn sortUnique(entries: []Entry) []const Entry {
    std.mem.sort(Entry, entries, {}, lessThanPath);
    var len: usize = 0;
    for (entries) |entry| {
        if (len > 0 and std.mem.eql(u8, entries[len - 1].path, entry.path)) continue;
        entries[len] = entry;
        len += 1;
    }
    return entries[0..len];
}

fn lessThanPath(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestTree = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,

    fn init() !TestTree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *TestTree) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: TestTree, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try self.tmp.dir.createDirPath(std.testing.io, dir);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn scanAll(self: TestTree, spec: watch.Spec, options: Options) !Result {
        const roots = [_]Root{.{ .path = self.root, .label = "." }};
        return scan(std.testing.allocator, std.testing.io, &roots, spec, options);
    }
};

fn testSpec(include: []const []const u8, exclude: []const []const u8) watch.Spec {
    return .{ .paths = &watch.default_paths, .include = include, .exclude = exclude, .debounce_ms = 0 };
}

fn testPaths(snapshot: Snapshot) ![]const []const u8 {
    const paths = try std.testing.allocator.alloc([]const u8, snapshot.entries.len);
    for (snapshot.entries, paths) |entry, *path| path.* = entry.path;
    return paths;
}

fn testExpectPaths(expected: []const []const u8, snapshot: Snapshot) !void {
    const actual = try testPaths(snapshot);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "file_scan.scan: records watched files sorted and skips excluded directories" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("src/main.rs", "fn main() {}");
    try tree.write("src/lib.rs", "");
    try tree.write("README.md", "");
    try tree.write("target/debug/app", "");
    try tree.write(".git/HEAD", "");
    try tree.write("logs/app.log", "");

    var result = try tree.scanAll(testSpec(&.{}, &.{ "target", "*.log" }), .{ .missing_root = .fail });
    defer result.ok.deinit();

    try testExpectPaths(&.{ "README.md", "src/lib.rs", "src/main.rs" }, result.ok);
}

test "file_scan.scan: applies include patterns to files only" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("src/main.rs", "");
    try tree.write("src/notes.txt", "");

    var result = try tree.scanAll(testSpec(&.{"*.rs"}, &.{}), .{ .missing_root = .fail });
    defer result.ok.deinit();

    try testExpectPaths(&.{"src/main.rs"}, result.ok);
}

test "file_scan.scan: labels roots and merges overlapping paths" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("src/main.rs", "");
    try tree.write("Cargo.toml", "");
    const src = try std.fs.path.join(std.testing.allocator, &.{ tree.root, "src" });
    defer std.testing.allocator.free(src);
    const cargo = try std.fs.path.join(std.testing.allocator, &.{ tree.root, "Cargo.toml" });
    defer std.testing.allocator.free(cargo);
    const roots = [_]Root{
        .{ .path = src, .label = "src" },
        .{ .path = cargo, .label = "Cargo.toml" },
        .{ .path = tree.root, .label = "." },
    };

    var result = try scan(std.testing.allocator, std.testing.io, &roots, testSpec(&.{"*.rs"}, &.{}), .{ .missing_root = .fail });
    defer result.ok.deinit();

    try testExpectPaths(&.{ "Cargo.toml", "src/main.rs" }, result.ok);
}

test "file_scan.scan: missing root fails before the first snapshot" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const missing = try std.fs.path.join(std.testing.allocator, &.{ tree.root, "missing" });
    defer std.testing.allocator.free(missing);
    const roots = [_]Root{.{ .path = missing, .label = "missing" }};

    const failed = try scan(std.testing.allocator, std.testing.io, &roots, testSpec(&.{}, &.{}), .{ .missing_root = .fail });
    defer failed.failed.deinit(std.testing.allocator);
    var empty = try scan(std.testing.allocator, std.testing.io, &roots, testSpec(&.{}, &.{}), .{ .missing_root = .empty });
    defer empty.ok.deinit();

    try std.testing.expectEqual(FailureReason.missing, failed.failed.reason);
    try std.testing.expectEqualStrings(missing, failed.failed.path);
    try std.testing.expectEqual(@as(usize, 0), empty.ok.entries.len);
}

test "file_scan.scan: reports unreadable directories as access denied" {
    var tree = try TestTree.init();
    defer tree.deinit();
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    try tree.write("locked/secret.txt", "");
    try tree.tmp.dir.setFilePermissions(std.testing.io, "locked", @enumFromInt(0o000), .{});
    defer tree.tmp.dir.setFilePermissions(std.testing.io, "locked", @enumFromInt(0o755), .{}) catch {};

    const result = try tree.scanAll(testSpec(&.{}, &.{}), .{ .missing_root = .fail });
    defer result.failed.deinit(std.testing.allocator);

    try std.testing.expectEqual(FailureReason.access_denied, result.failed.reason);
    try std.testing.expect(std.mem.endsWith(u8, result.failed.path, "/locked"));
}

test "file_scan.scan: fails when watched files exceed the limit" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("a.txt", "");
    try tree.write("b.txt", "");

    const result = try tree.scanAll(testSpec(&.{}, &.{}), .{ .missing_root = .fail, .max_entries = 1 });
    defer result.failed.deinit(std.testing.allocator);

    try std.testing.expectEqual(FailureReason.too_many_files, result.failed.reason);
    try std.testing.expectEqualStrings(tree.root, result.failed.path);
}

test "file_scan.scan: hidden-file excludes keep the default root" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("main.rs", "");
    try tree.write(".env", "");

    var result = try tree.scanAll(testSpec(&.{}, &.{".*"}), .{ .missing_root = .fail });
    defer result.ok.deinit();

    try testExpectPaths(&.{"main.rs"}, result.ok);
}

test "file_scan.scan: applies excludes to paths named as roots" {
    var tree = try TestTree.init();
    defer tree.deinit();
    try tree.write("app.log", "");
    try tree.write(".git/HEAD", "");
    try tree.write("build/out.js", "");
    try tree.write("main.rs", "");
    const names = [_][]const u8{ "app.log", ".git", "build/", "main.rs" };
    var roots: [names.len]Root = undefined;
    for (names, &roots) |name, *root| {
        root.* = .{ .path = try std.fs.path.join(std.testing.allocator, &.{ tree.root, name }), .label = name };
    }
    defer for (roots) |root| std.testing.allocator.free(root.path);

    var result = try scan(std.testing.allocator, std.testing.io, &roots, testSpec(&.{"*.txt"}, &.{ "*.log", "build" }), .{ .missing_root = .fail });
    defer result.ok.deinit();

    try testExpectPaths(&.{"main.rs"}, result.ok);
}
