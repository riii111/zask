const std = @import("std");
const config_value = @import("config_value.zig");
const validate = @import("validate.zig");

const Value = std.json.Value;
const max_config_bytes = 10 * 1024 * 1024;

pub const Config = struct {
    value: Value,
    home: []const u8,

    pub fn parse(gpa: std.mem.Allocator, json: []const u8, home: []const u8) !Config {
        const value = try parseJsonBytes(gpa, json);
        return .{
            .value = try normalizeConfig(gpa, value),
            .home = home,
        };
    }

    pub fn projectName(self: Config) ![]const u8 {
        const name = try self.requiredString(&.{ "project", "name" });
        try validate.identifier(name);
        return name;
    }

    pub fn sessionName(self: Config) ![]const u8 {
        const name = self.optionalString(&.{ "project", "session_name" }, try self.projectName());
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

pub fn parseJsonBytes(gpa: std.mem.Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, gpa, bytes, .{ .ignore_unknown_fields = true });
}

pub fn normalizeConfig(gpa: std.mem.Allocator, source: Value) !Value {
    if (source != .object) return error.InvalidConfig;
    if (source.object.get("services") != null or source.object.get("phases") != null) return error.InvalidConfig;
    try validateObjectKeys(source, &.{ "project", "docker", "startup_order", "prechecks", "start_profiles", "group_aliases", "groups" });
    try validateProject(source);
    try validatePrechecks(source);
    try validateStartProfiles(source);
    try validateGroupAliases(source);

    var root: std.json.ObjectMap = .empty;
    try copyObjectField(gpa, &root, source, "project");
    try normalizeDocker(gpa, &root, source);
    try normalizeServices(gpa, &root, source);
    try normalizeStartupOrder(gpa, &root, source);
    try copyObjectField(gpa, &root, source, "prechecks");
    try copyObjectField(gpa, &root, source, "start_profiles");
    try copyObjectField(gpa, &root, source, "group_aliases");
    return .{ .object = root };
}

fn normalizeDocker(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const docker = source.object.get("docker") orelse return;
    if (docker != .object) return error.InvalidConfig;
    try validateObjectKeys(docker, &.{ "compose", "wait_timeout_seconds" });
    const compose = docker.object.get("compose") orelse return error.InvalidConfig;
    if (compose != .string) return error.InvalidConfig;
    if (compose.string.len == 0) return error.InvalidConfig;

    var object: std.json.ObjectMap = .empty;
    try object.put(gpa, "enabled", .{ .bool = true });
    const dir = std.fs.path.dirname(compose.string) orelse "";
    const file = std.fs.path.basename(compose.string);
    if (dir.len != 0) try object.put(gpa, "dir", .{ .string = dir });
    try object.put(gpa, "compose_file", .{ .string = file });
    if (docker.object.get("wait_timeout_seconds")) |timeout| {
        if (timeout != .integer) return error.InvalidConfig;
        try object.put(gpa, "wait_timeout", timeout);
    }
    try root.put(gpa, "docker", .{ .object = object });
}

fn normalizeServices(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const groups = source.object.get("groups") orelse return error.InvalidConfig;
    if (groups != .array) return error.InvalidConfig;

    var group_names = std.StringHashMap(void).init(gpa);
    defer group_names.deinit();
    var service_names = std.StringHashMap(void).init(gpa);
    defer service_names.deinit();
    var services = std.json.Array.init(gpa);
    errdefer services.deinit();
    for (groups.array.items) |group| {
        if (group != .object) return error.InvalidConfig;
        try validateObjectKeys(group, &.{ "name", "services" });
        const name = try config_value.requiredObjectString(group, "name");
        try validate.identifier(name);
        if (group_names.contains(name)) return error.InvalidConfig;
        try group_names.put(name, {});
        const group_services = group.object.get("services") orelse return error.InvalidConfig;
        if (group_services != .array) return error.InvalidConfig;
        for (group_services.array.items) |service| {
            if (service != .object) return error.InvalidConfig;
            try validateService(service);
            const service_name = try config_value.requiredObjectString(service, "name");
            if (service_names.contains(service_name)) return error.InvalidConfig;
            try service_names.put(service_name, {});
            const normalized = try cloneObjectWithField(gpa, service, "group", .{ .string = name });
            try services.append(.{ .object = normalized });
        }
    }
    try root.put(gpa, "services", .{ .array = services });
}

fn normalizeStartupOrder(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const startup_order = source.object.get("startup_order") orelse return;
    if (startup_order != .array) return error.InvalidConfig;

    var phases = std.json.Array.init(gpa);
    errdefer phases.deinit();
    for (startup_order.array.items) |step| {
        if (step != .object) return error.InvalidConfig;
        var phase: std.json.ObjectMap = .empty;
        const kind = try validateStartupStep(step);
        switch (kind) {
            .docker => {
                try phase.put(gpa, "type", .{ .string = "docker" });
            },
            .group => {
                const group = step.object.get("group").?;
                if (group != .string) return error.InvalidConfig;
                var groups = std.json.Array.init(gpa);
                try groups.append(group);
                try phase.put(gpa, "groups", .{ .array = groups });
                if (step.object.get("wait_ports")) |wait_ports| {
                    if (wait_ports != .array) return error.InvalidConfig;
                    for (wait_ports.array.items) |port| {
                        if (port != .integer) return error.InvalidConfig;
                    }
                    try phase.put(gpa, "wait_ports", wait_ports);
                }
            },
            .command => {
                const command = step.object.get("command").?;
                if (command != .string) return error.InvalidConfig;
                try phase.put(gpa, "type", .{ .string = "command" });
                try phase.put(gpa, "command", command);
                try copyObjectField(gpa, &phase, step, "dir");
                try copyObjectField(gpa, &phase, step, "on_fail");
                try copyObjectField(gpa, &phase, step, "commands");
            },
        }
        try copyObjectField(gpa, &phase, step, "name");
        try phases.append(.{ .object = phase });
    }
    try root.put(gpa, "phases", .{ .array = phases });
}

fn copyObjectField(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value, key: []const u8) !void {
    if (source.object.get(key)) |value| try root.put(gpa, key, value);
}

fn cloneObjectWithField(gpa: std.mem.Allocator, source: Value, key: []const u8, value: Value) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(gpa);
    var it = source.object.iterator();
    while (it.next()) |entry| try object.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
    try object.put(gpa, key, value);
    return object;
}

const StartupStepKind = enum {
    docker,
    group,
    command,
};

fn validateStartupStep(step: Value) !StartupStepKind {
    try validateOptionalString(step, "name");
    const has_docker = step.object.get("docker") != null;
    const has_group = step.object.get("group") != null;
    const has_command = step.object.get("command") != null;
    const kind_count: u8 = @as(u8, @intFromBool(has_docker)) + @as(u8, @intFromBool(has_group)) + @as(u8, @intFromBool(has_command));
    if (kind_count != 1) return error.InvalidConfig;

    if (has_docker) {
        try validateObjectKeys(step, &.{ "name", "docker" });
        const docker = step.object.get("docker").?;
        if (docker != .bool or !docker.bool) return error.InvalidConfig;
        return .docker;
    }
    if (has_group) {
        try validateObjectKeys(step, &.{ "name", "group", "wait_ports" });
        if (step.object.get("group").? != .string) return error.InvalidConfig;
        if (step.object.get("wait_ports")) |wait_ports| {
            if (wait_ports != .array) return error.InvalidConfig;
            for (wait_ports.array.items) |port| {
                if (port != .integer) return error.InvalidConfig;
            }
        }
        return .group;
    }

    try validateObjectKeys(step, &.{ "name", "command", "dir", "on_fail", "commands" });
    if (step.object.get("command").? != .string) return error.InvalidConfig;
    try validateOptionalString(step, "dir");
    try validateOptionalString(step, "on_fail");
    if (step.object.get("commands")) |commands| try validateStringObject(commands);
    return .command;
}

fn validateProject(source: Value) !void {
    const project = source.object.get("project") orelse return error.InvalidConfig;
    if (project != .object) return error.InvalidConfig;
    try validateObjectKeys(project, &.{ "name", "root", "session_name" });
    _ = try config_value.requiredObjectString(project, "name");
    _ = try config_value.requiredObjectString(project, "root");
    try validateOptionalString(project, "session_name");
}

fn validateService(service: Value) !void {
    try validateObjectKeys(service, &.{ "name", "dir", "runtime", "command", "external", "port", "healthcheck" });
    _ = try config_value.requiredObjectString(service, "name");
    _ = try config_value.requiredObjectString(service, "command");
    try validateOptionalString(service, "dir");
    try validateOptionalString(service, "runtime");
    if (service.object.get("external")) |external| if (external != .bool) return error.InvalidConfig;
    if (service.object.get("port")) |port| if (port != .integer) return error.InvalidConfig;
    if (service.object.get("healthcheck")) |healthcheck| {
        if (healthcheck != .object) return error.InvalidConfig;
        try validateObjectKeys(healthcheck, &.{ "type", "path" });
        try validateOptionalString(healthcheck, "type");
        try validateOptionalString(healthcheck, "path");
    }
}

fn validatePrechecks(source: Value) !void {
    const prechecks = source.object.get("prechecks") orelse return;
    if (prechecks != .array) return error.InvalidConfig;
    for (prechecks.array.items) |check| {
        if (check != .object) return error.InvalidConfig;
        try validateObjectKeys(check, &.{ "name", "command", "on_fail", "hint", "dir" });
        _ = try config_value.requiredObjectString(check, "command");
        try validateOptionalString(check, "name");
        try validateOptionalString(check, "on_fail");
        try validateOptionalString(check, "hint");
        try validateOptionalString(check, "dir");
    }
}

fn validateStartProfiles(source: Value) !void {
    const profiles = source.object.get("start_profiles") orelse return;
    if (profiles != .object) return error.InvalidConfig;
    var it = profiles.object.iterator();
    while (it.next()) |entry| {
        const profile = entry.value_ptr.*;
        if (profile != .object) return error.InvalidConfig;
        try validateObjectKeys(profile, &.{ "profile", "label", "group_overrides" });
        _ = try config_value.requiredObjectString(profile, "profile");
        try validateOptionalString(profile, "label");
        if (profile.object.get("group_overrides")) |overrides| try validateStringObject(overrides);
    }
}

fn validateGroupAliases(source: Value) !void {
    const aliases = source.object.get("group_aliases") orelse return;
    if (aliases != .object) return error.InvalidConfig;
    var it = aliases.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .array) return error.InvalidConfig;
        for (entry.value_ptr.array.items) |value| {
            if (value != .string) return error.InvalidConfig;
        }
    }
}

fn validateStringObject(value: Value) !void {
    if (value != .object) return error.InvalidConfig;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidConfig;
    }
}

fn validateOptionalString(node: Value, key: []const u8) !void {
    if (node.object.get(key)) |value| {
        if (value != .string) return error.InvalidConfig;
    }
}

fn validateObjectKeys(node: Value, allowed: []const []const u8) !void {
    if (node != .object) return error.InvalidConfig;
    var it = node.object.iterator();
    while (it.next()) |entry| {
        if (!isAllowedKey(entry.key_ptr.*, allowed)) return error.InvalidConfig;
    }
}

fn isAllowedKey(key: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| {
        if (std.mem.eql(u8, key, item)) return true;
    }
    return false;
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
        \\  "groups": [
        \\    {"name":"be","services":[{"name":"api","dir":"backend","command":"serve"}]},
        \\    {"name":"fe","services":[{"name":"web","dir":"~/apps/web","runtime":"npm","command":"run dev","external":true}]}
        \\  ],
        \\  "group_aliases": {"all":["api","web"]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);
    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings("demo", try cfg.sessionName());
    try std.testing.expectEqualStrings("/home/me/work/demo", try cfg.projectRoot(arena.allocator()));
    try std.testing.expectEqualStrings("/home/me/work/demo/backend", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
    try std.testing.expectEqualStrings("npm run dev", try Config.serviceStartCommand(arena.allocator(), try cfg.findService("web")));
    const group = try cfg.resolveGroup(arena.allocator(), "all");
    try std.testing.expectEqualStrings("api", group[0]);
}

test "config.sessionName: defaults to project name" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqualStrings("demo", try cfg.sessionName());
}

test "resolves profiles and phase group overrides" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[
        \\      {"name":"api","dir":"backend","command":"serve"},
        \\      {"name":"worker","dir":"backend","command":"work"}
        \\    ]}
        \\  ],
        \\  "group_aliases": {"core-backend":["api"]},
        \\  "start_profiles": {
        \\    "core": {
        \\      "profile": "core",
        \\      "label": "core services",
        \\      "group_overrides": {"backend":"core-backend"}
        \\    }
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqualStrings("core", cfg.resolveStartProfileOption("--core").?);
    try std.testing.expectEqualStrings("core services", cfg.startProfileLabel("core"));
    try std.testing.expectEqualStrings("core-backend", cfg.resolvePhaseGroup("core", "backend"));

    const group = try cfg.resolveGroup(arena.allocator(), "backend");
    try std.testing.expectEqual(@as(usize, 2), group.len);
}

test "resolves command phase profile overrides and fallback" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [
        \\    {"command":"default","commands":{"core":"override"}},
        \\    {"command":"fallback","commands":{"core":"only-core"}}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);
    const phases = cfg.phases();

    try std.testing.expectEqualStrings("override", try Config.commandPhaseCommand(phases[0], "core"));
    try std.testing.expectEqualStrings("default", try Config.commandPhaseCommand(phases[0], "all"));
    try std.testing.expectEqualStrings("fallback", try Config.commandPhaseCommand(phases[1], "all"));
}

test "rejects unknown runtimes and missing services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","runtime":"unknown","command":"serve"}]}]
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
        \\  "groups": [],
        \\  "group_aliases": {"bad":["api", 42]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "rejects legacy flat services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "services": [{"name":"api","command":"serve"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "rejects legacy phases" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "phases": [{"type":"docker"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.parse: rejects malformed docker config" {
    const cases = [_][]const u8{
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": true,
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml", "wait_timeout_seconds": "30"},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": ""},
        \\  "groups": []
        \\}
        ,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (cases) |json| {
        try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
    }
}

test "config.parse: rejects malformed startup order" {
    const cases = [_][]const u8{
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"unexpected": true}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "wait_ports": ["3000"]}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "dir": 42}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "on_fail": false}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "commands": {"core": false}}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"name": 42, "command": "setup"}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"docker": false}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "dir": "backend"}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "command": "setup"}]
        \\}
        ,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (cases) |json| {
        try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
    }
}

test "config.parse: rejects duplicate groups and services" {
    const cases = [_][]const u8{
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[]},
        \\    {"name":"backend","services":[]}
        \\  ]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[{"name":"api","command":"serve"}]},
        \\    {"name":"worker","services":[{"name":"api","command":"work"}]}
        \\  ]
        \\}
        ,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (cases) |json| {
        try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
    }
}

test "config.parse: rejects unknown public schema fields" {
    const cases = [_][]const u8{
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "unexpected": true,
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo","unexpected":true},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "docker": {"compose": "compose.yaml", "unexpected": true},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","unexpected":true,"services":[]}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","command":"serve","unexpected":true}]}]
        \\}
        ,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    for (cases) |json| {
        try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
    }
}

test "rejects invalid identifiers at config boundaries" {
    const json =
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo","session_name":"demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api.bad","dir":"backend","command":"serve"}]}]
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
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"../escape","command":"serve"}]}]
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
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"../external","external":true,"command":"serve"}]}]
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
        \\  "docker": {"compose": "../escape/compose.yaml"},
        \\  "groups": []
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
    try std.testing.expectEqual(@as(?i64, 18080), Config.servicePort(try cfg.findService("api")));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("/tmp/zask-demo/infra", try cfg.dockerDir(arena.allocator()));
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
    try std.testing.expectEqual(@as(i64, 5), cfg.dockerWaitTimeout());
}
