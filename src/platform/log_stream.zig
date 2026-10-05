const std = @import("std");

pub fn run(gpa: std.mem.Allocator, io: std.Io, path: []const u8, token: []const u8) !void {
    const marker = try std.fmt.allocPrint(gpa, "\x1b]9999;zask-output-done;{s}\x07", .{token});
    defer gpa.free(marker);
    const done = try completionPath(gpa, path, token);
    defer gpa.free(done);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true, .NOFOLLOW = true });
    if (fd < 0) return error.OpenFailed;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var closed = false;
    defer if (!closed) file.close(io);
    var sink: Sink = .{ .file = file, .io = io };
    var relay: Relay = .{ .marker = marker };
    var buffer: [8192]u8 = undefined;
    while (true) {
        const count = try std.Io.File.stdin().readStreaming(io, &.{&buffer});
        if (count == 0) {
            try relay.finish(&sink);
            return;
        }
        if (try relay.feed(buffer[0..count], &sink)) {
            file.close(io);
            closed = true;
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = done, .data = "done\n", .flags = .{ .permissions = @enumFromInt(0o600) } });
            return;
        }
    }
}

pub fn completionPath(gpa: std.mem.Allocator, path: []const u8, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}.done-{s}", .{ path, token });
}

const Sink = struct {
    file: std.Io.File,
    io: std.Io,

    fn writeAll(self: *Sink, bytes: []const u8) !void {
        try self.file.writeStreamingAll(self.io, bytes);
    }
};

const Relay = struct {
    marker: []const u8,
    matched: usize = 0,

    fn feed(self: *Relay, bytes: []const u8, writer: anytype) !bool {
        var start: usize = 0;
        for (bytes, 0..) |byte, i| {
            if (self.matched == 0 and byte != self.marker[0]) continue;
            if (self.matched == 0) try writer.writeAll(bytes[start..i]);
            if (byte == self.marker[self.matched]) {
                self.matched += 1;
                start = i + 1;
                if (self.matched == self.marker.len) return true;
            } else {
                try writer.writeAll(self.marker[0..self.matched]);
                self.matched = 0;
                start = i;
                if (byte == self.marker[0]) {
                    self.matched = 1;
                    start = i + 1;
                }
            }
        }
        if (self.matched == 0) try writer.writeAll(bytes[start..]);
        return false;
    }

    fn finish(self: *Relay, writer: anytype) !void {
        try writer.writeAll(self.marker[0..self.matched]);
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "log_stream.Relay: saves final output before a marker split across reads" {
    const marker = "\x1b]9999;zask-output-done;123\x07";
    for (0..marker.len + 1) |split| {
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        var relay: Relay = .{ .marker = marker };
        try std.testing.expect(!try relay.feed("early\nFINAL\r\n", &writer));
        const first_done = try relay.feed(marker[0..split], &writer);
        const done = if (first_done) true else try relay.feed(marker[split..], &writer);
        try std.testing.expect(done);
        try std.testing.expectEqualStrings("early\nFINAL\r\n", writer.buffered());
    }
}

test "log_stream.Relay: keeps unrelated terminal escapes and truncated markers" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var relay: Relay = .{ .marker = "\x1b]9999;zask-output-done;123\x07" };
    const bytes = "line\x1b[31mred\x1b[0m\n\x1b]9999;partial";
    try std.testing.expect(!try relay.feed(bytes, &writer));
    try relay.finish(&writer);
    try std.testing.expectEqualStrings(bytes, writer.buffered());
}

test "log_stream.Relay: another run's complete marker cannot acknowledge this run" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var relay: Relay = .{ .marker = "\x1b]9999;zask-output-done;current\x07" };
    const old = "before\x1b]9999;zask-output-done;previous\x07after";
    for (old) |byte| try std.testing.expect(!try relay.feed(&.{byte}, &writer));
    try std.testing.expect(try relay.feed(relay.marker, &writer));
    try std.testing.expectEqualStrings(old, writer.buffered());
}
