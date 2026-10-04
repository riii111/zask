const std = @import("std");

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    escape,
    ctrl_c,
    unknown,
};

/// Decodes the keys contained in one raw terminal read. Several keys can share
/// a read (key repeat, paste), so the caller drains the iterator.
pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ?Key {
        if (self.index >= self.bytes.len) return null;
        const decoded = decode(self.bytes[self.index..]);
        self.index += decoded.len;
        return decoded.key;
    }
};

const Decoded = struct {
    key: Key,
    len: usize,
};

fn decode(bytes: []const u8) Decoded {
    const byte = bytes[0];
    return switch (byte) {
        0x03 => .{ .key = .ctrl_c, .len = 1 },
        '\r', '\n' => .{ .key = .enter, .len = 1 },
        0x1b => decodeEscape(bytes),
        0x20...0x7e => .{ .key = .{ .char = byte }, .len = 1 },
        else => .{ .key = .unknown, .len = 1 },
    };
}

// CSI (`ESC [`) and SS3 (`ESC O`) cover arrow keys in both normal and
// application cursor modes. Other sequences are consumed whole so their
// parameter bytes are not misread as separate key presses.
fn decodeEscape(bytes: []const u8) Decoded {
    if (bytes.len < 2 or (bytes[1] != '[' and bytes[1] != 'O')) return .{ .key = .escape, .len = 1 };
    var end: usize = 2;
    while (end < bytes.len) : (end += 1) {
        const final = bytes[end];
        if (final < 0x40 or final > 0x7e) continue;
        const key: Key = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .unknown,
        };
        return .{ .key = key, .len = end + 1 };
    }
    return .{ .key = .unknown, .len = bytes.len };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testExpectKeys(input: []const u8, expected: []const Key) !void {
    var keys: Iterator = .{ .bytes = input };
    for (expected) |key| try std.testing.expectEqual(key, keys.next() orelse return error.MissingKey);
    try std.testing.expectEqual(@as(?Key, null), keys.next());
}

test "keys.Iterator: decodes single keys" {
    const cases = [_]struct { input: []const u8, key: Key }{
        .{ .input = "j", .key = .{ .char = 'j' } },
        .{ .input = "\x1b[A", .key = .up },
        .{ .input = "\x1b[B", .key = .down },
        .{ .input = "\x1bOA", .key = .up },
        .{ .input = "\x1bOB", .key = .down },
        .{ .input = "\x1b[C", .key = .right },
        .{ .input = "\x1b[D", .key = .left },
        .{ .input = "\r", .key = .enter },
        .{ .input = "\x03", .key = .ctrl_c },
        .{ .input = "\x1b", .key = .escape },
        .{ .input = "\x7f", .key = .unknown },
    };
    for (cases) |case| try testExpectKeys(case.input, &.{case.key});
}

test "keys.Iterator: splits repeated keys from one read" {
    try testExpectKeys("jj\x1b[Ak", &.{ .{ .char = 'j' }, .{ .char = 'j' }, .up, .{ .char = 'k' } });
}

test "keys.Iterator: consumes unknown sequences without leaking parameter bytes" {
    try testExpectKeys("\x1b[1;5Aq", &.{ .up, .{ .char = 'q' } });
    try testExpectKeys("\x1b[3~j", &.{ .unknown, .{ .char = 'j' } });
    try testExpectKeys("\x1b[12", &.{.unknown});
}
