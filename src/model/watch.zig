//! File watch settings for a service and the path filter derived from them.
//!
//! Patterns follow the gitignore convention: a pattern without `/` matches the
//! last path component at any depth (`*.log`, `node_modules`); a pattern with
//! `/` matches the whole path relative to the watched path (`build/**`). A
//! trailing `/` is ignored. `*` and `?` stay within one component and `**`
//! spans any number of components.

const std = @import("std");

pub const default_paths = [_][]const u8{"."};
pub const default_debounce_ms: u64 = 300;

/// Version-control metadata changes on every `git status`; watching it would
/// restart services without any source change.
pub const builtin_excludes = [_][]const u8{ ".git", ".hg", ".svn" };

pub const Spec = struct {
    paths: []const []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    debounce_ms: u64,

    /// Frees the outer slices only; the strings are borrowed from the config.
    pub fn deinit(self: Spec, gpa: std.mem.Allocator) void {
        gpa.free(self.paths);
        gpa.free(self.include);
        gpa.free(self.exclude);
    }

    /// Excluded directories are not descended into.
    pub fn skipsDir(self: Spec, rel_path: []const u8) bool {
        return self.excludes(rel_path);
    }

    pub fn watchesFile(self: Spec, rel_path: []const u8) bool {
        if (self.excludes(rel_path)) return false;
        if (self.include.len == 0) return true;
        return matchesAny(self.include, rel_path);
    }

    fn excludes(self: Spec, rel_path: []const u8) bool {
        return matchesAny(&builtin_excludes, rel_path) or matchesAny(self.exclude, rel_path);
    }
};

pub const PatternError = error{
    EmptyPattern,
    AbsolutePattern,
    ParentPattern,
};

pub fn checkPattern(pattern: []const u8) PatternError!void {
    const trimmed = trimTrailingSlash(pattern);
    if (trimmed.len == 0) return error.EmptyPattern;
    if (trimmed[0] == '/') return error.AbsolutePattern;
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.ParentPattern;
    }
}

pub fn patternMessage(err: PatternError) []const u8 {
    return switch (err) {
        error.EmptyPattern => "must not be empty",
        error.AbsolutePattern => "must be relative to the watched path",
        error.ParentPattern => "must not contain '..'",
    };
}

/// `rel_path` uses `/` separators and is relative to the watched path.
pub fn matches(pattern: []const u8, rel_path: []const u8) bool {
    const trimmed = trimTrailingSlash(pattern);
    if (std.mem.indexOfScalar(u8, trimmed, '/') == null) {
        return matchComponent(trimmed, std.fs.path.basenamePosix(rel_path));
    }
    return matchComponents(trimmed, rel_path);
}

fn matchesAny(patterns: []const []const u8, rel_path: []const u8) bool {
    for (patterns) |pattern| {
        if (matches(pattern, rel_path)) return true;
    }
    return false;
}

fn trimTrailingSlash(pattern: []const u8) []const u8 {
    return std.mem.trimEnd(u8, pattern, "/");
}

fn matchComponents(pattern: []const u8, path: []const u8) bool {
    const pattern_head, const pattern_rest = splitFirst(pattern);
    if (std.mem.eql(u8, pattern_head, "**")) {
        if (pattern_rest == null) return true;
        if (matchComponents(pattern_rest.?, path)) return true;
        const path_rest = splitFirst(path)[1] orelse return false;
        return matchComponents(pattern, path_rest);
    }
    const path_head, const path_rest = splitFirst(path);
    if (!matchComponent(pattern_head, path_head)) return false;
    if (pattern_rest == null and path_rest == null) return true;
    if (pattern_rest == null) return false;
    // `dir/**` also matches `dir` itself so the directory can be pruned.
    if (path_rest == null) return std.mem.eql(u8, pattern_rest.?, "**");
    return matchComponents(pattern_rest.?, path_rest.?);
}

fn splitFirst(value: []const u8) struct { []const u8, ?[]const u8 } {
    const index = std.mem.indexOfScalar(u8, value, '/') orelse return .{ value, null };
    return .{ value[0..index], value[index + 1 ..] };
}

fn matchComponent(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testSpec(include: []const []const u8, exclude: []const []const u8) Spec {
    return .{ .paths = &default_paths, .include = include, .exclude = exclude, .debounce_ms = default_debounce_ms };
}

test "watch.matches: applies gitignore-style patterns" {
    const cases = [_]struct {
        pattern: []const u8,
        path: []const u8,
        want: bool,
    }{
        .{ .pattern = "*.log", .path = "app.log", .want = true },
        .{ .pattern = "*.log", .path = "logs/deep/app.log", .want = true },
        .{ .pattern = "*.log", .path = "app.log.txt", .want = false },
        .{ .pattern = "node_modules", .path = "web/node_modules", .want = true },
        .{ .pattern = "target/", .path = "crates/a/target", .want = true },
        .{ .pattern = "src/*.rs", .path = "src/main.rs", .want = true },
        .{ .pattern = "src/*.rs", .path = "src/bin/main.rs", .want = false },
        .{ .pattern = "src/*.rs", .path = "lib/src/main.rs", .want = false },
        .{ .pattern = "src/**/*.rs", .path = "src/main.rs", .want = true },
        .{ .pattern = "src/**/*.rs", .path = "src/bin/tool/main.rs", .want = true },
        .{ .pattern = "build/**", .path = "build", .want = true },
        .{ .pattern = "build/**", .path = "build/out/app.js", .want = true },
        .{ .pattern = "build/**", .path = "src/build/app.js", .want = false },
        .{ .pattern = "**/gen/*.go", .path = "a/b/gen/x.go", .want = true },
        .{ .pattern = "file?.txt", .path = "file1.txt", .want = true },
        .{ .pattern = "file?.txt", .path = "file10.txt", .want = false },
        .{ .pattern = "*", .path = "src/main.rs", .want = true },
    };

    for (cases) |case| {
        errdefer std.debug.print("pattern={s} path={s}\n", .{ case.pattern, case.path });
        try std.testing.expectEqual(case.want, matches(case.pattern, case.path));
    }
}

test "watch.Spec: excludes win over includes and prune directories" {
    const spec = testSpec(&.{"*.rs"}, &.{ "target", "src/gen/**" });

    try std.testing.expect(spec.watchesFile("src/main.rs"));
    try std.testing.expect(!spec.watchesFile("README.md"));
    try std.testing.expect(!spec.watchesFile("src/gen/schema.rs"));
    try std.testing.expect(spec.skipsDir("target"));
    try std.testing.expect(spec.skipsDir("src/gen"));
    try std.testing.expect(!spec.skipsDir("src"));
}

test "watch.Spec: skips version control directories by default" {
    const spec = testSpec(&.{}, &.{});

    try std.testing.expect(spec.skipsDir(".git"));
    try std.testing.expect(spec.skipsDir("vendor/lib/.git"));
    try std.testing.expect(spec.watchesFile(".gitignore"));
}

test "watch.checkPattern: rejects empty absolute and parent patterns" {
    const cases = [_]struct {
        pattern: []const u8,
        want: PatternError,
    }{
        .{ .pattern = "", .want = error.EmptyPattern },
        .{ .pattern = "/", .want = error.EmptyPattern },
        .{ .pattern = "/tmp/*.log", .want = error.AbsolutePattern },
        .{ .pattern = "../shared/**", .want = error.ParentPattern },
        .{ .pattern = "src/../x", .want = error.ParentPattern },
    };

    for (cases) |case| {
        try std.testing.expectError(case.want, checkPattern(case.pattern));
    }
    try checkPattern("src/**/*.rs");
    try checkPattern("target/");
}
