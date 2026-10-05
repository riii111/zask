const std = @import("std");

/// Writes the bytes of `path` as they were when it was opened, or only its last
/// `max_lines` lines when set. A last line without a newline (a run cut off
/// mid-line) is completed with one, so the output always ends at a line end.
/// Returns error.FileNotFound when the file does not exist; the file is never
/// held in memory as a whole.
pub fn writeLines(io: std.Io, path: []const u8, max_lines: ?u32, out: *std.Io.Writer) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size == 0) return;

    var last: [1]u8 = undefined;
    if (try file.readPositional(io, &.{&last}, size - 1) != 1) return error.EndOfStream;
    const start = if (max_lines) |count| try lastLinesStart(io, file, size, count) else 0;

    var buffer: [chunk_size]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(start);
    try reader.interface.streamExact64(out, size - start);
    if (last[0] != '\n') try out.writeByte('\n');
}

/// Returns false only when the file is known to be absent; other failures are
/// left to the read that follows.
pub fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

const chunk_size = 64 * 1024;

/// Scans backwards from the end, reading one chunk at a time, for the newline
/// that ends the line before the last `max_lines` lines. The newline ending the
/// file belongs to its last line, so it is not counted.
fn lastLinesStart(io: std.Io, file: std.Io.File, size: u64, max_lines: u32) !u64 {
    if (max_lines == 0) return size;
    var buffer: [chunk_size]u8 = undefined;
    var end = size - 1;
    var found: u32 = 0;
    while (end > 0) {
        const begin = end -| chunk_size;
        const chunk = buffer[0..@intCast(end - begin)];
        if (try file.readPositional(io, &.{chunk}, begin) != chunk.len) return error.EndOfStream;
        var index = chunk.len;
        while (index > 0) {
            index -= 1;
            if (chunk[index] != '\n') continue;
            found += 1;
            if (found == max_lines) return begin + index + 1;
        }
        end = begin;
    }
    return 0;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testWriteLines(gpa: std.mem.Allocator, data: ?[]const u8, max_lines: ?u32) ![]const u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (data) |bytes| try tmp.dir.writeFile(io, .{ .sub_path = "api.log", .data = bytes });
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const path = try std.fs.path.join(gpa, &.{ root, "api.log" });
    defer gpa.free(path);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeLines(io, path, max_lines, &out.writer);
    return out.toOwnedSlice();
}

test "log_reader.writeLines: keeps the last lines of the file" {
    const cases = [_]struct {
        name: []const u8,
        data: []const u8,
        max_lines: ?u32,
        expected: []const u8,
    }{
        .{ .name = "whole file", .data = "one\ntwo\n", .max_lines = null, .expected = "one\ntwo\n" },
        .{ .name = "last lines", .data = "one\ntwo\nthree\n", .max_lines = 2, .expected = "two\nthree\n" },
        .{ .name = "fewer than requested", .data = "one\ntwo\n", .max_lines = 5, .expected = "one\ntwo\n" },
        .{ .name = "exactly requested", .data = "one\ntwo\n", .max_lines = 2, .expected = "one\ntwo\n" },
        .{ .name = "cut off last line", .data = "one\ntwo\nthr", .max_lines = 2, .expected = "two\nthr\n" },
        .{ .name = "cut off whole file", .data = "one\nthr", .max_lines = null, .expected = "one\nthr\n" },
        .{ .name = "blank lines count", .data = "one\n\n\n", .max_lines = 2, .expected = "\n\n" },
        .{ .name = "terminal line endings", .data = "one\r\ntwo\r\n", .max_lines = 1, .expected = "two\r\n" },
        .{ .name = "empty file", .data = "", .max_lines = 3, .expected = "" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        const gpa = std.testing.allocator;

        const output = try testWriteLines(gpa, case.data, case.max_lines);
        defer gpa.free(output);

        try std.testing.expectEqualStrings(case.expected, output);
    }
}

test "log_reader.writeLines: finds lines across read chunks" {
    const gpa = std.testing.allocator;
    const filler = try gpa.alloc(u8, chunk_size * 2);
    defer gpa.free(filler);
    @memset(filler, 'x');
    const data = try std.mem.concat(gpa, u8, &.{ "first\n", filler, "\nlast\n" });
    defer gpa.free(data);

    const output = try testWriteLines(gpa, data, 2);
    defer gpa.free(output);

    try std.testing.expectEqual(filler.len + "\nlast\n".len, output.len);
    try std.testing.expect(std.mem.endsWith(u8, output, "x\nlast\n"));
    try std.testing.expectEqual(@as(u8, 'x'), output[0]);
}

test "log_reader.writeLines: reports a missing file" {
    try std.testing.expectError(error.FileNotFound, testWriteLines(std.testing.allocator, null, 3));
}
