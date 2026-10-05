const std = @import("std");
const builtin = @import("builtin");

pub const ExchangeError = error{
    /// The OS or filesystem cannot exchange paths atomically.
    ExchangeUnsupported,
    FileNotFound,
    AccessDenied,
    Unexpected,
} || std.mem.Allocator.Error;

/// Atomically swaps the files at two absolute paths on one filesystem: after
/// the call each path names the file the other one named, and no other
/// process sees a moment where either path is missing.
pub fn exchange(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ExchangeError!void {
    const a_z = try gpa.dupeZ(u8, a);
    defer gpa.free(a_z);
    const b_z = try gpa.dupeZ(u8, b);
    defer gpa.free(b_z);

    switch (builtin.os.tag) {
        .macos => {
            if (renamex_np(a_z, b_z, rename_swap) == 0) return;
            return switch (std.c.errno(-1)) {
                .OPNOTSUPP, .INVAL => error.ExchangeUnsupported,
                .NOENT => error.FileNotFound,
                .ACCES, .PERM => error.AccessDenied,
                else => error.Unexpected,
            };
        },
        .linux => {
            const linux = std.os.linux;
            const rc = linux.renameat2(linux.AT.FDCWD, a_z, linux.AT.FDCWD, b_z, .{ .EXCHANGE = true });
            return switch (linux.errno(rc)) {
                .SUCCESS => {},
                .OPNOTSUPP, .INVAL, .NOSYS => error.ExchangeUnsupported,
                .NOENT => error.FileNotFound,
                .ACCES, .PERM => error.AccessDenied,
                else => error.Unexpected,
            };
        },
        else => @compileError("file_swap.exchange supports macOS and Linux"),
    }
}

const rename_swap: c_uint = 0x2;
extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "file_swap.exchange: swaps file contents between paths" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "second" });
    const a = try tmp.dir.realPathFileAlloc(io, "a", gpa);
    defer gpa.free(a);
    const b = try tmp.dir.realPathFileAlloc(io, "b", gpa);
    defer gpa.free(b);

    try exchange(gpa, a, b);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("second", try tmp.dir.readFile(io, "a", &buffer));
    try std.testing.expectEqualStrings("first", try tmp.dir.readFile(io, "b", &buffer));
}

test "file_swap.exchange: reports a missing path" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "first" });
    const a = try tmp.dir.realPathFileAlloc(io, "a", gpa);
    defer gpa.free(a);
    const missing = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(a).?, "missing" });
    defer gpa.free(missing);

    try std.testing.expectError(error.FileNotFound, exchange(gpa, a, missing));
}
