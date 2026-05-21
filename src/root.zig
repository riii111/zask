const std = @import("std");

pub const cli = @import("cli.zig");

pub fn greeting() []const u8 {
    return "Hello from zask";
}

test "greeting returns the hello world message" {
    try std.testing.expectEqualStrings("Hello from zask", greeting());
}
