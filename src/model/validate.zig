const std = @import("std");

pub fn identifier(value: []const u8) !void {
    if (value.len == 0) return error.InvalidIdentifier;
    switch (value[0]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return error.InvalidIdentifier,
    }
    for (value[1..]) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return error.InvalidIdentifier,
        }
    }
}

pub fn relativeSubPath(value: []const u8) !void {
    if (value.len == 0) return;
    if (std.fs.path.isAbsolute(value)) return error.InvalidPath;
    var parts = std.mem.tokenizeAny(u8, value, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "validate.identifier: accepts alphanumeric underscore and hyphen after first byte" {
    const cases = [_][]const u8{
        "sample-agent",
        "studio_api",
        "api2",
    };
    for (cases) |case| {
        try identifier(case);
    }
}

test "validate.identifier: rejects empty pathlike quoted and leading hyphen input" {
    const cases = [_][]const u8{
        "",
        "../sample",
        "bad'name",
        "-rf",
        "bad\nname",
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidIdentifier, identifier(case));
    }
}

test "validate.relativeSubPath: accepts empty current and nested paths" {
    const cases = [_][]const u8{
        "",
        ".",
        "backend/api",
    };
    for (cases) |case| {
        try relativeSubPath(case);
    }
}

test "validate.relativeSubPath: rejects parent traversal and absolute paths" {
    const cases = [_][]const u8{
        "../escape",
        "backend/../escape",
        "/tmp/escape",
    };
    for (cases) |case| {
        try std.testing.expectError(error.InvalidPath, relativeSubPath(case));
    }
}
