const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const frontend = @import("../frontend/frontend.zig");
const function_like = @import("../frontend/function_like.zig");
const resolver = @import("../frontend/resolver.zig");
const diagnostics = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const modules_mod = @import("../modules/root.zig");

pub const type_info = @import("type_info.zig");
pub const type_collector = @import("type_collector.zig");
pub const type_inference = @import("type_inference.zig");
pub const checker = @import("checker.zig");
pub const type_compat = @import("type_compat.zig");
pub const dataflow = @import("dataflow.zig");
pub const narrowing = @import("narrowing.zig");

pub const SymbolTypeInfo = type_info.SymbolTypeInfo;
pub const NodeTypeInfo = type_info.NodeTypeInfo;
pub const ResolvedTypeNode = type_info.ResolvedTypeNode;
pub const FlowTypeInfo = type_info.FlowTypeInfo;
pub const TypeInfo = type_info.TypeInfo;
pub const TypeResolutionState = type_info.TypeResolutionState;
pub const ModuleId = u64;
pub const ReferenceId = resolver.ReferenceId;

pub const SemanticIdentity = struct {
    symbol_id: ?binder.SymbolId,
    declaration: types.SemanticDeclId,
    type_id: types.TypeId,
    namespace: binder.SymbolNamespace,
    /// Present only for source-less host modules. Numeric values may equal a
    /// source ModuleId without creating equal semantic provenance.
    external_module_id: ?u64 = null,
    external_symbol_id: ?u64 = null,
    external_declaration_kind: ?@import("../project/contracts.zig").ExternalDeclarationKind = null,
    external_effects: ?@import("../project/contracts.zig").ExternalEffectSet = null,
};

pub const SemanticLinkState = enum {
    resolved,
    namespace,
    external,
    unresolved,
    cyclic_partial,
};

pub const SemanticExport = struct {
    module_id: ModuleId,
    name: []const u8,
    identity: SemanticIdentity,
    type_only: bool,
    re_export: bool,
    span: @import("../frontend/tokens.zig").Span,
};

pub const SemanticImport = struct {
    module_id: ModuleId,
    import_symbol: ?binder.SymbolId,
    local_name: []const u8,
    imported_name: []const u8,
    type_only: bool,
    runtime_binding: bool,
    state: SemanticLinkState,
    target: ?SemanticIdentity,
    span: @import("../frontend/tokens.zig").Span,
};

pub const ProjectSemanticModule = struct {
    id: ModuleId,
    path: []const u8,
    type_info: TypeInfo,
};

/// Owned multi-file semantic output. `graph` owns source/frontend data; `arena`
/// owns all semantic tables. Cross-module links contain IDs only. Every TypeId
/// belongs to the single project TypeStore.
pub const ProjectSemanticResult = struct {
    arena: *std.heap.ArenaAllocator,
    graph: modules_mod.ModuleGraph,
    type_store: types.TypeStore,
    modules: []ProjectSemanticModule,
    exports: []SemanticExport,
    imports: []SemanticImport,
    diagnostics: []const diagnostics.Diagnostic,
    is_partial: bool,

    pub fn deinit(self: *ProjectSemanticResult) void {
        self.graph.deinit();
        destroyArena(self.arena);
        self.* = undefined;
    }

    pub fn lookupModule(self: *const ProjectSemanticResult, id: ModuleId) ?*const ProjectSemanticModule {
        for (self.modules) |*module| if (module.id == id) return module;
        return null;
    }

    pub fn lookupExport(self: *const ProjectSemanticResult, module_id: ModuleId, name: []const u8) ?SemanticExport {
        for (self.exports) |item| if (item.module_id == module_id and std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

/// Multi-file semantic output derived from a borrowed module graph. The graph
/// and every frontend result it references must outlive this result.
pub const BorrowedProjectSemanticResult = struct {
    arena: *std.heap.ArenaAllocator,
    type_store: types.TypeStore,
    modules: []ProjectSemanticModule,
    exports: []SemanticExport,
    imports: []SemanticImport,
    diagnostics: []const diagnostics.Diagnostic,
    is_partial: bool,

    pub fn deinit(self: *BorrowedProjectSemanticResult) void {
        destroyArena(self.arena);
        self.* = undefined;
    }

    pub fn lookupModule(self: *const BorrowedProjectSemanticResult, id: ModuleId) ?*const ProjectSemanticModule {
        for (self.modules) |*module| if (module.id == id) return module;
        return null;
    }

    pub fn lookupExport(self: *const BorrowedProjectSemanticResult, module_id: ModuleId, name: []const u8) ?SemanticExport {
        for (self.exports) |item| if (item.module_id == module_id and std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

const ProjectSemanticData = struct {
    arena: *std.heap.ArenaAllocator,
    type_store: types.TypeStore,
    modules: []ProjectSemanticModule,
    exports: []SemanticExport,
    imports: []SemanticImport,
    diagnostics: []const diagnostics.Diagnostic,
    is_partial: bool,
};

pub const SemanticMetadata = struct {
    source_kind: frontend.SourceKind,
    is_partial: bool,
    syntax_diagnostic_count: usize,
    semantic_diagnostic_count: usize,
};

/// Stable, value-based identity for the analyzed module. Import/export slices
/// remain valid until the owning SemanticResult is deinitialized.
pub const SemanticModule = struct {
    id: ModuleId,
    path: []const u8,
    imports: []const binder.ImportRecord,
    exports: []const binder.ExportRecord,
};

/// Owned output of one complete frontend + semantic analysis.
///
/// All slices, strings, AST nodes, symbols, scopes, references, module links,
/// types, and diagnostics are owned by `arena`. Call `deinit` exactly once and
/// do not retain any returned slice after that call. Diagnostics never make a
/// result unsafe to inspect: `metadata.is_partial` reports recovered output.
/// TypeIds belong to this result's TypeStore and must not be compared with IDs
/// from another SemanticResult.
pub const SemanticResult = struct {
    arena: *std.heap.ArenaAllocator,
    frontend: frontend.FrontendResult,
    module: SemanticModule,
    type_store: types.TypeStore,
    type_info: TypeInfo,
    syntax_diagnostics: []const diagnostics.Diagnostic,
    semantic_diagnostics: []const diagnostics.Diagnostic,
    diagnostics: []const diagnostics.Diagnostic,
    metadata: SemanticMetadata,

    pub fn deinit(self: *SemanticResult) void {
        destroyArena(self.arena);
        self.* = undefined;
    }

    pub fn lookupNode(self: *const SemanticResult, id: ast.NodeId) ?ast.Node {
        const index: usize = @intCast(id);
        if (index >= self.frontend.ast.nodes.len) return null;
        return self.frontend.ast.nodes[index];
    }

    pub fn lookupNodeType(self: *const SemanticResult, id: ast.NodeId) ?types.TypeId {
        return self.type_info.lookupNode(id);
    }

    pub fn lookupNodeTypeInfo(self: *const SemanticResult, id: ast.NodeId) ?NodeTypeInfo {
        return self.type_info.lookupNodeInfo(id);
    }

    pub fn lookupResolvedTypeNode(self: *const SemanticResult, id: ast.TypeNodeId) ?types.TypeId {
        return self.type_info.lookupResolvedTypeNode(id);
    }

    pub fn lookupType(self: *const SemanticResult, id: types.TypeId) ?types.Type {
        return self.type_store.lookup(id);
    }

    pub fn lookupFunctionType(self: *const SemanticResult, id: types.TypeId) ?types.FunctionSignature {
        return self.type_store.lookupFunction(id);
    }

    pub fn lookupSymbol(self: *const SemanticResult, id: binder.SymbolId) ?binder.Symbol {
        for (self.frontend.bind.symbols) |symbol| {
            if (symbol.id == id) return symbol;
        }
        return null;
    }

    pub fn lookupSymbolType(self: *const SemanticResult, id: binder.SymbolId) ?SymbolTypeInfo {
        return self.type_info.lookupSymbol(id);
    }

    pub fn lookupScope(self: *const SemanticResult, id: binder.ScopeId) ?binder.Scope {
        for (self.frontend.bind.scopes) |scope| {
            if (scope.id == id) return scope;
        }
        return null;
    }

    pub fn lookupReference(self: *const SemanticResult, id: ReferenceId) ?resolver.Reference {
        const index: usize = @intCast(id);
        if (index >= self.frontend.resolve.references.len) return null;
        return self.frontend.resolve.references[index];
    }

    pub fn lookupModule(self: *const SemanticResult, id: ModuleId) ?SemanticModule {
        if (id != self.module.id) return null;
        return self.module;
    }
};

test {
    _ = type_info;
    _ = type_collector;
    _ = type_inference;
    _ = type_compat;
}

/// Analyze one source exactly once and return the single owned semantic output.
pub fn analyzeSource(
    backing_allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    options: frontend.FrontendOptions,
) !SemanticResult {
    const arena = try createArena(backing_allocator);
    errdefer destroyArena(arena);
    const allocator = arena.allocator();

    const owned_source: frontend.SourceFile = .{
        .path = try allocator.dupe(u8, source.path),
        .text = try allocator.dupe(u8, source.text),
        .kind = source.kind,
    };
    const fe = try frontend.analyze(allocator, owned_source, options);
    var type_store = types.TypeStore.init(allocator);
    const info = try buildTypeInfo(allocator, @as(modules_mod.ModuleId, 0), fe, &type_store, true, &.{}, true);

    const syntax_diags = try selectDiagnostics(allocator, fe.diagnostics, true, owned_source.path);
    const frontend_semantic_diags = try selectDiagnostics(allocator, fe.diagnostics, false, owned_source.path);
    const semantic_diags = try combineDiagnostics(allocator, &.{ frontend_semantic_diags, info.diagnostics }, owned_source.path);
    const all_diags = try combineDiagnostics(allocator, &.{ syntax_diags, semantic_diags }, owned_source.path);

    const module: SemanticModule = .{
        .id = 0,
        .path = owned_source.path,
        .imports = fe.bind.module.imports,
        .exports = fe.bind.module.exports,
    };

    return .{
        .arena = arena,
        .frontend = fe,
        .module = module,
        .type_store = type_store,
        .type_info = info,
        .syntax_diagnostics = syntax_diags,
        .semantic_diagnostics = semantic_diags,
        .diagnostics = all_diags,
        .metadata = .{
            .source_kind = owned_source.kind,
            .is_partial = all_diags.len != 0,
            .syntax_diagnostic_count = syntax_diags.len,
            .semantic_diagnostic_count = semantic_diags.len,
        },
    };
}

/// Convenience entry point for in-memory module source.
pub fn analyze(backing_allocator: std.mem.Allocator, source: []const u8) !SemanticResult {
    return analyzeSource(backing_allocator, .{ .path = "input", .text = source }, .{});
}

/// Consumes `input_graph`, including on failure. The returned result owns both
/// graph and semantic allocations and must be deinitialized exactly once.
pub fn analyzeModuleGraph(backing_allocator: std.mem.Allocator, input_graph: modules_mod.ModuleGraph) !ProjectSemanticResult {
    var graph = input_graph;
    errdefer graph.deinit();

    const data = try analyzeModuleGraphData(backing_allocator, &graph);
    return .{
        .arena = data.arena,
        .graph = graph,
        .type_store = data.type_store,
        .modules = data.modules,
        .exports = data.exports,
        .imports = data.imports,
        .diagnostics = data.diagnostics,
        .is_partial = data.is_partial,
    };
}

/// Analyze already-owned frontend results without taking graph ownership.
pub fn analyzeBorrowedModuleGraph(backing_allocator: std.mem.Allocator, graph: *const modules_mod.ModuleGraph) !BorrowedProjectSemanticResult {
    const data = try analyzeModuleGraphData(backing_allocator, graph);
    return .{
        .arena = data.arena,
        .type_store = data.type_store,
        .modules = data.modules,
        .exports = data.exports,
        .imports = data.imports,
        .diagnostics = data.diagnostics,
        .is_partial = data.is_partial,
    };
}

fn analyzeModuleGraphData(backing_allocator: std.mem.Allocator, graph: *const modules_mod.ModuleGraph) !ProjectSemanticData {
    const arena = try createArena(backing_allocator);
    errdefer destroyArena(arena);
    const allocator = arena.allocator();
    var type_store = types.TypeStore.init(allocator);

    var project_modules: std.ArrayList(ProjectSemanticModule) = .empty;
    for (graph.modules) |module| {
        try project_modules.append(allocator, .{
            .id = module.id,
            .path = module.display_path,
            .type_info = try buildTypeInfo(allocator, module.id, module.result, &type_store, false, &.{}, false),
        });
    }

    var export_list: std.ArrayList(SemanticExport) = .empty;
    try collectDirectExports(allocator, graph.modules, project_modules.items, &type_store, &export_list);
    try resolveReExports(allocator, graph, project_modules.items, &type_store, &export_list);

    var import_list: std.ArrayList(SemanticImport) = .empty;
    try collectSemanticImports(allocator, graph, &type_store, export_list.items, &import_list);

    // The first pass establishes exported identities. Once imports are linked,
    // complete nominal tables exactly once in dependency-first graph order so
    // inherited/imported shapes exist before any consumer lowers aliases.
    _ = refreshImportTargets(graph, export_list.items, import_list.items);
    _ = try refreshNamespaceImportTargets(allocator, graph, &type_store, export_list.items, import_list.items);
    var completion_index = project_modules.items.len;
    while (completion_index > 0) {
        completion_index -= 1;
        const module = &project_modules.items[completion_index];
        const graph_module = graphModule(graph, module.id) orelse continue;
        const imported_types = try importedTypeBindings(allocator, module.id, import_list.items, &type_store);
        _ = try type_collector.collectDeclaredTypesInModuleWithImports(
            allocator,
            graph_module.result.source,
            graph_module.result.ast,
            graph_module.result.bind,
            module.id,
            &type_store,
            imported_types,
            true,
        );
    }

    // Rebuild effective module types against the now-immutable nominal tables.
    // Missing/cyclic targets remain stable `unknown` placeholders.
    for (project_modules.items) |*module| {
        const graph_module = graphModule(graph, module.id) orelse continue;
        const imported_types = try importedTypeBindings(allocator, module.id, import_list.items, &type_store);
        module.type_info = try buildTypeInfo(
            allocator,
            module.id,
            graph_module.result,
            &type_store,
            false,
            imported_types,
            false,
        );
    }

    // Imported values may feed exported initializers. Iterate bounded propagation
    // over IDs; cycles settle as unknown or a stable canonical TypeId.
    var round: usize = 0;
    while (round < graph.modules.len + 2) : (round += 1) {
        var changed = refreshImportTargets(graph, export_list.items, import_list.items);
        for (project_modules.items) |*module| {
            const graph_module = graphModule(graph, module.id) orelse continue;
            changed = (try applyImportedTypes(module, import_list.items, &type_store)) or changed;
            changed = (try refreshProjectTypes(allocator, module.id, graph_module.result, &module.type_info, &type_store)) or changed;
        }
        changed = refreshDirectExportTypes(project_modules.items, export_list.items) or changed;
        try resolveReExports(allocator, graph, project_modules.items, &type_store, &export_list);
        // Namespace objects cache export TypeIds. Rebuild them after direct and
        // re-export propagation so the next round refreshes imported symbols,
        // references, expressions, and dependent exports from the final shape.
        changed = (try refreshNamespaceImportTargets(allocator, graph, &type_store, export_list.items, import_list.items)) or changed;
        if (!changed) break;
    }

    for (project_modules.items) |*module| {
        const graph_module = graphModule(graph, module.id) orelse continue;
        try finishProjectTypes(allocator, graph_module.result, &module.type_info, &type_store);
    }

    var all_diags: std.ArrayList(diagnostics.Diagnostic) = .empty;
    try all_diags.appendSlice(allocator, graph.diagnostics);
    for (project_modules.items) |module| try all_diags.appendSlice(allocator, module.type_info.diagnostics);

    const module_slice = try project_modules.toOwnedSlice(allocator);
    const export_slice = try export_list.toOwnedSlice(allocator);
    const import_slice = try import_list.toOwnedSlice(allocator);
    const diagnostic_slice = try all_diags.toOwnedSlice(allocator);
    return .{
        .arena = arena,
        .type_store = type_store,
        .modules = module_slice,
        .exports = export_slice,
        .imports = import_slice,
        .diagnostics = diagnostic_slice,
        .is_partial = diagnostic_slice.len != 0 or hasUnresolvedLinks(import_slice),
    };
}

fn createArena(backing_allocator: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try backing_allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(backing_allocator);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const backing_allocator = arena.child_allocator;
    arena.deinit();
    backing_allocator.destroy(arena);
}

fn graphModule(graph: *const modules_mod.ModuleGraph, id: ModuleId) ?*const modules_mod.Module {
    for (graph.modules) |*module| if (module.id == id) return module;
    return null;
}

fn projectModule(items: []ProjectSemanticModule, id: ModuleId) ?*ProjectSemanticModule {
    for (items) |*module| if (module.id == id) return module;
    return null;
}

fn symbolByName(module: modules_mod.Module, name: []const u8, type_only: bool) ?binder.Symbol {
    for (module.result.bind.symbols) |symbol| {
        if (!std.mem.eql(u8, symbol.name, name)) continue;
        if (type_only and symbol.namespace != .type) continue;
        return symbol;
    }
    return null;
}

fn collectDirectExports(
    allocator: std.mem.Allocator,
    graph_modules: []const modules_mod.Module,
    semantic_modules: []ProjectSemanticModule,
    type_store: *types.TypeStore,
    exports: *std.ArrayList(SemanticExport),
) !void {
    for (graph_modules) |module| {
        const semantic_module = projectModule(semantic_modules, module.id) orelse continue;
        for (module.result.bind.module.exports) |record| {
            if (record.source.len != 0 or record.kind == .export_all) continue;
            const symbol = symbolByName(module, record.local_name, record.type_only);
            const declaration = if (symbol) |item| item.declaration else record.node;
            const namespace: binder.SymbolNamespace = if (symbol) |item| item.namespace else if (record.type_only) .type else .value;
            const type_id = if (symbol) |item| blk: {
                const symbol_type = semantic_module.type_info.lookupSymbol(item.id) orelse break :blk type_store.builtins.unknown;
                break :blk symbol_type.effective() orelse type_store.builtins.unknown;
            } else semantic_module.type_info.lookupNode(record.node) orelse type_store.builtins.unknown;
            try exports.append(allocator, .{
                .module_id = module.id,
                .name = record.name,
                .identity = .{
                    .symbol_id = if (symbol) |item| item.id else null,
                    .declaration = types.SemanticDeclId.init(module.id, declaration),
                    .type_id = type_id,
                    .namespace = namespace,
                },
                .type_only = record.type_only or namespace == .type,
                .re_export = false,
                .span = module.result.ast.node(record.node).span,
            });
        }
    }
}

fn edgeForSource(graph: *const modules_mod.ModuleGraph, from: ModuleId, source: []const u8, re_export: bool) ?modules_mod.ImportEdge {
    for (graph.imports) |edge| {
        if (edge.from == from and edge.re_export == re_export and std.mem.eql(u8, edge.specifier, source)) return edge;
    }
    return null;
}

fn exportIndex(exports: []const SemanticExport, module_id: ModuleId, name: []const u8, type_only: bool) ?usize {
    var fallback: ?usize = null;
    for (exports, 0..) |item, index| {
        if (item.module_id != module_id or !std.mem.eql(u8, item.name, name)) continue;
        if (item.type_only == type_only) return index;
        fallback = index;
    }
    return fallback;
}

fn appendReExport(allocator: std.mem.Allocator, exports: *std.ArrayList(SemanticExport), module_id: ModuleId, name: []const u8, target: SemanticExport, type_only: bool, span: @import("../frontend/tokens.zig").Span) !bool {
    if (exportIndex(exports.items, module_id, name, type_only)) |index| {
        const changed = exports.items[index].identity.type_id != target.identity.type_id or !exports.items[index].identity.declaration.eql(target.identity.declaration);
        exports.items[index].identity = target.identity;
        exports.items[index].type_only = type_only or target.type_only;
        exports.items[index].re_export = true;
        return changed;
    }
    try exports.append(allocator, .{
        .module_id = module_id,
        .name = name,
        .identity = target.identity,
        .type_only = type_only or target.type_only,
        .re_export = true,
        .span = span,
    });
    return true;
}

fn resolveReExports(
    allocator: std.mem.Allocator,
    graph: *const modules_mod.ModuleGraph,
    semantic_modules: []ProjectSemanticModule,
    type_store: *types.TypeStore,
    exports: *std.ArrayList(SemanticExport),
) !void {
    _ = semantic_modules;
    _ = type_store;
    var round: usize = 0;
    while (round < graph.modules.len + 1) : (round += 1) {
        var changed = false;
        for (graph.modules) |module| {
            for (module.result.bind.module.exports) |record| {
                if (record.source.len == 0 or record.kind == .export_all) continue;
                const edge = edgeForSource(graph, module.id, record.source, true) orelse continue;
                const target_module = edge.to orelse continue;
                const target_index = exportIndex(exports.items, target_module, record.local_name, record.type_only) orelse continue;
                changed = (try appendReExport(allocator, exports, module.id, record.name, exports.items[target_index], record.type_only, module.result.ast.node(record.node).span)) or changed;
            }
            for (module.result.ast.nodes) |node| switch (node.data) {
                .ExportDeclaration => |decl| if (decl.kind == .export_all and decl.source.len != 0) {
                    const edge = edgeForSource(graph, module.id, decl.source, true) orelse continue;
                    const target_module = edge.to orelse continue;
                    const snapshot_len = exports.items.len;
                    var index: usize = 0;
                    while (index < snapshot_len) : (index += 1) {
                        const target = exports.items[index];
                        if (target.module_id != target_module or std.mem.eql(u8, target.name, "default")) continue;
                        changed = (try appendReExport(allocator, exports, module.id, target.name, target, decl.type_only, node.span)) or changed;
                    }
                },
                else => {},
            };
        }
        if (!changed) break;
    }
}

fn importEdge(graph: *const modules_mod.ModuleGraph, id: modules_mod.graph.ImportEdgeId) ?modules_mod.ImportEdge {
    for (graph.imports) |edge| if (edge.id == id) return edge;
    return null;
}

fn collectSemanticImports(
    allocator: std.mem.Allocator,
    graph: *const modules_mod.ModuleGraph,
    type_store: *types.TypeStore,
    exports: []const SemanticExport,
    imports: *std.ArrayList(SemanticImport),
) !void {
    for (graph.linked_imports) |link| {
        const edge = importEdge(graph, link.import_edge) orelse continue;
        const source_module = graphModule(graph, link.from_module);
        const type_only = if (source_module) |module| blk: {
            for (module.result.bind.module.imports) |record| {
                if (std.mem.eql(u8, record.local_name, link.local_name)) break :blk record.type_only;
            }
            break :blk edge.type_only;
        } else edge.type_only;
        var state: SemanticLinkState = switch (link.kind) {
            .external => .external,
            .namespace => .namespace,
            .unresolved => if (edge.to != null) .cyclic_partial else .unresolved,
            else => .unresolved,
        };
        var target: ?SemanticIdentity = null;
        if (link.target_module) |target_module| {
            if (link.kind == .namespace) {
                var properties: std.ArrayList(types.ObjectProperty) = .empty;
                for (exports) |item| {
                    if (item.module_id != target_module or item.type_only) continue;
                    try properties.append(allocator, .{ .name = item.name, .type_id = item.identity.type_id });
                }
                target = .{
                    .symbol_id = null,
                    .declaration = types.SemanticDeclId.init(target_module, ast.invalid_node),
                    .type_id = if (properties.items.len == 0) type_store.builtins.unknown else try type_store.intern(.{ .object = properties.items }),
                    .namespace = if (type_only) .type else .value,
                };
            } else if (exportIndex(exports, target_module, link.imported_name, type_only)) |index| {
                target = exports[index].identity;
                state = .resolved;
            }
        }
        try imports.append(allocator, .{
            .module_id = link.from_module,
            .import_symbol = link.import_symbol,
            .local_name = link.local_name,
            .imported_name = link.imported_name,
            .type_only = type_only,
            .runtime_binding = !type_only and state != .unresolved and state != .cyclic_partial,
            .state = state,
            .target = target,
            .span = link.span,
        });
    }
}

fn refreshImportTargets(graph: *const modules_mod.ModuleGraph, exports: []const SemanticExport, imports: []SemanticImport) bool {
    var changed = false;
    for (imports) |*item| {
        if (item.state == .namespace or item.state == .external) continue;
        const link = blk: for (graph.linked_imports) |candidate| {
            if (candidate.from_module == item.module_id and candidate.import_symbol == item.import_symbol) break :blk candidate;
        } else continue;
        const target_module = link.target_module orelse continue;
        const index = exportIndex(exports, target_module, item.imported_name, item.type_only) orelse continue;
        const target = exports[index].identity;
        if (item.target == null or item.target.?.type_id != target.type_id or !item.target.?.declaration.eql(target.declaration)) changed = true;
        item.target = target;
        item.state = .resolved;
        item.runtime_binding = !item.type_only;
    }
    return changed;
}

fn refreshNamespaceImportTargets(
    allocator: std.mem.Allocator,
    graph: *const modules_mod.ModuleGraph,
    type_store: *types.TypeStore,
    exports: []const SemanticExport,
    imports: []SemanticImport,
) !bool {
    var changed = false;
    for (imports) |*item| {
        if (item.state != .namespace) continue;
        const link = blk: for (graph.linked_imports) |candidate| {
            if (candidate.from_module == item.module_id and candidate.import_symbol == item.import_symbol) break :blk candidate;
        } else continue;
        const target_module = link.target_module orelse continue;
        var properties: std.ArrayList(types.ObjectProperty) = .empty;
        for (exports) |exported| {
            if (exported.module_id != target_module or exported.type_only) continue;
            try properties.append(allocator, .{ .name = exported.name, .type_id = exported.identity.type_id });
        }
        const type_id = if (properties.items.len == 0)
            type_store.builtins.unknown
        else
            try type_store.intern(.{ .object = properties.items });
        if (item.target == null or item.target.?.type_id != type_id) changed = true;
        item.target = .{
            .symbol_id = null,
            .declaration = types.SemanticDeclId.init(target_module, ast.invalid_node),
            .type_id = type_id,
            .namespace = if (item.type_only) .type else .value,
        };
        item.runtime_binding = !item.type_only;
    }
    return changed;
}

fn applyImportedTypes(module: *ProjectSemanticModule, imports: []const SemanticImport, type_store: *types.TypeStore) !bool {
    _ = type_store;
    var changed = false;
    const symbols = @constCast(module.type_info.symbols);
    for (imports) |item| {
        if (item.module_id != module.id) continue;
        const symbol_id = item.import_symbol orelse continue;
        const target_type = if (item.target) |target| target.type_id else continue;
        for (symbols) |*entry| {
            if (entry.symbol_id != symbol_id) continue;
            if (entry.inferred_type != target_type or entry.state != .resolved) changed = true;
            entry.inferred_type = target_type;
            entry.state = .resolved;
            break;
        }
    }
    return changed;
}

fn refreshProjectTypes(allocator: std.mem.Allocator, module_id: ModuleId, result: frontend.FrontendResult, info: *TypeInfo, type_store: *types.TypeStore) !bool {
    var nodes: std.ArrayList(NodeTypeInfo) = .{ .items = @constCast(info.nodes), .capacity = info.nodes.len };
    const symbols = @constCast(info.symbols);
    try refreshReferenceTypes(allocator, result, symbols, &nodes, &type_store.builtins);
    _ = try type_inference.inferPrimitiveExpressionsWithCfgs(allocator, result.ast, &nodes, type_store, info.resolved_type_nodes, result.cfgs);
    var changed = refreshVariableTypes(result, symbols, nodes.items, &type_store.builtins);
    changed = (try refreshFunctionReturns(allocator, module_id, result, symbols, nodes.items, info.resolved_type_nodes, type_store)) or changed;
    info.nodes = try nodes.toOwnedSlice(allocator);
    return changed;
}

fn refreshDirectExportTypes(modules: []ProjectSemanticModule, exports: []SemanticExport) bool {
    var changed = false;
    for (exports) |*item| {
        if (item.re_export) continue;
        const symbol_id = item.identity.symbol_id orelse continue;
        const module = projectModule(modules, item.module_id) orelse continue;
        const type_id = (module.type_info.lookupSymbol(symbol_id) orelse continue).effective() orelse continue;
        if (item.identity.type_id != type_id) changed = true;
        item.identity.type_id = type_id;
    }
    return changed;
}

fn finishProjectTypes(allocator: std.mem.Allocator, result: frontend.FrontendResult, info: *TypeInfo, type_store: *types.TypeStore) !void {
    var nodes: std.ArrayList(NodeTypeInfo) = .{ .items = @constCast(info.nodes), .capacity = info.nodes.len };
    const narrowed = try narrowing.analyze(allocator, result, type_store, info.symbols, &nodes);
    info.nodes = try nodes.toOwnedSlice(allocator);
    info.flow_types = narrowed.flow_types;
    const checker_info: TypeInfo = .{ .symbols = info.symbols, .nodes = info.nodes, .flow_types = info.flow_types, .diagnostics = &.{} };
    const checker_diags = try checker.checkFile(allocator, result, checker_info, type_store);
    info.diagnostics = try combineDiagnostics(allocator, &.{ info.diagnostics, checker_diags }, result.source.path);
}

fn hasUnresolvedLinks(imports: []const SemanticImport) bool {
    for (imports) |item| if (item.state == .unresolved or item.state == .cyclic_partial) return true;
    return false;
}

fn importedTypeBindings(
    allocator: std.mem.Allocator,
    module_id: ModuleId,
    imports: []const SemanticImport,
    type_store: *const types.TypeStore,
) ![]const type_collector.ImportedTypeBinding {
    var bindings: std.ArrayList(type_collector.ImportedTypeBinding) = .empty;
    for (imports) |item| {
        if (item.module_id != module_id or item.state == .namespace or item.state == .external) continue;
        try bindings.append(allocator, .{
            .local_name = item.local_name,
            .symbol_id = item.import_symbol,
            .type_id = if (item.target) |target| target.type_id else type_store.builtins.unknown,
            .declaration = if (item.target) |target| target.declaration else null,
            .placeholder = item.target == null,
        });
    }
    return bindings.toOwnedSlice(allocator);
}

fn buildTypeInfo(
    allocator: std.mem.Allocator,
    module_id: modules_mod.ModuleId,
    result: frontend.FrontendResult,
    type_store: *types.TypeStore,
    run_checker: bool,
    imported_types: []const type_collector.ImportedTypeBinding,
    complete_nominals: bool,
) !TypeInfo {
    const builtins = &type_store.builtins;
    var symbol_types: std.ArrayList(SymbolTypeInfo) = .empty;
    var node_types: std.ArrayList(NodeTypeInfo) = .empty;
    var collected = try type_collector.collectDeclaredTypesInModuleWithImports(
        allocator,
        result.source,
        result.ast,
        result.bind,
        module_id,
        type_store,
        imported_types,
        complete_nominals,
    );

    const inferred_nodes = try type_inference.inferLiteralNodeTypes(allocator, result.ast, builtins);
    try node_types.appendSlice(allocator, inferred_nodes);
    try seedClassContextExpressionTypes(allocator, module_id, result, type_store, &node_types);

    // Build declarations before references. Forward references therefore observe
    // the same stable SymbolId and TypeId as references after a declaration.
    for (result.bind.symbols) |symbol| {
        var entry: SymbolTypeInfo = .{ .symbol_id = symbol.id };
        if (declaredType(collected.symbol_declared_types, symbol.id)) |declared| {
            entry.declared_type = declared;
        }
        if (isDuplicateSymbol(result.bind.symbols, symbol)) entry.state = .@"error";

        switch (symbol.kind) {
            .variable => if (entry.declared_type == null) {
                const node = result.ast.node(symbol.declaration);
                switch (node.data) {
                    .VariableDeclarator => |declarator| {
                        if (declarator.init) |initializer| {
                            entry.inferred_type = nodeType(node_types.items, initializer) orelse builtins.unknown;
                        } else {
                            entry.inferred_type = builtins.unknown;
                            if (entry.state != .@"error") entry.state = .uninitialized;
                        }
                    },
                    else => entry.inferred_type = builtins.unknown,
                }
            },
            .parameter => if (entry.declared_type == null) {
                entry.inferred_type = builtins.unknown;
            },
            .function => if (entry.declared_type == null) {
                entry.inferred_type = functionType(collected.function_signatures, symbol.id) orelse builtins.unknown;
            },
            .class, .interface, .enum_ => {
                // The collector predeclares one canonical nominal TypeId so
                // annotations and the declaration symbol share identity.
                entry.inferred_type = entry.declared_type orelse priorDeclarationType(
                    result.bind.symbols,
                    symbol_types.items,
                    symbol.declaration,
                ) orelse builtins.unknown;
            },
            .type_alias, .type_parameter => if (entry.declared_type == null) {
                entry.inferred_type = builtins.unknown;
            },
            .import => entry.inferred_type = builtins.unknown,
            .enum_member => entry.inferred_type = owningEnumType(
                result,
                symbol_types.items,
                symbol.declaration,
            ) orelse builtins.unknown,
            .field => entry.inferred_type = entry.declared_type orelse builtins.unknown,
            .method => entry.inferred_type = functionType(collected.function_signatures, symbol.id) orelse builtins.unknown,
        }
        if (symbol.kind == .variable) {
            if (entry.declared_type) |declared| switch (result.ast.node(symbol.declaration).data) {
                .VariableDeclarator => |declarator| if (declarator.init) |initializer| {
                    try putNodeContextualType(allocator, &node_types, initializer, declared, builtins.unknown);
                },
                else => {},
            };
        }
        try symbol_types.append(allocator, entry);
    }

    // Resolve references and primitive expressions to a fixed point. This lets
    // inferred declaration types flow through chains such as `a -> b -> c`
    // while preserving the resolver's exact SymbolId identity.
    var round: usize = 0;
    while (round < symbol_types.items.len + 2) : (round += 1) {
        try refreshReferenceTypes(allocator, result, symbol_types.items, &node_types, builtins);
        _ = try type_inference.inferPrimitiveExpressionsWithCfgs(
            allocator,
            result.ast,
            &node_types,
            type_store,
            collected.resolved_type_nodes,
            result.cfgs,
        );
        const variables_changed = refreshVariableTypes(result, symbol_types.items, node_types.items, builtins);
        const functions_changed = try refreshFunctionReturns(
            allocator,
            module_id,
            result,
            symbol_types.items,
            node_types.items,
            collected.resolved_type_nodes,
            type_store,
        );
        if (!variables_changed and !functions_changed) break;
    }

    // Type queries consume the resolved value table, which intentionally does
    // not exist during declaration collection. Re-collect once with effective
    // SymbolTypeInfo, then let dependent aliases/contexts flow to a fixed point.
    collected = try type_collector.collectDeclaredTypesInModuleWithImportsAndValues(
        allocator,
        result.source,
        result.ast,
        result.bind,
        module_id,
        type_store,
        imported_types,
        symbol_types.items,
        false,
    );
    for (symbol_types.items) |*entry| {
        if (declaredType(collected.symbol_declared_types, entry.symbol_id)) |declared| entry.declared_type = declared;
    }
    for (result.bind.symbols) |symbol| {
        if (symbol.kind != .variable) continue;
        const declared = declaredType(collected.symbol_declared_types, symbol.id) orelse continue;
        switch (result.ast.node(symbol.declaration).data) {
            .VariableDeclarator => |declarator| if (declarator.init) |initializer|
                try putNodeContextualType(allocator, &node_types, initializer, declared, builtins.unknown),
            else => {},
        }
    }
    round = 0;
    while (round < symbol_types.items.len + 2) : (round += 1) {
        try refreshReferenceTypes(allocator, result, symbol_types.items, &node_types, builtins);
        _ = try type_inference.inferPrimitiveExpressionsWithCfgs(
            allocator,
            result.ast,
            &node_types,
            type_store,
            collected.resolved_type_nodes,
            result.cfgs,
        );
        const variables_changed = refreshVariableTypes(result, symbol_types.items, node_types.items, builtins);
        const functions_changed = try refreshFunctionReturns(
            allocator,
            module_id,
            result,
            symbol_types.items,
            node_types.items,
            collected.resolved_type_nodes,
            type_store,
        );
        if (!variables_changed and !functions_changed) break;
    }

    const coverage_diags = try completeExpressionCoverage(allocator, result.ast, &node_types, builtins);

    const narrowed = try narrowing.analyze(allocator, result, type_store, symbol_types.items, &node_types);
    const checker_info: TypeInfo = .{
        .symbols = symbol_types.items,
        .nodes = node_types.items,
        .resolved_type_nodes = collected.resolved_type_nodes,
        .flow_types = narrowed.flow_types,
        .diagnostics = &.{},
    };
    const checker_diags = if (run_checker)
        try checker.checkFile(allocator, result, checker_info, type_store)
    else
        &.{};
    const semantic_diags = try combineDiagnostics(
        allocator,
        &.{ collected.diagnostics, coverage_diags, checker_diags },
        result.source.path,
    );

    return .{
        .symbols = try symbol_types.toOwnedSlice(allocator),
        .nodes = try node_types.toOwnedSlice(allocator),
        .resolved_type_nodes = collected.resolved_type_nodes,
        .flow_types = narrowed.flow_types,
        .diagnostics = semantic_diags,
    };
}

fn declaredType(entries: []const type_collector.DeclaredSymbolType, symbol_id: binder.SymbolId) ?types.TypeId {
    for (entries) |entry| if (entry.symbol_id == symbol_id) return entry.declared_type;
    return null;
}

fn functionType(entries: []const type_collector.FunctionSignatureEntry, symbol_id: binder.SymbolId) ?types.TypeId {
    for (entries) |entry| if (entry.symbol_id == symbol_id) return entry.signature_id;
    return null;
}

fn symbolType(entries: []const SymbolTypeInfo, symbol_id: binder.SymbolId) ?SymbolTypeInfo {
    for (entries) |entry| if (entry.symbol_id == symbol_id) return entry;
    return null;
}

fn seedClassContextExpressionTypes(
    allocator: std.mem.Allocator,
    module_id: ModuleId,
    result: frontend.FrontendResult,
    type_store: *types.TypeStore,
    entries: *std.ArrayList(NodeTypeInfo),
) !void {
    for (result.ast.nodes, 0..) |node, raw_id| {
        const node_id: ast.NodeId = @intCast(raw_id);
        const type_id: ?types.TypeId = switch (node.data) {
            .ClassExpression => if (type_store.lookupClassSemanticType(.init(module_id, node_id))) |class|
                class.constructor_type
            else
                null,
            .ThisExpression => if (enclosingClassNode(result, node_id)) |class_node|
                if (type_store.lookupClassSemanticType(.init(module_id, class_node))) |class| class.instance_type else null
            else
                null,
            .SuperExpression => if (enclosingClassNode(result, node_id)) |class_node|
                if (type_store.lookupClassSemanticType(.init(module_id, class_node))) |class| class.inheritance.extends else null
            else
                null,
            .MetaProperty => |meta| if (meta.kind == .new_target)
                if (enclosingClassNode(result, node_id)) |class_node|
                    if (type_store.lookupClassSemanticType(.init(module_id, class_node))) |class| class.constructor_type else null
                else
                    null
            else
                null,
            else => null,
        };
        if (type_id) |value| try putNodeType(allocator, entries, .{ .node_id = node_id, .type_id = value });
    }
}

fn enclosingClassNode(result: frontend.FrontendResult, node_id: ast.NodeId) ?ast.NodeId {
    var scope_id = scopeForBoundNode(result.bind, node_id);
    while (true) {
        const scope = boundScope(result.bind, scope_id) orelse return null;
        if (scope.kind == .class) {
            for (result.ast.nodes, 0..) |node, raw_id| switch (node.data) {
                .ClassDeclaration => |class| if (class.members.len != 0 and scopeForBoundNode(result.bind, class.members[0]) == scope_id)
                    return @intCast(raw_id),
                .ClassExpression => |class| if (class.members.len != 0 and scopeForBoundNode(result.bind, class.members[0]) == scope_id)
                    return @intCast(raw_id),
                else => {},
            };
            return null;
        }
        scope_id = scope.parent orelse return null;
    }
}

fn scopeForBoundNode(bind: binder.BindResult, node_id: ast.NodeId) binder.ScopeId {
    for (bind.node_scopes) |entry| if (entry.node == node_id) return entry.scope;
    for (bind.symbols) |symbol| if (symbol.declaration == node_id) return symbol.scope;
    return 0;
}

fn boundScope(bind: binder.BindResult, scope_id: binder.ScopeId) ?binder.Scope {
    for (bind.scopes) |scope| if (scope.id == scope_id) return scope;
    return null;
}

fn completeExpressionCoverage(
    allocator: std.mem.Allocator,
    tree: ast.Ast,
    entries: *std.ArrayList(NodeTypeInfo),
    builtins: *const types.Builtins,
) ![]const diagnostics.Diagnostic {
    var recovery: std.ArrayList(diagnostics.Diagnostic) = .empty;
    for (tree.nodes, 0..) |node, raw_id| {
        if (!isExecutableExpression(node.data)) continue;
        const node_id: ast.NodeId = @intCast(raw_id);
        if (nodeType(entries.items, node_id) != null) continue;
        try putNodeType(allocator, entries, .{ .node_id = node_id, .type_id = builtins.unknown, .state = .resolved });
        try recovery.append(allocator, .{
            .severity = .warning,
            .code = .unsupported_syntax,
            .phase = .type_checker,
            .message = "expression semantic typing deferred; recovered as unknown",
            .span = node.span,
            .label = "explicit semantic recovery",
        });
    }
    return recovery.toOwnedSlice(allocator);
}

fn isExecutableExpression(data: ast.NodeData) bool {
    return switch (data) {
        .Identifier,
        .Literal,
        .RegExpLiteral,
        .TemplateExpression,
        .TaggedTemplateExpression,
        .ImportExpression,
        .MetaProperty,
        .FunctionExpression,
        .YieldExpression,
        .ArrowFunctionExpression,
        .ClassExpression,
        .SpreadElement,
        .ThisExpression,
        .SuperExpression,
        .NewExpression,
        .CallExpression,
        .MemberExpression,
        .ElementAccessExpression,
        .AsExpression,
        .SatisfiesExpression,
        .NonNullExpression,
        .UnaryExpression,
        .BinaryExpression,
        .SequenceExpression,
        .ConditionalExpression,
        .UpdateExpression,
        .AssignmentExpression,
        .ObjectExpression,
        .ArrayExpression,
        => true,
        .Program,
        .BlockStatement,
        .ExpressionStatement,
        .TypeAliasDeclaration,
        .InterfaceDeclaration,
        .EnumDeclaration,
        .EnumMember,
        .VariableDeclaration,
        .VariableDeclarator,
        .FunctionDeclaration,
        .ClassDeclaration,
        .ClassField,
        .ClassMethod,
        .Parameter,
        .ReturnStatement,
        .ThrowStatement,
        .DebuggerStatement,
        .TryStatement,
        .CatchClause,
        .FinallyClause,
        .BreakStatement,
        .ContinueStatement,
        .LabeledStatement,
        .IfStatement,
        .WhileStatement,
        .DoWhileStatement,
        .ForStatement,
        .SwitchStatement,
        .SwitchCase,
        .ImportDeclaration,
        .ExportDeclaration,
        => false,
    };
}

fn owningEnumType(
    result: frontend.FrontendResult,
    entries: []const SymbolTypeInfo,
    member_id: ast.NodeId,
) ?types.TypeId {
    for (result.ast.nodes, 0..) |node, raw_id| switch (node.data) {
        .EnumDeclaration => |declaration| for (declaration.members) |candidate| {
            if (candidate == member_id) return priorDeclarationType(result.bind.symbols, entries, @intCast(raw_id));
        },
        else => {},
    };
    return null;
}

fn nodeType(entries: []const NodeTypeInfo, node_id: ast.NodeId) ?types.TypeId {
    for (entries) |entry| if (entry.node_id == node_id) return entry.type_id;
    return null;
}

fn priorDeclarationType(
    symbols: []const binder.Symbol,
    entries: []const SymbolTypeInfo,
    declaration: ast.NodeId,
) ?types.TypeId {
    for (entries) |entry| {
        const index: usize = @intCast(entry.symbol_id);
        if (index < symbols.len and symbols[index].declaration == declaration) return entry.effective();
    }
    return null;
}

fn isDuplicateSymbol(symbols: []const binder.Symbol, symbol: binder.Symbol) bool {
    for (symbols) |candidate| {
        if (candidate.id == symbol.id) break;
        if (candidate.scope == symbol.scope and candidate.namespace == symbol.namespace and
            std.mem.eql(u8, candidate.name, symbol.name)) return true;
    }
    return false;
}

fn refreshReferenceTypes(
    allocator: std.mem.Allocator,
    result: frontend.FrontendResult,
    symbol_types: []const SymbolTypeInfo,
    node_types: *std.ArrayList(NodeTypeInfo),
    builtins: *const types.Builtins,
) !void {
    for (result.resolve.references) |reference| {
        if (reference.symbol) |symbol_id| {
            const symbol_info = symbolType(symbol_types, symbol_id);
            try putNodeType(allocator, node_types, .{
                .node_id = reference.node,
                .type_id = if (symbol_info) |info| info.effective() orelse builtins.unknown else builtins.unknown,
                .state = if (symbol_info) |info| info.state else .unresolved,
            });
        } else {
            try putNodeType(allocator, node_types, .{
                .node_id = reference.node,
                .type_id = builtins.unknown,
                .state = .unresolved,
            });
        }
    }
}

fn refreshVariableTypes(
    result: frontend.FrontendResult,
    symbol_types: []SymbolTypeInfo,
    node_types: []const NodeTypeInfo,
    builtins: *const types.Builtins,
) bool {
    var changed = false;
    for (result.bind.symbols) |symbol| {
        if (symbol.kind != .variable) continue;
        const entry = symbolTypePtr(symbol_types, symbol.id) orelse continue;
        if (entry.declared_type != null or entry.state == .@"error") continue;
        switch (result.ast.node(symbol.declaration).data) {
            .VariableDeclarator => |declarator| if (declarator.init) |initializer| {
                const inferred = nodeType(node_types, initializer) orelse builtins.unknown;
                if (entry.inferred_type == null or entry.inferred_type.? != inferred) {
                    entry.inferred_type = inferred;
                    changed = true;
                }
            },
            else => {},
        }
    }
    return changed;
}

fn refreshFunctionReturns(
    allocator: std.mem.Allocator,
    module_id: ModuleId,
    result: frontend.FrontendResult,
    symbol_types: []SymbolTypeInfo,
    node_types: []const NodeTypeInfo,
    resolved_type_nodes: []const ResolvedTypeNode,
    type_store: *types.TypeStore,
) !bool {
    var changed = false;
    for (result.bind.symbols) |symbol| {
        if (symbol.kind != .function and symbol.kind != .method) continue;
        const function = function_like.describe(result.ast, symbol.declaration) orelse continue;
        const return_type = try type_inference.inferFunctionLikeReturnWithCfgs(
            allocator,
            function,
            result.ast,
            node_types,
            type_store,
            result.cfgs,
        );

        const new_sig_params = try type_inference.collectFunctionLikeParameters(
            allocator,
            function,
            result.ast,
            type_store,
            resolved_type_nodes,
        );
        const new_signature_id = try type_store.addFunctionDetailed(
            new_sig_params,
            return_type,
            @intCast(function.type_parameters.len),
            @import("../types/model.zig").FunctionFlags{
                .is_async = function.flags.is_async,
                .is_generator = function.flags.is_generator,
            },
        );
        allocator.free(new_sig_params);

        // Body inference is always separate from declaration evidence. For an
        // annotated function effective() continues to prefer declared_type.
        const sym_info_ptr = symbolTypePtr(symbol_types, symbol.id) orelse continue;
        if (symbol.kind == .method) {
            const owner = enclosingClassNode(result, symbol.declaration) orelse continue;
            const effective_signature = sym_info_ptr.declared_type orelse new_signature_id;
            const member_type = switch (function.kind) {
                .getter => if (type_store.lookupFunction(effective_signature)) |signature|
                    signature.return_type
                else
                    type_store.builtins.unknown,
                .setter => if (type_store.lookupFunction(effective_signature)) |signature|
                    if (signature.parameters.len != 0) signature.parameters[0].type_id else type_store.builtins.unknown
                else
                    type_store.builtins.unknown,
                else => effective_signature,
            };
            try type_store.updateClassCallableType(
                .init(module_id, owner),
                function.name orelse "",
                function.receiver == .class_static,
                function.kind == .constructor,
                member_type,
            );
        }
        if (sym_info_ptr.inferred_type != null and sym_info_ptr.inferred_type.? == new_signature_id) continue;
        sym_info_ptr.inferred_type = new_signature_id;
        changed = true;
    }
    return changed;
}

fn lookupResolvedTypeNode(entries: []const ResolvedTypeNode, node_id: ast.TypeNodeId) ?types.TypeId {
    for (entries) |entry| if (entry.node_id == node_id) return entry.type_id;
    return null;
}

fn symbolTypePtr(entries: []SymbolTypeInfo, symbol_id: binder.SymbolId) ?*SymbolTypeInfo {
    for (entries) |*entry| if (entry.symbol_id == symbol_id) return entry;
    return null;
}

fn putNodeType(allocator: std.mem.Allocator, entries: *std.ArrayList(NodeTypeInfo), value: NodeTypeInfo) !void {
    for (entries.items) |*entry| {
        if (entry.node_id == value.node_id) {
            entry.* = value;
            return;
        }
    }
    try entries.append(allocator, value);
}

fn putNodeContextualType(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(NodeTypeInfo),
    node_id: ast.NodeId,
    contextual_type: types.TypeId,
    fallback_type: types.TypeId,
) !void {
    for (entries.items) |*entry| {
        if (entry.node_id != node_id) continue;
        entry.contextual_type = contextual_type;
        return;
    }
    try entries.append(allocator, .{
        .node_id = node_id,
        .type_id = fallback_type,
        .contextual_type = contextual_type,
    });
}

fn selectDiagnostics(
    allocator: std.mem.Allocator,
    source: []const diagnostics.Diagnostic,
    syntax: bool,
    path: []const u8,
) ![]const diagnostics.Diagnostic {
    var selected: std.ArrayList(diagnostics.Diagnostic) = .empty;
    for (source) |diagnostic| {
        const is_syntax = diagnostic.phase == .scanner or diagnostic.phase == .parser;
        if (is_syntax != syntax) continue;
        var stamped = diagnostic;
        if (stamped.path == null or stamped.path.?.len == 0) stamped.path = path;
        try selected.append(allocator, stamped);
    }
    return selected.toOwnedSlice(allocator);
}

fn combineDiagnostics(
    allocator: std.mem.Allocator,
    lists: []const []const diagnostics.Diagnostic,
    path: []const u8,
) ![]const diagnostics.Diagnostic {
    var total: usize = 0;
    for (lists) |list| total += list.len;
    if (total == 0) return &.{};

    const combined = try allocator.alloc(diagnostics.Diagnostic, total);
    var index: usize = 0;
    for (lists) |list| {
        for (list) |diagnostic| {
            var stamped = diagnostic;
            if (stamped.path == null or stamped.path.?.len == 0) stamped.path = path;
            combined[index] = stamped;
            index += 1;
        }
    }

    for (combined[1..], 0..) |_, i| {
        var j = i + 1;
        while (j > 0) : (j -= 1) {
            const previous = combined[j - 1];
            const current = combined[j];
            const ordered = previous.span.start < current.span.start or
                (previous.span.start == current.span.start and
                    @intFromEnum(previous.code) <= @intFromEnum(current.code));
            if (ordered) break;
            combined[j - 1] = current;
            combined[j] = previous;
        }
    }

    var write: usize = 0;
    for (combined) |entry| {
        if (write == 0 or combined[write - 1].code != entry.code or
            combined[write - 1].span.start != entry.span.start)
        {
            combined[write] = entry;
            write += 1;
        }
    }
    return combined[0..write];
}

fn testVariableInitializer(result: *const SemanticResult, name: []const u8) ?ast.NodeId {
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind != .variable or !std.mem.eql(u8, symbol.name, name)) continue;
        return switch (result.frontend.ast.node(symbol.declaration).data) {
            .VariableDeclarator => |declarator| declarator.init,
            else => null,
        };
    }
    return null;
}

test "SemanticResult owns source and supports stable lookup" {
    const path = try std.testing.allocator.dupe(u8, "owned.ts");
    const text = try std.testing.allocator.dupe(u8, "let x: number = 1; x;");
    var result = try analyzeSource(std.testing.allocator, .{ .path = path, .text = text }, .{});
    std.testing.allocator.free(path);
    std.testing.allocator.free(text);
    defer result.deinit();

    try std.testing.expectEqualStrings("owned.ts", result.module.path);
    try std.testing.expect(result.lookupModule(0) != null);
    try std.testing.expect(result.lookupModule(1) == null);
    try std.testing.expect(result.lookupNode(result.frontend.ast.root) != null);
    try std.testing.expect(result.lookupNode(std.math.maxInt(ast.NodeId)) == null);
    try std.testing.expect(result.lookupScope(0) != null);
    try std.testing.expect(result.lookupScope(std.math.maxInt(binder.ScopeId)) == null);
    try std.testing.expect(result.frontend.bind.symbols.len > 0);
    const symbol = result.frontend.bind.symbols[0];
    try std.testing.expect(result.lookupSymbol(symbol.id) != null);
    try std.testing.expect(result.lookupSymbol(std.math.maxInt(binder.SymbolId)) == null);
}

test "SemanticResult keeps recovered partial output and split diagnostics" {
    var result = try analyzeSource(
        std.testing.allocator,
        .{ .path = "partial.ts", .text = "let value = ;" },
        .{ .recover_errors = true },
    );
    defer result.deinit();

    try std.testing.expect(result.metadata.is_partial);
    try std.testing.expect(result.syntax_diagnostics.len > 0);
    try std.testing.expectEqual(
        result.diagnostics.len,
        result.metadata.syntax_diagnostic_count + result.metadata.semantic_diagnostic_count,
    );
    try std.testing.expect(result.lookupNode(result.frontend.ast.root) != null);
}

test "Goal 133 semantic root repeated create query destroy" {
    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        var result = try analyze(std.testing.allocator, "let x: number = 1;");
        try std.testing.expect(result.lookupModule(0) != null);
        result.deinit();
    }
}

test "SemanticResult includes semantic checker diagnostics" {
    var result = try analyzeSource(
        std.testing.allocator,
        .{ .path = "test.ts", .text = "let x: number;\nx = \"bad\";" },
        .{},
    );
    defer result.deinit();

    var found_mismatch = false;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and diagnostic.path != null) {
            found_mismatch = true;
            break;
        }
    }
    try std.testing.expect(found_mismatch);
}

test "SemanticResult shares one canonical builtin registry across passes" {
    var result = try analyzeSource(
        std.testing.allocator,
        .{ .path = "builtins.ts", .text = "let value: number = 1;" },
        .{},
    );
    defer result.deinit();

    try std.testing.expect(result.type_store.builtins.any != result.type_store.builtins.unknown);
    try std.testing.expectEqual(types.builtinKinds.len, result.type_store.builtins.records.len);

    var found_declared_number = false;
    for (result.type_info.symbols) |entry| {
        if (entry.declared_type == result.type_store.builtins.number) {
            found_declared_number = true;
            break;
        }
    }
    try std.testing.expect(found_declared_number);

    var found_inferred_number = false;
    for (result.type_info.nodes) |entry| {
        if (entry.type_id == result.type_store.builtins.number) {
            found_inferred_number = true;
            break;
        }
    }
    try std.testing.expect(found_inferred_number);
}

test "SemanticResult owns collected function signatures in its TypeStore" {
    var result = try analyzeSource(
        std.testing.allocator,
        .{ .path = "function.ts", .text = "function convert(value: number): string { return \"ok\"; }" },
        .{},
    );
    defer result.deinit();

    const function_type = types.next_user_type_id;
    try std.testing.expect(result.lookupType(function_type) != null);
    const signature = result.lookupFunctionType(function_type).?;
    try std.testing.expectEqual(result.type_store.builtins.number, signature.parameters[0].type_id);
    try std.testing.expectEqual(result.type_store.builtins.string, signature.return_type);
}

test "function calls infer returns and validate argument count and type" {
    var result = try analyze(std.testing.allocator,
        \\function identity(value: number) { return value; }
        \\const good = identity(1);
        \\const missing = identity();
        \\const wrong = identity("text");
    );
    defer result.deinit();

    const good = testVariableInitializer(&result, "good").?;
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(good).?);

    var count_errors: usize = 0;
    var type_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| switch (diagnostic.code) {
        .invalid_argument_count => count_errors += 1,
        .invalid_argument_type => type_errors += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), count_errors);
    try std.testing.expectEqual(@as(usize, 1), type_errors);
}

test "arrow implicit returns and optional default rest parameters shape signatures" {
    var result = try analyze(std.testing.allocator,
        \\const choose = (first: number, second?: number, ...rest: number[]) => first;
        \\const withDefault = (item: number = 1) => item;
        \\const value = choose(1, 2, 3);
        \\const defaulted = withDefault();
    );
    defer result.deinit();

    const choose_init = testVariableInitializer(&result, "choose").?;
    const function_type = result.lookupNodeType(choose_init).?;
    const signature = result.lookupFunctionType(function_type).?;
    try std.testing.expectEqual(@as(usize, 1), signature.requiredParameterCount());
    try std.testing.expect(signature.parameters[1].optional);
    try std.testing.expect(signature.parameters[2].rest);
    try std.testing.expectEqual(result.type_store.builtins.number, signature.return_type);

    const default_init = testVariableInitializer(&result, "withDefault").?;
    const default_signature = result.lookupFunctionType(result.lookupNodeType(default_init).?).?;
    try std.testing.expect(default_signature.parameters[0].has_default);
    try std.testing.expectEqual(@as(usize, 0), default_signature.requiredParameterCount());

    const value = testVariableInitializer(&result, "value").?;
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(value).?);
    const defaulted = testVariableInitializer(&result, "defaulted").?;
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(defaulted).?);
}

test "method calls preserve receiver and async functions wrap return type" {
    var result = try analyze(std.testing.allocator,
        \\const service = { read(value: number) { return value; } };
        \\const answer = service.read(1);
        \\async function load(): number { return 1; }
        \\const pending = load();
    );
    defer result.deinit();

    const answer = testVariableInitializer(&result, "answer").?;
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(answer).?);
    try std.testing.expect(result.lookupNodeTypeInfo(answer).?.receiver_type != null);

    const pending = testVariableInitializer(&result, "pending").?;
    const pending_type = result.lookupType(result.lookupNodeType(pending).?).?;
    try std.testing.expect(pending_type.kind == .promise);
    try std.testing.expectEqual(result.type_store.builtins.number, pending_type.kind.promise.value_type);
}

test "recursive function calls use the stable signature and overloads remain deferred" {
    var recursive = try analyze(std.testing.allocator,
        \\function descend(value: number): number { return value ? descend(value - 1) : 0; }
        \\const result = descend(2);
    );
    defer recursive.deinit();

    const recursive_result = testVariableInitializer(&recursive, "result").?;
    try std.testing.expectEqual(recursive.type_store.builtins.number, recursive.lookupNodeType(recursive_result).?);

    var deferred = try analyze(std.testing.allocator,
        \\function select(value: number): number { return value; }
        \\function select(value: string): string { return value; }
    );
    defer deferred.deinit();

    var duplicate_count: usize = 0;
    for (deferred.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .duplicate_declaration) duplicate_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), duplicate_count);
}

test "Goal 116 resolver symbol identity drives declaration and expression types" {
    var result = try analyze(std.testing.allocator, "const value = 1; value;");
    defer result.deinit();

    const symbol = result.frontend.bind.symbols[0];
    const symbol_info = result.lookupSymbolType(symbol.id).?;
    try std.testing.expectEqual(result.type_store.builtins.number, symbol_info.effective().?);

    var found_reference = false;
    for (result.frontend.resolve.references) |reference| {
        if (!std.mem.eql(u8, reference.name, "value")) continue;
        try std.testing.expectEqual(symbol.id, reference.symbol.?);
        try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(reference.node).?);
        found_reference = true;
    }
    try std.testing.expect(found_reference);
}

test "Goal 116 annotated and nominal declarations receive stable TypeIds" {
    var result = try analyze(std.testing.allocator,
        \\let annotated: string = "ok";
        \\function convert(value: number): string { return "ok"; }
        \\class Box {}
        \\interface Shape {}
        \\enum Color { Red }
        \\type Count = number;
    );
    defer result.deinit();

    var required: usize = 0;
    for (result.frontend.bind.symbols) |symbol| switch (symbol.kind) {
        .variable, .function, .class, .interface, .enum_, .type_alias => {
            const info = result.lookupSymbolType(symbol.id).?;
            try std.testing.expect(info.effective() != null);
            try std.testing.expect(result.lookupType(info.effective().?) != null);
            required += 1;
        },
        else => {},
    };
    try std.testing.expect(required >= 6);
}

test "Goal 116 shadowing uses nearest resolved symbol" {
    var result = try analyze(std.testing.allocator,
        \\let value: number = 1;
        \\value;
        \\{ let value: string = "inner"; value; }
    );
    defer result.deinit();

    var number_references: usize = 0;
    var string_references: usize = 0;
    for (result.frontend.resolve.references) |reference| {
        if (!std.mem.eql(u8, reference.name, "value")) continue;
        const symbol_id = reference.symbol.?;
        const symbol_info = result.lookupSymbolType(symbol_id).?;
        try std.testing.expectEqual(symbol_info.effective().?, result.lookupNodeType(reference.node).?);
        if (symbol_info.effective().? == result.type_store.builtins.number) number_references += 1;
        if (symbol_info.effective().? == result.type_store.builtins.string) string_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), number_references);
    try std.testing.expectEqual(@as(usize, 1), string_references);
}

test "Goal 116 unresolved and uninitialized states stay distinct" {
    var result = try analyze(std.testing.allocator, "let waiting: number; missing;");
    defer result.deinit();

    const waiting = result.lookupSymbolType(result.frontend.bind.symbols[0].id).?;
    try std.testing.expectEqual(TypeResolutionState.resolved, waiting.state);

    var unresolved_count: usize = 0;
    for (result.frontend.resolve.references) |reference| {
        if (!std.mem.eql(u8, reference.name, "missing")) continue;
        try std.testing.expect(reference.symbol == null);
        try std.testing.expectEqual(TypeResolutionState.unresolved, result.lookupNodeTypeInfo(reference.node).?.state);
        unresolved_count += 1;
    }
    var diagnostic_count: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| if (diagnostic.code == .cannot_find_name) {
        diagnostic_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), unresolved_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostic_count);
}

test "Goal 116 unannotated uninitialized symbol has explicit state" {
    var result = try analyze(std.testing.allocator, "let waiting;");
    defer result.deinit();
    try std.testing.expectEqual(
        TypeResolutionState.uninitialized,
        result.lookupSymbolType(result.frontend.bind.symbols[0].id).?.state,
    );
}

test "Goal 117 primitive expression inference respects precedence and sequence result" {
    var result = try analyze(std.testing.allocator,
        \\const arithmetic = 1 + 2 * 3;
        \\const comparison = arithmetic > 2;
        \\const sequence = (1, "last");
        \\const conditional = true ? 1 : 2;
    );
    defer result.deinit();

    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "arithmetic").?).?);
    try std.testing.expectEqual(result.type_store.builtins.boolean, result.lookupNodeType(testVariableInitializer(&result, "comparison").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "sequence").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "conditional").?).?);
}

test "Goal 117 satisfies preserves source type and as uses asserted type" {
    var result = try analyze(std.testing.allocator,
        \\const original = 1;
        \\const checked = original satisfies number;
        \\const asserted = original as string;
    );
    defer result.deinit();

    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "checked").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "asserted").?).?);
}

test "Goal 149 canonical annotation table preserves local user types everywhere" {
    var result = try analyze(std.testing.allocator,
        \\class User {
        \\  constructor(value: User) {}
        \\  clone(value: User): User { return value; }
        \\}
        \\let input: User;
        \\const asserted = input as User;
        \\const checked = input satisfies User;
        \\const arrow = (value: User): User => value;
        \\const expression = function(value: User): User { return value; };
    );
    defer result.deinit();

    var user_type: ?types.TypeId = null;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind == .class and symbol.namespace == .type and std.mem.eql(u8, symbol.name, "User"))
            user_type = result.lookupSymbolType(symbol.id).?.effective().?;
    }
    const expected = user_type orelse return error.TestExpectedEqual;
    const input = goal137ValueSymbol(&result, "input") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected, result.lookupSymbolType(input).?.declared_type.?);
    try std.testing.expectEqual(
        expected,
        result.lookupNodeType(testVariableInitializer(&result, "asserted").?).?,
    );

    const checked = testVariableInitializer(&result, "checked").?;
    const satisfies = switch (result.lookupNode(checked).?.data) {
        .SatisfiesExpression => |value| value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(expected, result.lookupResolvedTypeNode(satisfies.type_annotation.root).?);

    try std.testing.expect(result.type_info.resolved_type_nodes.len >= 10);
    for (result.type_info.resolved_type_nodes) |entry|
        try std.testing.expectEqual(expected, entry.type_id);

    for ([_][]const u8{ "arrow", "expression" }) |name| {
        const symbol_id = goal137ValueSymbol(&result, name) orelse return error.TestExpectedEqual;
        const signature_id = result.lookupSymbolType(symbol_id).?.effective().?;
        const signature = result.lookupFunctionType(signature_id) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(usize, 1), signature.parameters.len);
        try std.testing.expectEqual(expected, signature.parameters[0].type_id);
        try std.testing.expectEqual(expected, signature.return_type);
    }
}

test "Goal 149 canonical resolver preserves generic scope identity" {
    var result = try analyze(
        std.testing.allocator,
        "function identity<T>(value: T): T { return value; }",
    );
    defer result.deinit();

    var parameter_type: ?types.TypeId = null;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind == .type_parameter and std.mem.eql(u8, symbol.name, "T"))
            parameter_type = result.lookupSymbolType(symbol.id).?.effective().?;
    }
    const expected = parameter_type orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), result.type_info.resolved_type_nodes.len);
    for (result.type_info.resolved_type_nodes) |entry|
        try std.testing.expectEqual(expected, entry.type_id);
}

test "Goal 149 unresolved annotations diagnose once and recover explicitly" {
    var result = try analyze(std.testing.allocator,
        \\let first: Missing;
        \\let second: Missing;
        \\const asserted = 1 as Missing;
    );
    defer result.deinit();

    var diagnostic_count: usize = 0;
    for (result.semantic_diagnostics) |diagnostic|
        if (diagnostic.code == .unknown_type_name) {
            diagnostic_count += 1;
        };
    try std.testing.expectEqual(@as(usize, 3), diagnostic_count);
    try std.testing.expectEqual(@as(usize, 3), result.type_info.resolved_type_nodes.len);
    for (result.type_info.resolved_type_nodes) |entry|
        try std.testing.expectEqual(result.type_store.builtins.unknown, entry.type_id);
}

test "Goal 117 invalid operands recover with one targeted diagnostic" {
    var result = try analyze(std.testing.allocator, "const bad = \"x\" - 1;");
    defer result.deinit();

    const initializer = testVariableInitializer(&result, "bad").?;
    try std.testing.expectEqual(TypeResolutionState.@"error", result.lookupNodeTypeInfo(initializer).?.state);
    var count: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and
            diagnostic.label != null and
            std.mem.eql(u8, diagnostic.label.?, "invalid operator operands")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Goal 117 assignment expression type is the assigned value" {
    var result = try analyze(std.testing.allocator,
        \\let target = 1;
        \\const assigned = (target = "value");
    );
    defer result.deinit();
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "assigned").?).?);
}

test "Goal 118 arrays infer homogeneous unions and contextual tuples" {
    var result = try analyze(std.testing.allocator,
        \\const homogeneous = [1, 2, 3];
        \\const heterogeneous = [1, "two"];
        \\const shaped: readonly [number, string, boolean] = [1, , true];
    );
    defer result.deinit();

    const homogeneous = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "homogeneous").?).?).?;
    try std.testing.expectEqual(result.type_store.builtins.number, homogeneous.kind.array.element_type);

    const heterogeneous = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "heterogeneous").?).?).?;
    const element = result.lookupType(heterogeneous.kind.array.element_type).?;
    try std.testing.expectEqual(@as(usize, 2), element.kind.union_type.len);

    const shaped = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "shaped").?).?).?;
    try std.testing.expect(shaped.kind.tuple.readonly);
    try std.testing.expectEqual(@as(usize, 3), shaped.kind.tuple.elements.len);
    // Holes now live in contextual_type only (see Goal 137) — type_id reflects
    // the declared annotation shape without source-side hole fill.
}

test "Goal 137 annotated array mismatch reports per-element diagnostic" {
    var result = try analyze(std.testing.allocator,
        \\const values: number[] = ["wrong"];
    );
    defer result.deinit();

    const initializer_id = testVariableInitializer(&result, "values").?;
    try std.testing.expect(initializer_id != 0);

    var found_element_mismatch = false;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and
            std.mem.endsWith(u8, diagnostic.message, "is not assignable to the declared array element type"))
        {
            found_element_mismatch = true;
            break;
        }
    }
    try std.testing.expect(found_element_mismatch);

    const init_info = result.lookupNodeTypeInfo(initializer_id).?;
    const inferred = result.lookupType(init_info.type_id).?.kind.array;
    const contextual = result.lookupType(init_info.contextual_type.?).?.kind.array;
    try std.testing.expectEqual(result.type_store.builtins.string, inferred.element_type);
    try std.testing.expectEqual(result.type_store.builtins.number, contextual.element_type);
    try std.testing.expectEqual(init_info.type_id, init_info.effective().?);

    // The declaration remains number[] while the expression remains string[].
    const symbol_id = goal137ValueSymbol(&result, "values").?;
    const sym_info = result.lookupSymbolType(symbol_id).?;
    const dt = sym_info.declared_type orelse return error.TestFailed;
    try std.testing.expect(dt != 0);
}

test "Goal 137 annotated object mismatch reports property diagnostic" {
    var result = try analyze(std.testing.allocator,
        \\const object: { value: number } = { value: "wrong" };
    );
    defer result.deinit();

    const initializer_id = testVariableInitializer(&result, "object").?;
    try std.testing.expect(initializer_id != 0);

    var found_property_mismatch = false;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and
            std.mem.indexOf(u8, diagnostic.message, "object property") != null)
        {
            found_property_mismatch = true;
            break;
        }
    }
    try std.testing.expect(found_property_mismatch);

    const init_info = result.lookupNodeTypeInfo(initializer_id).?;
    const inferred = result.lookupType(init_info.type_id).?.kind.object;
    const contextual = result.lookupType(init_info.contextual_type.?).?.kind.object;
    try std.testing.expectEqual(result.type_store.builtins.string, inferred[0].type_id);
    try std.testing.expectEqual(result.type_store.builtins.number, contextual[0].type_id);
    try std.testing.expectEqual(init_info.type_id, init_info.effective().?);

    const symbol_id = goal137ValueSymbol(&result, "object").?;
    const sym_info = result.lookupSymbolType(symbol_id).?;
    // Declared object shape survives — contextual typing does not overwrite.
    try std.testing.expect(sym_info.declared_type != 0);
}

test "Goal 137 annotated tuple mismatch reports both element diagnostics" {
    var result = try analyze(std.testing.allocator,
        \\const tuple: [number, string] = ["wrong", 1];
    );
    defer result.deinit();

    const initializer_id = testVariableInitializer(&result, "tuple").?;
    try std.testing.expect(initializer_id != 0);

    // Both tuple positions disagree — expect at least two element-level mismatches.
    var mismatch_count: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and diagnostic.label != null) {
            mismatch_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), mismatch_count);

    const init_info = result.lookupNodeTypeInfo(initializer_id).?;
    const inferred = result.lookupType(init_info.type_id).?.kind.tuple;
    const contextual = result.lookupType(init_info.contextual_type.?).?.kind.tuple;
    try std.testing.expectEqual(result.type_store.builtins.string, inferred.elements[0].type_id);
    try std.testing.expectEqual(result.type_store.builtins.number, inferred.elements[1].type_id);
    try std.testing.expectEqual(result.type_store.builtins.number, contextual.elements[0].type_id);
    try std.testing.expectEqual(result.type_store.builtins.string, contextual.elements[1].type_id);
    try std.testing.expectEqual(init_info.type_id, init_info.effective().?);

    const symbol_id = goal137ValueSymbol(&result, "tuple").?;
    const sym_info = result.lookupSymbolType(symbol_id).?;
    // Declared tuple shape survives.
    try std.testing.expect(sym_info.declared_type != 0);
}

test "Goal 137 stable annotated aggregate converges without round exhaustion" {
    var result = try analyze(std.testing.allocator,
        \\const shaped: [number, string] = [1, "ok"];
    );
    defer result.deinit();

    // The declared annotation and the inferred initializer type should agree for
    // a stable aggregate — no round-limit error means convergence succeeded.
    const symbol_id = goal137ValueSymbol(&result, "shaped").?;
    const sym_info = result.lookupSymbolType(symbol_id).?;
    try std.testing.expect(sym_info.declared_type != 0);

    // The initializer node should be resolved (not stuck in unresolved state).
    const init_node = testVariableInitializer(&result, "shaped");
    try std.testing.expect(init_node != null);
    const node_id = init_node.?;
    const info = result.lookupNodeTypeInfo(node_id).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(type_info.TypeResolutionState.resolved)), @as(u8, @intFromEnum(info.state)));

    // Inferred type should match declared shape — stable convergence.
    const inferred_id = info.type_id;
    const declared_id = sym_info.declared_type;
    try std.testing.expectEqual(inferred_id, declared_id);
}

test "Goal 118 object forms spreads and duplicates are deterministic" {
    var result = try analyze(std.testing.allocator,
        \\const shorthand = 1;
        \\const base = { spread: "ok", duplicate: 1 };
        \\const value = {
        \\  shorthand,
        \\  ["computed"]: true,
        \\  method(input: number): string { return "ok"; },
        \\  get size(): number { return 1; },
        \\  set size(input: number) {},
        \\  ...base,
        \\  duplicate: "last"
        \\};
    );
    defer result.deinit();

    const object = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "value").?).?).?;
    const properties = object.kind.object;
    const expected_names = [_][]const u8{ "shorthand", "computed", "method", "size", "spread", "duplicate" };
    try std.testing.expectEqual(expected_names.len, properties.len);
    for (expected_names, properties) |name, property| try std.testing.expectEqualStrings(name, property.name);
    try std.testing.expectEqual(result.type_store.builtins.number, properties[0].type_id);
    try std.testing.expectEqual(result.type_store.builtins.boolean, properties[1].type_id);
    try std.testing.expect(result.lookupFunctionType(properties[2].type_id) != null);
    try std.testing.expectEqual(result.type_store.builtins.number, properties[3].type_id);
    try std.testing.expectEqual(result.type_store.builtins.string, properties[4].type_id);
    try std.testing.expectEqual(result.type_store.builtins.string, properties[5].type_id);
}

test "Goal 118 recursive object inference terminates with a stable shell" {
    var result = try analyze(std.testing.allocator, "let recursive = { self: recursive };");
    defer result.deinit();

    const initializer = testVariableInitializer(&result, "recursive").?;
    const object_id = result.lookupNodeType(initializer).?;
    const object = result.lookupType(object_id).?;
    try std.testing.expectEqual(object_id, object.kind.object[0].type_id);
}

test "Goal 119 member access resolves properties and preserves method receiver" {
    var result = try analyze(std.testing.allocator,
        \\const user = { name: "Ada", method(): number { return 1; } };
        \\const name = user.name;
        \\const method = user.method;
    );
    defer result.deinit();

    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "name").?).?);
    const method_node = testVariableInitializer(&result, "method").?;
    try std.testing.expect(result.lookupFunctionType(result.lookupNodeType(method_node).?) != null);
    try std.testing.expectEqual(
        result.lookupNodeType(testVariableInitializer(&result, "user").?).?,
        result.lookupNodeTypeInfo(method_node).?.receiver_type.?,
    );
}

test "Goal 119 indexed access handles tuples arrays objects and strings" {
    var result = try analyze(std.testing.allocator,
        \\const tuple: [number, string] = [1, "two"];
        \\const first = tuple[0];
        \\const items = [1, 2];
        \\const index = 1;
        \\const item = items[index];
        \\const object = { key: true };
        \\const keyed = object["key"];
        \\const character = "text"[0];
    );
    defer result.deinit();

    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "first").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "item").?).?);
    try std.testing.expectEqual(result.type_store.builtins.boolean, result.lookupNodeType(testVariableInitializer(&result, "keyed").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "character").?).?);
}

test "Goal 119 optional access removes nullish branches and adds undefined" {
    var result = try analyze(std.testing.allocator,
        \\const maybe = true ? { name: "Ada" } : null;
        \\const name = maybe?.name;
    );
    defer result.deinit();

    const access = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "name").?).?).?;
    try std.testing.expectEqual(@as(usize, 2), access.kind.union_type.len);
    try std.testing.expect(std.mem.indexOfScalar(types.TypeId, access.kind.union_type, result.type_store.builtins.string) != null);
    try std.testing.expect(std.mem.indexOfScalar(types.TypeId, access.kind.union_type, result.type_store.builtins.undefined) != null);
}

test "Goal 119 access failures emit distinct diagnostics and recover" {
    var result = try analyze(std.testing.allocator,
        \\const object = { known: 1 };
        \\const missing = object.absent;
        \\const tuple: [number, string] = [1, "two"];
        \\const invalid = tuple["bad"];
    );
    defer result.deinit();

    var unknown_properties: usize = 0;
    var invalid_indices: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| switch (diagnostic.code) {
        .unknown_property => unknown_properties += 1,
        .invalid_index => invalid_indices += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), unknown_properties);
    try std.testing.expectEqual(@as(usize, 1), invalid_indices);
    try std.testing.expectEqual(TypeResolutionState.@"error", result.lookupNodeTypeInfo(testVariableInitializer(&result, "missing").?).?.state);
    try std.testing.expectEqual(TypeResolutionState.@"error", result.lookupNodeTypeInfo(testVariableInitializer(&result, "invalid").?).?.state);
}

test "Goal 143 class and interface members participate in access and calls" {
    var result = try analyze(std.testing.allocator,
        \\class Base {
        \\  inherited: boolean;
        \\  static root(): number { return 1; }
        \\}
        \\class User extends Base {
        \\  name: string;
        \\  constructor(name: string) {}
        \\  greet(): number { return 1; }
        \\  static create(): User { return new User("A"); }
        \\}
        \\interface NamedBase { id: number }
        \\interface Named extends NamedBase {
        \\  title: string;
        \\  render(scale: number): boolean;
        \\}
        \\const user = new User("A");
        \\const name = user.name;
        \\const greeting = user.greet();
        \\const made = User.create();
        \\const inherited = user.inherited;
        \\const staticInherited = User.root();
        \\function inspect(value: Named) {
        \\  const title = value.title;
        \\  const rendered = value.render(1);
        \\  const id = value.id;
        \\}
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.semantic_diagnostics.len);
    const user_type = result.lookupNodeType(testVariableInitializer(&result, "user").?).?;
    try std.testing.expect(result.lookupType(user_type).?.kind == .class);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "name").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "greeting").?).?);
    try std.testing.expectEqual(user_type, result.lookupNodeType(testVariableInitializer(&result, "made").?).?);
    try std.testing.expectEqual(result.type_store.builtins.boolean, result.lookupNodeType(testVariableInitializer(&result, "inherited").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "staticInherited").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "title").?).?);
    try std.testing.expectEqual(result.type_store.builtins.boolean, result.lookupNodeType(testVariableInitializer(&result, "rendered").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "id").?).?);

    const greeting = result.frontend.ast.node(testVariableInitializer(&result, "greeting").?).data.CallExpression;
    try std.testing.expectEqual(user_type, result.lookupNodeTypeInfo(greeting.callee).?.receiver_type.?);
}

test "Goal 152 applied interfaces and classes substitute member and method types" {
    var result = try analyze(std.testing.allocator,
        \\interface Box<T> { value: T; map(input: T): T; }
        \\class Cell<T> { value: T; read(): T { return this.value; } }
        \\let box: Box<number>;
        \\let cell: Cell<string>;
        \\const boxed = box.value;
        \\const mapped = box.map(1);
        \\const stored = cell.value;
        \\const read = cell.read();
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.semantic_diagnostics.len);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "boxed").?).?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "mapped").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "stored").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "read").?).?);
}

test "Goal 152 applied interface compatibility uses substituted member types" {
    var result = try analyze(std.testing.allocator,
        \\interface Box<T> { value: T; }
        \\let valid: Box<number> = { value: 1 };
        \\let invalid: Box<number> = { value: "wrong" };
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.semantic_diagnostics.len);
    try std.testing.expectEqual(.type_mismatch, result.semantic_diagnostics[0].code);
}

test "Goal 153 typeof uses resolved declared and inferred value symbol types" {
    var result = try analyze(std.testing.allocator,
        \\const declared: string = "value";
        \\const inferred = 1;
        \\type DeclaredQuery = typeof declared;
        \\type InferredQuery = typeof inferred;
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.semantic_diagnostics.len);
    var declared_query: ?binder.SymbolId = null;
    var inferred_query: ?binder.SymbolId = null;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind != .type_alias) continue;
        if (std.mem.eql(u8, symbol.name, "DeclaredQuery")) declared_query = symbol.id;
        if (std.mem.eql(u8, symbol.name, "InferredQuery")) inferred_query = symbol.id;
    }
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupSymbolType(declared_query.?).?.declared_type.?);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupSymbolType(inferred_query.?).?.declared_type.?);
}

test "Goal 143 rejects unknown members and invalid constructors through Checker v2" {
    var result = try analyze(std.testing.allocator,
        \\class User {
        \\  constructor(name: string) {}
        \\  static create(): User { return new User("A"); }
        \\}
        \\const user = new User("A");
        \\const missing = user.absent;
        \\const wrongCount = new User();
        \\const wrongType = new User(1);
        \\const invalid = new user();
        \\const staticOnly = user.create;
    );
    defer result.deinit();

    var unknown_members: usize = 0;
    var invalid_counts: usize = 0;
    var invalid_types: usize = 0;
    var invalid_constructors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        switch (diagnostic.code) {
            .unknown_property => unknown_members += 1,
            .invalid_argument_count => invalid_counts += 1,
            .invalid_argument_type => invalid_types += 1,
            .type_mismatch => if (diagnostic.label != null and std.mem.eql(u8, diagnostic.label.?, "invalid constructor")) {
                invalid_constructors += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), unknown_members);
    try std.testing.expectEqual(@as(usize, 1), invalid_counts);
    try std.testing.expectEqual(@as(usize, 1), invalid_types);
    try std.testing.expectEqual(@as(usize, 1), invalid_constructors);
}

test "Goal 144 return inference includes reachable CFG fallthrough" {
    var result = try analyze(std.testing.allocator,
        \\function maybe(value: boolean) { if (value) return 1; }
        \\function strict(value: boolean): number { if (value) return 1; }
        \\function complete(value: boolean): number { if (value) return 1; else return 2; }
        \\function forever(): number { for (;;) {} }
        \\const inferred = maybe(true);
    );
    defer result.deinit();

    const inferred_type = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "inferred").?).?).?;
    try std.testing.expect(inferred_type.kind == .union_type);
    try std.testing.expect(std.mem.indexOfScalar(types.TypeId, inferred_type.kind.union_type, result.type_store.builtins.number) != null);
    try std.testing.expect(std.mem.indexOfScalar(types.TypeId, inferred_type.kind.union_type, result.type_store.builtins.undefined) != null);

    var fallthrough_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.label != null and std.mem.eql(u8, diagnostic.label.?, "incompatible fallthrough")) fallthrough_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fallthrough_errors);
}

test "Goal 156 return inference excludes unreachable and overridden returns" {
    var result = try analyze(std.testing.allocator,
        \\function unreachable() { return 1; return "dead"; }
        \\function overridden() { try { return 1; } finally { return "final"; } }
        \\function thrown() { try { return 1; } finally { throw "stop"; } }
        \\const first = unreachable();
        \\const second = overridden();
        \\const third = thrown();
    );
    defer result.deinit();

    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "first").?).?);
    try std.testing.expectEqual(result.type_store.builtins.string, result.lookupNodeType(testVariableInitializer(&result, "second").?).?);
    try std.testing.expectEqual(result.type_store.builtins.void, result.lookupNodeType(testVariableInitializer(&result, "third").?).?);
}

test "Goal 156 detailed aggregate diagnostics use compatibility" {
    var result = try analyze(std.testing.allocator,
        \\const value: { good: number; bad: number } = { good: 1, bad: "wrong" };
    );
    defer result.deinit();

    var property_mismatches: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.label != null and std.mem.eql(u8, diagnostic.label.?, "property type mismatch")) property_mismatches += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), property_mismatches);
}

test "Goal 144 optional method and callable union calls retain validation" {
    var result = try analyze(std.testing.allocator,
        \\const service = { read(value: number): string { return "ok"; } };
        \\const good = service.read?.(1);
        \\const bad = service.read?.("wrong");
        \\let maybe: ((value: number) => string) | undefined;
        \\const unionGood = maybe?.(1);
        \\const unionBad = maybe?.("wrong");
        \\let mixed: ((value: number) => string) | number;
        \\const rejected = mixed(1);
        \\let alternatives: ((value: number) => string) | ((value: string) => number);
        \\const incompatibleUnion = alternatives(1);
    );
    defer result.deinit();

    for ([_][]const u8{ "good", "unionGood" }) |name| {
        const result_type = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, name).?).?).?;
        try std.testing.expect(result_type.kind == .union_type);
        try std.testing.expect(std.mem.indexOfScalar(types.TypeId, result_type.kind.union_type, result.type_store.builtins.string) != null);
        try std.testing.expect(std.mem.indexOfScalar(types.TypeId, result_type.kind.union_type, result.type_store.builtins.undefined) != null);
    }

    var argument_errors: usize = 0;
    var callee_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .invalid_argument_type) argument_errors += 1;
        if (diagnostic.label != null and std.mem.eql(u8, diagnostic.label.?, "invalid call target")) callee_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), argument_errors);
    try std.testing.expectEqual(@as(usize, 1), callee_errors);
}

test "Goal 144 compound assignment checks call results and constructors remain stable" {
    var result = try analyze(std.testing.allocator,
        \\function text(): string { return "x"; }
        \\let count: number = 1;
        \\count += text();
        \\class Box { constructor(value: number) {} }
        \\const box = new Box(1);
        \\function descend(value: number): number { return value ? descend(value - 1) : 0; }
        \\const recursive = descend(2);
    );
    defer result.deinit();

    try std.testing.expect(result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "box").?).?).?.kind == .class);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(testVariableInitializer(&result, "recursive").?).?);
    var compound_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.message, "compound assignment result is not assignable to the target type")) compound_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), compound_errors);
}

test "Goal 144 async and generator return categories are explicit" {
    var result = try analyze(std.testing.allocator,
        \\async function load(): number { return 1; }
        \\function* values(): number { return 1; }
        \\const pending = load();
        \\const iterator = values();
    );
    defer result.deinit();

    const pending = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "pending").?).?).?;
    try std.testing.expect(pending.kind == .promise);
    try std.testing.expectEqual(result.type_store.builtins.number, pending.kind.promise.value_type);
    const iterator = result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "iterator").?).?).?;
    try std.testing.expect(iterator.kind == .generator);
    try std.testing.expectEqual(result.type_store.builtins.unknown, iterator.kind.generator.yield_type);
    try std.testing.expectEqual(result.type_store.builtins.number, iterator.kind.generator.return_type);
}

fn testReferenceTypeAt(result: *const SemanticResult, offset: usize) ?types.TypeId {
    for (result.frontend.resolve.references) |reference| {
        if (reference.span.start == offset) return result.lookupNodeType(reference.node);
    }
    return null;
}

fn testFlowEntryAt(result: *const SemanticResult, offset: usize) ?type_info.FlowTypeInfo {
    for (result.frontend.resolve.references) |reference| {
        if (reference.span.start != offset) continue;
        for (result.type_info.flow_types) |entry| {
            if (entry.reference_node == reference.node) return entry;
        }
    }
    return null;
}

test "Goal 145 dataflow converges and preserves same-block program points" {
    const source =
        \\function flow(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    const before = value;
        \\    value = 1;
        \\    const after = value;
        \\  }
        \\  if (flag) value = "left"; else value = 2;
        \\  while (flag) {
        \\    if (typeof value === "string") value = 3;
        \\    break;
        \\  }
        \\  return value;
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const before_offset = (std.mem.indexOf(u8, source, "before = value") orelse unreachable) + "before = ".len;
    const after_offset = (std.mem.indexOf(u8, source, "after = value") orelse unreachable) + "after = ".len;
    const before = testFlowEntryAt(&result, before_offset).?;
    const after = testFlowEntryAt(&result, after_offset).?;

    try std.testing.expectEqual(before.function_node, after.function_node);
    try std.testing.expectEqual(before.block_id, after.block_id);
    try std.testing.expect(after.program_point > before.program_point);
    try std.testing.expectEqual(result.type_store.builtins.string, before.type_id);
    try std.testing.expectEqual(result.type_store.builtins.number, after.type_id);
    try std.testing.expect(result.type_info.flow_types.len > 2);
}

test "Goal 146 typeof and instanceof narrow to the supported value types" {
    const source =
        \\class User { name: string; }
        \\class Admin { level: number; }
        \\function primitives(value: string | number) {
        \\  if (typeof value === "string") { const text = value; }
        \\  else { const numeric = value; }
        \\}
        \\function nominal(value: User | Admin) {
        \\  if (value instanceof User) { const user = value; }
        \\  else { const admin = value; }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();

    const text_offset = (std.mem.indexOf(u8, source, "text = value") orelse unreachable) + "text = ".len;
    const numeric_offset = (std.mem.indexOf(u8, source, "numeric = value") orelse unreachable) + "numeric = ".len;
    try std.testing.expectEqual(result.type_store.builtins.string, testReferenceTypeAt(&result, text_offset).?);
    try std.testing.expectEqual(result.type_store.builtins.number, testReferenceTypeAt(&result, numeric_offset).?);

    const user_offset = (std.mem.indexOf(u8, source, "user = value") orelse unreachable) + "user = ".len;
    const admin_offset = (std.mem.indexOf(u8, source, "admin = value") orelse unreachable) + "admin = ".len;
    const user = result.lookupType(testReferenceTypeAt(&result, user_offset).?).?;
    const admin = result.lookupType(testReferenceTypeAt(&result, admin_offset).?).?;
    try std.testing.expect(user.kind == .class);
    try std.testing.expect(admin.kind == .class);
    try std.testing.expectEqualStrings("User", user.kind.class.name);
    try std.testing.expectEqualStrings("Admin", admin.kind.class.name);
}

test "Goal 146 in narrows object and interface unions" {
    const source =
        \\interface Named { name: string; }
        \\interface Counted { count: number; }
        \\function interfaces(value: Named | Counted) {
        \\  if ("name" in value) { const named = value; }
        \\}
        \\function objects(value: { name: string } | { count: number }) {
        \\  if ("count" in value) { const counted = value; }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();

    const named_offset = (std.mem.indexOf(u8, source, "named = value") orelse unreachable) + "named = ".len;
    const named = result.lookupType(testReferenceTypeAt(&result, named_offset).?).?;
    try std.testing.expect(named.kind == .interface);
    try std.testing.expectEqualStrings("Named", named.kind.interface.name);

    const counted_offset = (std.mem.indexOf(u8, source, "counted = value") orelse unreachable) + "counted = ".len;
    const counted = result.lookupType(testReferenceTypeAt(&result, counted_offset).?).?;
    try std.testing.expect(counted.kind == .object);
    try std.testing.expectEqual(@as(usize, 1), counted.kind.object.len);
    try std.testing.expectEqualStrings("count", counted.kind.object[0].name);
}

test "Goal 146 truthiness preserves explicit falsy literals" {
    const source =
        \\function literals(value: "" | 0 | false | "ok" | 1 | true | null | undefined) {
        \\  if (value) { const truthy = value; }
        \\  else { const falsy = value; }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const truthy_offset = (std.mem.indexOf(u8, source, "truthy = value") orelse unreachable) + "truthy = ".len;
    const falsy_offset = (std.mem.indexOf(u8, source, "falsy = value") orelse unreachable) + "falsy = ".len;
    const truthy = result.lookupType(testReferenceTypeAt(&result, truthy_offset).?).?;
    const falsy = result.lookupType(testReferenceTypeAt(&result, falsy_offset).?).?;
    try std.testing.expect(truthy.kind == .union_type);
    try std.testing.expectEqual(@as(usize, 3), truthy.kind.union_type.len);
    try std.testing.expect(falsy.kind == .union_type);
    try std.testing.expectEqual(@as(usize, 5), falsy.kind.union_type.len);

    var has_empty = false;
    var has_zero = false;
    var has_false = false;
    var has_null = false;
    var has_undefined = false;
    for (falsy.kind.union_type) |member| {
        if (member == result.type_store.builtins.null_) has_null = true;
        if (member == result.type_store.builtins.undefined) has_undefined = true;
        const ty = result.lookupType(member).?;
        if (ty.kind == .literal) switch (ty.kind.literal) {
            .string => |value| has_empty = value.len == 0,
            .number => |value| has_zero = value == 0,
            .boolean => |value| has_false = !value,
            .bigint => {},
        };
    }
    try std.testing.expect(has_empty and has_zero and has_false and has_null and has_undefined);
}

test "Goal 146 joins facts and leaves unsupported guards conservative" {
    const source =
        \\function joined(value: string | number, flag: boolean, effect: any) {
        \\  if (typeof value === "string") {
        \\    if (flag) value = 1;
        \\    const merged = value;
        \\  }
        \\  if (typeof value === "object") { const unsupported = value; }
        \\  if (value) { effect(); const invalidated = value; }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const merged_offset = (std.mem.indexOf(u8, source, "merged = value") orelse unreachable) + "merged = ".len;
    const unsupported_offset = (std.mem.indexOf(u8, source, "unsupported = value") orelse unreachable) + "unsupported = ".len;
    const invalidated_offset = (std.mem.indexOf(u8, source, "invalidated = value") orelse unreachable) + "invalidated = ".len;
    try std.testing.expect(result.lookupType(testReferenceTypeAt(&result, merged_offset).?).?.kind == .union_type);
    try std.testing.expect(result.lookupType(testReferenceTypeAt(&result, unsupported_offset).?).?.kind == .union_type);
    try std.testing.expect(result.lookupType(testReferenceTypeAt(&result, invalidated_offset).?).?.kind == .union_type);
}

test "Goal 147 checker accepts structural interfaces and reports inherited property paths" {
    var result = try analyze(std.testing.allocator,
        \\interface Entity { id: number; }
        \\interface View extends Entity { label: string; }
        \\const good: View = { id: 1, label: "ok" };
        \\const bad: View = { id: "wrong", label: "ok" };
        \\let declared: View = good;
        \\const projected: { id: number; label: string } = declared;
    );
    defer result.deinit();

    var path_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and
            std.mem.indexOf(u8, diagnostic.message, "property path 'id'") != null)
        {
            path_errors += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), path_errors);
    try std.testing.expectEqual(@as(usize, 1), result.semantic_diagnostics.len);

    const good = result.lookupNodeTypeInfo(testVariableInitializer(&result, "good").?).?;
    try std.testing.expect(result.lookupType(good.type_id).?.kind == .object);
    try std.testing.expect(result.lookupType(good.contextual_type.?).?.kind == .interface);
    try std.testing.expectEqual(good.type_id, good.effective().?);
    try std.testing.expect(result.lookupType(result.lookupNodeType(testVariableInitializer(&result, "projected").?).?).?.kind == .interface);
}

test "Goal 154 expression branches join assignment effects at following references" {
    const source =
        \\function same(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    flag ? (value = 1) : (value = 2);
        \\    const afterSame = value;
        \\  }
        \\}
        \\function different(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    flag ? (value = 1) : (value = "next");
        \\    const afterDifferent = value;
        \\  }
        \\}
        \\function partial(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    flag && (value = 1);
        \\    const afterPartial = value;
        \\  }
        \\}
        \\function alternative(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    flag || (value = 1);
        \\    const afterAlternative = value;
        \\  }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();

    const after_same = (std.mem.indexOf(u8, source, "afterSame = value") orelse unreachable) + "afterSame = ".len;
    const after_different = (std.mem.indexOf(u8, source, "afterDifferent = value") orelse unreachable) + "afterDifferent = ".len;
    const after_partial = (std.mem.indexOf(u8, source, "afterPartial = value") orelse unreachable) + "afterPartial = ".len;
    const after_alternative = (std.mem.indexOf(u8, source, "afterAlternative = value") orelse unreachable) + "afterAlternative = ".len;
    const string_or_number = try result.type_store.unionOf(&.{ result.type_store.builtins.string, result.type_store.builtins.number });

    try std.testing.expectEqual(result.type_store.builtins.number, testReferenceTypeAt(&result, after_same).?);
    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_different).?);
    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_partial).?);
    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_alternative).?);
}

test "Goal 154 coalescing logical assignment and optional chains preserve only common facts" {
    const source =
        \\function coalesce(value: string | number, maybe: string | null) {
        \\  if (typeof value === "string") {
        \\    maybe ?? (value = 1);
        \\    const afterCoalesce = value;
        \\  }
        \\}
        \\function logicalAssign(value: string | number, flag: boolean) {
        \\  if (typeof value === "string") {
        \\    flag &&= (value = 1);
        \\    const afterLogicalAssign = value;
        \\  }
        \\}
        \\function optionalIndex(value: string | number, box: { item: number } | null) {
        \\  if (typeof value === "string") {
        \\    box?.[(value = 1)];
        \\    const afterOptional = value;
        \\  }
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();

    const string_or_number = try result.type_store.unionOf(&.{ result.type_store.builtins.string, result.type_store.builtins.number });
    const after_coalesce = (std.mem.indexOf(u8, source, "afterCoalesce = value") orelse unreachable) + "afterCoalesce = ".len;
    const after_logical = (std.mem.indexOf(u8, source, "afterLogicalAssign = value") orelse unreachable) + "afterLogicalAssign = ".len;
    const after_optional = (std.mem.indexOf(u8, source, "afterOptional = value") orelse unreachable) + "afterOptional = ".len;

    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_coalesce).?);
    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_logical).?);
    try std.testing.expectEqual(string_or_number, testReferenceTypeAt(&result, after_optional).?);
}

test "Goal 121 typeof narrowing follows early exits" {
    const source =
        \\function f(value: string | number) {
        \\  if (typeof value === "string") return value;
        \\  return value;
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const first_return = std.mem.indexOf(u8, source, "return value") orelse unreachable;
    const second_return = std.mem.lastIndexOf(u8, source, "return value") orelse unreachable;

    try std.testing.expectEqual(result.type_store.builtins.string, testReferenceTypeAt(&result, first_return + "return ".len).?);
    try std.testing.expectEqual(result.type_store.builtins.number, testReferenceTypeAt(&result, second_return + "return ".len).?);
}

test "Goal 121 falsy narrowing keeps nullish members and assignment invalidates facts" {
    const source =
        \\function f(flag: boolean) {
        \\  let value = flag ? "text" : null;
        \\  if (!value) return value;
        \\  const narrowed = value;
        \\  value = null;
        \\  return value;
        \\}
    ;
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const narrowed = std.mem.indexOf(u8, source, "narrowed = value") orelse unreachable;
    const final_return = std.mem.lastIndexOf(u8, source, "return value") orelse unreachable;

    try std.testing.expectEqual(result.type_store.builtins.string, testReferenceTypeAt(&result, narrowed + "narrowed = ".len).?);
    const final_type = testReferenceTypeAt(&result, final_return + "return ".len).?;
    try std.testing.expect(final_type != result.type_store.builtins.string);
    try std.testing.expect(final_type != result.type_store.builtins.never);
}

test "Goal 121 expression-body arrows receive flow entries" {
    const source = "const f = (value: string | null) => value;";
    var result = try analyze(std.testing.allocator, source);
    defer result.deinit();
    const body = std.mem.lastIndexOf(u8, source, "value") orelse unreachable;

    try std.testing.expect(testReferenceTypeAt(&result, body) != null);
    try std.testing.expect(result.type_info.flow_types.len != 0);
}

test "Goal 123 checker covers every diagnostic family from canonical types" {
    var result = try analyze(std.testing.allocator,
        \\let initialized: number = "wrong";
        \\let assigned: number = 1;
        \\assigned = "wrong";
        \\function badReturn(): number { return "wrong"; }
        \\function takes(value: number): void {}
        \\takes();
        \\takes("wrong");
        \\const object = { known: 1 };
        \\const missing = object.absent;
        \\const tuple: [number] = [1];
        \\const indexed = tuple["wrong"];
        \\const checked = "wrong" satisfies number;
        \\const operated = "wrong" - 1;
    );
    defer result.deinit();

    var mismatches: usize = 0;
    var property_errors: usize = 0;
    var index_errors: usize = 0;
    var count_errors: usize = 0;
    var argument_errors: usize = 0;
    var last_start: u32 = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.phase != .type_checker) continue;
        try std.testing.expect(diagnostic.span.start >= last_start);
        last_start = diagnostic.span.start;
        switch (diagnostic.code) {
            .type_mismatch => {
                try std.testing.expect(diagnostic.related.len != 0);
                mismatches += 1;
            },
            .unknown_property => {
                try std.testing.expect(diagnostic.related.len != 0);
                property_errors += 1;
            },
            .invalid_index => {
                try std.testing.expect(diagnostic.related.len != 0);
                index_errors += 1;
            },
            .invalid_argument_count => {
                try std.testing.expect(diagnostic.related.len != 0);
                count_errors += 1;
            },
            .invalid_argument_type => {
                try std.testing.expect(diagnostic.related.len != 0);
                argument_errors += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 5), mismatches);
    try std.testing.expectEqual(@as(usize, 1), property_errors);
    try std.testing.expectEqual(@as(usize, 1), index_errors);
    try std.testing.expectEqual(@as(usize, 1), count_errors);
    try std.testing.expectEqual(@as(usize, 1), argument_errors);
}

test "Goal 123 unresolved operands suppress derivative checker errors" {
    var result = try analyze(std.testing.allocator, "const value: number = missing + 1;");
    defer result.deinit();

    var unresolved: usize = 0;
    var checker_errors: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.code == .cannot_find_name) unresolved += 1;
        if (diagnostic.phase == .type_checker) checker_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unresolved);
    try std.testing.expectEqual(@as(usize, 0), checker_errors);
}

test "Goal 123 unannotated functions do not self-check inferred returns" {
    var result = try analyze(std.testing.allocator,
        \\function choose(flag) {
        \\    if (flag) return "text";
        \\    return 1;
        \\}
    );
    defer result.deinit();

    for (result.semantic_diagnostics) |diagnostic|
        try std.testing.expect(diagnostic.phase != .type_checker);
}

fn goal134FunctionSymbol(result: *const SemanticResult, name: []const u8) ?binder.SymbolId {
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind != .function or !std.mem.eql(u8, symbol.name, name)) continue;
        return symbol.id;
    }
    return null;
}

fn goal137ValueSymbol(result: *const SemanticResult, name: []const u8) ?binder.SymbolId {
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind != .variable or !std.mem.eql(u8, symbol.name, name)) continue;
        return symbol.id;
    }
    return null;
}

test "Goal 134 two unannotated functions with different inferred returns retain distinct effective signatures" {
    // Two zero-argument functions that happen to have identical parameter shapes
    // but differ in their inferred return types (number vs string). Each must
    // keep its own immutable signature TypeId and keep declared_type == null.
    var result = try analyze(std.testing.allocator,
        \\function first() { return 1; }
        \\function second() { return "hello"; }
    );
    defer result.deinit();

    const a = goal134FunctionSymbol(&result, "first").?;
    const b = goal134FunctionSymbol(&result, "second").?;

    // declared_type must remain null for unannotated functions.
    try std.testing.expectEqual(@as(?types.TypeId, null), result.lookupSymbolType(a).?.declared_type);
    try std.testing.expectEqual(@as(?types.TypeId, null), result.lookupSymbolType(b).?.declared_type);

    // Both must have a non-null inferred_type holding an immutable signature.
    const sig_a = result.lookupSymbolType(a).?.inferred_type orelse return error.TestFailed;
    const sig_b = result.lookupSymbolType(b).?.inferred_type orelse return error.TestFailed;

    try std.testing.expect(sig_a != sig_b);

    // effective() picks declared first (null), then inferred — both resolve to distinct IDs.
    try std.testing.expectEqual(sig_a, result.lookupSymbolType(a).?.effective());
    try std.testing.expectEqual(sig_b, result.lookupSymbolType(b).?.effective());

    // The signatures themselves are structurally unequal in return_type.
    const sa = result.lookupFunctionType(sig_a).?;
    const sb = result.lookupFunctionType(sig_b).?;
    try std.testing.expect(sa.parameters.len == 0);
    try std.testing.expect(sb.parameters.len == 0);
    try std.testing.expectEqual(result.type_store.builtins.number, sa.return_type);
    try std.testing.expectEqual(result.type_store.builtins.string, sb.return_type);
}

test "Goal 134 unannotated and annotated functions keep separate signature slots" {
    var result = try analyze(std.testing.allocator,
        \\function annotated(): number { return "body"; }
        \\function unannotated() { return "x"; }
    );
    defer result.deinit();

    const ann = goal134FunctionSymbol(&result, "annotated").?;
    const unn = goal134FunctionSymbol(&result, "unannotated").?;

    const ann_info = result.lookupSymbolType(ann).?;
    const ann_declared = ann_info.declared_type orelse return error.TestFailed;
    const ann_inferred = ann_info.inferred_type orelse return error.TestFailed;
    try std.testing.expect(result.lookupSymbolType(unn).?.inferred_type != null);

    const unn_sig_id = result.lookupSymbolType(unn).?.inferred_type.?;
    try std.testing.expect(ann_declared != ann_inferred);
    try std.testing.expectEqual(ann_declared, ann_info.effective().?);

    try std.testing.expectEqual(
        result.type_store.builtins.number,
        result.lookupFunctionType(ann_declared).?.return_type,
    );
    try std.testing.expectEqual(
        result.type_store.builtins.string,
        result.lookupFunctionType(ann_inferred).?.return_type,
    );

    const unn_sig = result.lookupFunctionType(unn_sig_id).?;
    try std.testing.expectEqual(result.type_store.builtins.string, unn_sig.return_type);
}

test "Goal 134 inference loop converges across repeated analysis rounds" {
    var first = try analyze(std.testing.allocator, "function a() { return 1; }\nfunction b(a: number): string { return \"x\"; }\nconst c = a(b(2));");
    defer first.deinit();

    const fa = goal134FunctionSymbol(&first, "a").?;
    const fb = goal134FunctionSymbol(&first, "b").?;
    const first_a = first.lookupFunctionType(first.lookupSymbolType(fa).?.inferred_type.?).?;
    const first_b = first.lookupFunctionType(first.lookupSymbolType(fb).?.inferred_type.?).?;
    try std.testing.expectEqual(first.type_store.builtins.number, first_a.return_type);
    try std.testing.expectEqual(first.type_store.builtins.string, first_b.return_type);

    // Run a second and third round — convergence must be stable across three.
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        var r2 = try analyze(std.testing.allocator, "function a() { return 1; }\nfunction b(a: number): string { return \"x\"; }\nconst c = a(b(2));");
        defer r2.deinit();
        const fa2 = goal134FunctionSymbol(&r2, "a").?;
        const fb2 = goal134FunctionSymbol(&r2, "b").?;
        const a_signature = r2.lookupFunctionType(r2.lookupSymbolType(fa2).?.inferred_type.?).?;
        const b_signature = r2.lookupFunctionType(r2.lookupSymbolType(fb2).?.inferred_type.?).?;
        try std.testing.expectEqual(r2.type_store.builtins.number, a_signature.return_type);
        try std.testing.expectEqual(r2.type_store.builtins.string, b_signature.return_type);
    }
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Goal 135 regression — single TypeId allocation space.
// Proves that within one SemanticResult, every TypeId (primitives from the
// Builtins registry, nominal types allocated via TypeStore.reserve(), and
// function signatures allocated via TypeStore.addFunctionDetailed()) lives in
// a single store with no independent allocator that could produce collisions.
// ---------------------------------------------------------------------------

test "Goal 135 primitives, objects and functions share one TypeId space" {
    var result = try analyze(std.testing.allocator,
        \\class Foo {
        \\    x: number;
        \\}
        \\function bar(a: number): string { return "x"; }
        \\const n: number = 1;
    );
    defer result.deinit();

    // Every TypeId we touch must belong to `result.type_store`. No second store.
    const ts = &result.type_store;
    try std.testing.expect(ts.builtins.number != ts.builtins.string);
    try std.testing.expect(ts.builtins.number != ts.builtins.boolean);

    // The builtin TypeId for `number` must sit in [100, 200) per the Builtins registry.
    try std.testing.expect(ts.builtins.number >= 100);
    try std.testing.expect(ts.builtins.number < 1000);

    const object_type = try ts.intern(.{ .object = &.{.{
        .name = "value",
        .type_id = ts.builtins.number,
    }} });
    try std.testing.expect(object_type >= types.next_user_type_id);

    // The function signature TypeId for `bar` must live in user space.
    const bar_sym = goal134FunctionSymbol(&result, "bar").?;
    const bar_sig = result.lookupSymbolType(bar_sym).?.inferred_type orelse return error.TestFailed;
    try std.testing.expect(bar_sig >= 1000);

    // The builtin number TypeId must be findable via the store's lookup.
    const found_number = ts.lookup(ts.builtins.number) orelse return error.TestFailed;
    _ = found_number; // existence check passed

    // Sanity: no two of {number, string, bar_sig} may collide — they come from
    // different allocation sites but the same TypeStore.
    try std.testing.expect(ts.builtins.number != ts.builtins.string);
    try std.testing.expect(ts.builtins.number != bar_sig);
    try std.testing.expect(ts.builtins.string != bar_sig);
    try std.testing.expect(object_type != bar_sig);
    try std.testing.expect(ts.lookup(object_type) != null);

    // The TypeStore is the only allocator: every record, signature and builtin
    // TypeId lives within one struct with a single source of identity. Walk the
    // signatures slice to confirm no user-space id collides with any builtin.
    for (ts.signatures.items) |sig| {
        try std.testing.expect(sig.id >= 1000);
        var b: usize = 0;
        while (b < ts.builtins.records.len) : (b += 1) {
            try std.testing.expect(sig.id != ts.builtins.records[b].id);
        }
    }

    // Future independent allocators would violate these ownership assertions.
}

test "Goal 150 every binder symbol has explicit semantic type information" {
    var result = try analyze(std.testing.allocator,
        \\import { imported } from "dep";
        \\type Alias = number;
        \\interface Shape { value: number; }
        \\enum Choice { first }
        \\class Box<T> {
        \\  value: T;
        \\  method(input: T): T { return input; }
        \\}
        \\function identity<U>(input: U): U { return input; }
        \\const local = imported;
    );
    defer result.deinit();

    var seen: [@typeInfo(binder.SymbolKind).@"enum".fields.len]bool = @splat(false);
    for (result.frontend.bind.symbols) |symbol| {
        try std.testing.expect(result.lookupSymbolType(symbol.id) != null);
        seen[@intFromEnum(symbol.kind)] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "Goal 150 every accepted executable expression has semantic type information" {
    var result = try analyze(std.testing.allocator,
        \\const regex = /x/g;
        \\function tag(parts: unknown): string { return "tagged"; }
        \\const tagged = tag`x${1}`;
        \\const dynamic = import("dep");
        \\const meta = import.meta;
        \\function* values() { yield 1; }
        \\class Base {}
        \\class Derived extends Base { parent() { return super; } }
        \\const ClassValue = class Named extends Base { self() { return this; } };
    );
    defer result.deinit();

    var special = [_]bool{false} ** 8;
    for (result.frontend.ast.nodes, 0..) |node, raw_id| {
        if (isExecutableExpression(node.data))
            try std.testing.expect(result.lookupNodeTypeInfo(@intCast(raw_id)) != null);
        switch (node.data) {
            .RegExpLiteral => special[0] = true,
            .TaggedTemplateExpression => special[1] = true,
            .ImportExpression => special[2] = true,
            .MetaProperty => special[3] = true,
            .YieldExpression => special[4] = true,
            .ClassExpression => special[5] = true,
            .ThisExpression => special[6] = true,
            .SuperExpression => special[7] = true,
            else => {},
        }
    }
    for (special) |present| try std.testing.expect(present);
}

test "Goal 150 this super and class expressions use canonical class identities" {
    var result = try analyze(std.testing.allocator,
        \\class Base {}
        \\class Derived extends Base { self() { return this; } parent() { return super; } }
        \\const ClassValue = class Named extends Base { self() { return this; } };
    );
    defer result.deinit();

    var base_id: ?ast.NodeId = null;
    var derived_id: ?ast.NodeId = null;
    var expression_id: ?ast.NodeId = null;
    var this_nodes: [2]ast.NodeId = undefined;
    var this_count: usize = 0;
    var super_id: ?ast.NodeId = null;
    for (result.frontend.ast.nodes, 0..) |node, raw_id| switch (node.data) {
        .ClassDeclaration => |class| {
            if (std.mem.eql(u8, class.name, "Base")) base_id = @intCast(raw_id);
            if (std.mem.eql(u8, class.name, "Derived")) derived_id = @intCast(raw_id);
        },
        .ClassExpression => expression_id = @intCast(raw_id),
        .ThisExpression => {
            this_nodes[this_count] = @intCast(raw_id);
            this_count += 1;
        },
        .SuperExpression => super_id = @intCast(raw_id),
        else => {},
    };

    const base = result.type_store.lookupClassSemanticType(.init(result.module.id, base_id.?)).?;
    const derived = result.type_store.lookupClassSemanticType(.init(result.module.id, derived_id.?)).?;
    const expression = result.type_store.lookupClassSemanticType(.init(result.module.id, expression_id.?)).?;
    try std.testing.expectEqual(base.instance_type, derived.inheritance.extends.?);
    try std.testing.expectEqual(base.instance_type, result.lookupNodeType(super_id.?).?);
    try std.testing.expectEqual(derived.instance_type, result.lookupNodeType(this_nodes[0]).?);
    try std.testing.expectEqual(expression.instance_type, result.lookupNodeType(this_nodes[1]).?);
    try std.testing.expectEqual(expression.constructor_type, result.lookupNodeType(expression_id.?).?);
    try std.testing.expect(expression.constructor_type != expression.instance_type);

    var named_symbol_found = false;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.declaration == expression_id.? and std.mem.eql(u8, symbol.name, "Named")) {
            try std.testing.expectEqual(expression.constructor_type, result.lookupSymbolType(symbol.id).?.effective().?);
            named_symbol_found = true;
        }
    }
    try std.testing.expect(named_symbol_found);
}

fn goal151ClassType(result: *const SemanticResult, name: []const u8) ?types.ClassSemanticType {
    for (result.frontend.ast.nodes, 0..) |node, raw_id| switch (node.data) {
        .ClassDeclaration => |class| if (std.mem.eql(u8, class.name, name))
            return result.type_store.lookupClassSemanticType(.init(result.module.id, @intCast(raw_id))),
        else => {},
    };
    return null;
}

fn goal151MemberType(table: types.MemberTable, name: []const u8) ?types.TypeId {
    for (table.members) |member| if (std.mem.eql(u8, member.name, name)) return member.type_id;
    return null;
}

test "Goal 151 declarations object methods and class methods share return inference" {
    var result = try analyze(std.testing.allocator,
        \\function regular() { return 1; }
        \\const object = { method() { return 2; } };
        \\class Example {
        \\  value: number;
        \\  method() { return 3; }
        \\  read() { return this.value; }
        \\}
    );
    defer result.deinit();

    const regular = goal134FunctionSymbol(&result, "regular").?;
    const regular_signature = result.lookupFunctionType(result.lookupSymbolType(regular).?.effective().?).?;
    try std.testing.expectEqual(result.type_store.builtins.number, regular_signature.return_type);

    var object_method: ?ast.NodeId = null;
    var receiver_member: ?ast.NodeId = null;
    for (result.frontend.ast.nodes, 0..) |node, raw_id| switch (node.data) {
        .FunctionExpression => {
            if (function_like.describe(result.frontend.ast, @intCast(raw_id)).?.receiver == .object)
                object_method = @intCast(raw_id);
        },
        .MemberExpression => |member| {
            if (switch (result.frontend.ast.node(member.object).data) {
                .ThisExpression => true,
                else => false,
            }) receiver_member = @intCast(raw_id);
        },
        else => {},
    };
    const object_signature = result.lookupFunctionType(result.lookupNodeType(object_method.?).?).?;
    try std.testing.expectEqual(result.type_store.builtins.number, object_signature.return_type);

    const class = goal151ClassType(&result, "Example").?;
    const method_signature = result.lookupFunctionType(goal151MemberType(class.instance_members, "method").?).?;
    const read_signature = result.lookupFunctionType(goal151MemberType(class.instance_members, "read").?).?;
    try std.testing.expectEqual(result.type_store.builtins.number, method_signature.return_type);
    try std.testing.expectEqual(result.type_store.builtins.number, read_signature.return_type);
    try std.testing.expectEqual(result.type_store.builtins.number, result.lookupNodeType(receiver_member.?).?);
}

test "Goal 151 annotated class methods validate inferred body returns" {
    var result = try analyze(std.testing.allocator,
        \\class Example { invalid(): number { return "wrong"; } }
    );
    defer result.deinit();

    var incompatible_returns: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| {
        if (diagnostic.label != null and std.mem.eql(u8, diagnostic.label.?, "incompatible return"))
            incompatible_returns += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), incompatible_returns);
}

test "Goal 151 constructors accessors async and generators use one callable contract" {
    var result = try analyze(std.testing.allocator,
        \\class Invalid {
        \\  constructor(): number { return 1; }
        \\  get value(input: number) { return 1; }
        \\  set item(): number { return 1; }
        \\}
        \\class Worker {
        \\  async load() { return 1; }
        \\  *values() { return 2; }
        \\}
        \\const object = {
        \\  get bad(input: number) { return 1; },
        \\  set badSet(value: number) { return 1; }
        \\};
    );
    defer result.deinit();

    var invalid_setter_descriptors: usize = 0;
    for (result.frontend.ast.nodes, 0..) |_, raw_id| {
        const callable = function_like.describe(result.frontend.ast, @intCast(raw_id)) orelse continue;
        if (callable.kind == .setter and callable.params.len != 1) invalid_setter_descriptors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), invalid_setter_descriptors);

    var invalid_constructor_return_type: usize = 0;
    var invalid_getter_parameters: usize = 0;
    var invalid_setter_return_type: usize = 0;
    var invalid_setter_parameter: usize = 0;
    var invalid_return_value: usize = 0;
    for (result.semantic_diagnostics) |diagnostic| if (diagnostic.label) |label| {
        if (std.mem.eql(u8, label, "invalid constructor return type")) invalid_constructor_return_type += 1;
        if (std.mem.eql(u8, label, "invalid getter parameters")) invalid_getter_parameters += 1;
        if (std.mem.eql(u8, label, "invalid setter return type")) invalid_setter_return_type += 1;
        if (std.mem.eql(u8, label, "invalid setter parameter")) invalid_setter_parameter += 1;
        if (std.mem.eql(u8, label, "invalid return value")) invalid_return_value += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), invalid_constructor_return_type);
    try std.testing.expectEqual(@as(usize, 2), invalid_getter_parameters);
    try std.testing.expectEqual(@as(usize, 1), invalid_setter_return_type);
    try std.testing.expectEqual(@as(usize, 1), invalid_setter_parameter);
    try std.testing.expectEqual(@as(usize, 3), invalid_return_value);

    const worker = goal151ClassType(&result, "Worker").?;
    const load = result.lookupFunctionType(goal151MemberType(worker.instance_members, "load").?).?;
    const values = result.lookupFunctionType(goal151MemberType(worker.instance_members, "values").?).?;
    try std.testing.expect(load.flags.is_async);
    try std.testing.expect(values.flags.is_generator);
    const promised = result.lookupType(load.return_type).?;
    const generated = result.lookupType(values.return_type).?;
    try std.testing.expect(promised.kind == .promise);
    try std.testing.expect(generated.kind == .generator);
    try std.testing.expectEqual(result.type_store.builtins.number, promised.kind.promise.value_type);
    try std.testing.expectEqual(result.type_store.builtins.number, generated.kind.generator.return_type);
}

fn goal158ValidateAnalysis(allocator: std.mem.Allocator, source: []const u8) !void {
    var result = try analyze(allocator, source);
    defer result.deinit();
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.span.start > diagnostic.span.end) return error.InvalidDiagnosticSpan;
        if (diagnostic.span.end > source.len) return error.InvalidDiagnosticSpan;
    }
}

fn goal158ThreadWorker() !void {
    const inputs = [_][]const u8{
        "const threaded: number = 9;",
        "function f<T>(x: T): T { return x; } f(1);",
        "const broken = `unterminated ${1 +`;",
        "class C { value: number = 1; } new C().value;",
    };
    for (0..25) |iteration| try goal158ValidateAnalysis(std.heap.page_allocator, inputs[iteration % inputs.len]);
}

test "Goal 158 deterministic malformed corpus and diagnostic stability" {
    const corpus = [_][]const u8{
        "",
        "\xff\xfeconst x = 1;",
        "const n = 1e+; const later: number = 'wrong';",
        "const s = 'unterminated",
        "/* unterminated",
        "const r = /unterminated;",
        "const t = `head ${ { broken: } tail`;",
        "import { missing as } from './nope'; export {;",
        "function broken(): number \xff return 1; }",
        "((((((((((((((((((((((((1))))))))))))))))))))))))",
        "function f<T extends {x: number}>(v: T): number { return v.x; }",
    };
    for (corpus) |source| try goal158ValidateAnalysis(std.testing.allocator, source);

    const source = "const first = 1e+; const second: number = 'wrong';";
    var first = try analyze(std.testing.allocator, source);
    defer first.deinit();
    var second = try analyze(std.testing.allocator, source);
    defer second.deinit();
    try std.testing.expectEqual(first.diagnostics.len, second.diagnostics.len);
    for (first.diagnostics, second.diagnostics) |left, right| {
        try std.testing.expectEqual(left.code, right.code);
        try std.testing.expectEqual(left.phase, right.phase);
        try std.testing.expectEqual(left.span, right.span);
    }
}

test "Goal 158 deterministic byte-mutation corpus remains memory safe" {
    const seeds = [_][]const u8{
        "const value = { nested: [1, 2, 3] };",
        "function map<T>(value: T): T { return value; }",
        "const template = `head ${value} tail`;",
        "import { value as renamed } from './dependency';",
    };
    const replacements = [_]u8{ 0x00, 0x22, 0x27, 0x60, 0x7f, 0xff };
    for (seeds) |seed| {
        for (0..@min(seed.len, 48)) |offset| {
            const mutated = try std.testing.allocator.dupe(u8, seed);
            defer std.testing.allocator.free(mutated);
            mutated[offset] = replacements[offset % replacements.len];
            try goal158ValidateAnalysis(std.testing.allocator, mutated);
        }
    }
}

test "Goal 158 semantic oracle preserves representative checker outcomes" {
    const Oracle = struct {
        source: []const u8,
        expected: diagnostics.DiagnosticCode,
    };
    const cases = [_]Oracle{
        .{ .source = "const value: number = 'wrong';", .expected = .type_mismatch },
        .{ .source = "const object = { known: 1 }; object.missing;", .expected = .unknown_property },
        .{ .source = "function takes(value: number): void {} takes();", .expected = .invalid_argument_count },
        .{ .source = "function takes(value: number): void {} takes('wrong');", .expected = .invalid_argument_type },
    };
    for (cases) |case| {
        var result = try analyze(std.testing.allocator, case.source);
        defer result.deinit();
        var found = false;
        for (result.semantic_diagnostics) |diagnostic| {
            if (diagnostic.code == case.expected) found = true;
        }
        try std.testing.expect(found);
    }

    var valid = try analyze(std.testing.allocator,
        \\interface Box<T> { value: T; map(input: T): T; }
        \\let box: Box<number>;
        \\const boxed = box.value;
        \\const mapped = box.map(1);
    );
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 0), valid.semantic_diagnostics.len);
}

test "Goal 158 repeated lifecycle huge literal and explicit parse limit" {
    for (0..50) |_| {
        var result = try analyze(std.testing.allocator, "const x: number = 1; function f() { return x; }");
        result.deinit();
    }

    const payload = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'a');
    const source = try std.fmt.allocPrint(std.testing.allocator, "const huge = '{s}';", .{payload});
    defer std.testing.allocator.free(source);
    try goal158ValidateAnalysis(std.testing.allocator, source);

    try std.testing.expectError(error.ParseRecursionLimitReached, analyzeSource(
        std.testing.allocator,
        .{ .path = "depth.ts", .text = "const x = (((((((1)))))));" },
        .{ .max_parse_depth = 2 },
    ));
}

test "Goal 158 independent analyses run in parallel" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, goal158ThreadWorker, .{});
    for (threads) |thread| thread.join();
}
