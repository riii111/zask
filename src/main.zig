const std = @import("std");
const zask = @import("zask");

pub fn main(init: std.process.Init) !void {
    try zask.cli.run(init);
}

test "main: runs default command" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try zask.cli.runWithArgs(.{ .gpa = std.testing.allocator }, &.{}, &writer);
    try std.testing.expectEqualStrings("Hello from zask\n", writer.buffered());
}
