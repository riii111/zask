const std = @import("std");

pub const clear_screen = "\x1b[2J\x1b[H";
pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const cyan = "\x1b[36m";
pub const reverse = "\x1b[7m";
// Alternate screen keeps the pane's previous contents intact after the monitor exits.
pub const enter_screen = "\x1b[?1049h\x1b[?25l";
pub const leave_screen = "\x1b[0m\x1b[?25h\x1b[?1049l";

pub fn writeCentered(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const text_width = text.len;
    if (text_width >= width) {
        try writer.writeAll(text);
        return;
    }
    const left = (width - text_width) / 2;
    const right = width - text_width - left;
    try writeSpaces(writer, left);
    try writer.writeAll(text);
    try writeSpaces(writer, right);
}

pub fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len < width) try writeSpaces(writer, width - text.len);
}

pub fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(' ');
}

pub fn writeRule(writer: *std.Io.Writer, left: []const u8, fill: []const u8, right: []const u8, width: usize) !void {
    try writer.writeAll(left);
    var i: usize = 0;
    while (i < width) : (i += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
}

pub fn truncate(text: []const u8, width: usize) []const u8 {
    if (text.len <= width) return text;
    return text[0..width];
}

/// Cuts every line to `width` visible columns so narrow panes do not wrap rows
/// into each other. Escape sequences are kept up to the cut and do not count
/// as columns; each UTF-8 code point counts as one column. A cut line ends
/// with `reset` so a color opened before the cut does not bleed onward.
/// Caller owns the returned slice.
pub fn clipLines(gpa: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try appendClippedLine(gpa, &out, line, width);
    }
    return out.toOwnedSlice(gpa);
}

fn appendClippedLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, width: usize) !void {
    var columns: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            const end = escapeEnd(line, i);
            try out.appendSlice(gpa, line[i..end]);
            i = end;
            continue;
        }
        if (columns == width) {
            try out.appendSlice(gpa, reset);
            return;
        }
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const end = @min(i + len, line.len);
        try out.appendSlice(gpa, line[i..end]);
        columns += 1;
        i = end;
    }
}

fn escapeEnd(line: []const u8, start: usize) usize {
    if (start + 1 >= line.len or line[start + 1] != '[') return @min(start + 2, line.len);
    var i = start + 2;
    while (i < line.len) : (i += 1) {
        if (line[i] >= 0x40 and line[i] <= 0x7e) return i + 1;
    }
    return line.len;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "ansi.clipLines: cuts visible columns per line" {
    const cases = [_]struct { input: []const u8, width: usize, expected: []const u8 }{
        .{ .input = "abcdef\nxy", .width = 3, .expected = "abc" ++ reset ++ "\nxy" },
        .{ .input = "abc", .width = 3, .expected = "abc" },
        .{ .input = red ++ "abcdef" ++ reset, .width = 2, .expected = red ++ "ab" ++ reset },
        .{ .input = "●│abc", .width = 3, .expected = "●│a" ++ reset },
        .{ .input = "abc", .width = 0, .expected = reset },
        .{ .input = "", .width = 4, .expected = "" },
    };
    for (cases) |case| {
        const clipped = try clipLines(std.testing.allocator, case.input, case.width);
        defer std.testing.allocator.free(clipped);

        try std.testing.expectEqualStrings(case.expected, clipped);
    }
}
