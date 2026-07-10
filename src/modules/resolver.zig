const std = @import("std");
const Io = std.Io;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: Io,

    // Extensions tried when an import specifier lacks a file extension. First entry is the
    // primary default; subsequent entries are fallback candidates appended in order (without
    // index-file fallback). When empty, resolver falls back to ".ts" as primary only — i.e.
    // identical to the historical behavior hardcoding .ts. C2 fix: extension list no longer
    // hardcoded into resolveRelative body itself.
    extensions: []const [:0]const u8 = undefined,

    fn primaryDefaultExtension(self: Resolver) [:0]const u8 {
        if (self.extensions.len > 0) return self.extensions[0];
        return ".ts";
    }

    pub fn resolveRelative(self: Resolver, from_path: []const u8, specifier: []const u8) !?[]const u8 {
        const from_dir = std.fs.path.dirname(from_path) orelse ".";
        if (std.mem.endsWith(u8, specifier, self.primaryDefaultExtension())) {
            const exact = try std.fs.path.resolve(self.allocator, &.{ from_dir, specifier });
            return try self.tryCanonicalize(exact);
        }

        // Try each configured extension in priority order; only the first is also given an
        // index-file fallback (matches historical behavior where .ts-only was the rule).
        var tried_index = false;
        for (self.extensions) |ext| {
            const extended = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ specifier, ext });
            const path = try std.fs.path.resolve(self.allocator, &.{ from_dir, extended });
            if (try self.tryCanonicalize(path)) |canonical| return canonical;

            // index-file fallback applies only when ext is the primary default — i.e., the
            // historical single-extension .ts behavior preserved exactly for non-empty config.
            if (!tried_index and self.extensions.len == 1) {
                tried_index = true;
                const idx_spec = try std.fmt.allocPrint(
                    self.allocator, "{s}/index{s}",
                    .{ specifier, ext },
                );
                const idx_path = try std.fs.path.resolve(self.allocator, &.{ from_dir, idx_spec });
                if (try self.tryCanonicalize(idx_path)) |canonical| return canonical;
            }
        }
        return null;
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
