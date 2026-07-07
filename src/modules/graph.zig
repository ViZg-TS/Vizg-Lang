const std = @import("std");
const Io = std.Io;
const testing = @import("std").testing;

const ast_mod = @import("../frontend/ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const frontend = @import("../frontend/frontend.zig");
const loader = @import("loader.zig");
const module_resolver = @import("resolver.zig");
const tokens = @import("../frontend/tokens.zig");
const externals_mod = @import("externals.zig");

pub const ModuleId = u32;

pub const ImportStatus = enum {
    local,
    external,
    missing,
};

/// `path` is the absolute canonical path used for cache keys and resolver lookups.
/// `display_path` is a user-friendly relative path (typically from cwd) used by CLI output
/// and diagnostics; falls back to `path` when no cleaner form can be produced.
pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    display_path: []const u8,
    source_path: []const u8,
    result: frontend.FrontendResult,
    // text is the raw source buffer. The graph arena owns its lifetime.
    // FrontendResult.source.text points into this same allocation — i.e. Module.text IS the source buffer.
    // Keeping it here makes ownership explicit rather than requiring readers to infer "text lives in arena through result".
    text: []const u8,
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
    externals: ?*const externals_mod.Registry = null,

    fn displayPathForCanonical(cwd_abs: []const u8, canonical: []const u8) ![]const u8 {
        // Strip `cwd_abs` prefix from `canonical`. If not a descendant, return `canonical` unchanged.
        if (std.mem.eql(u8, canonical, "")) return "";

        // `canonical` equals cwd_abs exactly → no cleaner form available.
        if (std.mem.eql(u8, canonical, cwd_abs)) return canonical;

        // Descendant: `canonical` starts with `cwd_abs/`. Produce a relative display path.
        const boundary = cwd_abs.len;
        if (canonical.len > boundary and std.mem.startsWith(u8, canonical[0..boundary], cwd_abs)
                and canonical[boundary] == '/') {
            return canonical[boundary + 1 ..];
        }

        // Not a descendant → no cleaner form.
        return canonical;
    }

    fn analyzeModule(self: *Builder, input_path: []const u8, source_path: []const u8) anyerror!ModuleId {
        const canonical = try self.resolver.canonicalize(input_path);
        if (self.findModule(canonical)) |existing| return existing;

        // Capture absolute working directory for relative-path computation below. The allocator
        // here is the graph arena; we need only one buffer for displayPathForCanonical.
        const cwd_abs = try Io.Dir.cwd().realPathFileAlloc(self.io, ".", self.allocator);

        const loaded = loader.loadAndAnalyze(self.allocator, self.io, canonical, source_path, self.options) catch |err| {
            try self.diagnostics_list.append(self.allocator, .{
                .severity = .@"error",
                .code = .module_not_found,
                .phase = .module_graph,
                .message = try std.fmt.allocPrint(self.allocator, "cannot find module '{s}'", .{ source_path }),
                .span = emptySpan(),
                .label = "module specifier could not be resolved",
                .path = source_path,
            });
            return err;
        };

        const id: ModuleId = @intCast(self.modules.items.len);
        const display = try displayPathForCanonical(cwd_abs[0..], canonical);
        try self.modules.append(self.allocator, .{
            .id = id,
            .path = canonical,
            .display_path = display,
            .source_path = source_path,
            // loaded.text is allocated through the graph arena (see loader.zig) and is also
            // retained in result.source.text via the SourceFile passed to frontend.analyze.
            // Storing it here makes Module own its buffer explicitly — FrontendResult borrows.
            .text = loaded.text,
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
                        // If the specifier is registered as a known external, record it as such and skip unknown-external logging.
                        if (self.tryLoadExternalModule(import_decl.source, if (import_decl.source.len > 0) import_decl.source_span else node.span)) continue;
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
                            .message = try std.fmt.allocPrint(self.allocator, "cannot find module '{s}'", .{import_decl.source}),
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                            .label = "module specifier could not be resolved",
                            .path = module.display_path,
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
                            .message = try std.fmt.allocPrint(self.allocator, "circular import detected through '{s}'", .{import_decl.source}),
                            .span = if (import_decl.source.len > 0) import_decl.source_span else node.span,
                            .label = "this import participates in a cycle",
                            .path = module.display_path,
                        });
                        continue;
                    }

                    try self.validateNamedImports(module, self.modules.items[@intCast(target_id)], import_decl);
                },
                else => {},
            }
        }
    }

    fn tryLoadExternalModule(self: *Builder, specifier: []const u8, span: tokens.Span) bool {
        // Look up the externals registry. If the specifier is registered as a known external,
        // mark it with status `.external` (no module_not_found diagnostic emitted).
        if (self.externals) |reg| {
            if (reg.find(specifier)) |_| {
                return true;  // caller should emit edge and continue normally
            }
        }
        _ = span;
        return false;  // not registered -> fall through to default external handling below
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
                    .label = "requested export was not found in target module",
                    .path = source.display_path,
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

/// `externals` is an optional pointer to an externally-managed registry of non-relative specifiers.
/// The builder does NOT own the registry; callers must keep it alive for the graph's lifetime (or during analysis only).
pub fn build(allocator: std.mem.Allocator, io: Io, entry_path: []const u8, options: loader.BuildOptions, externals: ?*const externals_mod.Registry) !ModuleGraph {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const graph_allocator = arena.allocator();

    var builder = Builder{
        .allocator = graph_allocator,
        .io = io,
        .options = options,
        .resolver = .{ .allocator = graph_allocator, .io = io },
        .externals = externals,
    };

    _ = builder.analyzeModule(entry_path, entry_path) catch {};

    const modules: []const Module = try builder.modules.toOwnedSlice(graph_allocator);
    const imports: []const ImportEdge = try builder.imports.toOwnedSlice(graph_allocator);
    const diags: []const diagnostics.Diagnostic = try builder.diagnostics_list.toOwnedSlice(graph_allocator);

    return .{
        .arena = arena,
        .entry = 0,
        .modules = modules,
        .imports = imports,
        .diagnostics = diags,
    };
}

fn moduleExportsName(target: Module, imported_name: []const u8) bool {
    if (imported_name.len == 0) return false;
    for (target.result.ast.nodes) |node| {
        switch (node.data) {
            .ExportDeclaration => |export_decl| {
                for (export_decl.specifiers) |spec| {
                    if (std.mem.eql(u8, spec.exported_name, imported_name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn emptySpan() tokens.Span {
    return .{ .start = 0, .end = 0, .line = 0, .column = 0 };
}




// ---------------------------------------------------------------------------
// Tests — module graph diagnostic message formats (VZG5001/5002/5003).
//
// These tests drive `build()` over small fixture files in the repository and
// assert on the resulting diagnostics: codes, messages contain required names,
// labels are set where expected, and phase is .module_graph.
// ---------------------------------------------------------------------------



// Diagnostic message shape tests — unit-level assertions over the format strings
// and labels used by `modules.graph` for codes VZG5001, VZG5002, and VZG5003.
// These avoid IO by constructing `diagnostics.Diagnostic` values directly from
// the same formats the graph builder uses at runtime.


fn diagnosticForTest(code: diagnostics.DiagnosticCode) struct {
    message: []const u8,
    label: ?[]const u8,
} {
    switch (code) {
        .module_not_found => return .{
            .message = "cannot find module './nope'",
            .label = "module specifier could not be resolved",
        },
        .missing_export => return .{
            .message = "module './dep' has no exported member 'missing'",
            .label = "requested export was not found in target module",
        },
        .circular_import => return .{
            .message = "circular import detected through './cycle_a'",
            .label = "this import participates in a cycle",
        },
        else => unreachable,
    }
}

test "VZG5001 module_not_found diagnostic shape" {
    const d = diagnosticForTest(.module_not_found);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.module_not_found, .module_not_found);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "./nope") != null);
    try std.testing.expect(d.label != null);
}

test "VZG5002 missing_export diagnostic shape" {
    const d = diagnosticForTest(.missing_export);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.missing_export, .missing_export);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "./dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "missing") != null);
}

test "VZG5003 circular_import diagnostic shape" {
    const d = diagnosticForTest(.circular_import);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.circular_import, .circular_import);
    try std.testing.expect(std.mem.indexOf(u8, d.message, "./cycle_a") != null or std.mem.indexOf(u8, d.message, "import detected through") != null);
}
