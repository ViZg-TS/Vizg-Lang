//! Reference native filesystem host for the portable Project request/response API.
//!
//! Policy: only relative specifiers are loaded. Canonical targets must remain
//! inside the root file's directory. Symlinks are followed only when their
//! canonical target remains inside that boundary. Supported extensions are
//! explicit; extension-less imports try files, then index files, in order.

const std = @import("std");
const Io = std.Io;
const core = @import("vizg-core");

pub const default_extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx" };

/// Borrowed source-less module binding supplied by a native host.
pub const ExternalBinding = struct {
    specifier: []const u8,
    descriptor: core.ExternalModuleDescriptor,
};

pub const Options = struct {
    max_source_bytes: usize = 16 * 1024 * 1024,
    max_modules: usize = 1024,
    extensions: []const []const u8 = &default_extensions,
    externals: []const ExternalBinding = &.{},
};

pub const ResponseCounts = struct {
    source: usize = 0,
    external: usize = 0,
    not_found: usize = 0,
    denied: usize = 0,
    failed: usize = 0,
};

const PathRecord = struct {
    canonical: []const u8,
    id: core.ModuleId,
};

const Resolution = union(enum) {
    source: ResolvedSource,
    external: core.ExternalModuleDescriptor,
    not_found,
    denied,
    failed,
};

const ResolvedSource = struct {
    canonical: [:0]u8,
    file: Io.File,
};

pub const FsModuleHost = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: Options,
    project: core.Project,
    root_directory: ?[]const u8 = null,
    root_dir: ?Io.Dir = null,
    paths: std.ArrayList(PathRecord) = .empty,
    ids_by_path: std.StringHashMap(core.ModuleId),
    next_id: u64 = 1,
    responses: ResponseCounts = .{},

    pub fn init(allocator: std.mem.Allocator, io: Io, options: Options) !FsModuleHost {
        if (options.max_source_bytes == 0 or options.max_modules == 0 or options.extensions.len == 0)
            return error.InvalidOptions;
        for (options.extensions) |extension| {
            if (extension.len < 2 or extension[0] != '.') return error.InvalidOptions;
        }
        for (options.externals, 0..) |binding, index| {
            if (binding.specifier.len == 0) return error.InvalidOptions;
            for (options.externals[0..index]) |previous| {
                if (std.mem.eql(u8, binding.specifier, previous.specifier)) return error.InvalidOptions;
            }
        }
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .project = .init(allocator),
            .ids_by_path = std.StringHashMap(core.ModuleId).init(allocator),
        };
    }

    pub fn deinit(self: *FsModuleHost) void {
        self.project.deinit();
        self.ids_by_path.deinit();
        for (self.paths.items) |record| self.allocator.free(record.canonical);
        self.paths.deinit(self.allocator);
        if (self.root_dir) |directory| directory.close(self.io);
        if (self.root_directory) |directory| self.allocator.free(directory);
        self.* = undefined;
    }

    /// Canonicalizes, bounds, reads, and submits the root file.
    pub fn loadRoot(self: *FsModuleHost, root_path: []const u8) !core.ModuleId {
        if (self.root_directory != null) return error.RootAlreadyLoaded;
        const canonical_z = try Io.Dir.cwd().realPathFileAlloc(self.io, root_path, self.allocator);
        const canonical: []u8 = canonical_z[0..canonical_z.len];
        defer self.allocator.free(canonical_z);
        const directory = std.fs.path.dirname(canonical) orelse return error.InvalidRootPath;
        self.root_directory = try self.allocator.dupe(u8, directory);
        errdefer {
            self.allocator.free(self.root_directory.?);
            self.root_directory = null;
        }

        self.root_dir = try Io.Dir.cwd().openDir(self.io, directory, .{ .follow_symlinks = false });
        errdefer {
            self.root_dir.?.close(self.io);
            self.root_dir = null;
        }
        const file_name = std.fs.path.basename(canonical);
        const file = try self.root_dir.?.openFile(self.io, file_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
        defer file.close(self.io);
        const source = try self.readOpenedFile(file);
        defer self.allocator.free(source);

        const id = try self.registerCanonical(canonical);
        try self.project.addRoot(.{
            .id = id,
            .logical_name = canonical,
            .bytes = source,
            .kind = .module,
        });
        return id;
    }

    /// Drives requests until the portable project reaches its terminal state.
    pub fn drive(self: *FsModuleHost) !core.ProjectFinishResult {
        if (self.root_directory == null) return error.RootNotLoaded;
        while (true) switch (try self.project.step()) {
            .complete => return self.project.finish(),
            .request => |request| try self.answer(request),
        };
    }

    /// Returns an existing session identity for any spelling of a loaded file.
    pub fn moduleIdForPath(self: *FsModuleHost, path: []const u8) !?core.ModuleId {
        const canonical_z = try Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        defer self.allocator.free(canonical_z);
        return self.ids_by_path.get(canonical_z[0..canonical_z.len]);
    }

    fn answer(self: *FsModuleHost, request: core.ModuleRequest) !void {
        switch (try self.resolve(request)) {
            .source => |resolved| {
                defer self.allocator.free(resolved.canonical);
                defer resolved.file.close(self.io);
                const source = self.readOpenedFile(resolved.file) catch {
                    try self.project.respondFailed(request.id);
                    self.responses.failed += 1;
                    return;
                };
                defer self.allocator.free(source);
                const id = self.registerCanonical(resolved.canonical) catch |err| switch (err) {
                    error.ModuleLimitExceeded => {
                        try self.project.respondFailed(request.id);
                        self.responses.failed += 1;
                        return;
                    },
                    else => return err,
                };
                try self.project.respondSource(request.id, .{
                    .id = id,
                    .logical_name = resolved.canonical,
                    .bytes = source,
                    .kind = .module,
                });
                self.responses.source += 1;
            },
            .external => |descriptor| {
                try self.project.respondExternalModule(request.id, descriptor);
                self.responses.external += 1;
            },
            .not_found => {
                try self.project.respondNotFound(request.id);
                self.responses.not_found += 1;
            },
            .denied => {
                try self.project.respondDenied(request.id);
                self.responses.denied += 1;
            },
            .failed => {
                try self.project.respondFailed(request.id);
                self.responses.failed += 1;
            },
        }
    }

    fn resolve(self: *FsModuleHost, request: core.ModuleRequest) !Resolution {
        if (!isRelative(request.raw_specifier)) {
            for (self.options.externals) |binding| {
                if (std.mem.eql(u8, request.raw_specifier, binding.specifier)) return .{ .external = binding.descriptor };
            }
            return .not_found;
        }
        const importer_path = self.pathForId(request.importer) orelse return .failed;
        const importer_directory = std.fs.path.dirname(importer_path) orelse return .failed;
        const extension = std.fs.path.extension(request.raw_specifier);

        if (extension.len != 0) {
            if (!self.supportsExtension(extension)) return .not_found;
            const candidate = try std.fs.path.resolve(self.allocator, &.{ importer_directory, request.raw_specifier });
            defer self.allocator.free(candidate);
            return self.canonicalCandidate(candidate);
        }

        for (self.options.extensions) |supported| {
            const file_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ request.raw_specifier, supported });
            defer self.allocator.free(file_name);
            const candidate = try std.fs.path.resolve(self.allocator, &.{ importer_directory, file_name });
            defer self.allocator.free(candidate);
            switch (try self.canonicalCandidate(candidate)) {
                .not_found => {},
                else => |resolved| return resolved,
            }
        }
        for (self.options.extensions) |supported| {
            const index_name = try std.fmt.allocPrint(self.allocator, "{s}/index{s}", .{ request.raw_specifier, supported });
            defer self.allocator.free(index_name);
            const candidate = try std.fs.path.resolve(self.allocator, &.{ importer_directory, index_name });
            defer self.allocator.free(candidate);
            switch (try self.canonicalCandidate(candidate)) {
                .not_found => {},
                else => |resolved| return resolved,
            }
        }
        return .not_found;
    }

    fn canonicalCandidate(self: *FsModuleHost, candidate: []const u8) !Resolution {
        if (!self.insideRoot(candidate)) return .denied;
        const canonical_z = Io.Dir.cwd().realPathFileAlloc(self.io, candidate, self.allocator) catch |err| return switch (err) {
            error.FileNotFound, error.NotDir => .not_found,
            error.AccessDenied => .denied,
            else => .failed,
        };
        if (!self.insideRoot(canonical_z)) {
            self.allocator.free(canonical_z);
            return .denied;
        }
        const relative = try std.fs.path.relative(
            self.allocator,
            self.root_directory.?,
            null,
            self.root_directory.?,
            canonical_z,
        );
        defer self.allocator.free(relative);
        const file = self.openAnchoredFile(relative) catch |err| {
            self.allocator.free(canonical_z);
            return switch (err) {
                error.FileNotFound, error.NotDir => .not_found,
                error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => .denied,
                else => .failed,
            };
        };
        return .{ .source = .{ .canonical = canonical_z, .file = file } };
    }

    fn openAnchoredFile(self: *FsModuleHost, relative: []const u8) !Io.File {
        if (std.fs.path.isAbsolute(relative)) return error.AccessDenied;
        const file_name = std.fs.path.basename(relative);
        if (file_name.len == 0 or std.mem.eql(u8, file_name, ".") or std.mem.eql(u8, file_name, ".."))
            return error.AccessDenied;

        var current = self.root_dir orelse return error.AccessDenied;
        var owned_current: ?Io.Dir = null;
        defer if (owned_current) |directory| directory.close(self.io);
        if (std.fs.path.dirname(relative)) |parent| {
            var iterator = std.fs.path.componentIterator(parent);
            while (iterator.next()) |component| {
                if (std.mem.eql(u8, component.name, ".")) continue;
                if (std.mem.eql(u8, component.name, "..")) return error.AccessDenied;
                const next = try current.openDir(self.io, component.name, .{ .follow_symlinks = false });
                if (owned_current) |directory| directory.close(self.io);
                owned_current = next;
                current = next;
            }
        }
        return current.openFile(self.io, file_name, .{
            .allow_directory = false,
            .follow_symlinks = false,
        });
    }

    fn readOpenedFile(self: *FsModuleHost, file: Io.File) ![]u8 {
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.NotAFile;
        if (stat.size > self.options.max_source_bytes) return error.SourceTooLarge;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        return reader.interface.allocRemaining(self.allocator, .limited(self.options.max_source_bytes)) catch |err| switch (err) {
            error.StreamTooLong => error.SourceTooLarge,
            else => err,
        };
    }

    fn supportsExtension(self: *const FsModuleHost, extension: []const u8) bool {
        for (self.options.extensions) |supported| {
            if (std.mem.eql(u8, extension, supported)) return true;
        }
        return false;
    }

    fn insideRoot(self: *const FsModuleHost, path: []const u8) bool {
        const root = self.root_directory orelse return false;
        if (std.mem.eql(u8, root, path)) return true;
        if (!std.mem.startsWith(u8, path, root)) return false;
        if (root.len == 1 and std.fs.path.isSep(root[0])) return true;
        return path.len > root.len and std.fs.path.isSep(path[root.len]);
    }

    fn registerCanonical(self: *FsModuleHost, canonical: []const u8) !core.ModuleId {
        if (self.ids_by_path.get(canonical)) |id| return id;
        if (self.paths.items.len >= self.options.max_modules) return error.ModuleLimitExceeded;
        const owned = try self.allocator.dupe(u8, canonical);
        errdefer self.allocator.free(owned);
        const id = core.ModuleId.init(self.next_id);
        self.next_id = std.math.add(u64, self.next_id, 1) catch return error.ModuleIdExhausted;
        try self.paths.append(self.allocator, .{ .canonical = owned, .id = id });
        errdefer _ = self.paths.pop();
        try self.ids_by_path.put(owned, id);
        return id;
    }

    fn pathForId(self: *const FsModuleHost, id: core.ModuleId) ?[]const u8 {
        for (self.paths.items) |record| if (record.id == id) return record.canonical;
        return null;
    }
};

fn isRelative(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

test "filesystem host drives multiple files and assigns canonical session IDs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "folder");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "import { x } from './dep'; import { y } from './folder'; export const z = x + y;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data = "export const x = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "folder/index.ts", .data = "export const y = 2;" });
    const root = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const dep = try tmp.dir.realPathFileAlloc(io, "dep.ts", std.testing.allocator);
    defer std.testing.allocator.free(dep);

    var host = try FsModuleHost.init(std.testing.allocator, io, .{});
    defer host.deinit();
    _ = try host.loadRoot(root);
    const result = try host.drive();
    try std.testing.expectEqual(@as(usize, 3), result.module_count);
    try std.testing.expect(!result.has_failures);
    try std.testing.expectEqual(@as(usize, 2), host.responses.source);
    const first = (try host.moduleIdForPath(dep)).?;
    const alias = try std.fs.path.resolve(std.testing.allocator, &.{ std.fs.path.dirname(dep).?, ".", "dep.ts" });
    defer std.testing.allocator.free(alias);
    try std.testing.expectEqual(first, (try host.moduleIdForPath(alias)).?);
}

test "filesystem host denies traversal and escaping symlinks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.ts", .data = "export const secret = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/main.ts", .data = "import '../outside'; import './escape'; import './missing';" });
    try tmp.dir.symLink(io, "../outside.ts", "project/escape.ts", .{});
    const root = try tmp.dir.realPathFileAlloc(io, "project/main.ts", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var host = try FsModuleHost.init(std.testing.allocator, io, .{});
    defer host.deinit();
    _ = try host.loadRoot(root);
    const result = try host.drive();
    try std.testing.expect(result.has_failures);
    try std.testing.expectEqual(@as(usize, 2), host.responses.denied);
    try std.testing.expectEqual(@as(usize, 1), host.responses.not_found);
    try std.testing.expectEqual(@as(usize, 1), result.module_count);
}

test "filesystem host reads the opened file across a path replacement" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.ts", .data = "secret" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/main.ts", .data = "export {};" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/dep.ts", .data = "safe" });
    const root = try tmp.dir.realPathFileAlloc(io, "project/main.ts", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var host = try FsModuleHost.init(std.testing.allocator, io, .{});
    defer host.deinit();
    const root_id = try host.loadRoot(root);
    const resolution = try host.resolve(.{
        .id = .init(1),
        .importer = root_id,
        .raw_specifier = "./dep.ts",
        .kind = .static,
        .span = .{ .start = 0, .end = 0, .line = 0, .column = 0 },
    });
    switch (resolution) {
        .source => |resolved| {
            defer std.testing.allocator.free(resolved.canonical);
            defer resolved.file.close(io);
            try tmp.dir.deleteFile(io, "project/dep.ts");
            try tmp.dir.symLink(io, "../outside.ts", "project/dep.ts", .{});
            const source = try host.readOpenedFile(resolved.file);
            defer std.testing.allocator.free(source);
            try std.testing.expectEqualStrings("safe", source);
        },
        else => return error.ExpectedSourceResolution,
    }
}

test "filesystem host applies root size and module limits before source allocation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "large.ts", .data = "export const value = 123456789;" });
    const large = try tmp.dir.realPathFileAlloc(io, "large.ts", std.testing.allocator);
    defer std.testing.allocator.free(large);
    var small_host = try FsModuleHost.init(std.testing.allocator, io, .{ .max_source_bytes = 4 });
    defer small_host.deinit();
    try std.testing.expectError(error.SourceTooLarge, small_host.loadRoot(large));

    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "import './dep';" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data = "export {};" });
    const root = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var bounded = try FsModuleHost.init(std.testing.allocator, io, .{ .max_modules = 1 });
    defer bounded.deinit();
    _ = try bounded.loadRoot(root);
    const result = try bounded.drive();
    try std.testing.expect(result.has_failures);
    try std.testing.expectEqual(@as(usize, 1), bounded.responses.failed);
    try std.testing.expectEqual(@as(usize, 1), result.module_count);
}

test "filesystem host resolves registered source-less external modules" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "import runtime from 'runtime'; runtime();" });
    const root = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const exports = [_]core.ExternalExportDescriptor{.{ .name = "default", .kind = .default }};
    const bindings = [_]ExternalBinding{.{
        .specifier = "runtime",
        .descriptor = .{ .id = .init(1), .logical_name = "runtime", .exports = &exports },
    }};

    var host = try FsModuleHost.init(std.testing.allocator, io, .{ .externals = &bindings });
    defer host.deinit();
    _ = try host.loadRoot(root);
    const result = try host.drive();
    try std.testing.expect(!result.has_failures);
    try std.testing.expectEqual(@as(usize, 1), host.responses.external);
    try std.testing.expectEqual(.external, host.project.edges()[0].state);
    try std.testing.expectEqual(core.ExternalModuleId.init(1), host.project.edges()[0].external_target.?);
}
