const std = @import("std");
const builtin = @import("builtin");

/// Column count of the terminal behind `file`. null means the width is unknown
/// (not a terminal, unsupported platform, or a zero-sized report); callers
/// choose their own fallback.
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
