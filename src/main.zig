const std = @import("std");
const zask = @import("zask");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("{s}\n", .{zask.greeting()});
    try stdout.flush();
}

test "prints the greeting text" {
    try std.testing.expectEqualStrings("Hello from zask", zask.greeting());
}
