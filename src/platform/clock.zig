const std = @import("std");

pub const ClockTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn localClockTime(epoch_seconds: i64) ?ClockTime {
    const t: std.c.time_t = std.math.cast(std.c.time_t, epoch_seconds) orelse return null;
    var parts: Tm = undefined;
    _ = localtime_r(&t, &parts) orelse return null;
    return .{
        .hour = std.math.cast(u8, parts.tm_hour) orelse return null,
        .minute = std.math.cast(u8, parts.tm_min) orelse return null,
        .second = std.math.cast(u8, parts.tm_sec) orelse return null,
    };
}

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

extern "c" fn localtime_r(timer: *const std.c.time_t, result: *Tm) ?*Tm;

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "clock.localClockTime: keeps seconds of the timestamp" {
    const time = localClockTime(1_700_000_042) orelse return error.MissingLocalTime;

    try std.testing.expect(time.hour < 24);
    try std.testing.expect(time.minute < 60);
    try std.testing.expectEqual(@as(u8, 2), time.second);
}
