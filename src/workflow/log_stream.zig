const std = @import("std");
const stream = @import("../platform/log_stream.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, path: []const u8, token: []const u8) !void {
    return stream.run(gpa, io, path, token);
}
