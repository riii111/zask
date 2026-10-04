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

/// Buffers raw terminal reads and yields keys. One read can hold several keys
/// (key repeat, paste), and one escape sequence can arrive split across reads,
/// so an incomplete sequence stays pending until more bytes arrive or the
/// caller gives up waiting and calls `flush`.
pub const Decoder = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    /// Free space for the next read; pass the byte count to `commit`.
    pub fn space(self: *Decoder) []u8 {
        // A pending sequence that fills the buffer can never complete.
        if (self.len == self.buffer.len) self.len = 0;
        return self.buffer[self.len..];
    }

    pub fn commit(self: *Decoder, count: usize) void {
        self.len += count;
    }

    pub fn pending(self: Decoder) bool {
        return self.len > 0;
    }

    /// Returns null when no bytes remain or only an incomplete sequence is pending.
    pub fn next(self: *Decoder) ?Key {
        if (self.len == 0) return null;
        const decoded = decode(self.buffer[0..self.len]) orelse return null;
        self.consume(decoded.len);
        return decoded.key;
    }

    /// Decodes a pending incomplete sequence as-is: a lone ESC is the Escape key,
    /// a cut-off CSI / SS3 sequence is unknown.
    pub fn flush(self: *Decoder) ?Key {
        if (self.len == 0) return null;
        const key: Key = if (self.len == 1) .escape else .unknown;
        self.len = 0;
        return key;
    }

    fn consume(self: *Decoder, count: usize) void {
        std.mem.copyForwards(u8, self.buffer[0 .. self.len - count], self.buffer[count..self.len]);
        self.len -= count;
    }
};

const Decoded = struct {
    key: Key,
    len: usize,
};

/// Returns null when `bytes` ends inside an escape sequence.
fn decode(bytes: []const u8) ?Decoded {
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
fn decodeEscape(bytes: []const u8) ?Decoded {
    if (bytes.len < 2) return null;
    if (bytes[1] != '[' and bytes[1] != 'O') return .{ .key = .escape, .len = 1 };
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
    return null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testFeed(decoder: *Decoder, bytes: []const u8) void {
    @memcpy(decoder.space()[0..bytes.len], bytes);
    decoder.commit(bytes.len);
}

fn testExpectKeys(input: []const u8, expected: []const Key) !void {
    var decoder: Decoder = .{};
    testFeed(&decoder, input);
    for (expected) |key| try std.testing.expectEqual(key, decoder.next() orelse decoder.flush() orelse return error.MissingKey);
    try std.testing.expectEqual(@as(?Key, null), decoder.next());
    try std.testing.expect(!decoder.pending());
}

test "keys.Decoder: decodes single keys" {
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
        .{ .input = "\x7f", .key = .unknown },
    };
    for (cases) |case| try testExpectKeys(case.input, &.{case.key});
}

test "keys.Decoder: splits repeated keys from one read" {
    try testExpectKeys("jj\x1b[Ak", &.{ .{ .char = 'j' }, .{ .char = 'j' }, .up, .{ .char = 'k' } });
}

test "keys.Decoder: consumes unknown sequences without leaking parameter bytes" {
    try testExpectKeys("\x1b[1;5Aq", &.{ .up, .{ .char = 'q' } });
    try testExpectKeys("\x1b[3~j", &.{ .unknown, .{ .char = 'j' } });
    try testExpectKeys("\x1bj", &.{ .escape, .{ .char = 'j' } });
}

test "keys.Decoder: joins an arrow sequence split across reads" {
    const input = "\x1b[B";
    for (1..input.len) |cut| {
        var decoder: Decoder = .{};
        testFeed(&decoder, input[0..cut]);
        try std.testing.expectEqual(@as(?Key, null), decoder.next());
        try std.testing.expect(decoder.pending());

        testFeed(&decoder, input[cut..]);

        try std.testing.expectEqual(@as(?Key, .down), decoder.next());
        try std.testing.expect(!decoder.pending());
    }
}

test "keys.Decoder.flush: resolves an abandoned sequence" {
    const cases = [_]struct { input: []const u8, key: Key }{
        .{ .input = "\x1b", .key = .escape },
        .{ .input = "\x1b[", .key = .unknown },
        .{ .input = "\x1b[12", .key = .unknown },
    };
    for (cases) |case| {
        var decoder: Decoder = .{};
        testFeed(&decoder, case.input);
        try std.testing.expectEqual(@as(?Key, null), decoder.next());

        try std.testing.expectEqual(@as(?Key, case.key), decoder.flush());
        try std.testing.expect(!decoder.pending());
    }
}

test "keys.Decoder.space: drops a pending sequence that fills the buffer" {
    var decoder: Decoder = .{};
    var filler: [64]u8 = undefined;
    filler[0] = 0x1b;
    filler[1] = '[';
    @memset(filler[2..], '1');
    testFeed(&decoder, &filler);
    try std.testing.expectEqual(@as(?Key, null), decoder.next());

    testFeed(&decoder, "j");

    try std.testing.expectEqual(@as(?Key, .{ .char = 'j' }), decoder.next());
}
