const std = @import("std");
const observations = @import("observations.zig");

pub const Kind = enum {
    waiting,
    restarted,
    gave_up,
    unconfirmed,
};

pub const Record = struct {
    kind: Kind,
    pid: ?i64 = null,
    attempt: u32,
    max_retries: u32,
    exit: observations.PaneExit,

    pub fn encode(self: Record, gpa: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.print("{s},", .{@tagName(self.kind)});
        if (self.pid) |pid| try out.writer.print("{d}", .{pid});
        try out.writer.print(",{d},{d},", .{ self.attempt, self.max_retries });
        switch (self.exit) {
            .failed => |status| try out.writer.print("{d}", .{status}),
            .clean, .interrupted, .killed => try out.writer.writeAll(killed_text),
        }
        return out.toOwnedSlice();
    }
};

pub const RecordObservation = union(enum) {
    none,
    malformed,
    record: Record,
};

pub fn parse(value: []const u8) RecordObservation {
    if (value.len == 0) return .none;
    var fields = std.mem.splitScalar(u8, value, ',');
    const kind = std.meta.stringToEnum(Kind, fields.next() orelse return .malformed) orelse return .malformed;
    const pid_text = fields.next() orelse return .malformed;
    const pid: ?i64 = if (pid_text.len == 0) null else std.fmt.parseInt(i64, pid_text, 10) catch return .malformed;
    const attempt = std.fmt.parseInt(u32, fields.next() orelse return .malformed, 10) catch return .malformed;
    const max_retries = std.fmt.parseInt(u32, fields.next() orelse return .malformed, 10) catch return .malformed;
    const exit_text = fields.next() orelse return .malformed;
    if (fields.next() != null) return .malformed;
    const exit: observations.PaneExit = if (std.mem.eql(u8, exit_text, killed_text))
        .killed
    else
        .{ .failed = std.fmt.parseInt(u32, exit_text, 10) catch return .malformed };
    if ((kind == .restarted) != (pid == null)) return .malformed;
    return .{ .record = .{ .kind = kind, .pid = pid, .attempt = attempt, .max_retries = max_retries, .exit = exit } };
}

const killed_text = "killed";

pub const View = union(enum) {
    not_configured,
    unknown,
    none: u32,
    restarted: Record,
    waiting: Record,
    gave_up: Record,
};

pub fn view(max_retries: ?u32, pane: observations.PaneState, pane_pid: ?i64, record: RecordObservation) View {
    const max = max_retries orelse return .not_configured;
    if (pane == .tmux_unavailable) return .unknown;
    const current = switch (record) {
        .none => return .{ .none = max },
        .malformed => return .unknown,
        .record => |value| value,
    };
    return switch (current.kind) {
        .restarted => if (pane == .busy) .{ .restarted = current } else .{ .none = max },
        .waiting, .gave_up, .unconfirmed => {
            if (pane != .dead or pane_pid == null or current.pid != pane_pid) return .{ .none = max };
            return switch (current.kind) {
                .waiting => .{ .waiting = current },
                .gave_up => .{ .gave_up = current },
                .unconfirmed => .unknown,
                .restarted => unreachable,
            };
        },
    };
}

pub const ExitText = struct {
    exit: observations.PaneExit,

    pub fn format(self: ExitText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.exit) {
            .clean => try writer.writeAll("exited with status 0"),
            .interrupted => try writer.writeAll("was interrupted"),
            .failed => |status| try writer.print("exited with status {d}", .{status}),
            .killed => try writer.writeAll("was killed"),
        }
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "recovery.Record: encode round-trips through parse" {
    const cases = [_]Record{
        .{ .kind = .waiting, .pid = 123, .attempt = 1, .max_retries = 3, .exit = .{ .failed = 2 } },
        .{ .kind = .restarted, .attempt = 2, .max_retries = 3, .exit = .killed },
        .{ .kind = .gave_up, .pid = 9, .attempt = 3, .max_retries = 3, .exit = .{ .failed = 137 } },
        .{ .kind = .unconfirmed, .pid = 9, .attempt = 0, .max_retries = 3, .exit = .{ .failed = 1 } },
    };

    for (cases) |case| {
        const encoded = try case.encode(std.testing.allocator);
        defer std.testing.allocator.free(encoded);

        try std.testing.expectEqualDeep(RecordObservation{ .record = case }, parse(encoded));
    }
}

test "recovery.Record.encode: writes the option value" {
    const encoded = try (Record{ .kind = .waiting, .pid = 123, .attempt = 1, .max_retries = 3, .exit = .{ .failed = 2 } }).encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("waiting,123,1,3,2", encoded);
}

test "recovery.parse: rejects values zask does not write" {
    const cases = [_][]const u8{
        "waiting",
        "waiting,123,1,3",
        "waiting,123,1,3,2,extra",
        "resting,123,1,3,2",
        "waiting,abc,1,3,2",
        "waiting,,1,3,2",
        "restarted,123,1,3,2",
        "waiting,123,-1,3,2",
        "waiting,123,1,3,segv",
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case});
        try std.testing.expectEqual(RecordObservation.malformed, parse(case));
    }
}

test "recovery.parse: reads an unset option as no record" {
    try std.testing.expectEqual(RecordObservation.none, parse(""));
}

test "recovery.view: shows a record only for the run it describes" {
    const waiting: Record = .{ .kind = .waiting, .pid = 100, .attempt = 1, .max_retries = 3, .exit = .{ .failed = 1 } };
    const restarted: Record = .{ .kind = .restarted, .attempt = 2, .max_retries = 3, .exit = .{ .failed = 1 } };
    const gave_up: Record = .{ .kind = .gave_up, .pid = 100, .attempt = 3, .max_retries = 3, .exit = .killed };
    const unconfirmed: Record = .{ .kind = .unconfirmed, .pid = 100, .attempt = 0, .max_retries = 3, .exit = .{ .failed = 1 } };
    const cases = [_]struct {
        name: []const u8,
        max: ?u32 = 3,
        pane: observations.PaneState,
        pid: ?i64 = 100,
        record: RecordObservation,
        want: View,
    }{
        .{ .name = "not configured", .max = null, .pane = .dead, .record = .{ .record = gave_up }, .want = .not_configured },
        .{ .name = "tmux unavailable", .pane = .tmux_unavailable, .record = .none, .want = .unknown },
        .{ .name = "malformed", .pane = .busy, .record = .malformed, .want = .unknown },
        .{ .name = "no record yet", .pane = .busy, .record = .none, .want = .{ .none = 3 } },
        .{ .name = "recovered run running", .pane = .busy, .pid = 200, .record = .{ .record = restarted }, .want = .{ .restarted = restarted } },
        .{ .name = "recovered run stopped by hand", .pane = .idle, .record = .{ .record = restarted }, .want = .{ .none = 3 } },
        .{ .name = "recovered run exited", .pane = .dead, .record = .{ .record = restarted }, .want = .{ .none = 3 } },
        .{ .name = "waiting for delay", .pane = .dead, .record = .{ .record = waiting }, .want = .{ .waiting = waiting } },
        .{ .name = "waiting of an earlier run", .pane = .dead, .pid = 200, .record = .{ .record = waiting }, .want = .{ .none = 3 } },
        .{ .name = "waiting but started again", .pane = .busy, .record = .{ .record = waiting }, .want = .{ .none = 3 } },
        .{ .name = "gave up", .pane = .dead, .record = .{ .record = gave_up }, .want = .{ .gave_up = gave_up } },
        .{ .name = "gave up, pid unknown", .pane = .dead, .pid = null, .record = .{ .record = gave_up }, .want = .{ .none = 3 } },
        .{ .name = "gave up of an earlier run", .pane = .dead, .pid = 200, .record = .{ .record = gave_up }, .want = .{ .none = 3 } },
        .{ .name = "stop record unreadable", .pane = .dead, .record = .{ .record = unconfirmed }, .want = .unknown },
        .{ .name = "window closed", .pane = .window_missing, .record = .none, .want = .{ .none = 3 } },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expectEqualDeep(case.want, view(case.max, case.pane, case.pid, case.record));
    }
}
