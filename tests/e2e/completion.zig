const std = @import("std");
const harness = @import("harness.zig");

const demo_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "groups": [{"name":"backend","services":[
    \\    {"name":"api","command":"serve"},
    \\    {"name":"bff-dashboard","command":"dev"}
    \\  ]}],
    \\  "start_profiles": {"lite": {"profile": "lite"}}
    \\}
;

const special_names_config =
    \\{
    \\  "project": {"name":"demo","root":"/tmp/demo"},
    \\  "groups": [{"name":"backend","services":[
    \\    {"name":"api","command":"serve"},
    \\    {"name":"bff-dashboard","command":"dev"}
    \\  ]}],
    \\  "group_aliases": {
    \\    "sp ace": ["api"],
    \\    "semi;touch PWNED": ["api"],
    \\    "dollar$(touch PWNED)": ["api"],
    \\    "tick`touch PWNED`": ["api"],
    \\    "it's": ["api"]
    \\  }
    \\}
;

// Runs the real script's `_zask` for the word under the cursor, then evaluates
// each reply as bash would once the line runs: inside the quote the user opened,
// which readline closes after a unique match.
const bash_driver =
    \\eval "$(zask completion bash)" || exit 1
    \\complete_word() {
    \\  local quote= reply
    \\  case $1 in \'*|\"*) quote=${1:0:1} ;; esac
    \\  COMP_WORDS=(zask "${@:2}" restart "$1"); COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 )); COMPREPLY=()
    \\  _zask
    \\  for reply in "${COMPREPLY[@]}"; do eval "printf '<%s>' $quote$reply$quote"; done
    \\  echo
    \\}
    \\complete_word bf
    \\complete_word sp
    \\complete_word sem
    \\complete_word do
    \\complete_word '"do'
    \\complete_word "'do"
    \\complete_word '"ti'
    \\complete_word "'it"
    \\complete_word '"it'
    \\complete_word bf --config '~/home.json'
    \\if [ -e PWNED ]; then echo executed; fi
;

fn testRunBash(gpa: std.mem.Allocator, io: std.Io, ws: harness.Workspace, script: []const u8) !harness.RunResult {
    const zask_dir = std.fs.path.dirname(harness.zask_path) orelse return error.InvalidPath;
    const path = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin", .{zask_dir});
    defer gpa.free(path);
    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("PATH", path);
    try env_map.put("HOME", ws.home);
    try env_map.put("XDG_CONFIG_HOME", ws.xdg);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/bash", "--norc", "--noprofile", "-c", script },
        .cwd = .{ .path = ws.project },
        .environ_map = &env_map,
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

test "__complete: uses discovered and named config like commands" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", demo_config);
    try ws.writeNamedConfig(gpa, io, "demo", demo_config);
    const cases = [_]struct { cwd: []const u8, args: []const []const u8, expected: []const u8 }{
        .{ .cwd = ws.project, .args = &.{ "__complete", "restart", "bf" }, .expected = "bff-dashboard\n" },
        .{ .cwd = ws.project, .args = &.{ "__complete", "open", "--" }, .expected = "--lite\n" },
        .{ .cwd = ws.elsewhere, .args = &.{ "__complete", "demo", "restart", "bf" }, .expected = "bff-dashboard\n" },
    };

    for (cases) |case| {
        var res = try harness.spawnZask(gpa, io, .{ .cwd = case.cwd, .xdg_config_home = ws.xdg, .home = ws.home }, case.args);
        defer res.deinit(gpa);

        try std.testing.expect(res.exitedWith(0));
        try std.testing.expectEqualStrings(case.expected, res.stdout);
        try std.testing.expectEqualStrings("", res.stderr);
    }
}

test "__complete: exits cleanly with static candidates when config is unusable" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_]?[]const u8{ null, "not json", "{\"foo\":1}" };

    for (cases) |contents| {
        var ws = try harness.Workspace.init(gpa, io);
        defer ws.deinit(gpa);
        if (contents) |data| try ws.writeProjectFile(io, "zask.json", data);

        var start = try harness.spawnZask(gpa, io, .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home }, &.{ "__complete", "start", "" });
        defer start.deinit(gpa);
        var top = try harness.spawnZask(gpa, io, .{ .cwd = ws.project, .xdg_config_home = ws.xdg, .home = ws.home }, &.{ "__complete", "rest" });
        defer top.deinit(gpa);

        try std.testing.expect(start.exitedWith(0));
        try std.testing.expectEqualStrings("--all\n", start.stdout);
        try std.testing.expectEqualStrings("", start.stderr);
        try std.testing.expect(top.exitedWith(0));
        try std.testing.expectEqualStrings("restart\n", top.stdout);
        try std.testing.expectEqualStrings("", top.stderr);
    }
}

test "completion bash: inserts special config names as literal words" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ws = try harness.Workspace.init(gpa, io);
    defer ws.deinit(gpa);
    try ws.writeProjectFile(io, "zask.json", special_names_config);
    const home_config = try std.fs.path.join(gpa, &.{ ws.home, "home.json" });
    defer gpa.free(home_config);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home_config, .data = demo_config });
    const expected =
        \\<bff-dashboard>
        \\<sp ace>
        \\<semi;touch PWNED>
        \\<dollar$(touch PWNED)>
        \\<dollar$(touch PWNED)>
        \\<dollar$(touch PWNED)>
        \\<tick`touch PWNED`>
        \\<it's>
        \\<it's>
        \\<bff-dashboard>
        \\
    ;

    var res = try testRunBash(gpa, io, ws, bash_driver);
    defer res.deinit(gpa);

    try std.testing.expectEqualStrings("", res.stderr);
    try std.testing.expectEqualStrings(expected, res.stdout);
    try std.testing.expect(res.exitedWith(0));
}
