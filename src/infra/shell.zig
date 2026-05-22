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

test "quotes shell strings" {
    const simple = try quote(std.testing.allocator, "abc");
    defer std.testing.allocator.free(simple);
    try std.testing.expectEqualStrings("'abc'", simple);
    const value = try quote(std.testing.allocator, "a'b");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("'a'\\''b'", value);
}
