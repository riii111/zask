//! Key input and size queries for the terminal the monitor runs in.
//!
//! termios, poll, and TIOCGWINSZ have no std.Io equivalent in Zig 0.16, so this
//! adapter is the one place that calls std.posix / libc directly for them.

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
    /// The terminal hung up or the descriptor is no longer readable.
    closed,
};

/// Non-canonical, no-echo, no-signal mode for single-key input.
pub const RawMode = struct {
    fd: posix.fd_t,
    original: posix.termios,

    /// Returns null when `fd` is not a terminal; callers then run without key input.
    /// The returned mode must be released with `restore`.
    pub fn enter(fd: posix.fd_t) !?RawMode {
        const original = posix.tcgetattr(fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        // Ctrl+C arrives as a byte so the caller can restore the terminal before exiting.
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .original = original };
    }

    /// Restores only the termios captured by `enter`. Screen contents, cursor
    /// visibility, and the alternate screen are left to the caller.
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

/// Returns 0 at end of input.
pub fn read(fd: posix.fd_t, buffer: []u8) !usize {
    return posix.read(fd, buffer);
}

/// Drops input already typed but not yet read, so keys pressed while the
/// caller was blocked are not acted on afterwards.
pub fn discardInput(fd: posix.fd_t) void {
    var buffer: [256]u8 = undefined;
    while (true) {
        const readiness = waitReadable(fd, 0) catch return;
        if (readiness != .input) return;
        const len = read(fd, &buffer) catch return;
        if (len == 0) return;
    }
}

/// Returns null when `fd` is not a terminal or reports a zero size.
pub fn size(fd: posix.fd_t) ?Size {
    var ws: posix.winsize = undefined;
    const request: c_int = @bitCast(@as(u32, @truncate(@as(usize, std.c.T.IOCGWINSZ))));
    if (std.c.ioctl(fd, request, &ws) != 0) return null;
    if (ws.col == 0 or ws.row == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}
