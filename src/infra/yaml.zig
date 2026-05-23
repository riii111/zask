const std = @import("std");

pub fn quote(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("''");
        } else {
            try out.writer.writeByte(byte);
        }
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

test "quotes yaml single quoted scalars" {
    const value = try quote(std.testing.allocator, "'zask path' --config '/tmp/demo config.json' dashboard");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("'''zask path'' --config ''/tmp/demo config.json'' dashboard'", value);
}
