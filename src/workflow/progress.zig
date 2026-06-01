const std = @import("std");

pub const Line = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) Line {
        return .{ .writer = writer };
    }

    pub fn raw(self: *Line) *std.Io.Writer {
        return self.writer;
    }

    pub fn step(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
        try self.writer.flush();
    }

    pub fn info(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        try self.step(fmt, args);
    }

    pub fn warn(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        try self.step(fmt, args);
    }

    pub fn failContext(self: *Line) !void {
        _ = self;
    }

    pub fn finishSuccess(self: *Line) !void {
        _ = self;
    }

    pub fn finishError(self: *Line) !void {
        _ = self;
    }
};
