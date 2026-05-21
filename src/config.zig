const std = @import("std");
const config_value = @import("config_value.zig");

const Value = std.json.Value;

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
        return self.requiredString(&.{ "project", "name" });
    }

    pub fn sessionName(self: Config) ![]const u8 {
        return self.requiredString(&.{ "project", "session_name" });
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
        return (try self.required(&.{"services"})).array.items;
    }

    pub fn phases(self: Config) []const Value {
        const node = self.get(&.{"phases"}) orelse return &.{};
        if (node != .array) return &.{};
        return node.array.items;
    }

    pub fn serviceName(service: Value) ![]const u8 {
        return requiredObjectString(service, "name");
    }

    pub fn serviceGroup(service: Value) []const u8 {
        return optionalObjectString(service, "group", "");
    }

    pub fn servicePort(service: Value) ?i64 {
        return optionalObjectInt(service, "port");
    }

    pub fn serviceDir(self: Config, gpa: std.mem.Allocator, service: Value) ![]const u8 {
        const dir = optionalObjectString(service, "dir", ".");
        const external = optionalObjectBool(service, "external", false);
        if (external or std.fs.path.isAbsolute(dir) or std.mem.startsWith(u8, dir, "~")) {
            return self.expandHome(gpa, dir);
        }
        return std.fs.path.join(gpa, &.{ try self.projectRoot(gpa), dir });
    }

    pub fn serviceCommand(service: Value) ![]const u8 {
        const command = requiredObjectString(service, "command") catch "";
        const runtime = optionalObjectString(service, "runtime", "");
        if (runtime.len == 0) return command;
        if (!isAllowedRuntime(runtime)) return error.UnknownRuntime;
        return command;
    }

    pub fn serviceStartCommand(self: Config, gpa: std.mem.Allocator, service: Value) ![]const u8 {
        _ = self;
        const command = try requiredObjectString(service, "command");
        const runtime = optionalObjectString(service, "runtime", "");
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

        var list = std.array_list.Managed([]const u8).init(gpa);
        for (try self.services()) |service| {
            if (std.mem.eql(u8, serviceGroup(service), name)) {
                try list.append(try serviceName(service));
            }
        }
        if (list.items.len == 0) return error.UnknownGroup;
        return list.toOwnedSlice();
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

    pub fn commandPhaseCommand(self: Config, phase: Value, start_profile: []const u8) ![]const u8 {
        _ = self;
        if (phase != .object) return error.InvalidConfig;
        if (phase.object.get("commands")) |commands| {
            if (commands == .object) {
                if (commands.object.get(start_profile)) |cmd| {
                    if (cmd == .string) return cmd.string;
                }
            }
        }
        return requiredObjectString(phase, "command");
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

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(10 * 1024 * 1024));
}

fn requiredObjectString(node: Value, key: []const u8) ![]const u8 {
    return config_value.requiredObjectString(node, key);
}

fn optionalObjectString(node: Value, key: []const u8, default: []const u8) []const u8 {
    return config_value.optionalObjectString(node, key, default);
}

fn optionalObjectBool(node: Value, key: []const u8, default: bool) bool {
    return config_value.optionalObjectBool(node, key, default);
}

fn optionalObjectInt(node: Value, key: []const u8) ?i64 {
    return config_value.optionalObjectInt(node, key);
}

fn stringArray(gpa: std.mem.Allocator, values: []const Value) ![][]const u8 {
    var list = std.array_list.Managed([]const u8).init(gpa);
    for (values) |value| {
        if (value != .string) return error.InvalidConfig;
        try list.append(value.string);
    }
    return list.toOwnedSlice();
}

fn isAllowedRuntime(runtime: []const u8) bool {
    const allowed = [_][]const u8{ "npm", "yarn", "pnpm", "bun", "cargo", "bacon" };
    for (allowed) |item| {
        if (std.mem.eql(u8, item, runtime)) return true;
    }
    return false;
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
    const cfg = try Config.parse(arena.allocator(), json, "/home/me");
    try std.testing.expectEqualStrings("demo", try cfg.projectName());
    try std.testing.expectEqualStrings("/home/me/work/demo", try cfg.projectRoot(arena.allocator()));
    try std.testing.expectEqualStrings("/home/me/work/demo/backend", try cfg.serviceDir(arena.allocator(), try cfg.findService("api")));
    try std.testing.expectEqualStrings("npm run dev", try cfg.serviceStartCommand(arena.allocator(), try cfg.findService("web")));
    const group = try cfg.resolveGroup(arena.allocator(), "all");
    try std.testing.expectEqualStrings("api", group[0]);
}
