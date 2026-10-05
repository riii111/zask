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
    const columns = displayWidth(text);
    if (columns < width) try writeSpaces(writer, width - columns);
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
    var columns: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const char = nextChar(text, i);
        if (columns + char.width > width) return text[0..i];
        columns += char.width;
        i = char.end;
    }
    return text;
}

pub fn displayWidth(text: []const u8) usize {
    var columns: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const char = nextChar(text, i);
        columns += char.width;
        i = char.end;
    }
    return columns;
}

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
        const char = nextChar(line, i);
        if (columns + char.width > width) {
            try out.appendSlice(gpa, reset);
            return;
        }
        try out.appendSlice(gpa, line[i..char.end]);
        columns += char.width;
        i = char.end;
    }
}

const Char = struct {
    end: usize,
    width: usize,
};

fn nextChar(text: []const u8, start: usize) Char {
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return .{ .end = start + 1, .width = 1 };
    if (start + len > text.len) return .{ .end = text.len, .width = 1 };
    const code_point = std.unicode.utf8Decode(text[start .. start + len]) catch return .{ .end = start + 1, .width = 1 };
    return .{ .end = start + len, .width = charWidth(code_point) };
}

fn charWidth(code_point: u21) usize {
    const zero_width = [_][2]u21{
        .{ 0x0300, 0x036F }, .{ 0x200B, 0x200F }, .{ 0x20D0, 0x20FF }, .{ 0xFE00, 0xFE0F }, .{ 0xFE20, 0xFE2F },
    };
    const wide = [_][2]u21{
        .{ 0x1100, 0x115F },   .{ 0x231A, 0x231B },   .{ 0x2329, 0x232A },   .{ 0x23E9, 0x23EC },
        .{ 0x23F0, 0x23F0 },   .{ 0x23F3, 0x23F3 },   .{ 0x25FD, 0x25FE },   .{ 0x2614, 0x2615 },
        .{ 0x2648, 0x2653 },   .{ 0x267F, 0x267F },   .{ 0x2693, 0x2693 },   .{ 0x26A1, 0x26A1 },
        .{ 0x26AA, 0x26AB },   .{ 0x26BD, 0x26BE },   .{ 0x26C4, 0x26C5 },   .{ 0x26CE, 0x26CE },
        .{ 0x26D4, 0x26D4 },   .{ 0x26EA, 0x26EA },   .{ 0x26F2, 0x26F3 },   .{ 0x26F5, 0x26F5 },
        .{ 0x26FA, 0x26FA },   .{ 0x26FD, 0x26FD },   .{ 0x2705, 0x2705 },   .{ 0x270A, 0x270B },
        .{ 0x2728, 0x2728 },   .{ 0x274C, 0x274C },   .{ 0x274E, 0x274E },   .{ 0x2753, 0x2755 },
        .{ 0x2757, 0x2757 },   .{ 0x2795, 0x2797 },   .{ 0x27B0, 0x27B0 },   .{ 0x27BF, 0x27BF },
        .{ 0x2B1B, 0x2B1C },   .{ 0x2B50, 0x2B50 },   .{ 0x2B55, 0x2B55 },   .{ 0x2E80, 0x303E },
        .{ 0x3041, 0x33FF },   .{ 0x3400, 0x4DBF },   .{ 0x4E00, 0x9FFF },   .{ 0xA000, 0xA4CF },
        .{ 0xA960, 0xA97F },   .{ 0xAC00, 0xD7A3 },   .{ 0xF900, 0xFAFF },   .{ 0xFE10, 0xFE19 },
        .{ 0xFE30, 0xFE6F },   .{ 0xFF00, 0xFF60 },   .{ 0xFFE0, 0xFFE6 },   .{ 0x16FE0, 0x18CFF },
        .{ 0x1B000, 0x1B2FF }, .{ 0x1F004, 0x1F004 }, .{ 0x1F0CF, 0x1F0CF }, .{ 0x1F18E, 0x1F18E },
        .{ 0x1F191, 0x1F19A }, .{ 0x1F200, 0x1F2FF }, .{ 0x1F300, 0x1F64F }, .{ 0x1F680, 0x1F6FF },
        .{ 0x1F7E0, 0x1F7FF }, .{ 0x1F900, 0x1F9FF }, .{ 0x1FA70, 0x1FAFF }, .{ 0x20000, 0x3FFFD },
    };
    for (zero_width) |range| {
        if (code_point >= range[0] and code_point <= range[1]) return 0;
    }
    for (wide) |range| {
        if (code_point >= range[0] and code_point <= range[1]) return 2;
    }
    return 1;
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
        .{ .input = "ログ日本語", .width = 5, .expected = "ログ" ++ reset },
        .{ .input = "aログ", .width = 2, .expected = "a" ++ reset },
        .{ .input = "🚀🚀🚀", .width = 5, .expected = "🚀🚀" ++ reset },
        .{ .input = "abc", .width = 0, .expected = reset },
        .{ .input = "", .width = 4, .expected = "" },
    };
    for (cases) |case| {
        const clipped = try clipLines(std.testing.allocator, case.input, case.width);
        defer std.testing.allocator.free(clipped);

        try std.testing.expectEqualStrings(case.expected, clipped);
    }
}

test "ansi.truncate: cuts by columns without splitting characters" {
    const cases = [_]struct { input: []const u8, width: usize, expected: []const u8 }{
        .{ .input = "service", .width = 4, .expected = "serv" },
        .{ .input = "日本語ログ", .width = 5, .expected = "日本" },
        .{ .input = "aé", .width = 2, .expected = "aé" },
        .{ .input = "short", .width = 10, .expected = "short" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, truncate(case.input, case.width));
}

test "ansi.displayWidth: counts wide and combining characters" {
    const cases = [_]struct { input: []const u8, expected: usize }{
        .{ .input = "api", .expected = 3 },
        .{ .input = "日本語", .expected = 6 },
        .{ .input = "e\u{0301}", .expected = 1 },
        .{ .input = "●◐▲✗│─", .expected = 6 },
        .{ .input = "🚀✅⚡🧪🫠", .expected = 10 },
        .{ .input = "\xff", .expected = 1 },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, displayWidth(case.input));
}
