const std = @import("std");
const diagnostics = @import("../../model/diagnostics.zig");
const paths = @import("../../platform/paths.zig");
const service_add = @import("../../workflow/service_add.zig");
const Context = @import("context.zig").Context;

pub const Options = struct {
    name: []const u8,
    command: []const u8,
    group: ?[]const u8 = null,
    port: ?u16 = null,

    pub fn parse(args: []const []const u8) !Options {
        var positional: [2][]const u8 = undefined;
        var positional_count: usize = 0;
        var group: ?[]const u8 = null;
        var port: ?u16 = null;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--group")) {
                if (group != null or i + 1 >= args.len) return error.InvalidArguments;
                i += 1;
                group = args[i];
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (port != null or i + 1 >= args.len) return error.InvalidArguments;
                i += 1;
                port = std.fmt.parseUnsigned(u16, args[i], 10) catch return error.InvalidArguments;
            } else if (std.mem.startsWith(u8, arg, "--") or positional_count == positional.len) {
                return error.InvalidArguments;
            } else {
                positional[positional_count] = arg;
                positional_count += 1;
            }
        }
        if (positional_count != positional.len) return error.InvalidArguments;
        return .{ .name = positional[0], .command = positional[1], .group = group, .port = port };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const gpa = ctx.base.gpa;
    const io = ctx.base.io orelse return error.MissingIo;
    const writer = ctx.writer;
    const edit_lock = try service_add.lockConfigEdits(gpa, io, try paths.runtimeBase(gpa, ctx.base.environ));
    defer edit_lock.release(io);
    var selected = try ctx.selectConfig();
    defer selected.deinitExpectedProjectName(gpa);
    const path = selected.path;

    const file = try ctx.loadSelectedConfig(selected);

    var diags = diagnostics.Diagnostics.init(gpa);
    defer diags.deinit();
    const target: service_add.Target = .{ .path = path, .bytes = file.bytes, .home = file.cfg.home };
    const service: service_add.NewService = .{ .name = opts.name, .command = opts.command, .port = opts.port };
    const outcome = service_add.addService(gpa, io, target, opts.group, service, &diags) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.ExchangeUnsupported => {
            try writer.writeAll("Error: zask add cannot replace the config safely on this filesystem\n");
            try writeUnchanged(writer, path);
            try writer.writeAll("Add the service to the file by hand.\n");
            return error.ConfigWriteFailed;
        },
        else => {
            try writer.print("Error: could not update config: {t}\n", .{err});
            try writer.print("Config: {s}\n", .{path});
            try writer.writeAll("The config was not changed.\n");
            return error.ConfigWriteFailed;
        },
    };

    switch (outcome) {
        .added => |added| {
            try writer.print("Added service '{s}' to group '{s}'\n", .{ opts.name, added.group });
            try writer.print("Config: {s}\n", .{path});
            try writer.print("  {s}\n", .{added.summary});
        },
        .duplicate => |group| {
            try writer.print("Error: service '{s}' already exists in group '{s}'\n", .{ opts.name, group });
            try writeUnchanged(writer, path);
            return error.ServiceAlreadyExists;
        },
        .group_not_found => |names| {
            if (opts.group) |group| {
                try writer.print("Error: group '{s}' not found\n", .{group});
            } else try writer.writeAll("Error: the config has no groups\n");
            try writeGroupNames(writer, names);
            try writeUnchanged(writer, path);
            return error.GroupNotFound;
        },
        .group_required => |names| {
            try writer.writeAll("Error: the config has more than one group; choose one with --group <group>\n");
            try writeGroupNames(writer, names);
            try writeUnchanged(writer, path);
            return error.GroupRequired;
        },
        .invalid => {
            try writer.print("Error: adding service '{s}' would make the config invalid\n", .{opts.name});
            for (diags.slice()) |diagnostic| try writer.print("  {s}: {s}\n", .{ diagnostic.path, diagnostic.message });
            try writeUnchanged(writer, path);
            return error.ServiceNotAdded;
        },
        .too_large => {
            try writer.print("Error: adding service '{s}' would make the config too large to load\n", .{opts.name});
            try writeUnchanged(writer, path);
            return error.ServiceNotAdded;
        },
        .conflict => |kept| {
            try writer.writeAll("Error: the config changed while zask add was writing it\n");
            try writer.print("Config: {s}\n", .{path});
            try writer.print("The replaced version is kept at {s}\n", .{kept});
            try writer.writeAll("Compare it with the config and merge by hand.\n");
            return error.ConfigConflict;
        },
        .changed => {
            try writer.writeAll("Error: the config changed while zask add was editing it\n");
            try writeUnchanged(writer, path);
            try writer.writeAll("Run the command again.\n");
            return error.ConfigChanged;
        },
    }
}

fn writeGroupNames(writer: *std.Io.Writer, names: []const []const u8) !void {
    if (names.len == 0) return;
    try writer.writeAll("Groups:");
    for (names) |name| try writer.print(" {s}", .{name});
    try writer.writeByte('\n');
}

fn writeUnchanged(writer: *std.Io.Writer, path: []const u8) !void {
    try writer.print("Config: {s}\n", .{path});
    try writer.writeAll("The config was not changed.\n");
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const TestRun = struct {
    output: []const u8,
    config: []const u8,
    err: ?anyerror,
};

fn testRunAdd(gpa: std.mem.Allocator, config_name: []const u8, contents: []const u8, args: []const []const u8) !TestRun {
    const cli = @import("../cli.zig");
    const env = @import("../../platform/env.zig");
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = config_name, .data = contents });
    const path = try tmp.dir.realPathFileAlloc(io, config_name, gpa);
    var environ = env.Map.init(gpa);
    try environ.put("HOME", "/home/me");
    try environ.put("XDG_RUNTIME_DIR", try tmp.dir.realPathFileAlloc(io, ".", gpa));
    var diags = diagnostics.Diagnostics.init(gpa);
    const output = try gpa.alloc(u8, 4096);
    var writer: std.Io.Writer = .fixed(output);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "--config", path, "add" });
    try argv.appendSlice(gpa, args);
    var err: ?anyerror = null;
    cli.runWithArgs(.{ .gpa = gpa, .io = io, .environ = &environ, .diagnostics = &diags }, argv.items, &writer) catch |e| {
        err = e;
    };

    const result = try std.mem.replaceOwned(u8, gpa, writer.buffered(), path, "<config>");
    return .{ .output = result, .config = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)), .err = err };
}

const test_config =
    \\{
    \\  "project": {"name": "demo", "root": "/tmp/demo"},
    \\  "groups": [
    \\    {"name": "backend", "services": [{"name": "api", "command": "serve"}]},
    \\    {"name": "frontend", "services": {}}
    \\  ]
    \\}
    \\
;

test "add.Options: parses positionals and options in any order" {
    const opts = try Options.parse(&.{ "--port", "8080", "web", "npm run dev", "--group", "frontend" });

    try std.testing.expectEqualStrings("web", opts.name);
    try std.testing.expectEqualStrings("npm run dev", opts.command);
    try std.testing.expectEqualStrings("frontend", opts.group.?);
    try std.testing.expectEqual(@as(?u16, 8080), opts.port);
}

test "add.Options: rejects invalid arguments" {
    const cases = [_][]const []const u8{
        &.{"web"},
        &.{ "web", "dev", "extra" },
        &.{ "web", "dev", "--port" },
        &.{ "web", "dev", "--port", "http" },
        &.{ "web", "dev", "--port", "70000" },
        &.{ "web", "dev", "--group", "a", "--group", "b" },
        &.{ "web", "dev", "--dir", "web" },
    };
    for (cases) |args| try std.testing.expectError(error.InvalidArguments, Options.parse(args));
}

test "add.run: reports the added entry and edited config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const run_result = try testRunAdd(arena.allocator(), "zask.json", test_config, &.{ "web", "npm run dev", "--group", "frontend", "--port", "5173" });

    try std.testing.expectEqual(@as(?anyerror, null), run_result.err);
    try std.testing.expectEqualStrings(
        \\Added service 'web' to group 'frontend'
        \\Config: <config>
        \\  "web": {"command": "npm run dev", "port": 5173}
        \\
    , run_result.output);
    try std.testing.expectEqualStrings(
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": [{"name": "api", "command": "serve"}]},
        \\    {"name": "frontend", "services": {
        \\      "web": {
        \\        "command": "npm run dev",
        \\        "port": 5173
        \\      }
        \\    }}
        \\  ]
        \\}
        \\
    , run_result.config);
}

test "add.run: leaves the config on refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, err: anyerror, first_line: []const u8, lists_groups: bool = false }{
        .{ .args = &.{ "api", "x", "--group", "frontend" }, .err = error.ServiceAlreadyExists, .first_line = "Error: service 'api' already exists in group 'backend'" },
        .{ .args = &.{ "web", "x" }, .err = error.GroupRequired, .first_line = "Error: the config has more than one group; choose one with --group <group>", .lists_groups = true },
        .{ .args = &.{ "web", "x", "--group", "tools" }, .err = error.GroupNotFound, .first_line = "Error: group 'tools' not found", .lists_groups = true },
        .{ .args = &.{ "web!", "x", "--group", "frontend" }, .err = error.ServiceNotAdded, .first_line = "Error: adding service 'web!' would make the config invalid" },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.first_line});
        const run_result = try testRunAdd(arena.allocator(), "zask.json", test_config, case.args);

        try std.testing.expectEqual(@as(?anyerror, case.err), run_result.err);
        try std.testing.expect(std.mem.startsWith(u8, run_result.output, case.first_line));
        try std.testing.expectEqual(case.lists_groups, std.mem.indexOf(u8, run_result.output, "\nGroups: backend frontend\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, run_result.output, "Config: <config>\nThe config was not changed.\n"));
        try std.testing.expectEqualStrings(test_config, run_result.config);
    }
}

test "add.run: adds to a jsonc config and keeps its comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const commented =
        \\// local services
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": [
        \\      {"name": "api", "command": "serve"} // needs the db
        \\    ]}
        \\  ]
        \\}
        \\
    ;

    const run_result = try testRunAdd(arena.allocator(), "zask.jsonc", commented, &.{ "web", "npm run dev" });

    try std.testing.expectEqual(@as(?anyerror, null), run_result.err);
    try std.testing.expectEqualStrings(
        \\Added service 'web' to group 'backend'
        \\Config: <config>
        \\  {"name": "web", "command": "npm run dev"}
        \\
    , run_result.output);
    try std.testing.expectEqualStrings(
        \\// local services
        \\{
        \\  "project": {"name": "demo", "root": "/tmp/demo"},
        \\  "groups": [
        \\    {"name": "backend", "services": [
        \\      {"name": "api", "command": "serve"}, // needs the db
        \\      {"name": "web", "command": "npm run dev"}
        \\    ]}
        \\  ]
        \\}
        \\
    , run_result.config);
}
