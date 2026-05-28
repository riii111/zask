const std = @import("std");
const build_options = @import("e2e_options");

pub const zask_path: []const u8 = build_options.zask_path;

pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn exitedWith(self: RunResult, code: u8) bool {
        return self.term == .exited and self.term.exited == code;
    }
};

pub const SpawnOptions = struct {
    cwd: []const u8,
    xdg_config_home: []const u8,
    home: []const u8,
};

pub fn spawnZask(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: SpawnOptions,
    args: []const []const u8,
) !RunResult {
    var argv = try gpa.alloc([]const u8, args.len + 1);
    defer gpa.free(argv);
    argv[0] = zask_path;
    @memcpy(argv[1..], args);

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", opts.home);
    try env_map.put("XDG_CONFIG_HOME", opts.xdg_config_home);

    const output_limit = 1024 * 1024;
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = &env_map,
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

pub const Workspace = struct {
    tmp: std.testing.TmpDir,
    project: []u8,
    xdg: []u8,
    elsewhere: []u8,
    home: []u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Workspace {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        try tmp.dir.createDirPath(io, "project");
        try tmp.dir.createDirPath(io, "xdg");
        try tmp.dir.createDirPath(io, "elsewhere");
        try tmp.dir.createDirPath(io, "home");

        const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(base);
        const project = try std.fs.path.join(gpa, &.{ base, "project" });
        errdefer gpa.free(project);
        const xdg = try std.fs.path.join(gpa, &.{ base, "xdg" });
        errdefer gpa.free(xdg);
        const elsewhere = try std.fs.path.join(gpa, &.{ base, "elsewhere" });
        errdefer gpa.free(elsewhere);
        const home = try std.fs.path.join(gpa, &.{ base, "home" });

        return .{
            .tmp = tmp,
            .project = project,
            .xdg = xdg,
            .elsewhere = elsewhere,
            .home = home,
        };
    }

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        gpa.free(self.project);
        gpa.free(self.xdg);
        gpa.free(self.elsewhere);
        gpa.free(self.home);
        self.tmp.cleanup();
    }

    pub fn writeProjectFile(self: Workspace, io: std.Io, sub_path: []const u8, contents: []const u8) !void {
        var project_dir = try self.tmp.dir.openDir(io, "project", .{});
        defer project_dir.close(io);
        try project_dir.writeFile(io, .{ .sub_path = sub_path, .data = contents });
    }

    pub fn configPath(self: Workspace, gpa: std.mem.Allocator, project_name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ self.xdg, "zask", project_name, "config.json" });
    }
};
