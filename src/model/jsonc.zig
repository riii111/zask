const std = @import("std");

const Value = std.json.Value;

/// Config syntax selected by file name. Only `.jsonc` accepts comments so a
/// plain `.json` file stays valid for every JSON tool and editor mode.
pub const Format = enum {
    json,
    jsonc,

    pub fn fromPath(path: []const u8) Format {
        return if (std.mem.eql(u8, std.fs.path.extension(path), ".jsonc")) .jsonc else .json;
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .json => "JSON",
            .jsonc => "JSONC",
        };
    }
};

/// 1-based position of the first syntax problem. Columns count bytes.
pub const SyntaxError = struct {
    line: u64,
    column: u64,
    message: []const u8,
};

/// Parses `bytes` into a `std.json.Value` allocated from `gpa` (use an arena).
/// On `error.InvalidSyntax`, `syntax_error` describes the first problem.
/// Trailing commas are rejected in both formats.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, format: Format, syntax_error: *SyntaxError) !Value {
    const source = switch (try blankComments(gpa, bytes, format)) {
        .ok => |source| source,
        .err => |err| {
            syntax_error.* = positionAt(bytes, err.offset, err.message);
            return error.InvalidSyntax;
        },
    };

    var scanner = std.json.Scanner.initCompleteInput(gpa, source);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    return std.json.parseFromTokenSourceLeaky(Value, gpa, &scanner, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            syntax_error.* = .{ .line = diag.getLine(), .column = diag.getColumn(), .message = scannerMessage(err) };
            return error.InvalidSyntax;
        },
    };
}

/// Returns `bytes` with every comment replaced by spaces, so byte offsets
/// found in the result point at the same tokens in `bytes`. `bytes` must
/// already parse as JSONC. The result is `bytes` itself when it has no
/// comments; otherwise it is allocated from `gpa`.
pub fn withoutComments(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return switch (try blankComments(gpa, bytes, .jsonc)) {
        .ok => |source| source,
        .err => error.InvalidSyntax,
    };
}

pub const CommentRun = struct {
    /// Just past the last comment, or the start offset when none was found.
    end: usize,
    /// The last comment runs to the end of its line, so anything placed at
    /// `end` must start on a new line.
    line_comment: bool = false,
};

/// Skips whitespace and comments from `start`, which must sit outside any
/// string or comment, and reports where the comments end. With `same_line`,
/// only comments that begin on the line of `start` count; a block comment
/// that begins there still counts as a whole even when it spans lines.
pub fn skipComments(bytes: []const u8, start: usize, same_line: bool) CommentRun {
    var run: CommentRun = .{ .end = start };
    var i = start;
    while (i < bytes.len) {
        switch (bytes[i]) {
            ' ', '\t', '\r' => i += 1,
            '\n' => if (same_line) return run else {
                i += 1;
            },
            '/' => {
                const end = (commentEnd(bytes, i) orelse return run) orelse return run;
                run = .{ .end = end, .line_comment = bytes[i + 1] == '/' };
                i = end;
            },
            else => return run,
        }
    }
    return run;
}

const BlankResult = union(enum) {
    ok: []const u8,
    err: struct { offset: usize, message: []const u8 },
};

/// Replaces comment bytes with spaces, keeping newlines, so std.json reports
/// positions that match the original file. Returns `bytes` unchanged when no
/// comment is present.
fn blankComments(gpa: std.mem.Allocator, bytes: []const u8, format: Format) !BlankResult {
    var out: ?[]u8 = null;
    var in_string = false;
    var last_significant: ?usize = null;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (in_string) {
            switch (c) {
                '\\' => i += 1,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => {
                in_string = true;
                last_significant = i;
            },
            ' ', '\t', '\n', '\r' => {},
            '/' => {
                const comment = commentEnd(bytes, i) orelse {
                    last_significant = i;
                    continue;
                };
                if (format == .json) return .{ .err = .{ .offset = i, .message = "comments are allowed only in .jsonc config files" } };
                const end = comment orelse return .{ .err = .{ .offset = i, .message = "unterminated block comment" } };
                if (out == null) out = try gpa.dupe(u8, bytes);
                for (out.?[i..end]) |*byte| {
                    if (byte.* != '\n' and byte.* != '\r') byte.* = ' ';
                }
                i = end - 1;
            },
            ']', '}' => {
                if (last_significant) |prev| {
                    if (bytes[prev] == ',') return .{ .err = .{ .offset = prev, .message = "trailing comma is not allowed" } };
                }
                last_significant = i;
            },
            else => last_significant = i,
        }
    }
    return .{ .ok = out orelse bytes };
}

/// Returns the exclusive end of the comment starting at `start`. The outer
/// null means the slash does not start a comment; the inner null means an
/// unterminated block comment.
fn commentEnd(bytes: []const u8, start: usize) ??usize {
    if (start + 1 >= bytes.len) return null;
    return switch (bytes[start + 1]) {
        '/' => std.mem.indexOfScalarPos(u8, bytes, start + 2, '\n') orelse bytes.len,
        '*' => if (std.mem.indexOfPos(u8, bytes, start + 2, "*/")) |close| close + 2 else @as(?usize, null),
        else => null,
    };
}

fn positionAt(bytes: []const u8, offset: usize, message: []const u8) SyntaxError {
    const before = bytes[0..offset];
    const line_start = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |nl| nl + 1 else 0;
    return .{
        .line = std.mem.count(u8, before, "\n") + 1,
        .column = offset - line_start + 1,
        .message = message,
    };
}

fn scannerMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedEndOfInput => "unexpected end of input",
        error.DuplicateField => "duplicate key",
        error.ValueTooLong => "value is too long",
        else => "invalid syntax",
    };
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testParse(arena: std.mem.Allocator, bytes: []const u8, format: Format) !Value {
    var syntax_error: SyntaxError = undefined;
    return parse(arena, bytes, format, &syntax_error);
}

fn testSyntaxError(arena: std.mem.Allocator, bytes: []const u8, format: Format) !SyntaxError {
    var syntax_error: SyntaxError = undefined;
    if (parse(arena, bytes, format, &syntax_error)) |_| {
        return error.TestExpectedSyntaxError;
    } else |err| switch (err) {
        error.InvalidSyntax => return syntax_error,
        else => return err,
    }
}

fn testExpectSameValue(arena: std.mem.Allocator, expected_json: []const u8, actual: Value) !void {
    const expected = try std.json.parseFromSliceLeaky(Value, arena, expected_json, .{});
    const expected_text = try std.json.Stringify.valueAlloc(arena, expected, .{});
    const actual_text = try std.json.Stringify.valueAlloc(arena, actual, .{});
    try std.testing.expectEqualStrings(expected_text, actual_text);
}

test "jsonc.Format.fromPath: selects jsonc only for .jsonc" {
    const cases = [_]struct { path: []const u8, format: Format }{
        .{ .path = "zask.json", .format = .json },
        .{ .path = "/home/me/.config/zask/demo/config.jsonc", .format = .jsonc },
        .{ .path = ".zask.jsonc", .format = .jsonc },
        .{ .path = "zask.jsonc.bak", .format = .json },
        .{ .path = "zask", .format = .json },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.format, Format.fromPath(case.path));
    }
}

test "jsonc.parse: jsonc comments parse like the same json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try testParse(arena.allocator(),
        \\// leading note
        \\{
        \\  /* block
        \\     comment */
        \\  "port": 8080, // waits for ES
        \\  "tags": [1, /* inline */ 2]
        \\}
        \\// trailing note without newline
    , .jsonc);
    const block_at_end = try testParse(arena.allocator(), "{} /* note */", .jsonc);

    try testExpectSameValue(arena.allocator(),
        \\{"port":8080,"tags":[1,2]}
    , value);
    try testExpectSameValue(arena.allocator(), "{}", block_at_end);
}

test "jsonc.parse: comment markers inside strings stay literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try testParse(arena.allocator(),
        \\{"url": "http://localhost//api", "glob": "src/**/*.zig", "quote": "a\"//b", "end": "*/"} // note
    , .jsonc);

    try testExpectSameValue(arena.allocator(),
        \\{"url":"http://localhost//api","glob":"src/**/*.zig","quote":"a\"//b","end":"*/"}
    , value);
}

test "jsonc.parse: json accepts the same input without comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"url": "http://localhost//api", "items": [1, 2]}
    ;

    const as_json = try testParse(arena.allocator(), json, .json);
    const as_jsonc = try testParse(arena.allocator(), json, .jsonc);

    try testExpectSameValue(arena.allocator(), json, as_json);
    try testExpectSameValue(arena.allocator(), json, as_jsonc);
}

test "jsonc.parse: reports syntax errors with original position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct {
        name: []const u8,
        bytes: []const u8,
        format: Format,
        line: u64,
        column: u64,
        message: []const u8,
    }{
        .{ .name = "comment in json", .bytes = "{\n  \"a\": 1 // note\n}", .format = .json, .line = 2, .column = 10, .message = "comments are allowed only in .jsonc config files" },
        .{ .name = "block comment in json", .bytes = "/* note */{}", .format = .json, .line = 1, .column = 1, .message = "comments are allowed only in .jsonc config files" },
        .{ .name = "unterminated block comment", .bytes = "{\n  /* note\n}", .format = .jsonc, .line = 2, .column = 3, .message = "unterminated block comment" },
        .{ .name = "unterminated block comment at end", .bytes = "{} /*", .format = .jsonc, .line = 1, .column = 4, .message = "unterminated block comment" },
        .{ .name = "trailing comma in object", .bytes = "{\n  \"a\": 1,\n}", .format = .json, .line = 2, .column = 9, .message = "trailing comma is not allowed" },
        .{ .name = "trailing comma before comment", .bytes = "{\n  \"a\": [1, // last\n  ]\n}", .format = .jsonc, .line = 2, .column = 10, .message = "trailing comma is not allowed" },
        .{ .name = "error after block comment", .bytes = "{\n  /* one\n     two */ \"a\" 1\n}", .format = .jsonc, .line = 3, .column = 17, .message = "invalid syntax" },
        .{ .name = "lone slash", .bytes = "{\"a\": /}", .format = .jsonc, .line = 1, .column = 7, .message = "invalid syntax" },
        .{ .name = "unexpected end", .bytes = "{\"a\": 1", .format = .jsonc, .line = 1, .column = 8, .message = "unexpected end of input" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        const actual = try testSyntaxError(arena.allocator(), case.bytes, case.format);

        try std.testing.expectEqualStrings(case.message, actual.message);
        try std.testing.expectEqual(case.line, actual.line);
        try std.testing.expectEqual(case.column, actual.column);
    }
}

test "jsonc.skipComments: reports where comments after a value end" {
    const cases = [_]struct {
        name: []const u8,
        bytes: []const u8,
        same_line: bool,
        end: usize,
        line_comment: bool,
    }{
        .{ .name = "no comment", .bytes = "1 ]", .same_line = true, .end = 1, .line_comment = false },
        .{ .name = "line comment", .bytes = "1 // a\n]", .same_line = true, .end = 6, .line_comment = true },
        .{ .name = "block then line", .bytes = "1 /* a */ // b\n]", .same_line = true, .end = 14, .line_comment = true },
        .{ .name = "block spanning lines", .bytes = "1 /* a\n b */\n]", .same_line = true, .end = 12, .line_comment = false },
        .{ .name = "comment on next line", .bytes = "1\n// a\n]", .same_line = true, .end = 1, .line_comment = false },
        .{ .name = "comments across lines", .bytes = "1\n// a\n/* b */ ]", .same_line = false, .end = 14, .line_comment = false },
        .{ .name = "slash outside comment", .bytes = "1 /x", .same_line = true, .end = 1, .line_comment = false },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});

        const run = skipComments(case.bytes, 1, case.same_line);

        try std.testing.expectEqual(case.end, run.end);
        try std.testing.expectEqual(case.line_comment, run.line_comment);
    }
}
