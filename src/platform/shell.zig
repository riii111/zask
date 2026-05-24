const std = @import("std");

pub fn quote(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("'\\''");
        } else {
            try out.writer.writeByte(byte);
        }
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "quote wraps shell strings in single quotes" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "abc", .expected = "'abc'" },
        .{ .input = "a'b", .expected = "'a'\\''b'" },
        .{ .input = "", .expected = "''" },
        .{ .input = "a\nb", .expected = "'a\nb'" },
        .{ .input = "$HOME", .expected = "'$HOME'" },
        .{ .input = "''", .expected = "''\\'''\\'''" },
    };

    for (cases) |case| {
        const value = try quote(std.testing.allocator, case.input);
        defer std.testing.allocator.free(value);

        try std.testing.expectEqualStrings(case.expected, value);
    }
}
