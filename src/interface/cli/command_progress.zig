const std = @import("std");

const env = @import("../../platform/env.zig");

const clear_line = "\r\x1b[2K";
const reset = "\x1b[0m";
const yellow = "\x1b[33m";
const cyan = "\x1b[36m";

/// Stores transient step history in the command arena. It intentionally has no
/// deinit; callers must pass an allocator whose lifetime covers the command.
pub const Progress = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    transient: bool,
    color: bool,
    history: std.ArrayList([]const u8) = .empty,
    failure_replayed: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: ?*const env.Map, writer: *std.Io.Writer) Progress {
        const stdout = std.Io.File.stdout();
        const tty = stdout.isTty(io) catch false;
        const color = tty and colorEnabled(environ);
        if (color) stdout.enableAnsiEscapeCodes(io) catch {};
        return .{
            .gpa = gpa,
            .writer = writer,
            .transient = tty,
            .color = color,
        };
    }

    pub fn raw(self: *Progress) *std.Io.Writer {
        return self.writer;
    }

    pub fn step(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        const text = try self.message(fmt, args);
        try self.history.append(self.gpa, text);
        try self.clearLine();
        try self.writeLabel(.info);
        try self.writer.writeAll(text);
        try self.writer.flush();
    }

    pub fn info(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.persist(.info, fmt, args);
    }

    pub fn warn(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.persist(.warn, fmt, args);
    }

    pub fn beforeInteractive(self: *Progress) !void {
        if (!self.transient) return self.writer.flush();
        try self.clearLine();
        try self.writer.flush();
    }

    pub fn failContext(self: *Progress) !void {
        if (!self.transient or self.failure_replayed) return;
        try self.clearLine();
        for (self.history.items) |item| {
            try self.writeLabel(.info);
            try self.writer.writeAll(item);
            try self.writer.writeByte('\n');
        }
        self.failure_replayed = true;
        try self.writer.flush();
    }

    pub fn finishSuccess(self: *Progress) !void {
        if (!self.transient) return;
        try self.clearLine();
        try self.writer.flush();
    }

    pub fn finishError(self: *Progress) !void {
        try self.failContext();
    }

    fn writePlain(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
        try self.writer.flush();
    }

    fn persist(self: *Progress, level: Level, comptime fmt: []const u8, args: anytype) !void {
        try self.clearLine();
        try self.writeLabel(level);
        if (level == .warn) {
            const text = try self.message(fmt, args);
            try self.writer.writeAll(stripWarningPrefix(text));
            try self.writer.writeByte('\n');
        } else {
            try self.writer.print(fmt, args);
        }
        try self.writer.flush();
    }

    fn clearLine(self: *Progress) !void {
        try self.writer.writeAll(clear_line);
    }

    fn message(self: *Progress, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const rendered = try std.fmt.allocPrint(self.gpa, fmt, args);
        return std.mem.trimEnd(u8, rendered, "\r\n");
    }

    fn writeLabel(self: *Progress, level: Level) !void {
        const text = switch (level) {
            .info => "INFO ",
            .warn => "WARN ",
        };
        if (!self.color) {
            try self.writer.writeAll(text);
            return;
        }
        const color = switch (level) {
            .info => cyan,
            .warn => yellow,
        };
        try self.writer.writeAll(color);
        try self.writer.writeAll(text);
        try self.writer.writeAll(reset);
    }
};

const Level = enum {
    info,
    warn,
};

fn colorEnabled(environ: ?*const env.Map) bool {
    if (env.get(environ, "NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    // NO_COLOR wins. CLICOLOR_FORCE only controls color choice; transient
    // rendering itself is still limited to TTY output.
    if (env.get(environ, "CLICOLOR_FORCE")) |value| {
        if (value.len > 0 and !std.mem.eql(u8, value, "0")) return true;
    }
    return true;
}

fn stripWarningPrefix(text: []const u8) []const u8 {
    const prefix = "Warning: ";
    if (std.mem.startsWith(u8, text, prefix)) return text[prefix.len..];
    return text;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "command progress: non-tty keeps line output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = false,
        .color = false,
    };

    try progress.step("Starting {s}...\n", .{"api"});
    try progress.info("{s} already running\n", .{"api"});

    try std.testing.expectEqualStrings(
        \\Starting api...
        \\api already running
        \\
    , writer.buffered());
}

test "command progress: failure replays transient history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.step("Starting {s}...\n", .{"api"});
    try progress.step("Waiting for {s}...\n", .{"api"});
    try progress.failContext();
    try progress.raw().writeAll("Error: api did not become ready\n");

    try std.testing.expectEqualStrings(
        "\r\x1b[2KINFO Starting api...\r\x1b[2KINFO Waiting for api...\r\x1b[2KINFO Starting api...\nINFO Waiting for api...\nError: api did not become ready\n",
        writer.buffered(),
    );
}

test "command progress: transient success clears final step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.step("Opening workspace...\n", .{});
    try progress.step("Starting {s}...\n", .{"api"});
    try progress.finishSuccess();

    try std.testing.expectEqualStrings(
        "\r\x1b[2KINFO Opening workspace...\r\x1b[2KINFO Starting api...\r\x1b[2K",
        writer.buffered(),
    );
}

test "command progress: transient warning strips duplicate prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.warn("Warning: docker compose down failed\n", .{});

    try std.testing.expectEqualStrings(
        "\r\x1b[2KWARN docker compose down failed\n",
        writer.buffered(),
    );
}

test "command progress: clears transient line before interactive command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.step("Docker containers ready\n", .{});
    try progress.beforeInteractive();
    try progress.raw().writeAll("command output\n");

    try std.testing.expectEqualStrings(
        "\r\x1b[2KINFO Docker containers ready\r\x1b[2Kcommand output\n",
        writer.buffered(),
    );
}

test "command progress: color preference honors NO_COLOR first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = env.Map.init(arena.allocator());

    try std.testing.expect(colorEnabled(null));
    try environ.put("CLICOLOR_FORCE", "1");
    try std.testing.expect(colorEnabled(&environ));
    try environ.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(&environ));
}
