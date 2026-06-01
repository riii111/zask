const std = @import("std");
const builtin = @import("builtin");

const env = @import("../../platform/env.zig");

const clear_line = "\r\x1b[2K";
const clear_previous_line = "\x1b[1A\r\x1b[2K";
const reset = "\x1b[0m";
const yellow = "\x1b[33m";
const subtle = "\x1b[2m";
const default_width = 80;
const detail_indent = "  ";
const command_prefix = "  $ ";

/// Command-lifetime state: success clears it, failure replays it.
/// Detail redraws use a nested arena so long waits do not grow memory.
pub const Progress = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    transient: bool,
    color: bool,
    history: std.ArrayList([]const u8) = .empty,
    details: std.ArrayList([]const u8) = .empty,
    detail_arena: ?std.heap.ArenaAllocator = null,
    current_step: []const u8 = "",
    current_command: []const u8 = "",
    current_status: []const u8 = "",
    rendered_rows: usize = 0,
    width: usize = default_width,
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
            .width = terminalWidth(io, stdout) catch default_width,
        };
    }

    pub fn raw(self: *Progress) *std.Io.Writer {
        return self.writer;
    }

    pub fn step(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.setStep(fmt, args);
    }

    pub fn info(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.clearRegion();
        const text = try self.message(fmt, args);
        try self.writer.writeAll(text);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    pub fn focus(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return;
        try self.setStep(fmt, args);
    }

    pub fn command(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return;
        self.current_command = try self.message(fmt, args);
        try self.renderRegion();
    }

    pub fn status(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        self.current_status = try self.message(fmt, args);
        try self.renderRegion();
    }

    pub fn detail(self: *Progress, lines: []const []const u8) !void {
        if (!self.transient) return;
        self.details.items.len = 0;
        try self.details.ensureUnusedCapacity(self.gpa, lines.len);
        const detail_gpa = self.resetDetailAllocator();
        for (lines) |line| {
            self.details.appendAssumeCapacity(try displayLine(detail_gpa, line));
        }
        try self.renderRegion();
    }

    pub fn warn(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.persist(fmt, args);
    }

    pub fn beforeInteractive(self: *Progress) !void {
        if (!self.transient) return self.writer.flush();
        try self.clearRegion();
        try self.writer.flush();
    }

    pub fn failContext(self: *Progress) !void {
        if (!self.transient or self.failure_replayed) return;
        try self.clearRegion();
        for (self.history.items) |item| {
            try self.writer.writeAll(item);
            try self.writer.writeByte('\n');
        }
        if (self.current_command.len > 0) {
            try self.writeCommandLine(self.current_command);
            try self.writer.writeByte('\n');
        }
        if (self.current_status.len > 0) {
            try self.writeDetailLine(self.current_status);
            try self.writer.writeByte('\n');
        }
        for (self.details.items) |line| {
            try self.writeDetailLine(line);
            try self.writer.writeByte('\n');
        }
        self.failure_replayed = true;
        try self.writer.flush();
    }

    pub fn finishSuccess(self: *Progress) !void {
        if (!self.transient) return;
        try self.clearRegion();
        try self.writer.flush();
    }

    pub fn finishError(self: *Progress) !void {
        try self.failContext();
    }

    fn writePlain(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.print(fmt, args);
        try self.writer.flush();
    }

    fn setStep(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        const text = try self.message(fmt, args);
        try self.history.append(self.gpa, text);
        self.current_step = text;
        self.current_command = "";
        self.current_status = "";
        self.details.items.len = 0;
        if (self.detail_arena) |*arena| _ = arena.reset(.retain_capacity);
        try self.renderRegion();
    }

    fn persist(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        try self.clearRegion();
        const text = try self.message(fmt, args);
        try self.writeWarnLabel();
        try self.writer.writeAll(stripWarningPrefix(text));
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    fn renderRegion(self: *Progress) !void {
        try self.clearRegion();
        var rows: usize = 0;
        if (self.current_step.len > 0) {
            try self.writer.writeAll(self.current_step);
            rows += displayRows(0, self.current_step, self.width);
        }
        if (self.current_command.len > 0) {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeCommandLine(self.current_command);
            rows += displayRows(command_prefix.len, self.current_command, self.width);
        }
        if (self.current_status.len > 0) {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeDetailLine(self.current_status);
            rows += displayRows(detail_indent.len, self.current_status, self.width);
        }
        for (self.details.items) |line| {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeDetailLine(line);
            rows += displayRows(detail_indent.len, line, self.width);
        }
        self.rendered_rows = rows;
        try self.writer.flush();
    }

    fn clearRegion(self: *Progress) !void {
        try self.writer.writeAll(clear_line);
        var row: usize = 1;
        while (row < self.rendered_rows) : (row += 1) {
            try self.writer.writeAll(clear_previous_line);
        }
        self.rendered_rows = 0;
    }

    fn message(self: *Progress, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const rendered = try std.fmt.allocPrint(self.gpa, fmt, args);
        return displayLine(self.gpa, rendered);
    }

    fn resetDetailAllocator(self: *Progress) std.mem.Allocator {
        if (self.detail_arena == null) {
            self.detail_arena = std.heap.ArenaAllocator.init(self.gpa);
        }
        if (self.detail_arena) |*arena| {
            _ = arena.reset(.retain_capacity);
            return arena.allocator();
        }
        unreachable;
    }

    fn writeWarnLabel(self: *Progress) !void {
        const text = "WARN ";
        if (!self.color) {
            try self.writer.writeAll(text);
            return;
        }
        try self.writer.writeAll(yellow);
        try self.writer.writeAll(text);
        try self.writer.writeAll(reset);
    }

    fn writeCommandLine(self: *Progress, line: []const u8) !void {
        if (!self.color) {
            try self.writer.writeAll(command_prefix);
            try self.writer.writeAll(line);
            return;
        }
        try self.writer.writeAll(subtle);
        try self.writer.writeAll(command_prefix);
        try self.writer.writeAll(line);
        try self.writer.writeAll(reset);
    }

    fn writeDetailLine(self: *Progress, line: []const u8) !void {
        if (!self.color) {
            try self.writer.writeAll(detail_indent);
            try self.writer.writeAll(line);
            return;
        }
        try self.writer.writeAll(subtle);
        try self.writer.writeAll(detail_indent);
        try self.writer.writeAll(line);
        try self.writer.writeAll(reset);
    }
};

fn colorEnabled(environ: ?*const env.Map) bool {
    if (env.get(environ, "NO_COLOR")) |value| {
        if (value.len > 0) return false;
    }
    return true;
}

fn stripWarningPrefix(text: []const u8) []const u8 {
    const prefix = "Warning: ";
    if (std.mem.startsWith(u8, text, prefix)) return text[prefix.len..];
    return text;
}

fn displayLine(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    const normalized = try gpa.dupe(u8, trimmed);
    for (normalized) |*byte| {
        if (byte.* == '\r' or byte.* == '\n') byte.* = ' ';
    }
    return normalized;
}

fn terminalWidth(io: std.Io, file: std.Io.File) !usize {
    if (builtin.os.tag == .windows) return default_width;
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const err = (try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &winsize,
    } })).device_io_control;
    if (err < 0 or winsize.col == 0) return default_width;
    return winsize.col;
}

fn displayRows(prefix_width: usize, text: []const u8, width: usize) usize {
    const safe_width = @max(width, 1);
    const visible_len = prefix_width + visibleWidth(text);
    if (visible_len == 0) return 1;
    return ((visible_len - 1) / safe_width) + 1;
}

fn visibleWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            width += 1;
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            width += 1;
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len) {
            width += 1;
            index += 1;
            continue;
        }
        width += 2;
        index += sequence_len;
    }
    return width;
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
        "\r\x1b[2KStarting api...\r\x1b[2KWaiting for api...\r\x1b[2KStarting api...\nWaiting for api...\nError: api did not become ready\n",
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
        "\r\x1b[2KOpening workspace...\r\x1b[2KStarting api...\r\x1b[2K",
        writer.buffered(),
    );
}

test "command progress: transient command status and detail redraw region" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.step("Starting api...\n", .{});
    try progress.command("npm run dev\n", .{});
    try progress.status("Waiting for localhost:3000...\n", .{});
    try progress.detail(&.{ "db ready", "api listening" });
    try progress.step("api ready\n", .{});

    try std.testing.expectEqualStrings(
        "\r\x1b[2KStarting api...\r\x1b[2KStarting api...\n  $ npm run dev\r\x1b[2K\x1b[1A\r\x1b[2KStarting api...\n  $ npm run dev\n  Waiting for localhost:3000...\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2KStarting api...\n  $ npm run dev\n  Waiting for localhost:3000...\n  db ready\n  api listening\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2Kapi ready",
        writer.buffered(),
    );
}

test "command progress: transient embedded newlines stay on one row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
    };

    try progress.step("Starting api...\n", .{});
    try progress.command("npm run dev\nnode server\n", .{});
    try progress.detail(&.{"line one\nline two"});
    try progress.step("api ready\n", .{});

    try std.testing.expectEqualStrings(
        "\r\x1b[2KStarting api...\r\x1b[2KStarting api...\n  $ npm run dev node server\r\x1b[2K\x1b[1A\r\x1b[2KStarting api...\n  $ npm run dev node server\n  line one line two\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2Kapi ready",
        writer.buffered(),
    );
}

test "command progress: colored nested lines use terminal default foreground" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = true,
    };

    try progress.step("Starting api...\n", .{});
    try progress.command("npm run dev\n", .{});
    try progress.detail(&.{"listening"});

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2m  $ npm run dev\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[2m  listening\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\x1b[90m") == null);
}

test "command progress: transient info persists without warning label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = true,
    };

    try progress.step("Starting api...\n", .{});
    try progress.info("api already running\n", .{});

    try std.testing.expectEqualStrings(
        "\r\x1b[2KStarting api...\r\x1b[2Kapi already running\n",
        writer.buffered(),
    );
}

test "command progress: transient detail clear counts wrapped rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var progress: Progress = .{
        .gpa = arena.allocator(),
        .writer = &writer,
        .transient = true,
        .color = false,
        .width = 10,
    };

    try progress.step("Wait\n", .{});
    try progress.detail(&.{"1234567890123"});
    try progress.finishSuccess();

    try std.testing.expectEqualStrings(
        "\r\x1b[2KWait\r\x1b[2KWait\n  1234567890123\r\x1b[2K\x1b[1A\r\x1b[2K\x1b[1A\r\x1b[2K",
        writer.buffered(),
    );
}

test "command progress: display rows count unicode conservatively" {
    try std.testing.expectEqual(@as(usize, 1), displayRows(2, "abc", 10));
    try std.testing.expectEqual(@as(usize, 2), displayRows(2, "123456789", 10));
    try std.testing.expectEqual(@as(usize, 2), displayRows(2, "日本語", 6));
    try std.testing.expectEqual(@as(usize, 2), displayRows(2, "✔ ok", 6));
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
        "\r\x1b[2KDocker containers ready\r\x1b[2Kcommand output\n",
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
    try environ.put("CLICOLOR_FORCE", "0");
    try std.testing.expect(colorEnabled(&environ));
    try environ.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(&environ));
}
