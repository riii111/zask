const std = @import("std");
const config_value = @import("config_value.zig");
const validate = @import("validate.zig");

const Value = std.json.Value;
const max_config_bytes = 10 * 1024 * 1024;

pub const Config = struct {
    value: Value,
    home: []const u8,

    pub fn parse(gpa: std.mem.Allocator, json: []const u8, home: []const u8) !Config {
        return .{
            .value = try std.json.parseFromSliceLeaky(Value, gpa, json, .{ .ignore_unknown_fields = true }),
            .home = home,
        };
    }

    pub fn projectName(self: Config) ![]const u8 {
        const name = try self.requiredString(&.{ "project", "name" });
        try validate.identifier(name);
        return name;
    }

    pub fn sessionName(self: Config) ![]const u8 {
        const name = try self.requiredString(&.{ "project", "session_name" });
        try validate.identifier(name);
        return name;
    }

    pub fn projectRoot(self: Config, gpa: std.mem.Allocator) ![]const u8 {
        return self.expandHome(gpa, try self.requiredString(&.{ "project", "root" }));
    }

    pub fn dockerEnabled(self: Config) bool {
        return self.optionalBool(&.{ "docker", "enabled" }, false);
    }

    pub fn dockerDir(self: Config, gpa: std.mem.Allocator) ![]const u8 {
        const root = try self.projectRoot(gpa);
        const dir = self.optionalString(&.{ "docker", "dir" }, "");
        if (dir.len == 0) return root;
        try validate.relativeSubPath(dir);
        return std.fs.path.join(gpa, &.{ root, dir });
    }

    pub fn dockerComposeFile(self: Config) []const u8 {
        return self.optionalString(&.{ "docker", "compose_file" }, "docker-compose.yml");
    }

    pub fn dockerWaitTimeout(self: Config) i64 {
        return self.optionalInt(&.{ "docker", "wait_timeout" }, 60);
    }

    pub fn logKeepSessions(self: Config) i64 {
        return self.optionalInt(&.{ "options", "log_keep_sessions" }, 3);
    }

    pub fn popupWidth(self: Config) []const u8 {
        return self.optionalString(&.{ "options", "popup_width" }, "80%");
    }

    pub fn popupHeight(self: Config) []const u8 {
        return self.optionalString(&.{ "options", "popup_height" }, "80%");
    }

    pub fn services(self: Config) ![]const Value {
        const node = try self.required(&.{"services"});
        if (node != .array) return error.InvalidConfig;
        return node.array.items;
    }

    pub fn phases(self: Config) []const Value {
        const node = self.get(&.{"phases"}) orelse return &.{};
        if (node != .array) return &.{};
        return node.array.items;
    }

    pub fn prechecks(self: Config) []const Value {
        const node = self.get(&.{"prechecks"}) orelse return &.{};
        if (node != .array) return &.{};
        return node.array.items;
    }

    pub fn serviceName(service: Value) ![]const u8 {
        const name = try config_value.requiredObjectString(service, "name");
        try validate.identifier(name);
        return name;
    }

    pub fn serviceGroup(service: Value) []const u8 {
        return config_value.optionalObjectString(service, "group", "");
    }

    pub fn servicePort(service: Value) ?i64 {
        return config_value.optionalObjectInt(service, "port");
    }

    pub fn serviceHealthcheckType(service: Value) []const u8 {
        const healthcheck = serviceHealthcheck(service) orelse return "tcp";
        return config_value.optionalObjectString(healthcheck, "type", "tcp");
    }

    pub fn serviceHealthcheckPath(service: Value) []const u8 {
        const healthcheck = serviceHealthcheck(service) orelse return "/health";
        return config_value.optionalObjectString(healthcheck, "path", "/health");
    }

    pub fn serviceDir(self: Config, gpa: std.mem.Allocator, service: Value) ![]const u8 {
        const dir = config_value.optionalObjectString(service, "dir", ".");
        const external = config_value.optionalObjectBool(service, "external", false);
        if (external or std.fs.path.isAbsolute(dir) or std.mem.startsWith(u8, dir, "~")) {
            return self.expandHome(gpa, dir);
        }
        try validate.relativeSubPath(dir);
        return std.fs.path.join(gpa, &.{ try self.projectRoot(gpa), dir });
    }

    pub fn serviceStartCommand(gpa: std.mem.Allocator, service: Value) ![]const u8 {
        const command = try config_value.requiredObjectString(service, "command");
        const runtime = config_value.optionalObjectString(service, "runtime", "");
        if (runtime.len == 0) return command;
        if (!isAllowedRuntime(runtime)) return error.UnknownRuntime;
        return std.fmt.allocPrint(gpa, "{s} {s}", .{ runtime, command });
    }

    pub fn findService(self: Config, name: []const u8) !Value {
        for (try self.services()) |service| {
            if (std.mem.eql(u8, try serviceName(service), name)) return service;
        }
        return error.UnknownService;
    }

    pub fn resolveGroup(self: Config, gpa: std.mem.Allocator, name: []const u8) ![][]const u8 {
        if (self.get(&.{ "group_aliases", name })) |alias| {
            if (alias == .array) return stringArray(gpa, alias.array.items);
        }

        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        for (try self.services()) |service| {
            if (std.mem.eql(u8, serviceGroup(service), name)) {
                try list.append(gpa, try serviceName(service));
            }
        }
        if (list.items.len == 0) return error.UnknownGroup;
        return list.toOwnedSlice(gpa);
    }

    pub fn resolveStartProfileOption(self: Config, option: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, option, "--")) return null;
        const key = option[2..];
        if (key.len == 0) return null;
        const node = self.get(&.{ "start_profiles", key, "profile" }) orelse return null;
        return if (node == .string) node.string else null;
    }

    pub fn startProfileLabel(self: Config, profile: []const u8) []const u8 {
        const profiles = self.get(&.{"start_profiles"}) orelse return profile;
        if (profiles != .object) return profile;
        var it = profiles.object.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (p != .object) continue;
            const prof = p.object.get("profile") orelse continue;
            if (prof == .string and std.mem.eql(u8, prof.string, profile)) {
                const label = p.object.get("label") orelse return profile;
                if (label == .string) return label.string;
            }
        }
        return profile;
    }

    pub fn resolvePhaseGroup(self: Config, start_profile: []const u8, group: []const u8) []const u8 {
        const profiles = self.get(&.{"start_profiles"}) orelse return group;
        if (profiles != .object) return group;
        var it = profiles.object.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            if (p != .object) continue;
            const prof = p.object.get("profile") orelse continue;
            if (prof != .string or !std.mem.eql(u8, prof.string, start_profile)) continue;
            const override = p.object.get("group_overrides") orelse return group;
            if (override != .object) return group;
            const value = override.object.get(group) orelse return group;
            if (value == .string) return value.string;
        }
        return group;
    }

    pub fn commandPhaseCommand(phase: Value, start_profile: []const u8) ![]const u8 {
        if (phase != .object) return error.InvalidConfig;
        if (phase.object.get("commands")) |commands| {
            if (commands == .object) {
                if (commands.object.get(start_profile)) |cmd| {
                    if (cmd == .string) return cmd.string;
                }
            }
        }
        return config_value.requiredObjectString(phase, "command");
    }

    pub fn dockerExecDefault(self: Config, container: []const u8) []const u8 {
        const node = self.get(&.{ "docker", "exec_defaults", container }) orelse return "bash";
        return if (node == .string) node.string else "bash";
    }

    pub fn requiredString(self: Config, path: []const []const u8) ![]const u8 {
        return self.view().requiredString(path);
    }

    fn required(self: Config, path: []const []const u8) !Value {
        return self.view().required(path);
    }

    fn get(self: Config, path: []const []const u8) ?Value {
        return self.view().get(path);
    }

    fn optionalString(self: Config, path: []const []const u8, default: []const u8) []const u8 {
        return self.view().optionalString(path, default);
    }

    fn optionalBool(self: Config, path: []const []const u8, default: bool) bool {
        return self.view().optionalBool(path, default);
    }

    fn optionalInt(self: Config, path: []const []const u8, default: i64) i64 {
        return self.view().optionalInt(path, default);
    }

    fn view(self: Config) config_value.View {
        return .{ .value = self.value };
    }

    fn expandHome(self: Config, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (std.mem.eql(u8, path, "~")) return self.home;
        if (std.mem.startsWith(u8, path, "~/")) {
            return std.fs.path.join(gpa, &.{ self.home, path[2..] });
        }
        return path;
    }
};

pub fn loadPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8) !Config {
    const bytes = try readFile(gpa, io, path);
    return Config.parse(gpa, bytes, home);
}

fn serviceHealthcheck(service: Value) ?Value {
    if (service != .object) return null;
    return service.object.get("healthcheck");
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_config_bytes));
}

fn stringArray(gpa: std.mem.Allocator, values: []const Value) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    for (values) |value| {
        if (value != .string) return error.InvalidConfig;
        try list.append(gpa, value.string);
    }
    return list.toOwnedSlice(gpa);
}

fn isAllowedRuntime(runtime: []const u8) bool {
    const allowed = [_][]const u8{ "npm", "yarn", "pnpm", "bun", "cargo", "bacon" };
    for (allowed) |item| {
        if (std.mem.eql(u8, item, runtime)) return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

fn parseTestConfig(arena: *std.heap.ArenaAllocator, json: []const u8) !Config {
    return Config.parse(arena.allocator(), json, "/home/me");
}

test "loads defaults and resolves paths" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"~/work/demo","session_name":"demo"},
        \\  "services": [
        \\    {"name":"api","dir":"backend","command":"serve","group":"be"},
        \\    {"name":"web","dir":"~/apps/web","runtime":"npm","command":"run dev","group":"fe","external":true}
        \\  ],
        \\  "group_aliases": {"all":["api","web"]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);
    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings("/home/me/work/demo", try cfg.projectRoot(arena.allocator()));
    try std.testing.expectEqualStrings("/home/me/work/demo/backend", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
    try std.testing.expectEqualStrings("npm run dev", try Config.serviceStartCommand(arena.allocator(), try cfg.findService("web")));
    const group = try cfg.resolveGroup(arena.allocator(), "all");
    try std.testing.expectEqualStrings("api", group[0]);
}

test "resolves profiles and phase group overrides" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [
        \\    {"name":"api","dir":"backend","command":"serve","group":"backend"},
        \\    {"name":"worker","dir":"backend","command":"work","group":"backend"}
        \\  ],
        \\  "group_aliases": {"core-backend":["api"]},
        \\  "start_profiles": {
        \\    "core": {
        \\      "profile": "core",
        \\      "label": "core services",
        \\      "group_overrides": {"backend":"core-backend"}
        \\    }
        \\  },
        \\  "docker": {"exec_defaults": {"db": "psql"}}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqualStrings("core", cfg.resolveStartProfileOption("--core").?);
    try std.testing.expectEqualStrings("core services", cfg.startProfileLabel("core"));
    try std.testing.expectEqualStrings("core-backend", cfg.resolvePhaseGroup("core", "backend"));
    try std.testing.expectEqualStrings("psql", cfg.dockerExecDefault("db"));

    const group = try cfg.resolveGroup(arena.allocator(), "backend");
    try std.testing.expectEqual(@as(usize, 2), group.len);
}

test "resolves command phase profile overrides and fallback" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [],
        \\  "phases": [
        \\    {"type":"command","command":"default","commands":{"core":"override"}},
        \\    {"type":"command","commands":{"core":"only-core"}}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);
    const phases = cfg.phases();

    try std.testing.expectEqualStrings("override", try Config.commandPhaseCommand(phases[0], "core"));
    try std.testing.expectEqualStrings("default", try Config.commandPhaseCommand(phases[0], "all"));
    try std.testing.expectError(error.InvalidConfig, Config.commandPhaseCommand(phases[1], "all"));
}

test "rejects unknown runtimes and missing services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api","dir":"backend","runtime":"unknown","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.UnknownRuntime, Config.serviceStartCommand(arena.allocator(), try cfg.findService("api")));
    try std.testing.expectError(error.UnknownService, cfg.findService("missing"));
    try std.testing.expectError(error.UnknownGroup, cfg.resolveGroup(arena.allocator(), "missing"));
}

test "rejects malformed group aliases" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [],
        \\  "group_aliases": {"bad":["api", 42]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.InvalidConfig, cfg.resolveGroup(arena.allocator(), "bad"));
}

test "rejects malformed service collection" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": {"api": {"command":"serve"}}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.InvalidConfig, cfg.services());
}

test "rejects invalid identifiers at config boundaries" {
    const json =
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api.bad","dir":"backend","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.InvalidIdentifier, cfg.projectName());
    try std.testing.expectError(error.InvalidIdentifier, Config.serviceName((try cfg.services())[0]));
}

test "rejects project-relative service paths that escape root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api","dir":"../escape","command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.InvalidPath, cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
}

test "allows external service paths outside project root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api","dir":"../external","external":true,"command":"serve","group":"backend"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqualStrings("../external", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
}

test "rejects docker paths that escape project root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"enabled": true, "dir": "../escape"},
        \\  "services": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.InvalidPath, cfg.dockerDir(arena.allocator()));
}

test "parses synthetic fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const cfg = try loadPath(arena.allocator(), threaded.io(), "testdata/synthetic.json", "/home/me");

    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqual(@as(usize, 3), (try cfg.services()).len);
    try std.testing.expectEqual(@as(usize, 3), cfg.phases().len);
    try std.testing.expectEqualStrings("core-backend", cfg.resolvePhaseGroup("core", "backend"));
    try std.testing.expectEqualStrings("psql", cfg.dockerExecDefault("db"));
    try std.testing.expectEqual(@as(?i64, 18080), Config.servicePort(try cfg.findService("api")));
}
