const std = @import("std");
const Io = std.Io;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: Io,

    pub fn resolveRelative(self: Resolver, from_path: []const u8, specifier: []const u8) !?[]const u8 {
        const from_dir = std.fs.path.dirname(from_path) orelse ".";
        if (std.mem.endsWith(u8, specifier, ".ts")) {
            const exact = try std.fs.path.resolve(self.allocator, &.{ from_dir, specifier });
            return try self.tryCanonicalize(exact);
        }

        const ts_specifier = try std.fmt.allocPrint(self.allocator, "{s}.ts", .{specifier});
        const ts_path = try std.fs.path.resolve(self.allocator, &.{ from_dir, ts_specifier });
        if (try self.tryCanonicalize(ts_path)) |canonical| return canonical;

        const index_specifier = try std.fmt.allocPrint(self.allocator, "{s}/index.ts", .{specifier});
        const index_path = try std.fs.path.resolve(self.allocator, &.{ from_dir, index_specifier });
        return try self.tryCanonicalize(index_path);
    }

    pub fn canonicalize(self: Resolver, path: []const u8) ![]const u8 {
        const canonical_z = try Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        return canonical_z[0..canonical_z.len];
    }

    pub fn tryCanonicalize(self: Resolver, path: []const u8) !?[]const u8 {
        const canonical_z = Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator) catch return null;
        return canonical_z[0..canonical_z.len];
    }
};

pub fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}
