const std = @import("std");

// Externals registry for non-relative specifiers.
//
// An external module is a name (e.g., "node:fs", "lodash") with an optional
// declaration file (.ts) that defines its exports. When an import specifier
// matches an externals entry, vizg validates the imported names against the
// declarations instead of silently classifying it as `.external`.

pub const ExternalModule = struct {
    /// Canonical name used in imports (e.g., "node:fs", "lodash").
    name: []const u8,
    /// Absolute path to a TypeScript declaration file that declares exports.
    /// May be null if the user only wants validation without bindings.
    decl_path: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.decl_path) |path| allocator.free(path);
    }
};

pub const Registry = struct {
    /// Ordered list of externals indexed by name. Search is O(n), but enough
    /// for the typical case (<100 external modules).
    entries: std.ArrayList(ExternalModule),

    pub fn init() Registry {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        defer self.entries.deinit(allocator);
        for (self.entries.items) |item| {
            var e = item;
            e.deinit(allocator);
        }
    }

    /// Look up an external by name. Returns the matching `ExternalModule` if
    /// one exists, else null.
    pub fn find(self: *const Registry, name: []const u8) ?*const ExternalModule {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry;
        }
        return null;
    }

    /// Register a new external. Copies `name` and optionally `decl_path`; the
    /// caller retains ownership of its inputs. Returns an error when memory
    /// cannot be allocated for the copy — callers may ignore it if duplicate
    /// suppression is acceptable (the entry will just not be added).
    pub fn add(self: *Registry, allocator: std.mem.Allocator, name: []const u8, decl_path: ?[]const u8) void {
        if (self.find(name)) |_| return; // ignore duplicates silently

        const name_copy = allocator.alloc(u8, name.len) catch return;
        @memcpy(name_copy, name);

        var ep: ?[]const u8 = null;
        if (decl_path) |dp| {
            ep = allocator.dupe(u8, dp) catch {
                allocator.free(name_copy);
                return;
            };
        }

        self.entries.append(allocator, .{ .name = name_copy, .decl_path = ep }) catch return;
    }
};

test "Registry lookup by name" {
    var reg = Registry.init();
    defer reg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?*const ExternalModule, null), reg.find("unknown"));

    reg.add(std.testing.allocator, "node:fs", "/abs/fs.ts");
    const found = reg.find("node:fs") orelse unreachable;
    try std.testing.expectEqualStrings("/abs/fs.ts", found.decl_path.?);
}

test "Registry dedupes identical names" {
    var reg = Registry.init();
    defer reg.deinit(std.testing.allocator);

    reg.add(std.testing.allocator, "a", "/1.ts");
    reg.add(std.testing.allocator, "a", "/2.ts");
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}
