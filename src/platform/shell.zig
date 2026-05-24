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

test "quotes shell strings" {
    const simple = try quote(std.testing.allocator, "abc");
    defer std.testing.allocator.free(simple);
    try std.testing.expectEqualStrings("'abc'", simple);
    const value = try quote(std.testing.allocator, "a'b");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("'a'\\''b'", value);
}

test "quotes shell edge cases" {
    const empty = try quote(std.testing.allocator, "");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("''", empty);

    const newline = try quote(std.testing.allocator, "a\nb");
    defer std.testing.allocator.free(newline);
    try std.testing.expectEqualStrings("'a\nb'", newline);

    const variable = try quote(std.testing.allocator, "$HOME");
    defer std.testing.allocator.free(variable);
    try std.testing.expectEqualStrings("'$HOME'", variable);

    const adjacent_quotes = try quote(std.testing.allocator, "''");
    defer std.testing.allocator.free(adjacent_quotes);
    try std.testing.expectEqualStrings("''\\'''\\'''", adjacent_quotes);
}
