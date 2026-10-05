const std = @import("std");
const Context = @import("context.zig").Context;

pub const Shell = enum {
    zsh,
    bash,
    fish,

    fn script(self: Shell) []const u8 {
        return switch (self) {
            .zsh => @embedFile("completion/zask.zsh"),
            .bash => @embedFile("completion/zask.bash"),
            .fish => @embedFile("completion/zask.fish"),
        };
    }
};

pub const Options = struct {
    shell: ?Shell = null,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len == 0) return .{};
        if (args.len != 1) return error.InvalidArguments;
        return .{ .shell = std.meta.stringToEnum(Shell, args[0]) orelse return error.InvalidArguments };
    }

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub fn run(ctx: *Context, opts: Options) !void {
    const shell = opts.shell orelse return printSetup(ctx.writer);
    try ctx.writer.writeAll(shell.script());
}

fn printSetup(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Enable completion by running the line for your shell once, then open a new shell:
        \\  zsh:   echo 'eval "$(zask completion zsh)"' >> ~/.zshrc
        \\  bash:  echo 'eval "$(zask completion bash)"' >> ~/.bashrc
        \\  fish:  echo 'zask completion fish | source' >> ~/.config/fish/config.fish
        \\
    );
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "completion.Options: parses shell names" {
    const cases = [_]struct { args: []const []const u8, expected: ?Shell }{
        .{ .args = &.{}, .expected = null },
        .{ .args = &.{"zsh"}, .expected = .zsh },
        .{ .args = &.{"bash"}, .expected = .bash },
        .{ .args = &.{"fish"}, .expected = .fish },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, (try Options.parse(case.args)).shell);
    }
}

test "completion.Options: rejects unknown shell and extra arguments" {
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{"powershell"}));
    try std.testing.expectError(error.InvalidArguments, Options.parse(&.{ "zsh", "bash" }));
}
