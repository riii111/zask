const std = @import("std");

pub const Direction = enum { up, down };

/// Remembers the selected row by name so refreshes and filter changes never
/// move the selection onto a different service. When the selected row is
/// hidden, nothing is highlighted until the user moves again.
pub const Selection = struct {
    /// Owned by the allocator passed to `move` / `track`; freed by `deinit`.
    name: ?[]u8 = null,
    /// Last visible position of `name`, used to pick a nearby row after it is hidden.
    index: usize = 0,

    /// Safe on the default empty value.
    pub fn deinit(self: *Selection, gpa: std.mem.Allocator) void {
        if (self.name) |name| gpa.free(name);
        self.* = .{};
    }

    /// Returns the visible position of the selected row, or null when it is hidden.
    pub fn position(self: Selection, names: []const []const u8) ?usize {
        const name = self.name orelse return null;
        for (names, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) return i;
        }
        return null;
    }

    /// Selects the first row when nothing was ever selected, and records the
    /// current position of a visible selection. A hidden selection is kept.
    pub fn track(self: *Selection, gpa: std.mem.Allocator, names: []const []const u8) !void {
        if (self.name == null) {
            if (names.len > 0) try self.select(gpa, names, 0);
            return;
        }
        if (self.position(names)) |i| self.index = i;
    }

    /// Moves within the visible rows without wrapping. A hidden selection
    /// lands on the row now at its last position.
    pub fn move(self: *Selection, gpa: std.mem.Allocator, names: []const []const u8, direction: Direction) !void {
        if (names.len == 0) return;
        const target = if (self.position(names)) |current| switch (direction) {
            .up => current -| 1,
            .down => @min(current + 1, names.len - 1),
        } else @min(self.index, names.len - 1);
        try self.select(gpa, names, target);
    }

    fn select(self: *Selection, gpa: std.mem.Allocator, names: []const []const u8, i: usize) !void {
        const owned = try gpa.dupe(u8, names[i]);
        if (self.name) |name| gpa.free(name);
        self.name = owned;
        self.index = i;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testSelectionAt(name: []const u8, index: usize) !Selection {
    return .{ .name = try std.testing.allocator.dupe(u8, name), .index = index };
}

test "Selection.deinit: empty selection is a no-op" {
    var selection: Selection = .{};

    selection.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?[]u8, null), selection.name);
}

test "Selection.track: selects the first row once" {
    var selection: Selection = .{};
    defer selection.deinit(std.testing.allocator);

    try selection.track(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(?[]u8, null), selection.name);
    try selection.track(std.testing.allocator, &.{ "api", "web" });

    try std.testing.expectEqualStrings("api", selection.name.?);
}

test "Selection.track: keeps the selected name when rows reorder or hide it" {
    var selection = try testSelectionAt("web", 1);
    defer selection.deinit(std.testing.allocator);

    try selection.track(std.testing.allocator, &.{ "web", "api" });
    try std.testing.expectEqualStrings("web", selection.name.?);
    try std.testing.expectEqual(@as(usize, 0), selection.index);

    try selection.track(std.testing.allocator, &.{"api"});
    try std.testing.expectEqualStrings("web", selection.name.?);
    try std.testing.expectEqual(@as(?usize, null), selection.position(&.{"api"}));
}

test "Selection.move: steps through visible rows without wrapping" {
    const names = [_][]const u8{ "docker", "api", "web" };
    const cases = [_]struct { from: []const u8, direction: Direction, expected: []const u8 }{
        .{ .from = "api", .direction = .down, .expected = "web" },
        .{ .from = "api", .direction = .up, .expected = "docker" },
        .{ .from = "web", .direction = .down, .expected = "web" },
        .{ .from = "docker", .direction = .up, .expected = "docker" },
    };
    for (cases) |case| {
        var selection = try testSelectionAt(case.from, 0);
        defer selection.deinit(std.testing.allocator);

        try selection.move(std.testing.allocator, &names, case.direction);

        try std.testing.expectEqualStrings(case.expected, selection.name.?);
    }
}

test "Selection.move: hidden selection lands on the row at its last position" {
    const cases = [_]struct { index: usize, direction: Direction, expected: []const u8 }{
        .{ .index = 1, .direction = .down, .expected = "worker" },
        .{ .index = 1, .direction = .up, .expected = "worker" },
        .{ .index = 5, .direction = .down, .expected = "worker" },
    };
    for (cases) |case| {
        var selection = try testSelectionAt("web", case.index);
        defer selection.deinit(std.testing.allocator);

        try selection.move(std.testing.allocator, &.{ "api", "worker" }, case.direction);

        try std.testing.expectEqualStrings(case.expected, selection.name.?);
    }
}

test "Selection.move: empty list keeps the selection" {
    var selection = try testSelectionAt("api", 0);
    defer selection.deinit(std.testing.allocator);

    try selection.move(std.testing.allocator, &.{}, .down);

    try std.testing.expectEqualStrings("api", selection.name.?);
}
