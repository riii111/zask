const std = @import("std");
const config = @import("../../model/config.zig");

/// Argument shape each command accepts. Completion offers only words the
/// command's own `Options.parse` and runtime target resolution accept.
pub const ArgKind = enum {
    none,
    open_profile,
    start_target,
    restart_target,
    service,
    init_options,

    /// Whether candidates for this argument come from the selected config.
    pub fn needsConfig(self: ArgKind) bool {
        return switch (self) {
            .open_profile, .start_target, .restart_target, .service => true,
            .none, .init_options => false,
        };
    }
};

/// Candidates matching the word under the cursor, one per output line.
/// Values passed to `add` are borrowed and must outlive `write`; `deinit`
/// frees the list and every value built by `addOption`.
pub const Candidates = struct {
    arena: std.heap.ArenaAllocator,
    prefix: []const u8,
    items: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, prefix: []const u8) Candidates {
        return .{ .arena = .init(gpa), .prefix = prefix };
    }

    pub fn deinit(self: *Candidates) void {
        self.arena.deinit();
    }

    /// Adds `--<name>`.
    pub fn addOption(self: *Candidates, name: []const u8) !void {
        try self.add(try std.fmt.allocPrint(self.arena.allocator(), "--{s}", .{name}));
    }

    pub fn add(self: *Candidates, value: []const u8) !void {
        if (!std.mem.startsWith(u8, value, self.prefix)) return;
        // The output is line based; a value with control bytes cannot be
        // represented and would split into words the user never configured.
        if (!isPrintable(value)) return;
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item, value)) return;
        }
        try self.items.append(self.arena.allocator(), value);
    }

    pub fn write(self: Candidates, writer: *std.Io.Writer) !void {
        for (self.items.items) |item| try writer.print("{s}\n", .{item});
    }
};

/// Adds candidates for the next argument after `typed_args`. `cfg` is null when
/// the config is missing or invalid; only static candidates are offered then.
pub fn collectArguments(kind: ArgKind, typed_args: []const []const u8, cfg: ?config.Config, candidates: *Candidates) !void {
    switch (kind) {
        .none => {},
        .init_options => try collectInitOptions(typed_args, candidates),
        .open_profile, .start_target, .restart_target, .service => {
            if (typed_args.len != 0) return;
            if (kind == .start_target) try candidates.add("--all");
            const selected = cfg orelse return;
            collectConfigTargets(kind, selected, candidates) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        },
    }
}

fn collectInitOptions(typed_args: []const []const u8, candidates: *Candidates) !void {
    if (typed_args.len > 0 and std.mem.eql(u8, typed_args[typed_args.len - 1], "--root")) return;
    for ([_][]const u8{ "--root", "--force" }) |option| {
        if (!containsArg(typed_args, option)) try candidates.add(option);
    }
}

fn collectConfigTargets(kind: ArgKind, cfg: config.Config, candidates: *Candidates) !void {
    switch (kind) {
        .open_profile => {
            if (cfg.dockerEnabled()) try candidates.add("--docker");
            const keys = try cfg.startProfileKeys(candidates.arena.allocator());
            for (keys) |key| try candidates.addOption(key);
        },
        .start_target, .restart_target => {
            if (cfg.dockerEnabled()) try candidates.add("docker");
            const groups = try cfg.groupNames(candidates.arena.allocator());
            for (groups) |group| try addTarget(group, candidates);
            for (try cfg.services()) |service| try addTarget(try config.Config.serviceName(service), candidates);
        },
        .service => {
            for (try cfg.services()) |service| try candidates.add(try config.Config.serviceName(service));
        },
        .none, .init_options => {},
    }
}

/// start / stop / restart `Options.parse` reject `--` targets other than
/// `--all`, so an alias spelled like an option is never a usable target.
fn addTarget(name: []const u8, candidates: *Candidates) !void {
    if (std.mem.startsWith(u8, name, "--")) return;
    try candidates.add(name);
}

fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn isPrintable(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

const test_config_json =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "docker": {"compose": "compose.yaml"},
    \\  "groups": [
    \\    {"name":"backend","services":[
    \\      {"name":"api","command":"serve"},
    \\      {"name":"bff-dashboard","command":"dev"}
    \\    ]}
    \\  ],
    \\  "group_aliases": {"core":["api"]},
    \\  "start_profiles": {"lite": {"profile": "lite"}}
    \\}
;

fn testCollect(gpa: std.mem.Allocator, kind: ArgKind, typed_args: []const []const u8, cfg: ?config.Config, prefix: []const u8) ![]const u8 {
    var candidates = Candidates.init(gpa, prefix);
    defer candidates.deinit();
    try collectArguments(kind, typed_args, cfg, &candidates);
    var out: std.Io.Writer.Allocating = .init(gpa);
    try candidates.write(&out.writer);
    return out.toOwnedSlice();
}

test "complete.collectArguments: offers config targets per command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cfg = try config.Config.parse(gpa, test_config_json, "/home/me");
    const cases = [_]struct { kind: ArgKind, expected: []const u8 }{
        .{ .kind = .open_profile, .expected = "--docker\n--lite\n" },
        .{ .kind = .start_target, .expected = "--all\ndocker\nbackend\ncore\napi\nbff-dashboard\n" },
        .{ .kind = .restart_target, .expected = "docker\nbackend\ncore\napi\nbff-dashboard\n" },
        .{ .kind = .service, .expected = "api\nbff-dashboard\n" },
        .{ .kind = .none, .expected = "" },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, try testCollect(gpa, case.kind, &.{}, cfg, ""));
    }
}

test "complete.collectArguments: skips option-like aliases as targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const json =
        \\{
        \\  "project": {"name":"demo","root":"/tmp/demo"},
        \\  "groups": [{"name":"backend","services":[{"name":"api","command":"serve"}]}],
        \\  "group_aliases": {"--bad":["api"]}
        \\}
    ;
    const cfg = try config.Config.parse(gpa, json, "/home/me");

    try std.testing.expectEqualStrings("--all\n", try testCollect(gpa, .start_target, &.{}, cfg, "--"));
    try std.testing.expectEqualStrings("", try testCollect(gpa, .restart_target, &.{}, cfg, "--"));
}

test "complete.collectArguments: filters by typed prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cfg = try config.Config.parse(gpa, test_config_json, "/home/me");

    try std.testing.expectEqualStrings("bff-dashboard\n", try testCollect(gpa, .restart_target, &.{}, cfg, "bf"));
    try std.testing.expectEqualStrings("--lite\n", try testCollect(gpa, .open_profile, &.{}, cfg, "--l"));
}

test "complete.collectArguments: keeps static candidates without config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectEqualStrings("--all\n", try testCollect(gpa, .start_target, &.{}, null, ""));
    try std.testing.expectEqualStrings("", try testCollect(gpa, .restart_target, &.{}, null, ""));
    try std.testing.expectEqualStrings("--root\n--force\n", try testCollect(gpa, .init_options, &.{"demo"}, null, ""));
}

test "complete.collectArguments: stops after single target argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cfg = try config.Config.parse(gpa, test_config_json, "/home/me");

    try std.testing.expectEqualStrings("", try testCollect(gpa, .restart_target, &.{"api"}, cfg, ""));
    try std.testing.expectEqualStrings("", try testCollect(gpa, .open_profile, &.{"--lite"}, cfg, ""));
}

test "complete.collectArguments: init omits used options and path values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectEqualStrings("--root\n", try testCollect(gpa, .init_options, &.{"--force"}, null, ""));
    try std.testing.expectEqualStrings("", try testCollect(gpa, .init_options, &.{"--root"}, null, ""));
}

test "complete.Candidates: drops duplicates and control bytes" {
    var candidates = Candidates.init(std.testing.allocator, "");
    defer candidates.deinit();

    try candidates.add("api");
    try candidates.add("api");
    try candidates.add("bad\nname");
    try candidates.add("with space");

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try candidates.write(&writer);
    try std.testing.expectEqualStrings("api\nwith space\n", writer.buffered());
}
