const std = @import("std");
const Io = std.Io;

const ast_mod = @import("../frontend/ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const frontend = @import("../frontend/frontend.zig");
const loader = @import("loader.zig");
const module_resolver = @import("resolver.zig");
const tokens = @import("../frontend/tokens.zig");

pub const ModuleId = u32;

pub const ImportStatus = enum {
    local,
    external,
    missing,
};

pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    source_path: []const u8,
    result: frontend.FrontendResult,
};

pub const ImportEdge = struct {
    from: ModuleId,
    to: ?ModuleId,
    specifier: []const u8,
    status: ImportStatus,
    span: tokens.Span,
};

pub const ModuleGraph = struct {
    arena: std.heap.ArenaAllocator,
    entry: ModuleId,
    modules: []const Module,
    imports: []const ImportEdge,
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ModuleGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ModuleState = enum {
    visiting,
    done,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    io: Io,
    options: loader.BuildOptions,
    resolver: module_resolver.Resolver,
    modules: std.ArrayList(Module) = .empty,
    imports: std.ArrayList(ImportEdge) = .empty,
    states: std.ArrayList(ModuleState) = .empty,
    diagnostics_list: std.ArrayList(diagnostics.Diagnostic) = .empty,

    fn analyzeModule(self: *Builder, input_path: []const u8, source_path: []const u8) anyerror!ModuleId {
        const canonical = try self.resolver.canonicalize(input_path);
        if (self.findModule(canonical)) |existing| return existing;

        const loaded = loader.loadAndAnalyze(self.allocator, self.io, canonical, source_path, self.options) catch |err| {
            try self.diagnostics_list.append(self.allocator, .{
                .severity = .@"error",
                .code = .module_not_found,
                .phase = .module_graph,
                .message = try std.fmt.allocPrint(self.allocator, "could not read module '{s}': {s}", .{ source_path, @errorName(err) }),
                .span = emptySpan(),
                .path = source_path,
            });
            return err;
        };

        const id: ModuleId = @intCast(self.modules.items.len);
        try self.modules.append(self.allocator, .{
            .id = id,
            .path = canonical,
            .source_path = source_path,
            .result = loaded.result,
        });
        try self.states.append(self.allocator, .visiting);
        try self.appendFrontendDiagnostics(source_path, loaded.result.diagnostics);

        try self.processImports(id);
        self.states.items[@intCast(id)] = .done;
        return id;
    }

    fn processImports(self: *Builder, module_id: ModuleId) !void {
        const module = self.modules.items[@intCast(module_id)];
        for (module.result.ast.nodes) |node| {
            switch (node.data) {
                .ImportDeclaration => |import_decl| {
                    if (import_decl.source.len == 0) continue;
                    if (!module_resolver.isRelativeSpecifier(import_decl.source)) {
                        try self.imports.append(self.allocator, .{
                            .from = module_id,
                            .to = null,
                            .specifier = import_decl.source,
                            .status = .external,
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                        });
                        continue;
                    }

                    const resolved = try self.resolver.resolveRelative(module.path, import_decl.source);
                    if (resolved == null) {
                        try self.imports.append(self.allocator, .{
                            .from = module_id,
                            .to = null,
                            .specifier = import_decl.source,
                            .status = .missing,
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                        });
                        try self.diagnostics_list.append(self.allocator, .{
                            .severity = .@"error",
                            .code = .module_not_found,
                            .phase = .module_graph,
                            .message = try std.fmt.allocPrint(self.allocator, "module not found '{s}'", .{import_decl.source}),
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                            .label = "relative import could not be resolved",
                            .path = module.source_path,
                        });
                        continue;
                    }

                    const target_path = resolved.?;
                    const target_id = self.findModule(target_path) orelse target: {
                        break :target try self.analyzeModule(target_path, target_path);
                    };

                    try self.imports.append(self.allocator, .{
                        .from = module_id,
                        .to = target_id,
                        .specifier = import_decl.source,
                        .status = .local,
                        .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                    });

                    if (self.states.items[@intCast(target_id)] == .visiting) {
                        try self.diagnostics_list.append(self.allocator, .{
                            .severity = .@"error",
                            .code = .circular_import,
                            .phase = .module_graph,
                            .message = try std.fmt.allocPrint(self.allocator, "circular import through '{s}'", .{import_decl.source}),
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                            .label = "import reaches a module already being analyzed",
                            .path = module.source_path,
                        });
                        continue;
                    }

                    try self.validateNamedImports(module, self.modules.items[@intCast(target_id)], import_decl);
                },
                else => {},
            }
        }
    }

    fn validateNamedImports(self: *Builder, source: Module, target: Module, import_decl: ast_mod.ImportDeclaration) !void {
        for (import_decl.specifiers) |specifier| {
            if (!moduleExportsName(target, specifier.imported_name)) {
                try self.diagnostics_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .missing_export,
                    .phase = .module_graph,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "module '{s}' has no exported member '{s}'",
                        .{ import_decl.source, specifier.imported_name },
                    ),
                    .span = specifier.imported_span,
                    .label = "requested export was not found",
                    .path = source.source_path,
                });
            }
        }
    }

    fn appendFrontendDiagnostics(self: *Builder, path: []const u8, diags: []const diagnostics.Diagnostic) !void {
        for (diags) |diag| {
            var copy = diag;
            if (copy.path == null) copy.path = path;
            try self.diagnostics_list.append(self.allocator, copy);
        }
    }

    fn findModule(self: *Builder, canonical_path: []const u8) ?ModuleId {
        for (self.modules.items) |module| {
            if (std.mem.eql(u8, module.path, canonical_path)) return module.id;
        }
        return null;
    }
};

pub fn build(allocator: std.mem.Allocator, io: Io, entry_path: []const u8, options: loader.BuildOptions) !ModuleGraph {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const graph_allocator = arena.allocator();

    var builder: Builder = .{
        .allocator = graph_allocator,
        .io = io,
        .options = options,
        .resolver = .{
            .allocator = graph_allocator,
            .io = io,
        },
    };
    const entry = try builder.analyzeModule(entry_path, entry_path);
    return .{
        .arena = arena,
        .entry = entry,
        .modules = try builder.modules.toOwnedSlice(graph_allocator),
        .imports = try builder.imports.toOwnedSlice(graph_allocator),
        .diagnostics = try builder.diagnostics_list.toOwnedSlice(graph_allocator),
    };
}

fn moduleExportsName(module: Module, name: []const u8) bool {
    for (module.result.bind.module.exports) |export_record| {
        if (std.mem.eql(u8, export_record.name, name)) return true;
    }
    return false;
}

fn emptySpan() tokens.Span {
    return .{ .start = 0, .end = 0, .line = 1, .column = 1 };
}

fn writeTmpFile(tmp: std.testing.TmpDir, path: []const u8, text: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = text });
}

fn tmpEntryPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, file });
}

test "module graph resolves single local import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts", "import { value } from \"./dep\";\nconst x = value;\n");
    try writeTmpFile(tmp, "dep.ts", "export const value = 1;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.imports.len);
    try std.testing.expectEqual(ImportStatus.local, graph.imports[0].status);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
}

test "module graph reports missing module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts", "import { value } from \"./missing\";\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.imports.len);
    try std.testing.expectEqual(ImportStatus.missing, graph.imports[0].status);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.module_not_found, graph.diagnostics[0].code);
}

test "module graph missing-module diagnostic uses specifier span" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    //           0         12345678901
    // 012345678901234567890123456789012
    try writeTmpFile(tmp, "main.ts", "import { value } from \"./missing\";\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.module_not_found, graph.diagnostics[0].code);

    const diag = graph.diagnostics[0];
    // String literal "\./missing" spans bytes [22, 33) (end exclusive).
    try std.testing.expect(diag.span.start == 22);
    try std.testing.expect(diag.span.end   == 33);
}

test "module graph reports missing export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts", "import { missing } from \"./dep\";\n");
    try writeTmpFile(tmp, "dep.ts", "export const value = 1;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(diagnostics.DiagnosticCode.missing_export, graph.diagnostics[0].code);
}

test "module graph validates alias import by imported name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts", "import { value as localValue } from \"./dep\";\nconst x = localValue;\n");
    try writeTmpFile(tmp, "dep.ts", "export const value = 1;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
}

test "module graph records external import without validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts", "import { readFile } from \"node:fs\";\nconst x = readFile;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 1), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.imports.len);
    try std.testing.expectEqual(ImportStatus.external, graph.imports[0].status);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
}

test "module graph caches duplicate relative specifiers by canonical path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "main.ts",
        \\import { a } from "./dep";
        \\import { b } from "./dep.ts";
        \\const x = a + b;
    );
    try writeTmpFile(tmp, "dep.ts", "export const a = 1; export const b = 2;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 2), graph.imports.len);
    try std.testing.expectEqual(graph.imports[0].to.?, graph.imports[1].to.?);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
}

test "module graph reports simple cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTmpFile(tmp, "a.ts", "import { b } from \"./b\";\nexport const a = b;\n");
    try writeTmpFile(tmp, "b.ts", "import { a } from \"./a\";\nexport const b = a;\n");

    const entry = try tmpEntryPath(std.testing.allocator, tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var graph = try build(std.testing.allocator, std.testing.io, entry, .{});
    defer graph.deinit();

    var found_cycle = false;
    for (graph.diagnostics) |diag| {
        if (diag.code == .circular_import) found_cycle = true;
    }
    try std.testing.expect(found_cycle);
}
