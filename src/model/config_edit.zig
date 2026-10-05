const std = @import("std");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const jsonc = @import("jsonc.zig");

const Value = std.json.Value;
const keys = config.keys;

pub const NewService = struct {
    name: []const u8,
    command: []const u8,
    port: ?u16 = null,
};

pub const AddedService = struct {
    bytes: []u8,
    group: []const u8,
    summary: []u8,
};

pub const AddServiceResult = union(enum) {
    added: AddedService,
    duplicate: []const u8,
    group_not_found: []const []const u8,
    group_required: []const []const u8,
};

pub fn addService(gpa: std.mem.Allocator, bytes: []const u8, source: Value, group: ?[]const u8, service: NewService) !AddServiceResult {
    const groups = source.object.get(keys.groups).?.array.items;
    if (findServiceGroup(groups, service.name)) |holder| return .{ .duplicate = holder };

    const index = if (group) |name|
        findGroup(groups, name) orelse return .{ .group_not_found = try groupNames(gpa, groups) }
    else switch (groups.len) {
        0 => return .{ .group_not_found = &.{} },
        1 => 0,
        else => return .{ .group_required = try groupNames(gpa, groups) },
    };
    const target = groups[index];
    const services_value = target.object.get(keys.services).?;
    const kind: ContainerKind = if (services_value == .array) .array else .object;

    const plain = try jsonc.withoutComments(gpa, bytes);
    const container = try locateServices(gpa, plain, index);
    const layout = try Layout.detect(gpa, bytes, plain, container);
    const entry = try renderEntry(gpa, kind, service, layout.entryStyle(bytes, container));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (container.last) |last| {
        const trailing = jsonc.skipComments(bytes, last.end, true);
        try out.appendSlice(gpa, bytes[0..last.end]);
        try out.append(gpa, ',');
        try out.appendSlice(gpa, bytes[last.end..trailing.end]);
        if (layout.multiline) {
            try out.append(gpa, '\n');
            try out.appendSlice(gpa, layout.entry_indent);
        } else if (trailing.line_comment) {
            try out.append(gpa, '\n');
            try out.appendSlice(gpa, lineIndent(bytes, last.start));
        } else try out.append(gpa, ' ');
        try out.appendSlice(gpa, entry);
        try out.appendSlice(gpa, bytes[trailing.end..]);
    } else {
        const comments_end = jsonc.skipComments(bytes, container.open + 1, false).end;
        try out.appendSlice(gpa, bytes[0..comments_end]);
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, layout.entry_indent);
        try out.appendSlice(gpa, entry);
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, lineIndent(bytes, container.open));
        try out.appendSlice(gpa, bytes[container.close..]);
    }

    return .{ .added = .{
        .bytes = try out.toOwnedSlice(gpa),
        .group = target.object.get(keys.name).?.string,
        .summary = try renderEntry(gpa, kind, service, .single_line),
    } };
}

const ContainerKind = enum { array, object };

const Span = struct { start: usize, end: usize };

const Container = struct {
    open: usize,
    close: usize,
    first: ?Span = null,
    last: ?Span = null,
};

const EntryStyle = union(enum) {
    single_line,
    multi_line: struct { field_indent: []const u8, close_indent: []const u8 },
};

const Layout = struct {
    multiline: bool,
    entry_indent: []const u8,
    field_indent: []const u8,

    fn detect(gpa: std.mem.Allocator, bytes: []const u8, plain: []const u8, container: Container) !Layout {
        const open_indent = lineIndent(bytes, container.open);
        if (container.first) |first| {
            const multiline = std.mem.indexOfScalar(u8, bytes[container.open + 1 .. first.start], '\n') != null;
            const entry_indent = if (multiline) lineIndent(bytes, first.start) else open_indent;
            const unit = if (multiline and entry_indent.len > open_indent.len and std.mem.startsWith(u8, entry_indent, open_indent))
                entry_indent[open_indent.len..]
            else
                fileIndentUnit(plain);
            return .{
                .multiline = multiline,
                .entry_indent = entry_indent,
                .field_indent = try std.mem.concat(gpa, u8, &.{ entry_indent, unit }),
            };
        }
        const unit = fileIndentUnit(plain);
        const entry_indent = try std.mem.concat(gpa, u8, &.{ open_indent, unit });
        return .{
            .multiline = true,
            .entry_indent = entry_indent,
            .field_indent = try std.mem.concat(gpa, u8, &.{ entry_indent, unit }),
        };
    }

    fn entryStyle(self: Layout, bytes: []const u8, container: Container) EntryStyle {
        const spans_lines = if (container.last) |last|
            std.mem.indexOfScalar(u8, bytes[last.start..last.end], '\n') != null
        else
            self.multiline;
        if (!spans_lines) return .single_line;
        return .{ .multi_line = .{ .field_indent = self.field_indent, .close_indent = self.entry_indent } };
    }
};

fn locateServices(gpa: std.mem.Allocator, bytes: []const u8, group_index: usize) !Container {
    var scanner = std.json.Scanner.initCompleteInput(gpa, bytes);
    defer scanner.deinit();

    try expectToken(&scanner, .object_begin);
    try seekKey(gpa, &scanner, keys.groups);
    try expectToken(&scanner, .array_begin);
    for (0..group_index) |_| try scanner.skipValue();
    try expectToken(&scanner, .object_begin);
    try seekKey(gpa, &scanner, keys.services);
    return scanContainer(gpa, &scanner);
}

fn scanContainer(gpa: std.mem.Allocator, scanner: *std.json.Scanner) !Container {
    _ = try scanner.peekNextTokenType();
    const open = scanner.cursor;
    const kind: ContainerKind = switch (try scanner.next()) {
        .array_begin => .array,
        .object_begin => .object,
        else => return error.UnexpectedConfigShape,
    };
    var container: Container = .{ .open = open, .close = open };
    while (true) {
        switch (try scanner.peekNextTokenType()) {
            .array_end, .object_end => {
                container.close = scanner.cursor;
                _ = try scanner.next();
                return container;
            },
            else => {},
        }
        const start = scanner.cursor;
        if (kind == .object) try skipKey(gpa, scanner);
        try scanner.skipValue();
        const span: Span = .{ .start = start, .end = scanner.cursor };
        if (container.first == null) container.first = span;
        container.last = span;
    }
}

fn seekKey(gpa: std.mem.Allocator, scanner: *std.json.Scanner, key: []const u8) !void {
    while (true) {
        const token = try scanner.nextAlloc(gpa, .alloc_if_needed);
        const name = switch (token) {
            .string => |name| name,
            .allocated_string => |name| name,
            else => return error.UnexpectedConfigShape,
        };
        defer if (token == .allocated_string) gpa.free(name);
        if (std.mem.eql(u8, name, key)) return;
        try scanner.skipValue();
    }
}

fn skipKey(gpa: std.mem.Allocator, scanner: *std.json.Scanner) !void {
    const token = try scanner.nextAlloc(gpa, .alloc_if_needed);
    switch (token) {
        .string => {},
        .allocated_string => |name| gpa.free(name),
        else => return error.UnexpectedConfigShape,
    }
}

fn expectToken(scanner: *std.json.Scanner, comptime expected: std.meta.Tag(std.json.Token)) !void {
    if (try scanner.next() != expected) return error.UnexpectedConfigShape;
}

fn renderEntry(gpa: std.mem.Allocator, kind: ContainerKind, service: NewService, style: EntryStyle) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const writer = &out.writer;
    switch (kind) {
        .array => try renderObject(writer, &.{
            .{ .key = keys.name, .value = .{ .string = service.name } },
            .{ .key = keys.command, .value = .{ .string = service.command } },
        }, service.port, style),
        .object => {
            try std.json.Stringify.encodeJsonString(service.name, .{}, writer);
            try writer.writeAll(": ");
            if (service.port == null) {
                try std.json.Stringify.encodeJsonString(service.command, .{}, writer);
            } else try renderObject(writer, &.{
                .{ .key = keys.command, .value = .{ .string = service.command } },
            }, service.port, style);
        },
    }
    return out.toOwnedSlice();
}

const Field = struct { key: []const u8, value: Value };

fn renderObject(writer: *std.Io.Writer, fields: []const Field, port: ?u16, style: EntryStyle) !void {
    var all: [3]Field = undefined;
    @memcpy(all[0..fields.len], fields);
    var count = fields.len;
    if (port) |value| {
        all[count] = .{ .key = keys.port, .value = .{ .integer = value } };
        count += 1;
    }

    try writer.writeByte('{');
    for (all[0..count], 0..) |field, index| {
        switch (style) {
            .single_line => if (index > 0) try writer.writeAll(", "),
            .multi_line => |indent| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeByte('\n');
                try writer.writeAll(indent.field_indent);
            },
        }
        try std.json.Stringify.encodeJsonString(field.key, .{}, writer);
        try writer.writeAll(": ");
        try std.json.Stringify.value(field.value, .{}, writer);
    }
    switch (style) {
        .single_line => {},
        .multi_line => |indent| {
            try writer.writeByte('\n');
            try writer.writeAll(indent.close_indent);
        },
    }
    try writer.writeByte('}');
}

fn findServiceGroup(groups: []const Value, name: []const u8) ?[]const u8 {
    for (groups) |group| {
        const found = switch (group.object.get(keys.services).?) {
            .array => |items| for (items.items) |service| {
                if (std.mem.eql(u8, service.object.get(keys.name).?.string, name)) break true;
            } else false,
            .object => |entries| entries.contains(name),
            else => false,
        };
        if (found) return group.object.get(keys.name).?.string;
    }
    return null;
}

fn findGroup(groups: []const Value, name: []const u8) ?usize {
    for (groups, 0..) |group, index| {
        if (std.mem.eql(u8, group.object.get(keys.name).?.string, name)) return index;
    }
    return null;
}

fn groupNames(gpa: std.mem.Allocator, groups: []const Value) ![]const []const u8 {
    const names = try gpa.alloc([]const u8, groups.len);
    for (groups, names) |group, *name| name.* = group.object.get(keys.name).?.string;
    return names;
}

fn lineIndent(bytes: []const u8, pos: usize) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, bytes[0..pos], '\n')) |newline| newline + 1 else 0;
    var end = line_start;
    while (end < bytes.len and (bytes[end] == ' ' or bytes[end] == '\t')) end += 1;
    return bytes[line_start..end];
}

fn fileIndentUnit(bytes: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        var end: usize = 0;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) end += 1;
        if (end > 0 and end < line.len) return line[0..end];
    }
    return "  ";
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn testAdd(arena: *std.heap.ArenaAllocator, bytes: []const u8, group: ?[]const u8, service: NewService) !AddServiceResult {
    const gpa = arena.allocator();
    var syntax_error: jsonc.SyntaxError = undefined;
    const source = try jsonc.parse(gpa, bytes, .jsonc, &syntax_error);
    var diags = diagnostics.Diagnostics.init(gpa);
    try config.validateAll(gpa, source, &diags);
    try std.testing.expect(diags.isEmpty());
    return addService(gpa, bytes, source, group, service);
}

fn testAdded(arena: *std.heap.ArenaAllocator, bytes: []const u8, group: ?[]const u8, service: NewService) !AddedService {
    const result = try testAdd(arena, bytes, group, service);
    try std.testing.expect(result == .added);
    var diags = diagnostics.Diagnostics.init(arena.allocator());
    _ = try config.Config.parseFormatWithDiagnostics(arena.allocator(), result.added.bytes, .jsonc, "/home/me", &diags);
    return result.added;
}

test "config_edit.addService: appends a multi-line entry to an indented array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "/tmp/demo"
        \\  },
        \\  "groups": [
        \\    {
        \\      "name": "backend",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "command": "npm run dev"
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run", .port = 8080 });

    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {
        \\    "name": "demo",
        \\    "root": "/tmp/demo"
        \\  },
        \\  "groups": [
        \\    {
        \\      "name": "backend",
        \\      "services": [
        \\        {
        \\          "name": "web",
        \\          "command": "npm run dev"
        \\        },
        \\        {
        \\          "name": "api",
        \\          "command": "cargo run",
        \\          "port": 8080
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    , added.bytes);
    try std.testing.expectEqualStrings("backend", added.group);
    try std.testing.expectEqualStrings("{\"name\": \"api\", \"command\": \"cargo run\", \"port\": 8080}", added.summary);
}

test "config_edit.addService: keeps single-line array entries on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"web","command":"dev"}
        \\  ]}]
        \\}
    ;

    const added = try testAdded(&arena, bytes, "backend", .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"web","command":"dev"},
        \\    {"name": "api", "command": "cargo run"}
        \\  ]}]
        \\}
    , added.bytes);
}

test "config_edit.addService: adds shorthand to named services" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": {
        \\      "worker": "work"
        \\    }}
        \\  ]
        \\}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": {
        \\      "worker": "work",
        \\      "api": "cargo run"
        \\    }}
        \\  ]
        \\}
    , added.bytes);
    try std.testing.expectEqualStrings("\"api\": \"cargo run\"", added.summary);
}

test "config_edit.addService: adds detailed named entry when a port is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{"project": {"name": "demo", "root": "/tmp/demo"}, "groups": [{"name": "backend", "services": {"worker": "work"}}]}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run", .port = 8080 });

    try std.testing.expectEqualStrings(
        \\{"project": {"name": "demo", "root": "/tmp/demo"}, "groups": [{"name": "backend", "services": {"worker": "work", "api": {"command": "cargo run", "port": 8080}}}]}
    , added.bytes);
}

test "config_edit.addService: fills an empty container on new lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\    "project": {"name": "demo", "root": "/tmp/demo"},
        \\    "groups": [
        \\        {"name": "tools", "services": {"lint": "lint"}},
        \\        {"services": [], "name": "backend"}
        \\    ]
        \\}
    ;

    const added = try testAdded(&arena, bytes, "backend", .{ .name = "api", .command = "say \"hi\"" });

    try std.testing.expectEqualStrings(
        \\{
        \\    "project": {"name": "demo", "root": "/tmp/demo"},
        \\    "groups": [
        \\        {"name": "tools", "services": {"lint": "lint"}},
        \\        {"services": [
        \\            {
        \\                "name": "api",
        \\                "command": "say \"hi\""
        \\            }
        \\        ], "name": "backend"}
        \\    ]
        \\}
    , added.bytes);
}

test "config_edit.addService: reports the group holding a duplicate name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[{"name":"api","command":"serve"}]},
        \\    {"name":"workers","services":{"job":"run"}}
        \\  ]
        \\}
    ;

    const cases = [_]struct { name: []const u8, holder: []const u8 }{
        .{ .name = "api", .holder = "backend" },
        .{ .name = "job", .holder = "workers" },
    };
    for (cases) |case| {
        const result = try testAdd(&arena, bytes, "backend", .{ .name = case.name, .command = "x" });
        try std.testing.expectEqualStrings(case.holder, result.duplicate);
    }
}

test "config_edit.addService: requires an existing group when several exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[]},
        \\    {"name":"frontend","services":{}}
        \\  ]
        \\}
    ;
    const service: NewService = .{ .name = "api", .command = "serve" };

    const omitted = try testAdd(&arena, bytes, null, service);
    const missing = try testAdd(&arena, bytes, "web", service);

    try std.testing.expectEqual(@as(usize, 2), omitted.group_required.len);
    try std.testing.expectEqualStrings("backend", omitted.group_required[0]);
    try std.testing.expectEqualStrings("frontend", omitted.group_required[1]);
    try std.testing.expectEqual(@as(usize, 2), missing.group_not_found.len);
}

test "config_edit.addService: reports missing group when none exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{"project": {"name":"demo","root":"/tmp/demo"}, "groups": []}
    ;

    const result = try testAdd(&arena, bytes, null, .{ .name = "api", .command = "serve" });

    try std.testing.expectEqual(@as(usize, 0), result.group_not_found.len);
}

test "config_edit.addService: keeps a line comment with the last array entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  // services for local work
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": [
        \\    // the main api
        \\    {
        \\      "name": "web",
        \\      "command": "dev" // hot reload
        \\    } // waits for the db
        \\    // {"name": "old", "command": "legacy"}
        \\  ]}]
        \\}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run", .port = 8080 });

    try std.testing.expectEqualStrings(
        \\{
        \\  // services for local work
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": [
        \\    // the main api
        \\    {
        \\      "name": "web",
        \\      "command": "dev" // hot reload
        \\    }, // waits for the db
        \\    {
        \\      "name": "api",
        \\      "command": "cargo run",
        \\      "port": 8080
        \\    }
        \\    // {"name": "old", "command": "legacy"}
        \\  ]}]
        \\}
    , added.bytes);
}

test "config_edit.addService: keeps block comments with the last named entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": {
        \\    "worker": /* queue */ "work" /* paused by default,
        \\                                   start it by hand */
        \\  }}]
        \\}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": {
        \\    "worker": /* queue */ "work", /* paused by default,
        \\                                   start it by hand */
        \\    "api": "cargo run"
        \\  }}]
        \\}
    , added.bytes);
}

test "config_edit.addService: moves to a new line after a line comment on one-line entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{"project": {"name": "demo", "root": "/tmp/demo"},
        \\ "groups": [{"name": "backend", "services": {"worker": "work" // paused
        \\ }}]}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\{"project": {"name": "demo", "root": "/tmp/demo"},
        \\ "groups": [{"name": "backend", "services": {"worker": "work", // paused
        \\ "api": "cargo run"
        \\ }}]}
    , added.bytes);
}

test "config_edit.addService: keeps comments inside an empty container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\/*
        \\ * Local services.
        \\ */
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": [
        \\      // add services here
        \\    ]}
        \\  ]
        \\}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\/*
        \\ * Local services.
        \\ */
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": [
        \\      // add services here
        \\      {
        \\        "name": "api",
        \\        "command": "cargo run"
        \\      }
        \\    ]}
        \\  ]
        \\}
    , added.bytes);
}

test "config_edit.addService: ignores service names inside comments and strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes =
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": {
        \\    // "api": "old",
        \\    "worker": "echo '// \"api\": x /* ]'"
        \\  }}]
        \\}
    ;

    const added = try testAdded(&arena, bytes, null, .{ .name = "api", .command = "cargo run" });

    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [{"name": "backend", "services": {
        \\    // "api": "old",
        \\    "worker": "echo '// \"api\": x /* ]'",
        \\    "api": "cargo run"
        \\  }}]
        \\}
    , added.bytes);
}
