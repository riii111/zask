const std = @import("std");

const max_name_len = 64;

pub fn closest(value: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (value.len == 0 or value.len > max_name_len) return null;
    const limit = maxDistance(value.len);
    var best: ?[]const u8 = null;
    var best_distance: usize = limit + 1;
    var tied = false;
    for (candidates) |candidate| {
        if (candidate.len > max_name_len or std.mem.eql(u8, candidate, value)) continue;
        const distance = editDistance(value, candidate);
        if (distance > limit) continue;
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
            tied = false;
        } else if (distance == best_distance and !std.mem.eql(u8, best.?, candidate)) {
            tied = true;
        }
    }
    return if (tied) null else best;
}

fn maxDistance(len: usize) usize {
    return if (len <= 4) 1 else 2;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    var rows: [3][max_name_len + 1]usize = undefined;
    var prev2 = &rows[0];
    var prev = &rows[1];
    var current = &rows[2];
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |a_byte, i| {
        current[0] = i;
        for (b, 1..) |b_byte, j| {
            const cost: usize = if (sameLetter(a_byte, b_byte)) 0 else 1;
            var distance = @min(prev[j] + 1, current[j - 1] + 1, prev[j - 1] + cost);
            if (i > 1 and j > 1 and sameLetter(a_byte, b[j - 2]) and sameLetter(a[i - 2], b_byte))
                distance = @min(distance, prev2[j - 2] + 1);
            current[j] = distance;
        }
        const recycled = prev2;
        prev2 = prev;
        prev = current;
        current = recycled;
    }
    return prev[b.len];
}

fn sameLetter(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "suggest.closest: returns near candidates for typos" {
    const candidates = [_][]const u8{ "name", "command", "dir", "port", "env_file", "healthcheck" };
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "comand", .expected = "command" },
        .{ .input = "prot", .expected = "port" },
        .{ .input = "Name", .expected = "name" },
        .{ .input = "envfile", .expected = "env_file" },
        .{ .input = "helthchek", .expected = "healthcheck" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, closest(case.input, &candidates).?);
    }
}

test "suggest.closest: returns null for distant or ambiguous input" {
    const candidates = [_][]const u8{ "api", "app", "worker" };
    const cases = [_][]const u8{
        "",
        "frontend",
        "apx",
        "ap",
    };
    for (cases) |case| {
        try std.testing.expect(closest(case, &candidates) == null);
    }
}

test "suggest.closest: allows only one edit for short names" {
    const candidates = [_][]const u8{"dir"};

    try std.testing.expect(closest("dr", &candidates) != null);
    try std.testing.expect(closest("x", &candidates) == null);
}
