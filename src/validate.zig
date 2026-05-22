pub fn identifier(value: []const u8) !void {
    if (value.len == 0) return error.InvalidIdentifier;
    for (value) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return error.InvalidIdentifier,
        }
    }
}

test "validates identifiers" {
    try identifier("nodex-agent");
    try identifier("studio_api");
    try @import("std").testing.expectError(error.InvalidIdentifier, identifier("../nodex"));
    try @import("std").testing.expectError(error.InvalidIdentifier, identifier("bad'name"));
}
