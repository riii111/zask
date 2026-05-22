const std = @import("std");
const paths = @import("paths.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");

pub const Lock = struct {
    gpa: std.mem.Allocator,
    runner: runner.Runner,
    dir: []const u8,

    pub fn acquire(gpa: std.mem.Allocator, proc: runner.Runner, name: []const u8) !Lock {
        const base = try paths.runtimeBase(gpa);
        _ = proc.run(&.{ "mkdir", "-p", base }) catch {};
        const dir = try std.fs.path.join(gpa, &.{ base, try std.fmt.allocPrint(gpa, "{s}.lock", .{name}) });
        const quoted_dir = try shell.quote(gpa, dir);
        const pid = try std.fmt.allocPrint(gpa, "{d}", .{std.c.getpid()});
        const script = try std.fmt.allocPrint(gpa,
            \\if mkdir {s} 2>/dev/null; then
            \\  printf '%s\n' {s} > {s}/pid
            \\  exit 0
            \\fi
            \\pid=$(cat {s}/pid 2>/dev/null || true)
            \\if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            \\  exit 1
            \\fi
            \\rm -rf {s}
            \\mkdir {s}
            \\printf '%s\n' {s} > {s}/pid
        , .{ quoted_dir, pid, quoted_dir, quoted_dir, quoted_dir, quoted_dir, pid, quoted_dir });
        const result = try proc.run(&.{ "bash", "-c", script });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.LockBusy;
        return .{ .gpa = gpa, .runner = proc, .dir = dir };
    }

    pub fn release(self: Lock) void {
        const quoted_dir = shell.quote(self.gpa, self.dir) catch return;
        const script = std.fmt.allocPrint(self.gpa, "rm -rf {s}", .{quoted_dir}) catch return;
        const result = self.runner.run(&.{ "bash", "-c", script }) catch return;
        self.gpa.free(result.stdout);
        self.gpa.free(result.stderr);
    }
};
