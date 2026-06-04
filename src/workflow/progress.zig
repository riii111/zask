const std = @import("std");

/// Non-TTY implementation of the progress surface used by workflow code.
/// Keep this method set in sync with the CLI TTY renderer.
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

    pub fn focus(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub fn command(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub fn status(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        try self.step(fmt, args);
    }

    pub fn detail(self: *Line, lines: []const []const u8) !void {
        _ = self;
        _ = lines;
    }

    pub fn warn(self: *Line, comptime fmt: []const u8, args: anytype) !void {
        try self.step(fmt, args);
    }

    pub fn warnContext(self: *Line) !void {
        _ = self;
    }

    pub fn beforeInteractive(self: *Line) !void {
        try self.writer.flush();
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
