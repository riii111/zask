const std = @import("std");

const Value = std.json.Value;

pub const View = struct {
    value: Value,

    pub fn requiredString(self: View, path: []const []const u8) ![]const u8 {
        const node = try self.required(path);
        if (node != .string) return error.InvalidConfig;
        return node.string;
    }

    pub fn optionalString(self: View, path: []const []const u8, default: []const u8) []const u8 {
        const node = self.get(path) orelse return default;
        return if (node == .string) node.string else default;
    }

    pub fn optionalBool(self: View, path: []const []const u8, default: bool) bool {
        const node = self.get(path) orelse return default;
        return if (node == .bool) node.bool else default;
    }

    pub fn optionalInt(self: View, path: []const []const u8, default: i64) i64 {
        const node = self.get(path) orelse return default;
        return switch (node) {
            .integer => |v| v,
            else => default,
        };
    }

    pub fn required(self: View, path: []const []const u8) !Value {
        return self.get(path) orelse error.InvalidConfig;
    }

    pub fn get(self: View, path: []const []const u8) ?Value {
        var node = self.value;
        for (path) |part| {
            if (node != .object) return null;
            node = node.object.get(part) orelse return null;
        }
        return node;
    }
};

pub fn requiredObjectString(node: Value, key: []const u8) ![]const u8 {
    if (node != .object) return error.InvalidConfig;
    const value = node.object.get(key) orelse return error.InvalidConfig;
    if (value != .string) return error.InvalidConfig;
    return value.string;
}

pub fn optionalObjectString(node: Value, key: []const u8, default: []const u8) []const u8 {
    if (node != .object) return default;
    const value = node.object.get(key) orelse return default;
    return if (value == .string) value.string else default;
}

pub fn optionalObjectBool(node: Value, key: []const u8, default: bool) bool {
    if (node != .object) return default;
    const value = node.object.get(key) orelse return default;
    return if (value == .bool) value.bool else default;
}

pub fn optionalObjectInt(node: Value, key: []const u8) ?i64 {
    if (node != .object) return null;
    const value = node.object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

pub fn optionalObjectArray(node: Value, key: []const u8) ?[]const Value {
    if (node != .object) return null;
    const value = node.object.get(key) orelse return null;
    return if (value == .array) value.array.items else null;
}
