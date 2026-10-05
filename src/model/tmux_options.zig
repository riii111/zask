const std = @import("std");

pub const dash_mode = "@zask_dash_mode";
pub const zask_path = "@zask_path";
pub const config_path = "@zask_config_path";
// Pane option holding the Unix seconds of the last zask spawn of that pane.
pub const started_at = "@zask_started_at";
// Pane option holding what automatic recovery last did to that pane; see
// model/recovery.zig.
pub const recovery = "@zask_recovery";

// "bad" hides live rows, "all" shows every row; centralized so the monitor and
// the Ctrl+q m toggle binding stay on the same string values.
pub const dash_mode_all = "all";
pub const dash_mode_bad = "bad";

pub const DashMode = enum {
    all,
    bad,

    /// Unset or unknown values read as `all` so a stale option never hides rows.
    pub fn parse(value: ?[]const u8) DashMode {
        const text = value orelse return .all;
        return if (std.mem.eql(u8, text, dash_mode_bad)) .bad else .all;
    }

    pub fn optionValue(self: DashMode) []const u8 {
        return switch (self) {
            .all => dash_mode_all,
            .bad => dash_mode_bad,
        };
    }

    pub fn toggled(self: DashMode) DashMode {
        return switch (self) {
            .all => .bad,
            .bad => .all,
        };
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "DashMode.parse: falls back to all for unset or unknown values" {
    const cases = [_]struct { value: ?[]const u8, expected: DashMode }{
        .{ .value = null, .expected = .all },
        .{ .value = "all", .expected = .all },
        .{ .value = "bad", .expected = .bad },
        .{ .value = "BAD", .expected = .all },
        .{ .value = "", .expected = .all },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, DashMode.parse(case.value));
}

test "DashMode.toggled: round-trips through the option value" {
    try std.testing.expectEqual(DashMode.bad, DashMode.parse(DashMode.all.toggled().optionValue()));
    try std.testing.expectEqual(DashMode.all, DashMode.parse(DashMode.bad.toggled().optionValue()));
}
