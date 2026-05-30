const std = @import("std");

pub const Diagnostic = struct {
    path: []const u8,
    message: []const u8,
};

/// Collects user-facing config problems as `path / message` pairs so that
/// validation can report every issue at once instead of failing on the first.
/// Entries borrow the collector's allocator; callers use the same arena that
/// owns the parsed config, so nothing is freed individually.
pub const Diagnostics = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .gpa = gpa, .items = .empty };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.items.deinit(self.gpa);
    }

    pub fn add(self: *Diagnostics, path: []const u8, message: []const u8) !void {
        try self.items.append(self.gpa, .{ .path = path, .message = message });
    }

    pub fn addFmt(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.gpa, fmt, args);
        try self.items.append(self.gpa, .{ .path = path, .message = message });
    }

    pub fn isEmpty(self: Diagnostics) bool {
        return self.items.items.len == 0;
    }

    pub fn slice(self: Diagnostics) []const Diagnostic {
        return self.items.items;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "diagnostics.isEmpty: reports empty before first add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(arena.allocator());

    try std.testing.expect(diags.isEmpty());
}

test "diagnostics.add: accumulates path and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(arena.allocator());

    try diags.add("project.name", "required");
    try diags.add("groups[0].services[0].name", "must be an identifier");

    try std.testing.expect(!diags.isEmpty());
    try std.testing.expectEqual(@as(usize, 2), diags.slice().len);
    try std.testing.expectEqualStrings("project.name", diags.slice()[0].path);
    try std.testing.expectEqualStrings("required", diags.slice()[0].message);
    try std.testing.expectEqualStrings("groups[0].services[0].name", diags.slice()[1].path);
}

test "diagnostics.addFmt: formats message into arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = Diagnostics.init(arena.allocator());

    try diags.addFmt("docker.compose", "unknown key '{s}'", .{"extra"});

    try std.testing.expectEqualStrings("docker.compose", diags.slice()[0].path);
    try std.testing.expectEqualStrings("unknown key 'extra'", diags.slice()[0].message);
}
