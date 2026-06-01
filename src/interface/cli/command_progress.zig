const std = @import("std");

const env = @import("../../platform/env.zig");

const clear_line = "\r\x1b[2K";
const clear_previous_line = "\x1b[1A\r\x1b[2K";
const reset = "\x1b[0m";
const yellow = "\x1b[33m";
const gray = "\x1b[90m";
const default_width = 80;
const detail_indent = "  ";
const command_prefix = "  $ ";

/// Stores transient step history in the command arena. It intentionally has no
/// deinit; callers must pass an allocator whose lifetime covers the command.
pub const Progress = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    transient: bool,
    color: bool,
    history: std.ArrayList([]const u8) = .empty,
    details: std.ArrayList([]const u8) = .empty,
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
        try self.persist(.info, fmt, args);
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
        for (lines) |line| {
            self.details.appendAssumeCapacity(try self.gpa.dupe(u8, std.mem.trimEnd(u8, line, "\r\n")));
        }
        try self.renderRegion();
    }

    pub fn warn(self: *Progress, comptime fmt: []const u8, args: anytype) !void {
        if (!self.transient) return self.writePlain(fmt, args);
        try self.persist(.warn, fmt, args);
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
        try self.renderRegion();
    }

    fn persist(self: *Progress, level: Level, comptime fmt: []const u8, args: anytype) !void {
        try self.clearRegion();
        const text = try self.message(fmt, args);
        if (level == .warn) {
            try self.writeLabel(.warn);
            try self.writer.writeAll(stripWarningPrefix(text));
            try self.writer.writeByte('\n');
        } else {
            try self.writer.writeAll(text);
            try self.writer.writeByte('\n');
        }
        try self.writer.flush();
    }

    fn renderRegion(self: *Progress) !void {
        try self.clearRegion();
        var rows: usize = 0;
        if (self.current_step.len > 0) {
            try self.writer.writeAll(self.current_step);
            rows += displayRows(self.current_step.len, self.width);
        }
        if (self.current_command.len > 0) {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeCommandLine(self.current_command);
            rows += displayRows(command_prefix.len + self.current_command.len, self.width);
        }
        if (self.current_status.len > 0) {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeDetailLine(self.current_status);
            rows += displayRows(detail_indent.len + self.current_status.len, self.width);
        }
        for (self.details.items) |line| {
            if (rows > 0) try self.writer.writeByte('\n');
            try self.writeDetailLine(line);
            rows += displayRows(detail_indent.len + line.len, self.width);
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
        return std.mem.trimEnd(u8, rendered, "\r\n");
    }

    fn writeLabel(self: *Progress, level: Level) !void {
        const text = switch (level) {
            .warn => "WARN ",
            .info => unreachable,
        };
        if (!self.color) {
            try self.writer.writeAll(text);
            return;
        }
        const color = switch (level) {
            .warn => yellow,
            .info => unreachable,
        };
        try self.writer.writeAll(color);
        try self.writer.writeAll(text);
        try self.writer.writeAll(reset);
    }

    fn writeCommandLine(self: *Progress, line: []const u8) !void {
        if (!self.color) {
            try self.writer.writeAll(command_prefix);
            try self.writer.writeAll(line);
            return;
        }
        try self.writer.writeAll(gray);
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
        try self.writer.writeAll(gray);
        try self.writer.writeAll(detail_indent);
        try self.writer.writeAll(line);
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

fn displayRows(visible_len: usize, width: usize) usize {
    const safe_width = @max(width, 1);
    if (visible_len == 0) return 1;
    return ((visible_len - 1) / safe_width) + 1;
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
    try environ.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(&environ));
}
