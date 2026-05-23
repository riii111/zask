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

test "validates identifiers" {
    try identifier("sample-agent");
    try identifier("studio_api");
    try std.testing.expectError(error.InvalidIdentifier, identifier("../sample"));
    try std.testing.expectError(error.InvalidIdentifier, identifier("bad'name"));
    try std.testing.expectError(error.InvalidIdentifier, identifier("-rf"));
    try std.testing.expectError(error.InvalidIdentifier, identifier("bad\nname"));
}

test "validates relative subpaths" {
    try relativeSubPath(".");
    try relativeSubPath("backend/api");
    try std.testing.expectError(error.InvalidPath, relativeSubPath("../escape"));
    try std.testing.expectError(error.InvalidPath, relativeSubPath("backend/../escape"));
    try std.testing.expectError(error.InvalidPath, relativeSubPath("/tmp/escape"));
}
