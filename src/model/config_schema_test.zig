//! Keeps schema/zask.schema.json consistent with the config parser.
//!
//! The schema covers structure (keys, types, enums, required fields). References
//! between groups, services, and aliases, duplicate names, and path escapes are
//! checked only by the parser; the tests below fix that boundary.

const std = @import("std");
const config = @import("config.zig");
const diagnostics = @import("diagnostics.zig");
const validate = @import("validate.zig");

const Value = std.json.Value;
const schema_path = "schema/zask.schema.json";
const identifier_pattern = "^[A-Za-z0-9_][A-Za-z0-9_-]*$";

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

/// Validates instances against the subset of JSON Schema draft-07 that
/// zask.schema.json uses. Unsupported keywords fail the test so the schema
/// cannot grow constraints this checker silently ignores.
const TestSchemaChecker = struct {
    root: Value,

    fn accepts(self: TestSchemaChecker, instance: Value) anyerror!bool {
        return self.check(self.root, instance);
    }

    fn check(self: TestSchemaChecker, schema: Value, instance: Value) anyerror!bool {
        if (schema == .bool) return schema.bool;
        if (schema != .object) return error.InvalidSchema;
        var it = schema.object.iterator();
        while (it.next()) |entry| {
            if (!try self.checkKeyword(schema, entry.key_ptr.*, entry.value_ptr.*, instance)) return false;
        }
        return true;
    }

    fn checkKeyword(self: TestSchemaChecker, schema: Value, keyword: []const u8, arg: Value, instance: Value) anyerror!bool {
        const annotations = [_][]const u8{ "$schema", "title", "description", "default", "definitions" };
        for (annotations) |annotation| if (std.mem.eql(u8, keyword, annotation)) return true;

        if (std.mem.eql(u8, keyword, "$ref")) return self.check(try self.resolveRef(arg), instance);
        if (std.mem.eql(u8, keyword, "type")) return testMatchesType(arg.string, instance);
        if (std.mem.eql(u8, keyword, "enum")) {
            for (arg.array.items) |item| if (testJsonEql(item, instance)) return true;
            return false;
        }
        if (std.mem.eql(u8, keyword, "const")) return testJsonEql(arg, instance);
        if (std.mem.eql(u8, keyword, "oneOf")) {
            var matched: usize = 0;
            for (arg.array.items) |option| {
                if (try self.check(option, instance)) matched += 1;
            }
            return matched == 1;
        }
        if (std.mem.eql(u8, keyword, "minLength")) {
            if (instance != .string) return true;
            const len = try std.unicode.utf8CountCodepoints(instance.string);
            return len >= @as(usize, @intCast(arg.integer));
        }
        if (std.mem.eql(u8, keyword, "minimum")) {
            return switch (instance) {
                .integer => |n| n >= arg.integer,
                .float => |f| f >= @as(f64, @floatFromInt(arg.integer)),
                else => true,
            };
        }
        if (std.mem.eql(u8, keyword, "pattern")) {
            if (!std.mem.eql(u8, arg.string, identifier_pattern)) return error.UnsupportedSchemaPattern;
            if (instance != .string) return true;
            validate.identifier(instance.string) catch return false;
            return true;
        }
        if (std.mem.eql(u8, keyword, "required")) {
            if (instance != .object) return true;
            for (arg.array.items) |key| if (!instance.object.contains(key.string)) return false;
            return true;
        }
        if (std.mem.eql(u8, keyword, "properties")) {
            if (instance != .object) return true;
            var props = arg.object.iterator();
            while (props.next()) |prop| {
                const child = instance.object.get(prop.key_ptr.*) orelse continue;
                if (!try self.check(prop.value_ptr.*, child)) return false;
            }
            return true;
        }
        if (std.mem.eql(u8, keyword, "additionalProperties")) {
            if (instance != .object) return true;
            const declared = schema.object.get("properties");
            var fields = instance.object.iterator();
            while (fields.next()) |field| {
                if (declared) |props| if (props.object.contains(field.key_ptr.*)) continue;
                if (!try self.check(arg, field.value_ptr.*)) return false;
            }
            return true;
        }
        if (std.mem.eql(u8, keyword, "items")) {
            if (instance != .array) return true;
            for (instance.array.items) |item| if (!try self.check(arg, item)) return false;
            return true;
        }
        std.debug.print("unsupported schema keyword: {s}\n", .{keyword});
        return error.UnsupportedSchemaKeyword;
    }

    fn resolveRef(self: TestSchemaChecker, ref: Value) !Value {
        const prefix = "#/definitions/";
        if (!std.mem.startsWith(u8, ref.string, prefix)) return error.UnsupportedSchemaRef;
        const definitions = self.root.object.get("definitions") orelse return error.UnsupportedSchemaRef;
        return definitions.object.get(ref.string[prefix.len..]) orelse error.UnsupportedSchemaRef;
    }
};

fn testMatchesType(name: []const u8, instance: Value) !bool {
    if (std.mem.eql(u8, name, "object")) return instance == .object;
    if (std.mem.eql(u8, name, "array")) return instance == .array;
    if (std.mem.eql(u8, name, "string")) return instance == .string;
    if (std.mem.eql(u8, name, "boolean")) return instance == .bool;
    if (std.mem.eql(u8, name, "integer")) return switch (instance) {
        .integer, .number_string => true,
        .float => |f| @floor(f) == f,
        else => false,
    };
    return error.UnsupportedSchemaType;
}

fn testJsonEql(a: Value, b: Value) bool {
    return switch (a) {
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        .integer => |x| b == .integer and b.integer == x,
        else => false,
    };
}

fn testLoadSchema(arena: std.mem.Allocator) !TestSchemaChecker {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), schema_path, arena, .limited(1024 * 1024));
    return .{ .root = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{}) };
}

fn testReadFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, arena, .limited(1024 * 1024));
}

fn testSchemaAt(checker: TestSchemaChecker, path: []const []const u8) !Value {
    var node = checker.root;
    for (path) |segment| {
        node = node.object.get(segment) orelse return error.MissingSchemaPath;
        if (node == .object) if (node.object.get("$ref")) |ref| {
            node = try checker.resolveRef(ref);
        };
    }
    return node;
}

fn testParserAccepts(arena: std.mem.Allocator, json: []const u8) !bool {
    const value = try config.parseJsonBytes(arena, json);
    var diags = diagnostics.Diagnostics.init(arena);
    try config.validateAll(arena, value, &diags);
    return diags.isEmpty();
}

fn testSchemaAccepts(arena: std.mem.Allocator, checker: TestSchemaChecker, json: []const u8) !bool {
    return checker.accepts(try config.parseJsonBytes(arena, json));
}

fn testExpectSameStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |item| {
        var found = false;
        for (actual) |other| {
            if (std.mem.eql(u8, item, other)) found = true;
        }
        if (!found) {
            std.debug.print("missing: {s}\n", .{item});
            return error.TestExpectedEqual;
        }
    }
}

fn testObjectKeys(arena: std.mem.Allocator, object: Value) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = object.object.iterator();
    while (it.next()) |entry| try list.append(arena, entry.key_ptr.*);
    return list.items;
}

fn testEnumStrings(arena: std.mem.Allocator, schema: Value) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (schema.object.get("enum").?.array.items) |item| try list.append(arena, item.string);
    return list.items;
}

test "config.schema: object properties match parser keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());
    const cases = [_]struct {
        path: []const []const u8,
        keys: []const []const u8,
    }{
        .{ .path = &.{}, .keys = &config.object_keys.root },
        .{ .path = &.{ "properties", "project" }, .keys = &config.object_keys.project },
        .{ .path = &.{ "properties", "docker" }, .keys = &config.object_keys.docker },
        .{ .path = &.{ "definitions", "group" }, .keys = &config.object_keys.group },
        .{ .path = &.{ "definitions", "service" }, .keys = &config.object_keys.service },
        .{ .path = &.{ "definitions", "service", "properties", "healthcheck" }, .keys = &config.object_keys.healthcheck },
        .{ .path = &.{ "definitions", "dockerStep" }, .keys = &config.object_keys.docker_step },
        .{ .path = &.{ "definitions", "groupStep" }, .keys = &config.object_keys.group_step },
        .{ .path = &.{ "definitions", "commandStep" }, .keys = &config.object_keys.command_step },
        .{ .path = &.{ "definitions", "precheck" }, .keys = &config.object_keys.precheck },
        .{ .path = &.{ "definitions", "startProfile" }, .keys = &config.object_keys.start_profile },
    };

    for (cases) |case| {
        const node = try testSchemaAt(checker, case.path);
        try std.testing.expectEqual(false, node.object.get("additionalProperties").?.bool);
        try testExpectSameStrings(case.keys, try testObjectKeys(arena.allocator(), node.object.get("properties").?));
    }
}

test "config.schema: enum values match parser values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());
    // An empty runtime means "no prefix" in the parser, so the schema lists it too.
    const runtimes = config.allowed_values.runtime ++ [_][]const u8{""};
    const cases = [_]struct {
        path: []const []const u8,
        values: []const []const u8,
    }{
        .{ .path = &.{ "definitions", "service", "properties", "runtime" }, .values = &runtimes },
        .{ .path = &.{ "definitions", "service", "properties", "healthcheck", "properties", "type" }, .values = &config.allowed_values.healthcheck_type },
        .{ .path = &.{ "definitions", "commandStep", "properties", "on_fail" }, .values = &config.allowed_values.on_fail },
        .{ .path = &.{ "definitions", "precheck", "properties", "on_fail" }, .values = &config.allowed_values.on_fail },
    };

    for (cases) |case| {
        const node = try testSchemaAt(checker, case.path);
        try testExpectSameStrings(case.values, try testEnumStrings(arena.allocator(), node));
    }
}

test "config.schema: accepts fixtures the parser accepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());
    const paths = [_][]const u8{
        "testdata/synthetic.json",
        "testdata/showcase/receipt-lab/zask.json",
    };

    for (paths) |path| {
        const json = try testReadFile(arena.allocator(), path);
        try std.testing.expect(try testParserAccepts(arena.allocator(), json));
        try std.testing.expect(try testSchemaAccepts(arena.allocator(), checker, json));
    }
}

test "config.schema: accepts every public key with $schema" {
    const json =
        \\{
        \\  "$schema": "./schema/zask.schema.json",
        \\  "project": {"name":"demo","root":"~/work/demo"},
        \\  "docker": {"compose":"infra/compose.yaml","wait_timeout_seconds":30},
        \\  "env_file": [".env"],
        \\  "groups": [
        \\    {"name":"backend","env_file":"backend/.env","services":[
        \\      {"name":"api","dir":"backend","runtime":"cargo","command":"run","port":8080,
        \\       "healthcheck":{"type":"http","path":"/ready"},"env_file":".env.local"},
        \\      {"name":"tool","dir":"~/tools","external":true,"runtime":"","command":"watch"}
        \\    ]}
        \\  ],
        \\  "startup_order": [
        \\    {"name":"Docker","docker":true},
        \\    {"name":"Migrate","command":"make migrate","dir":"backend","on_fail":"warn","commands":{"core":"make migrate-core"}},
        \\    {"name":"Backend","group":"backend","wait_ports":[8080],"port_wait_timeout_seconds":0}
        \\  ],
        \\  "prechecks": [{"name":"tool","command":"which tool","on_fail":"abort","hint":"install tool","dir":"backend"}],
        \\  "start_profiles": {"core":{"profile":"core","label":"core only","group_overrides":{"backend":"core"}}},
        \\  "group_aliases": {"core":["api"]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());

    try std.testing.expect(try testParserAccepts(arena.allocator(), json));
    try std.testing.expect(try testSchemaAccepts(arena.allocator(), checker, json));
}

test "config.schema: rejects structural errors the parser rejects" {
    const cases = [_]struct {
        name: []const u8,
        json: []const u8,
    }{
        .{ .name = "missing project", .json =
        \\{"groups":[]}
        },
        .{ .name = "missing groups", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"}}
        },
        .{ .name = "top-level typo", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"prechecs":[]}
        },
        .{ .name = "legacy services", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"services":[]}
        },
        .{ .name = "non-string $schema", .json =
        \\{"$schema":1,"project":{"name":"demo","root":"/tmp/demo"},"groups":[]}
        },
        .{ .name = "invalid project name", .json =
        \\{"project":{"name":"bad name","root":"/tmp/demo"},"groups":[]}
        },
        .{ .name = "empty compose", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"docker":{"compose":""},"groups":[]}
        },
        .{ .name = "empty env_file", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"env_file":"","groups":[]}
        },
        .{ .name = "service key typo", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","comand":"serve"}]}]}
        },
        .{ .name = "string port", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve","port":"80"}]}]}
        },
        .{ .name = "unknown runtime", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve","runtime":"deno"}]}]}
        },
        .{ .name = "unknown healthcheck type", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve","healthcheck":{"type":"grpc"}}]}]}
        },
        .{ .name = "docker step false", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"startup_order":[{"docker":false}]}
        },
        .{ .name = "step with two kinds", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"startup_order":[{"docker":true,"command":"x"}]}
        },
        .{ .name = "step with no kind", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"startup_order":[{"name":"x"}]}
        },
        .{ .name = "negative port wait", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","command":"serve"}]}],"startup_order":[{"group":"be","port_wait_timeout_seconds":-1}]}
        },
        .{ .name = "unknown command step on_fail", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"startup_order":[{"command":"x","on_fail":"ignore"}]}
        },
        .{ .name = "unknown precheck on_fail", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"prechecks":[{"command":"x","on_fail":"ignore"}]}
        },
        .{ .name = "profile without profile", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"start_profiles":{"core":{"label":"core"}}}
        },
        .{ .name = "alias value not array", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"group_aliases":{"core":"api"}}
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expect(!try testParserAccepts(arena.allocator(), case.json));
        try std.testing.expect(!try testSchemaAccepts(arena.allocator(), checker, case.json));
    }
}

test "config.schema: leaves references and paths to the parser" {
    const cases = [_]struct {
        name: []const u8,
        json: []const u8,
    }{
        .{ .name = "unknown startup group", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"startup_order":[{"group":"missing"}]}
        },
        .{ .name = "unknown alias service", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[],"group_aliases":{"core":["missing"]}}
        },
        .{ .name = "duplicate service", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"a","services":[{"name":"api","command":"x"}]},{"name":"b","services":[{"name":"api","command":"y"}]}]}
        },
        .{ .name = "service dir escapes root", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"groups":[{"name":"be","services":[{"name":"api","dir":"../escape","command":"serve"}]}]}
        },
        .{ .name = "compose dir escapes root", .json =
        \\{"project":{"name":"demo","root":"/tmp/demo"},"docker":{"compose":"../escape/compose.yaml"},"groups":[]}
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const checker = try testLoadSchema(arena.allocator());

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        try std.testing.expect(!try testParserAccepts(arena.allocator(), case.json));
        try std.testing.expect(try testSchemaAccepts(arena.allocator(), checker, case.json));
    }
}
