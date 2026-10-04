const std = @import("std");
const diagnostics = @import("../model/diagnostics.zig");
const validate = @import("../model/validate.zig");

pub const Service = struct {
    name: []const u8,
    command: []const u8,
    /// 1-based line in the source file, kept so later checks can point back to it.
    line: usize,
};

/// Parses Procfile `name: command` lines. Blank lines and lines starting with
/// `#` are skipped; the command is everything after the first colon, so
/// colons and inner whitespace survive. Every problem is added to `diags` as
/// `<source>:<line>` before failing with `error.InvalidProcfile`.
/// Returned names and commands borrow from `bytes`; pass an arena for `gpa`.
pub fn parse(gpa: std.mem.Allocator, source: []const u8, bytes: []const u8, diags: *diagnostics.Diagnostics) ![]const Service {
    var services: std.ArrayList(Service) = .empty;
    const problems_before = diags.slice().len;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const location = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ source, line_number });
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            try diags.add(location, "expected '<name>: <command>'");
            continue;
        };
        const name = line[0..colon];
        const command = std.mem.trim(u8, line[colon + 1 ..], " \t");
        validate.identifier(name) catch {
            try diags.addFmt(location, "invalid service name '{s}' (use letters, digits, '_' or '-')", .{name});
            continue;
        };
        if (command.len == 0) {
            try diags.addFmt(location, "missing command for '{s}'", .{name});
            continue;
        }
        if (findService(services.items, name)) |first| {
            try diags.addFmt(location, "duplicate service '{s}' (first defined at line {d})", .{ name, first.line });
            continue;
        }
        try services.append(gpa, .{ .name = name, .command = command, .line = line_number });
    }

    if (diags.slice().len > problems_before) return error.InvalidProcfile;
    if (services.items.len == 0) {
        try diags.add(source, "no service definitions found");
        return error.InvalidProcfile;
    }
    return services.items;
}

fn findService(services: []const Service, name: []const u8) ?Service {
    for (services) |service| {
        if (std.mem.eql(u8, service.name, name)) return service;
    }
    return null;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testExpectProblems(bytes: []const u8, expected: []const diagnostics.Diagnostic) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = diagnostics.Diagnostics.init(arena.allocator());

    try std.testing.expectError(error.InvalidProcfile, parse(arena.allocator(), "Procfile.dev", bytes, &diags));

    try std.testing.expectEqual(expected.len, diags.slice().len);
    for (expected, diags.slice()) |want, got| {
        try std.testing.expectEqualStrings(want.path, got.path);
        try std.testing.expectEqualStrings(want.message, got.message);
    }
}

test "procfile.parse: skips comments and blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diags = diagnostics.Diagnostics.init(arena.allocator());

    const services = try parse(arena.allocator(), "Procfile.dev",
        \\# web stack
        \\
        \\web: bin/rails server
        \\   # indented comment
        \\
        \\worker: bundle exec sidekiq
        \\
    , &diags);

    try std.testing.expectEqual(@as(usize, 2), services.len);
    try std.testing.expectEqualStrings("web", services[0].name);
    try std.testing.expectEqualStrings("bin/rails server", services[0].command);
    try std.testing.expectEqual(@as(usize, 3), services[0].line);
    try std.testing.expectEqualStrings("worker", services[1].name);
    try std.testing.expectEqualStrings("bundle exec sidekiq", services[1].command);
    try std.testing.expectEqual(@as(usize, 6), services[1].line);
    try std.testing.expect(diags.isEmpty());
}

test "procfile.parse: keeps colons and inner whitespace in commands" {
    const cases = [_]struct {
        line: []const u8,
        command: []const u8,
    }{
        .{ .line = "web: bin/rails server -b 0.0.0.0:3000", .command = "bin/rails server -b 0.0.0.0:3000" },
        .{ .line = "web:npm run dev", .command = "npm run dev" },
        .{ .line = "web:\tenv  A=1   npm run dev  \r", .command = "env  A=1   npm run dev" },
        .{ .line = "web: echo 'a: b' # not a comment", .command = "echo 'a: b' # not a comment" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var diags = diagnostics.Diagnostics.init(arena.allocator());

        const services = try parse(arena.allocator(), "Procfile.dev", case.line, &diags);

        try std.testing.expectEqual(@as(usize, 1), services.len);
        try std.testing.expectEqualStrings("web", services[0].name);
        try std.testing.expectEqualStrings(case.command, services[0].command);
    }
}

test "procfile.parse: reports every invalid line with its location" {
    try testExpectProblems(
        \\web: npm run dev
        \\just a command
        \\bad name: run
        \\-web: run
        \\worker:
        \\web: npm start
        \\
    , &.{
        .{ .path = "Procfile.dev:2", .message = "expected '<name>: <command>'" },
        .{ .path = "Procfile.dev:3", .message = "invalid service name 'bad name' (use letters, digits, '_' or '-')" },
        .{ .path = "Procfile.dev:4", .message = "invalid service name '-web' (use letters, digits, '_' or '-')" },
        .{ .path = "Procfile.dev:5", .message = "missing command for 'worker'" },
        .{ .path = "Procfile.dev:6", .message = "duplicate service 'web' (first defined at line 1)" },
    });
}

test "procfile.parse: rejects files without service definitions" {
    try testExpectProblems(
        \\# nothing yet
        \\
    , &.{
        .{ .path = "Procfile.dev", .message = "no service definitions found" },
    });
}
