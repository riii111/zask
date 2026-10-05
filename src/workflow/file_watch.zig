const std = @import("std");
const config = @import("../model/config.zig");
const watch = @import("../model/watch.zig");
const file_scan = @import("../platform/file_scan.zig");

const Value = std.json.Value;
const Snapshot = file_scan.Snapshot;

pub const poll_interval_ms = 500;

pub const ChangeKind = enum {
    created,
    modified,
    deleted,
};

pub const Change = struct {
    kind: ChangeKind,
    path: []const u8,
};

pub const Event = union(enum) {
    changed: []const Change,
    failed: file_scan.Failure,
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    spec: watch.Spec,
    roots: []const file_scan.Root,
    tracker: Tracker,
    last_failure: ?file_scan.Failure = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config, service: Value) !?Watcher {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const spec = (try config.Config.serviceWatch(allocator, service)) orelse {
            arena.deinit();
            return null;
        };
        const roots = try allocator.alloc(file_scan.Root, spec.paths.len);
        for (spec.paths, roots) |path, *root| {
            root.* = .{ .path = try cfg.serviceWatchPath(allocator, service, path), .label = path };
        }
        return .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .spec = spec,
            .roots = roots,
            .tracker = .{ .debounce_ns = @as(i96, spec.debounce_ms) * std.time.ns_per_ms },
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.tracker.deinit(self.gpa);
        if (self.last_failure) |failure| failure.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn poll(self: *Watcher, now_ns: i96) !?Event {
        if (self.last_failure) |failure| failure.deinit(self.gpa);
        self.last_failure = null;

        const missing_root: file_scan.MissingRoot = if (self.tracker.hasBaseline()) .empty else .fail;
        switch (try file_scan.scan(self.gpa, self.io, self.roots, self.spec, .{ .missing_root = missing_root })) {
            .ok => |snapshot| {
                const changes = (try self.tracker.observe(self.gpa, snapshot, now_ns)) orelse return null;
                return .{ .changed = changes };
            },
            .failed => |failure| {
                if (!self.tracker.observeFailure()) {
                    failure.deinit(self.gpa);
                    return null;
                }
                self.last_failure = failure;
                return .{ .failed = failure };
            },
        }
    }
};

pub const Tracker = struct {
    debounce_ns: i96,
    baseline: ?Snapshot = null,
    pending: ?Snapshot = null,
    reported: ?Snapshot = null,
    last_change_ns: i96 = 0,
    failure_reported: bool = false,
    changes: std.ArrayList(Change) = .empty,

    pub fn deinit(self: *Tracker, gpa: std.mem.Allocator) void {
        self.dropSnapshots();
        self.changes.deinit(gpa);
    }

    pub fn hasBaseline(self: Tracker) bool {
        return self.baseline != null;
    }

    pub fn observe(self: *Tracker, gpa: std.mem.Allocator, snapshot: Snapshot, now_ns: i96) !?[]const Change {
        var next = snapshot;
        self.releaseReported();
        self.failure_reported = false;
        if (self.baseline == null) {
            self.baseline = next;
            return null;
        }

        const latest = if (self.pending) |*pending| pending else &self.baseline.?;
        if (sameEntries(latest.entries, next.entries)) {
            next.deinit();
        } else {
            if (self.pending) |*pending| pending.deinit();
            self.pending = next;
            self.last_change_ns = now_ns;
        }

        if (self.pending == null or now_ns - self.last_change_ns < self.debounce_ns) return null;
        self.changes.clearRetainingCapacity();
        try diffEntries(gpa, self.baseline.?.entries, self.pending.?.entries, &self.changes);
        self.reported = self.baseline;
        self.baseline = self.pending;
        self.pending = null;
        if (self.changes.items.len == 0) return null;
        return self.changes.items;
    }

    pub fn observeFailure(self: *Tracker) bool {
        self.dropSnapshots();
        if (self.failure_reported) return false;
        self.failure_reported = true;
        return true;
    }

    fn releaseReported(self: *Tracker) void {
        if (self.reported) |*reported| reported.deinit();
        self.reported = null;
    }

    fn dropSnapshots(self: *Tracker) void {
        self.releaseReported();
        if (self.baseline) |*baseline| baseline.deinit();
        if (self.pending) |*pending| pending.deinit();
        self.baseline = null;
        self.pending = null;
    }
};

fn sameEntries(a: []const file_scan.Entry, b: []const file_scan.Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.path, right.path) or !left.sameState(right)) return false;
    }
    return true;
}

fn diffEntries(gpa: std.mem.Allocator, before: []const file_scan.Entry, after: []const file_scan.Entry, out: *std.ArrayList(Change)) !void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.len or j < after.len) {
        if (j == after.len or (i < before.len and std.mem.lessThan(u8, before[i].path, after[j].path))) {
            try out.append(gpa, .{ .kind = .deleted, .path = before[i].path });
            i += 1;
        } else if (i == before.len or std.mem.lessThan(u8, after[j].path, before[i].path)) {
            try out.append(gpa, .{ .kind = .created, .path = after[j].path });
            j += 1;
        } else {
            if (!before[i].sameState(after[j])) try out.append(gpa, .{ .kind = .modified, .path = after[j].path });
            i += 1;
            j += 1;
        }
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestEntry = struct {
    path: []const u8,
    mtime_ns: i96 = 1,
};

fn testSnapshot(entries: []const TestEntry) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const items = try arena.allocator().alloc(file_scan.Entry, entries.len);
    for (entries, items, 0..) |entry, *item, index| {
        item.* = .{
            .path = try arena.allocator().dupe(u8, entry.path),
            .kind = .file,
            .inode = @intCast(index + 1),
            .size = 1,
            .mtime_ns = entry.mtime_ns,
        };
    }
    return .{ .arena = arena, .entries = items };
}

fn testExpectChanges(expected: []const Change, actual: ?[]const Change) !void {
    const changes = actual orelse return error.TestExpectedChanges;
    try std.testing.expectEqual(expected.len, changes.len);
    for (expected, changes) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.path, got.path);
    }
}

const TestProject = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,

    fn init(watch_json: []const u8) !TestProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
        const json = try std.fmt.allocPrint(arena.allocator(),
            \\{{"project":{{"name":"demo","root":"{s}"}},
            \\ "groups":[{{"name":"be","services":[{{"name":"api","command":"serve","watch":{s}}}]}}]}}
        , .{ root, watch_json });
        const cfg = try config.Config.parse(arena.allocator(), json, "/home/me");
        return .{ .tmp = tmp, .arena = arena, .cfg = cfg };
    }

    fn deinit(self: *TestProject) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn watcher(self: TestProject) !Watcher {
        return (try Watcher.init(std.testing.allocator, std.testing.io, self.cfg, try self.cfg.findService("api"))).?;
    }

    fn write(self: TestProject, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try self.tmp.dir.createDirPath(std.testing.io, dir);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }
};

test "file_watch.Tracker: reports net changes once the debounce period passes" {
    var tracker: Tracker = .{ .debounce_ns = 300 };
    defer tracker.deinit(std.testing.allocator);
    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a" }, .{ .path = "b" } }), 0);

    const pending = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 2 }, .{ .path = "c" } }), 1000);
    const early = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 2 }, .{ .path = "c" } }), 1299);
    const ready = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 2 }, .{ .path = "c" } }), 1300);

    try std.testing.expect(pending == null);
    try std.testing.expect(early == null);
    try testExpectChanges(&.{
        .{ .kind = .modified, .path = "a" },
        .{ .kind = .deleted, .path = "b" },
        .{ .kind = .created, .path = "c" },
    }, ready);
}

test "file_watch.Tracker: merges consecutive saves into one batch" {
    var tracker: Tracker = .{ .debounce_ns = 300 };
    defer tracker.deinit(std.testing.allocator);
    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a" }}), 0);

    const first = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a", .mtime_ns = 2 }}), 1000);
    const second = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 3 }, .{ .path = "b" } }), 1200);
    const before_quiet = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 3 }, .{ .path = "b" } }), 1400);
    const ready = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 3 }, .{ .path = "b" } }), 1500);
    const after = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a", .mtime_ns = 3 }, .{ .path = "b" } }), 2000);

    try std.testing.expect(first == null);
    try std.testing.expect(second == null);
    try std.testing.expect(before_quiet == null);
    try testExpectChanges(&.{
        .{ .kind = .modified, .path = "a" },
        .{ .kind = .created, .path = "b" },
    }, ready);
    try std.testing.expect(after == null);
}

test "file_watch.Tracker: skips bursts that leave no net change" {
    var tracker: Tracker = .{ .debounce_ns = 300 };
    defer tracker.deinit(std.testing.allocator);
    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a" }}), 0);

    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "a" }, .{ .path = "a.swp" } }), 1000);
    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a" }}), 1100);
    const settled = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a" }}), 1400);

    try std.testing.expect(settled == null);
}

test "file_watch.Tracker: reports a failure once and restarts from a new baseline" {
    var tracker: Tracker = .{ .debounce_ns = 0 };
    defer tracker.deinit(std.testing.allocator);
    _ = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "a" }}), 0);

    const first = tracker.observeFailure();
    const repeated = tracker.observeFailure();
    const recovered = try tracker.observe(std.testing.allocator, try testSnapshot(&.{.{ .path = "b" }}), 10);
    const next = try tracker.observe(std.testing.allocator, try testSnapshot(&.{ .{ .path = "b" }, .{ .path = "c" } }), 20);

    try std.testing.expect(first);
    try std.testing.expect(!repeated);
    try std.testing.expect(recovered == null);
    try testExpectChanges(&.{.{ .kind = .created, .path = "c" }}, next);
    try std.testing.expect(tracker.observeFailure());
}

test "file_watch.Watcher: returns null for services without watch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try config.Config.parse(arena.allocator(),
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}]}
    , "/home/me");

    const watcher = try Watcher.init(std.testing.allocator, std.testing.io, cfg, try cfg.findService("api"));

    try std.testing.expect(watcher == null);
}

test "file_watch.Watcher: detects create update delete and atomic replace" {
    var project = try TestProject.init(
        \\{"exclude":["*.log"],"debounce_ms":0}
    );
    defer project.deinit();
    try project.write("src/a.txt", "1");
    try project.write("src/b.txt", "1");
    var watcher = try project.watcher();
    defer watcher.deinit();
    try std.testing.expect(try watcher.poll(0) == null);

    try project.write("src/a.txt", "22");
    try project.write("src/c.txt", "1");
    try project.tmp.dir.deleteFile(std.testing.io, "src/b.txt");
    const edited = try watcher.poll(1);
    try testExpectChanges(&.{
        .{ .kind = .modified, .path = "src/a.txt" },
        .{ .kind = .deleted, .path = "src/b.txt" },
        .{ .kind = .created, .path = "src/c.txt" },
    }, edited.?.changed);

    try project.write("src/.a.txt.tmp", "22");
    try project.tmp.dir.rename("src/.a.txt.tmp", project.tmp.dir, "src/a.txt", std.testing.io);
    const replaced = try watcher.poll(2);
    try testExpectChanges(&.{.{ .kind = .modified, .path = "src/a.txt" }}, replaced.?.changed);

    try project.write("logs/app.log", "line");
    try std.testing.expect(try watcher.poll(3) == null);
}

test "file_watch.Watcher: fails on a missing path until it appears" {
    var project = try TestProject.init(
        \\{"paths":["src"],"debounce_ms":0}
    );
    defer project.deinit();
    var watcher = try project.watcher();
    defer watcher.deinit();

    const missing = try watcher.poll(0);
    try std.testing.expectEqual(file_scan.FailureReason.missing, missing.?.failed.reason);
    try std.testing.expect(try watcher.poll(1) == null);

    try project.write("src/a.txt", "1");
    try std.testing.expect(try watcher.poll(2) == null);
    try project.write("src/b.txt", "1");
    const created = try watcher.poll(3);
    try testExpectChanges(&.{.{ .kind = .created, .path = "src/b.txt" }}, created.?.changed);
}
