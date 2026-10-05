const std = @import("std");
const posix = std.posix;

pub const stdin: posix.fd_t = posix.STDIN_FILENO;
pub const stdout: posix.fd_t = posix.STDOUT_FILENO;

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const Readiness = enum {
    input,
    timeout,
    closed,
};

pub const RawMode = struct {
    fd: posix.fd_t,
    original: posix.termios,

    pub fn enter(fd: posix.fd_t) !?RawMode {
        const original = posix.tcgetattr(fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .original = original };
    }

    pub fn restore(self: RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.original) catch {};
    }
};

pub fn waitReadable(fd: posix.fd_t, timeout_ms: i32) !Readiness {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    if (try posix.poll(&fds, timeout_ms) == 0) return .timeout;
    if (fds[0].revents & posix.POLL.IN != 0) return .input;
    return .closed;
}

pub fn read(fd: posix.fd_t, buffer: []u8) !usize {
    return posix.read(fd, buffer);
}

pub fn discardInput(fd: posix.fd_t) void {
    var buffer: [256]u8 = undefined;
    while (true) {
        const readiness = waitReadable(fd, 0) catch return;
        if (readiness != .input) return;
        const len = read(fd, &buffer) catch return;
        if (len == 0) return;
    }
}

pub fn size(fd: posix.fd_t) ?Size {
    var ws: posix.winsize = undefined;
    const request: c_int = @bitCast(@as(u32, @truncate(@as(usize, std.c.T.IOCGWINSZ))));
    if (std.c.ioctl(fd, request, &ws) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

const builtin = @import("builtin");

pub fn columns(io: std.Io, file: std.Io.File) ?usize {
    if (builtin.os.tag == .windows) return null;
    var winsize: std.c.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const result = io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.c.T.IOCGWINSZ,
        .arg = &winsize,
    } }) catch return null;
    if (result.device_io_control < 0 or winsize.col == 0) return null;
    return winsize.col;
}
