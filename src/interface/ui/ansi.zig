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
