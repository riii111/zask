const std = @import("std");
const config_value = @import("config_value.zig");
const validate = @import("validate.zig");
const diagnostics = @import("diagnostics.zig");

const Value = std.json.Value;
const max_config_bytes = 10 * 1024 * 1024;

/// ユーザーが zask.json に書く公開キー名の単一定義。
/// validate の許可リスト・normalize の入力読み取り・init の生成で共有する。
/// 正規化後の内部キー(services/phases/enabled/compose_file 等)は別語彙なので含めない。
pub const keys = struct {
    // top-level sections
    pub const project = "project";
    pub const docker = "docker";
    pub const groups = "groups";
    pub const startup_order = "startup_order";
    pub const prechecks = "prechecks";
    pub const start_profiles = "start_profiles";
    pub const group_aliases = "group_aliases";

    // project
    pub const name = "name";
    pub const root = "root";

    // docker (authored)
    pub const compose = "compose";
    pub const wait_timeout_seconds = "wait_timeout_seconds";

    // group / service
    pub const services = "services";
    pub const command = "command";
    pub const dir = "dir";
    pub const runtime = "runtime";
    pub const external = "external";
    pub const port = "port";
    pub const healthcheck = "healthcheck";
    pub const @"type" = "type";
    pub const path = "path";

    // startup_order step
    pub const group = "group";
    pub const wait_ports = "wait_ports";
    pub const port_wait_timeout_seconds = "port_wait_timeout_seconds";
    pub const on_fail = "on_fail";
    pub const commands = "commands";

    // prechecks
    pub const hint = "hint";

    // start_profiles
    pub const profile = "profile";
    pub const label = "label";
    pub const group_overrides = "group_overrides";
};

pub const Config = struct {
    value: Value,
    home: []const u8,

    pub fn parse(gpa: std.mem.Allocator, json: []const u8, home: []const u8) !Config {
        var diags = diagnostics.Diagnostics.init(gpa);
        defer diags.deinit();
        return parseWithDiagnostics(gpa, json, home, &diags);
    }

    // Like parse, but records validation problems into the caller's collector so
    // the CLI can render them. On error.InvalidConfig, diags holds every issue.
    pub fn parseWithDiagnostics(gpa: std.mem.Allocator, json: []const u8, home: []const u8, diags: *diagnostics.Diagnostics) !Config {
        const value = parseJsonBytes(gpa, json) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidConfigSyntax,
        };
        try validateAll(gpa, value, diags);
        if (!diags.isEmpty()) return error.InvalidConfig;
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

    pub fn projectRoot(self: Config, gpa: std.mem.Allocator) ![]const u8 {
        return self.expandHome(gpa, try self.requiredString(&.{ "project", "root" }));
    }

    pub fn configuredProjectRoot(self: Config) ![]const u8 {
        return self.requiredString(&.{ "project", "root" });
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

    /// The compose directory relative to the project root. Callers already running
    /// from the project root (the monitor pane) must use this — `dockerDir` prepends
    /// the root, which doubles the path when the cwd is already the root.
    pub fn dockerSubdir(self: Config) []const u8 {
        const dir = self.optionalString(&.{ "docker", "dir" }, "");
        return if (dir.len == 0) "." else dir;
    }

    pub fn dockerComposeFile(self: Config) []const u8 {
        return self.optionalString(&.{ "docker", "compose_file" }, "docker-compose.yml");
    }

    pub fn configuredDockerCompose(self: Config, gpa: std.mem.Allocator) ![]const u8 {
        const dir = self.dockerSubdir();
        if (std.mem.eql(u8, dir, ".")) return self.dockerComposeFile();
        return std.fs.path.join(gpa, &.{ dir, self.dockerComposeFile() });
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

    pub fn phasePortWaitTimeout(phase: Value, default: i64) i64 {
        return config_value.optionalObjectInt(phase, "port_wait_timeout") orelse default;
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

    pub fn serviceDirValue(service: Value) []const u8 {
        return config_value.optionalObjectString(service, "dir", ".");
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
    var diags = diagnostics.Diagnostics.init(gpa);
    defer diags.deinit();
    return loadPathWithDiagnostics(gpa, io, path, home, &diags);
}

// Like loadPath, but records config validation problems into the caller's
// collector. File and JSON-syntax failures stay as plain errors.
pub fn loadPathWithDiagnostics(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8, diags: *diagnostics.Diagnostics) !Config {
    const bytes = readFile(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        error.StreamTooLong => return error.ConfigTooLarge,
        else => return err,
    };
    return Config.parseWithDiagnostics(gpa, bytes, home, diags);
}

pub fn parseJsonBytes(gpa: std.mem.Allocator, bytes: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, gpa, bytes, .{ .ignore_unknown_fields = true });
}

// normalizeConfig assumes `source` already passed validateAll; the remaining
// guards are defensive type casts, not user-facing validation.
pub fn normalizeConfig(gpa: std.mem.Allocator, source: Value) !Value {
    if (source != .object) return error.InvalidConfig;

    var root: std.json.ObjectMap = .empty;
    try copyObjectField(gpa, &root, source, keys.project);
    try normalizeDocker(gpa, &root, source);
    try normalizeServices(gpa, &root, source);
    try normalizeStartupOrder(gpa, &root, source);
    try copyObjectField(gpa, &root, source, keys.prechecks);
    try copyObjectField(gpa, &root, source, keys.start_profiles);
    try copyObjectField(gpa, &root, source, keys.group_aliases);
    return .{ .object = root };
}

fn normalizeDocker(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const docker = source.object.get(keys.docker) orelse return;
    if (docker != .object) return error.InvalidConfig;
    const compose = docker.object.get(keys.compose) orelse return error.InvalidConfig;
    if (compose != .string) return error.InvalidConfig;
    if (compose.string.len == 0) return error.InvalidConfig;

    var object: std.json.ObjectMap = .empty;
    try object.put(gpa, "enabled", .{ .bool = true });
    const dir = std.fs.path.dirname(compose.string) orelse "";
    const file = std.fs.path.basename(compose.string);
    if (dir.len != 0) try object.put(gpa, "dir", .{ .string = dir });
    try object.put(gpa, "compose_file", .{ .string = file });
    if (docker.object.get(keys.wait_timeout_seconds)) |timeout| {
        if (timeout != .integer) return error.InvalidConfig;
        try object.put(gpa, "wait_timeout", timeout);
    }
    try root.put(gpa, "docker", .{ .object = object });
}

fn normalizeServices(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const groups = source.object.get(keys.groups) orelse return error.InvalidConfig;
    if (groups != .array) return error.InvalidConfig;

    var services = std.json.Array.init(gpa);
    errdefer services.deinit();
    for (groups.array.items) |group| {
        if (group != .object) return error.InvalidConfig;
        const name = try config_value.requiredObjectString(group, keys.name);
        const group_services = group.object.get(keys.services) orelse return error.InvalidConfig;
        if (group_services != .array) return error.InvalidConfig;
        for (group_services.array.items) |service| {
            if (service != .object) return error.InvalidConfig;
            const normalized = try cloneObjectWithField(gpa, service, "group", .{ .string = name });
            try services.append(.{ .object = normalized });
        }
    }
    try root.put(gpa, "services", .{ .array = services });
}

fn normalizeStartupOrder(gpa: std.mem.Allocator, root: *std.json.ObjectMap, source: Value) !void {
    const startup_order = source.object.get(keys.startup_order) orelse return;
    if (startup_order != .array) return error.InvalidConfig;

    var phases = std.json.Array.init(gpa);
    errdefer phases.deinit();
    for (startup_order.array.items) |step| {
        if (step != .object) return error.InvalidConfig;
        var phase: std.json.ObjectMap = .empty;
        const kind = try classifyStartupStep(step);
        switch (kind) {
            .docker => {
                try phase.put(gpa, "type", .{ .string = "docker" });
            },
            .group => {
                var groups = std.json.Array.init(gpa);
                try groups.append(step.object.get(keys.group).?);
                try phase.put(gpa, "groups", .{ .array = groups });
                if (step.object.get(keys.wait_ports)) |wait_ports| {
                    try phase.put(gpa, "wait_ports", wait_ports);
                }
                if (step.object.get(keys.port_wait_timeout_seconds)) |timeout| {
                    if (timeout != .integer) return error.InvalidConfig;
                    try phase.put(gpa, "port_wait_timeout", timeout);
                }
            },
            .command => {
                try phase.put(gpa, "type", .{ .string = "command" });
                try phase.put(gpa, "command", step.object.get(keys.command).?);
                try copyObjectField(gpa, &phase, step, keys.dir);
                try copyObjectField(gpa, &phase, step, keys.on_fail);
                try copyObjectField(gpa, &phase, step, keys.commands);
            },
        }
        try copyObjectField(gpa, &phase, step, keys.name);
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

fn serviceHealthcheck(service: Value) ?Value {
    if (service != .object) return null;
    return service.object.get(keys.healthcheck);
}

const StartupStepKind = enum {
    docker,
    group,
    command,
};

fn classifyStartupStep(step: Value) !StartupStepKind {
    if (step != .object) return error.InvalidConfig;
    if (step.object.get(keys.docker) != null) return .docker;
    if (step.object.get(keys.group) != null) return .group;
    if (step.object.get(keys.command) != null) return .command;
    return error.InvalidConfig;
}

// -----------------------------------------------------------------------------
// Validation
//
// validateAll walks the raw parsed config and records every user-facing problem
// as a `path / message` diagnostic instead of failing on the first one. It is the
// single source of config validation; normalizeConfig assumes validated input.
// -----------------------------------------------------------------------------

pub fn validateAll(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics) !void {
    if (source != .object) {
        try diags.add("", "config must be a JSON object");
        return;
    }
    if (source.object.get("services") != null)
        try diags.add("services", "legacy flat services are not supported; define groups instead");
    if (source.object.get("phases") != null)
        try diags.add("phases", "legacy phases are not supported; define startup_order instead");

    var refs = ValidationIndex.init(gpa);
    defer refs.deinit();

    try checkKeys(gpa, source, "", &.{ keys.project, keys.docker, keys.startup_order, keys.prechecks, keys.start_profiles, keys.group_aliases, keys.groups }, diags);
    try validateProject(gpa, source, diags);
    try validateDocker(gpa, source, diags);
    // Build the reference index before validating references: startup_order and
    // profile overrides may point at groups or aliases declared later in the file.
    try validateGroups(gpa, source, diags, &refs);
    try refs.collectAliases(source);
    try validateStartupOrder(gpa, source, diags, refs);
    try validatePrechecks(gpa, source, diags);
    try validateStartProfiles(gpa, source, diags, refs);
    try validateGroupAliases(gpa, source, diags, refs);
}

const ValidationIndex = struct {
    declared_groups: std.StringHashMap(void),
    groups: std.StringHashMap(void),
    services: std.StringHashMap(void),
    aliases: std.StringHashMap(void),

    fn init(gpa: std.mem.Allocator) ValidationIndex {
        return .{
            .declared_groups = std.StringHashMap(void).init(gpa),
            .groups = std.StringHashMap(void).init(gpa),
            .services = std.StringHashMap(void).init(gpa),
            .aliases = std.StringHashMap(void).init(gpa),
        };
    }

    fn deinit(self: *ValidationIndex) void {
        self.declared_groups.deinit();
        self.groups.deinit();
        self.services.deinit();
        self.aliases.deinit();
    }

    fn collectAliases(self: *ValidationIndex, source: Value) !void {
        // Alias names participate in group resolution before alias values are
        // validated, so collect their keys separately from validateGroupAliases.
        const aliases = source.object.get(keys.group_aliases) orelse return;
        if (aliases != .object) return;
        var it = aliases.object.iterator();
        while (it.next()) |entry| try self.aliases.put(entry.key_ptr.*, {});
    }

    fn containsGroupOrAlias(self: ValidationIndex, name: []const u8) bool {
        return self.groups.contains(name) or self.aliases.contains(name);
    }
};

fn validateProject(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics) !void {
    const project = source.object.get(keys.project) orelse {
        try diags.add("project", "missing required section");
        return;
    };
    if (!try expectObject(project, "project", diags)) return;
    try checkKeys(gpa, project, "project", &.{ keys.name, keys.root }, diags);
    try checkIdentifier(gpa, project, keys.name, "project", diags);
    _ = try checkRequiredString(gpa, project, keys.root, "project", diags);
}

fn validateDocker(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics) !void {
    const docker = source.object.get(keys.docker) orelse return;
    if (!try expectObject(docker, "docker", diags)) return;
    try checkKeys(gpa, docker, "docker", &.{ keys.compose, keys.wait_timeout_seconds }, diags);
    if (docker.object.get(keys.compose)) |compose| {
        if (compose != .string) {
            try diags.add("docker.compose", "must be a string");
        } else if (compose.string.len == 0) {
            try diags.add("docker.compose", "must not be empty");
        } else {
            const dir = std.fs.path.dirname(compose.string) orelse "";
            if (dir.len != 0)
                validate.relativeSubPath(dir) catch try diags.add("docker.compose", "directory must stay within the project root");
        }
    } else try diags.add("docker", "missing required string 'compose'");
    if (docker.object.get(keys.wait_timeout_seconds)) |timeout| {
        if (timeout != .integer) try diags.add("docker.wait_timeout_seconds", "must be an integer");
    }
}

fn validateGroups(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics, refs: *ValidationIndex) !void {
    const groups = source.object.get(keys.groups) orelse {
        try diags.add("groups", "missing required array");
        return;
    };
    if (groups != .array) {
        try diags.add("groups", "must be an array");
        return;
    }
    for (groups.array.items, 0..) |group, gi| {
        const gpath = try indexedPath(gpa, "groups", gi);
        if (!try expectObject(group, gpath, diags)) continue;
        try checkKeys(gpa, group, gpath, &.{ keys.name, keys.services }, diags);
        var group_name: ?[]const u8 = null;
        if (try checkRequiredString(gpa, group, keys.name, gpath, diags)) |name| {
            group_name = name;
            const name_path = try joinPath(gpa, gpath, "name");
            validate.identifier(name) catch try diags.add(name_path, "must be a valid identifier");
            if (refs.declared_groups.contains(name)) {
                try diags.addFmt(name_path, "duplicate group '{s}'", .{name});
            } else try refs.declared_groups.put(name, {});
        }
        const services = group.object.get(keys.services) orelse {
            try diags.add(gpath, "missing required array 'services'");
            continue;
        };
        const services_path = try joinPath(gpa, gpath, "services");
        if (services != .array) {
            try diags.add(services_path, "must be an array");
            continue;
        }
        if (services.array.items.len > 0) if (group_name) |name| try refs.groups.put(name, {});
        for (services.array.items, 0..) |service, si| {
            const spath = try indexedPath(gpa, services_path, si);
            try validateService(gpa, service, spath, diags, refs);
        }
    }
}

fn validateService(gpa: std.mem.Allocator, service: Value, path: []const u8, diags: *diagnostics.Diagnostics, refs: *ValidationIndex) !void {
    if (!try expectObject(service, path, diags)) return;
    try checkKeys(gpa, service, path, &.{ keys.name, keys.dir, keys.runtime, keys.command, keys.external, keys.port, keys.healthcheck }, diags);
    if (try checkRequiredString(gpa, service, keys.name, path, diags)) |name| {
        const name_path = try joinPath(gpa, path, "name");
        validate.identifier(name) catch try diags.add(name_path, "must be a valid identifier");
        if (refs.services.contains(name)) {
            try diags.addFmt(name_path, "duplicate service '{s}'", .{name});
        } else try refs.services.put(name, {});
    }
    _ = try checkRequiredString(gpa, service, keys.command, path, diags);
    try checkOptionalString(gpa, service, keys.dir, path, diags);
    try checkOptionalRuntime(gpa, service, path, diags);
    if (service.object.get(keys.external)) |external| {
        if (external != .bool) try diags.add(try joinPath(gpa, path, "external"), "must be a boolean");
    }
    if (service.object.get(keys.port)) |port| {
        if (port != .integer) try diags.add(try joinPath(gpa, path, "port"), "must be an integer");
    }
    try checkServiceDir(gpa, service, path, diags);
    if (service.object.get(keys.healthcheck)) |healthcheck| {
        const hpath = try joinPath(gpa, path, "healthcheck");
        if (!try expectObject(healthcheck, hpath, diags)) return;
        try checkKeys(gpa, healthcheck, hpath, &.{ keys.type, keys.path }, diags);
        try checkOptionalString(gpa, healthcheck, keys.type, hpath, diags);
        try checkOptionalString(gpa, healthcheck, keys.path, hpath, diags);
    }
}

// Mirrors Config.serviceDir: only project-relative dirs are constrained.
fn checkServiceDir(gpa: std.mem.Allocator, service: Value, path: []const u8, diags: *diagnostics.Diagnostics) !void {
    const dir = config_value.optionalObjectString(service, keys.dir, ".");
    const external = config_value.optionalObjectBool(service, keys.external, false);
    if (external or std.fs.path.isAbsolute(dir) or std.mem.startsWith(u8, dir, "~")) return;
    validate.relativeSubPath(dir) catch try diags.add(try joinPath(gpa, path, "dir"), "must stay within the project root");
}

fn validateStartupOrder(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics, refs: ValidationIndex) !void {
    const startup_order = source.object.get(keys.startup_order) orelse return;
    if (startup_order != .array) {
        try diags.add("startup_order", "must be an array");
        return;
    }
    for (startup_order.array.items, 0..) |step, i| {
        try validateStartupStep(gpa, step, try indexedPath(gpa, "startup_order", i), diags, refs);
    }
}

fn validateStartupStep(gpa: std.mem.Allocator, step: Value, path: []const u8, diags: *diagnostics.Diagnostics, refs: ValidationIndex) !void {
    if (!try expectObject(step, path, diags)) return;
    try checkOptionalString(gpa, step, keys.name, path, diags);
    const has_docker = step.object.get(keys.docker) != null;
    const has_group = step.object.get(keys.group) != null;
    const has_command = step.object.get(keys.command) != null;
    const kind_count: u8 = @as(u8, @intFromBool(has_docker)) + @as(u8, @intFromBool(has_group)) + @as(u8, @intFromBool(has_command));
    if (kind_count != 1) {
        try diags.add(path, "must have exactly one of 'docker', 'group', or 'command'");
        return;
    }
    if (has_docker) {
        try checkKeys(gpa, step, path, &.{ keys.name, keys.docker }, diags);
        const docker = step.object.get(keys.docker).?;
        if (docker != .bool or !docker.bool) try diags.add(try joinPath(gpa, path, "docker"), "must be true");
        return;
    }
    if (has_group) {
        try checkKeys(gpa, step, path, &.{ keys.name, keys.group, keys.wait_ports, keys.port_wait_timeout_seconds }, diags);
        const group_path = try joinPath(gpa, path, "group");
        const group = step.object.get(keys.group).?;
        if (group != .string) {
            try diags.add(group_path, "must be a string");
        } else if (!refs.containsGroupOrAlias(group.string)) {
            try diags.addFmt(group_path, "unknown group '{s}'", .{group.string});
        }
        if (step.object.get(keys.wait_ports)) |wait_ports| {
            const wpath = try joinPath(gpa, path, "wait_ports");
            if (wait_ports != .array) {
                try diags.add(wpath, "must be an array");
            } else for (wait_ports.array.items, 0..) |port, pi| {
                if (port != .integer) try diags.add(try indexedPath(gpa, wpath, pi), "must be an integer");
            }
        }
        if (step.object.get(keys.port_wait_timeout_seconds)) |timeout| {
            if (timeout != .integer) try diags.add(try joinPath(gpa, path, keys.port_wait_timeout_seconds), "must be an integer");
        }
        return;
    }
    try checkKeys(gpa, step, path, &.{ keys.name, keys.command, keys.dir, keys.on_fail, keys.commands }, diags);
    if (step.object.get(keys.command).? != .string) try diags.add(try joinPath(gpa, path, "command"), "must be a string");
    try checkOptionalString(gpa, step, keys.dir, path, diags);
    try checkOptionalString(gpa, step, keys.on_fail, path, diags);
    if (step.object.get(keys.commands)) |commands| try checkStringObject(gpa, commands, try joinPath(gpa, path, "commands"), diags);
}

fn validatePrechecks(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics) !void {
    const prechecks = source.object.get(keys.prechecks) orelse return;
    if (prechecks != .array) {
        try diags.add("prechecks", "must be an array");
        return;
    }
    for (prechecks.array.items, 0..) |check, i| {
        const path = try indexedPath(gpa, "prechecks", i);
        if (!try expectObject(check, path, diags)) continue;
        try checkKeys(gpa, check, path, &.{ keys.name, keys.command, keys.on_fail, keys.hint, keys.dir }, diags);
        _ = try checkRequiredString(gpa, check, keys.command, path, diags);
        try checkOptionalString(gpa, check, keys.name, path, diags);
        try checkOptionalString(gpa, check, keys.on_fail, path, diags);
        try checkOptionalString(gpa, check, keys.hint, path, diags);
        try checkOptionalString(gpa, check, keys.dir, path, diags);
    }
}

fn validateStartProfiles(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics, refs: ValidationIndex) !void {
    const profiles = source.object.get(keys.start_profiles) orelse return;
    if (!try expectObject(profiles, "start_profiles", diags)) return;
    var it = profiles.object.iterator();
    while (it.next()) |entry| {
        const path = try joinPath(gpa, "start_profiles", entry.key_ptr.*);
        const profile = entry.value_ptr.*;
        if (!try expectObject(profile, path, diags)) continue;
        try checkKeys(gpa, profile, path, &.{ keys.profile, keys.label, keys.group_overrides }, diags);
        _ = try checkRequiredString(gpa, profile, keys.profile, path, diags);
        try checkOptionalString(gpa, profile, keys.label, path, diags);
        if (profile.object.get(keys.group_overrides)) |overrides|
            try checkGroupOverrideRefs(gpa, overrides, try joinPath(gpa, path, "group_overrides"), diags, refs);
    }
}

fn validateGroupAliases(gpa: std.mem.Allocator, source: Value, diags: *diagnostics.Diagnostics, refs: ValidationIndex) !void {
    const aliases = source.object.get(keys.group_aliases) orelse return;
    if (!try expectObject(aliases, "group_aliases", diags)) return;
    var it = aliases.object.iterator();
    while (it.next()) |entry| {
        const path = try joinPath(gpa, "group_aliases", entry.key_ptr.*);
        if (entry.value_ptr.* != .array) {
            try diags.add(path, "must be an array of strings");
            continue;
        }
        for (entry.value_ptr.array.items, 0..) |value, i| {
            const value_path = try indexedPath(gpa, path, i);
            if (value != .string) {
                try diags.add(value_path, "must be a string");
            } else if (!refs.services.contains(value.string)) {
                try diags.addFmt(value_path, "unknown service '{s}'", .{value.string});
            }
        }
    }
}

fn checkGroupOverrideRefs(gpa: std.mem.Allocator, value: Value, path: []const u8, diags: *diagnostics.Diagnostics, refs: ValidationIndex) !void {
    if (!try expectObject(value, path, diags)) return;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const entry_path = try joinPath(gpa, path, entry.key_ptr.*);
        if (!refs.containsGroupOrAlias(entry.key_ptr.*)) try diags.addFmt(entry_path, "unknown group '{s}'", .{entry.key_ptr.*});
        if (entry.value_ptr.* != .string) {
            try diags.add(entry_path, "must be a string");
        } else if (!refs.containsGroupOrAlias(entry.value_ptr.string)) {
            try diags.addFmt(entry_path, "unknown group '{s}'", .{entry.value_ptr.string});
        }
    }
}

fn checkStringObject(gpa: std.mem.Allocator, value: Value, path: []const u8, diags: *diagnostics.Diagnostics) !void {
    if (!try expectObject(value, path, diags)) return;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) try diags.add(try joinPath(gpa, path, entry.key_ptr.*), "must be a string");
    }
}

fn checkIdentifier(gpa: std.mem.Allocator, node: Value, key: []const u8, path: []const u8, diags: *diagnostics.Diagnostics) !void {
    const value = (try checkRequiredString(gpa, node, key, path, diags)) orelse return;
    validate.identifier(value) catch try diags.add(try joinPath(gpa, path, key), "must be a valid identifier");
}

fn checkRequiredString(gpa: std.mem.Allocator, node: Value, key: []const u8, path: []const u8, diags: *diagnostics.Diagnostics) !?[]const u8 {
    const value = node.object.get(key) orelse {
        try diags.addFmt(path, "missing required string '{s}'", .{key});
        return null;
    };
    if (value != .string) {
        try diags.add(try joinPath(gpa, path, key), "must be a string");
        return null;
    }
    return value.string;
}

fn checkOptionalString(gpa: std.mem.Allocator, node: Value, key: []const u8, path: []const u8, diags: *diagnostics.Diagnostics) !void {
    if (node.object.get(key)) |value| {
        if (value != .string) try diags.add(try joinPath(gpa, path, key), "must be a string");
    }
}

fn checkOptionalRuntime(gpa: std.mem.Allocator, node: Value, path: []const u8, diags: *diagnostics.Diagnostics) !void {
    const value = node.object.get(keys.runtime) orelse return;
    if (value != .string) {
        try diags.add(try joinPath(gpa, path, keys.runtime), "must be a string");
        return;
    }
    if (value.string.len > 0 and !isAllowedRuntime(value.string))
        try diags.addFmt(try joinPath(gpa, path, keys.runtime), "unknown runtime '{s}'", .{value.string});
}

fn checkKeys(gpa: std.mem.Allocator, node: Value, path: []const u8, allowed: []const []const u8, diags: *diagnostics.Diagnostics) !void {
    var it = node.object.iterator();
    while (it.next()) |entry| {
        if (!isAllowedKey(entry.key_ptr.*, allowed)) try diags.add(try joinPath(gpa, path, entry.key_ptr.*), "unknown key");
    }
}

fn expectObject(node: Value, path: []const u8, diags: *diagnostics.Diagnostics) !bool {
    if (node == .object) return true;
    try diags.add(path, "must be an object");
    return false;
}

fn joinPath(gpa: std.mem.Allocator, parent: []const u8, key: []const u8) ![]const u8 {
    if (parent.len == 0) return key;
    return std.fmt.allocPrint(gpa, "{s}.{s}", .{ parent, key });
}

fn indexedPath(gpa: std.mem.Allocator, parent: []const u8, index: usize) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}[{d}]", .{ parent, index });
}

fn isAllowedKey(key: []const u8, allowed: []const []const u8) bool {
    for (allowed) |item| {
        if (std.mem.eql(u8, key, item)) return true;
    }
    return false;
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

test "config.parse: loads defaults and resolves paths" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"~/work/demo"},
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
    try std.testing.expectEqualStrings("/home/me/work/demo", try cfg.projectRoot(arena.allocator()));
    try std.testing.expectEqualStrings("/home/me/work/demo/backend", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
    try std.testing.expectEqualStrings("npm run dev", try Config.serviceStartCommand(arena.allocator(), try cfg.findService("web")));
    const group = try cfg.resolveGroup(arena.allocator(), "all");
    try std.testing.expectEqualStrings("api", group[0]);
}

test "config.resolvePhaseGroup: resolves profiles and phase group overrides" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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

test "config.commandPhaseCommand: resolves command phase profile overrides and fallback" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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

test "config.phasePortWaitTimeout: normalizes startup order override" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve","port":5432}]}],
        \\  "startup_order": [{"group":"backend","wait_ports":[5432],"port_wait_timeout_seconds":240}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqual(@as(i64, 240), Config.phasePortWaitTimeout(cfg.phases()[0], 180));
}

test "config.parse: rejects unknown service runtime" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","runtime":"unknown","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.resolveGroup: rejects missing services and groups" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectError(error.UnknownService, cfg.findService("missing"));
    try std.testing.expectError(error.UnknownGroup, cfg.resolveGroup(arena.allocator(), "missing"));
}

test "config.parse: rejects malformed group aliases" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "group_aliases": {"bad":["api", 42]}
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.parse: rejects legacy flat services" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "services": [{"name":"api","command":"serve"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.parse: rejects legacy phases" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": true,
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml", "wait_timeout_seconds": "30"},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"unexpected": true}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "wait_ports": ["3000"]}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "port_wait_timeout_seconds": "180"}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "dir": 42}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "on_fail": false}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"command": "setup", "commands": {"core": false}}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"name": 42, "command": "setup"}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"docker": false}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [],
        \\  "startup_order": [{"group": "backend", "dir": "backend"}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [
        \\    {"name":"backend","services":[]},
        \\    {"name":"backend","services":[]}
        \\  ]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "unexpected": true,
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo","unexpected":true},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "compose.yaml", "unexpected": true},
        \\  "groups": []
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","unexpected":true,"services":[]}]
        \\}
        ,
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
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

test "config.parse: rejects invalid identifiers in project and service names" {
    const json =
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api.bad","dir":"backend","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.parse: rejects project-relative service paths that escape root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"../escape","command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.serviceDir: allows external service paths outside project root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","dir":"../external","external":true,"command":"serve"}]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseTestConfig(&arena, json);

    try std.testing.expectEqualStrings("../external", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
}

test "config.parse: rejects docker paths that escape project root" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "docker": {"compose": "../escape/compose.yaml"},
        \\  "groups": []
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidConfig, parseTestConfig(&arena, json));
}

test "config.validateAll: accumulates diagnostics with field paths" {
    const json =
        \\{
        \\  "project": {"name":"bad name","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api.bad","dir":"../escape","runtime":"unknown","command":"serve"}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseJsonBytes(arena.allocator(), json);
    var diags = diagnostics.Diagnostics.init(arena.allocator());
    defer diags.deinit();

    try validateAll(arena.allocator(), value, &diags);

    var found_project_name = false;
    var found_service_name = false;
    var found_service_dir = false;
    var found_service_runtime = false;
    for (diags.slice()) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.path, "project.name")) found_project_name = true;
        if (std.mem.eql(u8, diagnostic.path, "groups[0].services[0].name")) found_service_name = true;
        if (std.mem.eql(u8, diagnostic.path, "groups[0].services[0].dir")) found_service_dir = true;
        if (std.mem.eql(u8, diagnostic.path, "groups[0].services[0].runtime") and std.mem.eql(u8, diagnostic.message, "unknown runtime 'unknown'")) found_service_runtime = true;
    }
    try std.testing.expect(found_project_name);
    try std.testing.expect(found_service_name);
    try std.testing.expect(found_service_dir);
    try std.testing.expect(found_service_runtime);
}

test "config.validateAll: rejects unresolved references" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","command":"serve"}
        \\  ]}, {"name":"empty","services":[]}],
        \\  "group_aliases": {"frontend":["web"]},
        \\  "start_profiles": {
        \\    "core": {
        \\      "profile": "core",
        \\      "group_overrides": {"backend":"core-backend", "workers":"backend"}
        \\    }
        \\  },
        \\  "startup_order": [{"group":"workers"}, {"group":"empty"}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseJsonBytes(arena.allocator(), json);
    var diags = diagnostics.Diagnostics.init(arena.allocator());
    defer diags.deinit();

    try validateAll(arena.allocator(), value, &diags);

    var found_startup_group = false;
    var found_empty_group = false;
    var found_profile_source = false;
    var found_profile_override = false;
    var found_alias_service = false;
    for (diags.slice()) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.path, "startup_order[0].group") and std.mem.eql(u8, diagnostic.message, "unknown group 'workers'")) found_startup_group = true;
        if (std.mem.eql(u8, diagnostic.path, "startup_order[1].group") and std.mem.eql(u8, diagnostic.message, "unknown group 'empty'")) found_empty_group = true;
        if (std.mem.eql(u8, diagnostic.path, "start_profiles.core.group_overrides.workers") and std.mem.eql(u8, diagnostic.message, "unknown group 'workers'")) found_profile_source = true;
        if (std.mem.eql(u8, diagnostic.path, "start_profiles.core.group_overrides.backend") and std.mem.eql(u8, diagnostic.message, "unknown group 'core-backend'")) found_profile_override = true;
        if (std.mem.eql(u8, diagnostic.path, "group_aliases.frontend[0]") and std.mem.eql(u8, diagnostic.message, "unknown service 'web'")) found_alias_service = true;
    }
    try std.testing.expect(found_startup_group);
    try std.testing.expect(found_empty_group);
    try std.testing.expect(found_profile_source);
    try std.testing.expect(found_profile_override);
    try std.testing.expect(found_alias_service);
}

test "config.validateAll: accepts resolved references" {
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "startup_order": [{"group":"backend-alias"}],
        \\  "start_profiles": {
        \\    "core": {
        \\      "profile": "core",
        \\      "group_overrides": {"backend":"backend-alias"}
        \\    }
        \\  },
        \\  "group_aliases": {"backend-alias":["api"]},
        \\  "groups": [{"name":"backend","services":[
        \\    {"name":"api","command":"serve"}
        \\  ]}]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try parseJsonBytes(arena.allocator(), json);
    var diags = diagnostics.Diagnostics.init(arena.allocator());
    defer diags.deinit();

    try validateAll(arena.allocator(), value, &diags);

    try std.testing.expect(diags.isEmpty());
}

test "config.loadPath: parses synthetic fixture" {
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

test "config.parse: parses receipt lab showcase fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const cfg = try loadPath(arena.allocator(), threaded.io(), "testdata/showcase/receipt-lab/zask.json", "/home/me");

    try std.testing.expectEqualStrings("receipt_lab", try cfg.projectName());
    try std.testing.expectEqual(@as(usize, 8), (try cfg.services()).len);
    try std.testing.expectEqual(@as(usize, 4), cfg.phases().len);
    try std.testing.expectEqualStrings("docker", cfg.phases()[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("bff-only", cfg.resolvePhaseGroup("dashboard", "backend"));
    try std.testing.expectEqualStrings("none", cfg.resolvePhaseGroup("dashboard", "workers"));
    try std.testing.expectEqual(@as(?i64, 18110), Config.servicePort(try cfg.findService("bff-dashboard")));
    try std.testing.expect(cfg.dockerEnabled());
    try std.testing.expectEqualStrings("testdata/showcase/receipt-lab/infra", try cfg.dockerDir(arena.allocator()));
    try std.testing.expectEqualStrings("compose.yaml", cfg.dockerComposeFile());
    try std.testing.expectEqual(@as(i64, 5), cfg.dockerWaitTimeout());
}
