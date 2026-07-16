//! Owned, environment-neutral project session.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const contracts = @import("contracts.zig");
const frontend = @import("../frontend/frontend.zig");
const hir_result = @import("../hir/result.zig");
const modules_mod = @import("../modules/root.zig");
const semantics = @import("../semantics/root.zig");
const types = @import("../types/root.zig");
const project_graph = @import("graph.zig");
const state_machine = @import("state_machine.zig");

pub const ModuleState = enum(u32) {
    unseen,
    requested,
    supplied,
    parsing,
    analyzed,
    external,
    failed,
    complete,
};

/// One project-owned module record. Source slices and the semantic result stay
/// valid until a newer revision replaces them or the Project is deinitialized.
pub const Module = struct {
    id: contracts.ModuleId,
    state: ModuleState,
    is_root: bool,
    source: ?contracts.ModuleSource,
    semantic_result: ?*semantics.SemanticResult,
    metadata_derived: bool,

    pub fn diagnostics(self: *const Module) []const @import("../diagnostics/root.zig").Diagnostic {
        const result = self.semantic_result orelse return &.{};
        return result.diagnostics;
    }
};

pub const FinishResult = struct {
    module_count: usize,
    has_failures: bool,
};

const OwnedExternalModule = struct {
    descriptor: contracts.ExternalModuleDescriptor,
};

/// Owns every submitted source byte, logical name, semantic result, and
/// diagnostic reachable from a module. Submission copies host slices, so the
/// host may release or mutate its buffers as soon as the call returns.
pub const Project = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(Module) = .empty,
    requests: state_machine.StateMachine,
    graph: project_graph.Graph,
    project_semantics: ?*semantics.BorrowedProjectSemanticResult = null,
    project_hir: ?*hir_result.HirResult = null,
    external_modules: std.ArrayList(OwnedExternalModule) = .empty,

    pub fn init(allocator: std.mem.Allocator) Project {
        return .{ .allocator = allocator, .requests = .init(allocator), .graph = .init(allocator) };
    }

    pub fn deinit(self: *Project) void {
        self.clearProjectSemantics();
        for (self.modules.items) |*module| self.deinitModule(module);
        self.modules.deinit(self.allocator);
        for (self.external_modules.items) |module| self.freeExternalDescriptor(module.descriptor);
        self.external_modules.deinit(self.allocator);
        self.graph.deinit();
        self.requests.deinit();
        self.* = undefined;
    }

    pub fn moduleCount(self: *const Project) usize {
        return self.modules.items.len;
    }

    pub fn state(self: *const Project, id: contracts.ModuleId) ModuleState {
        const module = self.find(id) orelse return .unseen;
        return module.state;
    }

    pub fn lookup(self: *const Project, id: contracts.ModuleId) ?*const Module {
        return self.find(id);
    }

    /// Register an unresolved identity. Repeated requests are idempotent.
    fn requestModule(self: *Project, id: contracts.ModuleId) !void {
        if (self.findMut(id) != null) return;
        try self.modules.append(self.allocator, .{
            .id = id,
            .state = .requested,
            .is_root = false,
            .source = null,
            .semantic_result = null,
            .metadata_derived = false,
        });
    }

    pub fn addRoot(self: *Project, source: contracts.ModuleSource) !void {
        try self.submit(source, true);
    }

    pub fn supplySource(self: *Project, source: contracts.ModuleSource) !void {
        try self.submit(source, false);
    }

    fn queueRequest(self: *Project, input: contracts.ModuleRequestInput) !contracts.RequestId {
        if (self.find(input.importer) == null) return error.UnknownImporter;
        return self.requests.enqueue(input);
    }

    pub fn step(self: *Project) !state_machine.Step {
        try self.analyze();
        return self.requests.step();
    }

    pub fn edges(self: *const Project) []const project_graph.Edge {
        return self.graph.edges.items;
    }

    pub fn graphDiagnostics(self: *const Project) []const project_graph.GraphDiagnostic {
        return self.graph.diagnostics.items;
    }

    pub fn semanticResult(self: *const Project) ?*const semantics.BorrowedProjectSemanticResult {
        return self.project_semantics;
    }

    /// Immutable canonical HIR owned by this completed project, when derived.
    pub fn hirResult(self: *const Project) ?*const hir_result.HirResult {
        return self.project_hir;
    }

    /// Transfers one successfully lowered result into project ownership.
    /// Intended for the HIR project-session bridge; a second install is rejected.
    pub fn installHirResult(self: *Project, result: hir_result.HirResult) !*const hir_result.HirResult {
        if (self.project_hir != null) return error.HirAlreadyDerived;
        const owned = try self.allocator.create(hir_result.HirResult);
        owned.* = result;
        self.project_hir = owned;
        return owned;
    }

    pub fn lookupRequest(self: *const Project, id: contracts.RequestId) ?state_machine.RequestRecord {
        return self.requests.lookup(id);
    }

    pub fn respondSource(self: *Project, id: contracts.RequestId, source: contracts.ModuleSource) !void {
        try self.requests.validateResponse(id);
        if (self.find(source.id)) |existing| {
            if (existing.source) |owned| {
                const identical = source.revision == owned.revision and source.kind == owned.kind and
                    std.mem.eql(u8, source.logical_name, owned.logical_name) and
                    std.mem.eql(u8, source.bytes, owned.bytes);
                if (!identical) try self.supplySource(source);
            } else {
                try self.supplySource(source);
            }
        } else {
            try self.supplySource(source);
        }
        try self.requests.commitResponse(id, .{ .kind = .source, .module_id = source.id });
        try self.graph.resolve(id, .resolved, source.id);
        self.clearProjectSemantics();
    }

    /// Satisfy one request with copied source-less module metadata.
    pub fn respondExternalModule(self: *Project, id: contracts.RequestId, descriptor: contracts.ExternalModuleDescriptor) !void {
        try self.requests.validateResponse(id);
        try validateExternalDescriptor(descriptor);
        try self.registerExternalModule(descriptor);
        try self.requests.commitResponse(id, .{ .kind = .external, .external_module_id = descriptor.id });
        self.graph.resolveExternal(id, descriptor.id);
        self.clearProjectSemantics();
    }

    pub fn respondNotFound(self: *Project, id: contracts.RequestId) !void {
        try self.requests.commitResponse(id, .{ .kind = .not_found });
        try self.graph.resolve(id, .not_found, null);
        self.clearProjectSemantics();
    }

    pub fn respondDenied(self: *Project, id: contracts.RequestId) !void {
        try self.requests.commitResponse(id, .{ .kind = .denied });
        try self.graph.resolve(id, .denied, null);
        self.clearProjectSemantics();
    }

    pub fn respondFailed(self: *Project, id: contracts.RequestId) !void {
        try self.requests.commitResponse(id, .{ .kind = .failed });
        try self.graph.resolve(id, .failed, null);
        self.clearProjectSemantics();
    }

    /// Finish is legal only after every request has a response and every source
    /// has reached complete or failed. It never performs hidden analysis.
    pub fn finish(self: *Project) !FinishResult {
        if (self.requests.hasUnresolved()) return error.PendingRequests;
        var has_failures = self.requests.hasFailures();
        for (self.modules.items) |module| switch (module.state) {
            .complete => {},
            .failed => has_failures = true,
            .unseen, .requested, .supplied, .parsing, .analyzed, .external => return error.IncompleteModules,
        };
        if (self.project_semantics == null) try self.buildProjectSemantics();
        return .{ .module_count = self.modules.items.len, .has_failures = has_failures };
    }

    /// Analyze a supplied module. A completed unchanged revision is returned
    /// without re-analysis. Allocation or internal analysis failures leave this
    /// module inspectably failed and do not modify other completed modules.
    fn analyzeModule(self: *Project, id: contracts.ModuleId) !*const semantics.SemanticResult {
        const initial = self.find(id) orelse return error.UnknownModule;
        if (initial.state == .complete) {
            if (!initial.metadata_derived) try self.deriveModuleMetadata(id);
            return self.find(id).?.semantic_result.?;
        }
        if (initial.source == null) return error.SourceNotSupplied;

        self.findMut(id).?.state = .parsing;
        const result_ptr = self.allocator.create(semantics.SemanticResult) catch |err| {
            self.findMut(id).?.state = .failed;
            return err;
        };
        errdefer self.allocator.destroy(result_ptr);

        const source = self.find(id).?.source.?;
        result_ptr.* = semantics.analyzeSource(self.allocator, .{
            .path = source.logical_name,
            .text = source.bytes,
            .kind = switch (source.kind) {
                .script => .script,
                .module => .module,
            },
        }, .{}) catch |err| {
            self.findMut(id).?.state = .failed;
            return err;
        };

        const module = self.findMut(id).?;
        module.semantic_result = result_ptr;
        module.state = .analyzed;
        module.state = .complete;
        try self.deriveModuleMetadata(id);
        self.clearProjectSemantics();
        return result_ptr;
    }

    /// Analyze every supplied or previously failed module. Completed modules
    /// remain available if a later module fails.
    fn analyze(self: *Project) !void {
        var index: usize = 0;
        while (index < self.modules.items.len) : (index += 1) {
            const module = &self.modules.items[index];
            if (module.source != null and module.state != .complete) {
                _ = try self.analyzeModule(module.id);
            }
        }
    }

    fn submit(self: *Project, source: contracts.ModuleSource, is_root: bool) !void {
        const logical_name = try self.allocator.dupe(u8, source.logical_name);
        errdefer self.allocator.free(logical_name);
        const bytes = try self.allocator.dupe(u8, source.bytes);
        errdefer self.allocator.free(bytes);
        const owned: contracts.ModuleSource = .{
            .id = source.id,
            .logical_name = logical_name,
            .bytes = bytes,
            .kind = source.kind,
            .revision = source.revision,
        };

        if (self.findMut(source.id)) |module| {
            if (module.source) |previous| {
                if (source.revision < previous.revision) return error.StaleRevision;
                if (source.revision == previous.revision) {
                    const identical = source.kind == previous.kind and
                        std.mem.eql(u8, source.logical_name, previous.logical_name) and
                        std.mem.eql(u8, source.bytes, previous.bytes);
                    if (identical) return error.DuplicateModule;
                    return error.RevisionConflict;
                }
                self.requests.invalidateImporter(source.id);
                self.graph.invalidateImporter(source.id);
                self.clearProjectSemantics();
                self.clearResult(module);
                self.freeSource(previous);
            }
            module.source = owned;
            module.state = .supplied;
            module.metadata_derived = false;
            module.is_root = module.is_root or is_root;
            return;
        }

        try self.modules.append(self.allocator, .{
            .id = source.id,
            .state = .supplied,
            .is_root = is_root,
            .source = owned,
            .semantic_result = null,
            .metadata_derived = false,
        });
    }

    fn clearProjectSemantics(self: *Project) void {
        self.clearProjectHir();
        if (self.project_semantics) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.project_semantics = null;
        }
    }

    fn clearProjectHir(self: *Project) void {
        if (self.project_hir) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.project_hir = null;
        }
    }

    fn deriveModuleMetadata(self: *Project, id: contracts.ModuleId) !void {
        const module = self.find(id) orelse return error.UnknownModule;
        if (module.metadata_derived) return;
        const result = module.semantic_result orelse return error.ModuleNotAnalyzed;
        const edge_start = self.graph.edges.items.len;
        errdefer self.graph.edges.shrinkRetainingCapacity(edge_start);

        for (result.frontend.ast.nodes) |node| switch (node.data) {
            .ImportDeclaration => |decl| try self.appendDerivedEdge(
                id,
                decl.source,
                if (decl.type_only) .type_only else .static,
                decl.kind,
                decl.attributes,
                decl.source_span,
            ),
            .ExportDeclaration => |decl| if (decl.source.len != 0) try self.appendDerivedEdge(
                id,
                decl.source,
                .re_export,
                .named,
                null,
                decl.source_span orelse node.span,
            ),
            .ImportExpression => |expr| switch (result.frontend.ast.node(expr.source).data) {
                .Literal => |literal| try self.appendDerivedEdge(
                    id,
                    literal.value,
                    .dynamic,
                    .side_effect,
                    expr.attributes,
                    result.frontend.ast.node(expr.source).span,
                ),
                else => {},
            },
            else => {},
        };

        try self.graph.recordModule(.{
            .id = id,
            .imports = result.frontend.bind.module.imports,
            .exports = result.frontend.bind.module.exports,
        });
        self.findMut(id).?.metadata_derived = true;
    }

    fn appendDerivedEdge(
        self: *Project,
        importer: contracts.ModuleId,
        raw_specifier: []const u8,
        kind: contracts.RequestKind,
        import_kind: ast.ImportKind,
        source_attributes: ?ast.ImportAttributes,
        span: contracts.SourceSpan,
    ) !void {
        var attributes: std.ArrayList(contracts.RequestAttribute) = .empty;
        defer attributes.deinit(self.allocator);
        if (source_attributes) |source| for (source.entries) |attribute| {
            const value = switch (self.find(importer).?.semantic_result.?.frontend.ast.node(attribute.value).data) {
                .Literal => |literal| literal.value,
                else => "",
            };
            try attributes.append(self.allocator, .{ .key = attribute.key, .value = value, .span = attribute.span });
        };
        const request_id = try self.queueRequest(.{
            .importer = importer,
            .raw_specifier = raw_specifier,
            .kind = kind,
            .attributes = attributes.items,
            .span = span,
        });
        const owned_request = self.requests.lookup(request_id).?.request;
        try self.graph.appendEdge(.{
            .request_id = request_id,
            .importer = importer,
            .raw_specifier = owned_request.raw_specifier,
            .kind = kind,
            .import_kind = import_kind,
            .span = span,
        });
    }

    fn buildProjectSemantics(self: *Project) !void {
        self.clearProjectSemantics();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();

        var graph_modules: std.ArrayList(modules_mod.Module) = .empty;
        var entry: modules_mod.ModuleId = 0;
        var have_entry = false;
        for (self.modules.items) |module| {
            const result = module.semantic_result orelse continue;
            const source = module.source orelse continue;
            const module_id = module.id.value();
            try graph_modules.append(allocator, .{
                .id = module_id,
                .path = source.logical_name,
                .display_path = source.logical_name,
                .source_path = source.logical_name,
                .result = result.frontend,
                .text = source.bytes,
            });
            if (!have_entry or module.is_root) {
                entry = module_id;
                have_entry = true;
            }
        }

        var graph_edges: std.ArrayList(modules_mod.ImportEdge) = .empty;
        for (self.graph.edges.items) |edge| {
            if (edge.state == .stale or edge.kind == .dynamic) continue;
            const status: modules_mod.ImportStatus = switch (edge.state) {
                .resolved => .local,
                .external => .external,
                .unresolved, .not_found, .denied, .failed => .missing,
                .stale => unreachable,
            };
            try graph_edges.append(allocator, .{
                .id = @intCast(graph_edges.items.len),
                .from = edge.importer.value(),
                .to = if (edge.target) |target| target.value() else null,
                .specifier = edge.raw_specifier,
                .kind = edge.import_kind,
                .type_only = edge.kind == .type_only,
                .re_export = edge.kind == .re_export,
                .status = status,
                .span = edge.span,
            });
        }

        var linked_imports: std.ArrayList(modules_mod.LinkedImport) = .empty;
        for (graph_modules.items) |module| {
            for (module.result.ast.nodes) |node| {
                if (node.data != .ImportDeclaration) continue;
                const decl = node.data.ImportDeclaration;
                const edge = findSemanticEdge(graph_edges.items, module.id, decl.source, false) orelse continue;
                for (decl.specifiers) |specifier| {
                    const target_module = if (edge.to) |target_id| findSemanticModule(graph_modules.items, target_id) else null;
                    const target_symbol = if (target_module) |target|
                        if (specifier.kind == .namespace) null else modules_mod.linker.findExportedSymbol(target, specifier.imported_name)
                    else
                        null;
                    try linked_imports.append(allocator, .{
                        .id = @intCast(linked_imports.items.len),
                        .from_module = module.id,
                        .import_edge = edge.id,
                        .import_symbol = findImportSymbol(module.result.bind.symbols, specifier.local_name),
                        .local_name = specifier.local_name,
                        .imported_name = specifier.imported_name,
                        .target_module = edge.to,
                        .target_symbol = target_symbol,
                        .kind = switch (edge.status) {
                            .external => .external,
                            .missing => .unresolved,
                            .local => switch (specifier.kind) {
                                .namespace => .namespace,
                                .named => if (target_symbol != null) .named else .unresolved,
                                .default => if (target_symbol != null) .default else .unresolved,
                            },
                        },
                        .span = specifier.local_span,
                    });
                }
            }
        }

        var placeholder_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer placeholder_arena.deinit();
        const semantic_graph: modules_mod.ModuleGraph = .{
            .arena = placeholder_arena,
            .entry = entry,
            .modules = graph_modules.items,
            .imports = graph_edges.items,
            .linked_imports = linked_imports.items,
            .diagnostics = &.{},
        };
        const result = try self.allocator.create(semantics.BorrowedProjectSemanticResult);
        errdefer self.allocator.destroy(result);
        result.* = try semantics.analyzeBorrowedModuleGraph(self.allocator, &semantic_graph);
        try self.linkExternalImports(result);
        self.project_semantics = result;
    }

    fn linkExternalImports(self: *Project, result: *semantics.BorrowedProjectSemanticResult) !void {
        const allocator = result.arena.allocator();
        for (result.imports) |*item| {
            if (item.state != .external) continue;
            const import_record = self.findImportRecord(item.module_id, item.local_name) orelse continue;
            const edge = self.findExternalEdge(item.module_id, import_record.source) orelse continue;
            const external_id = edge.external_target orelse continue;
            const external = self.findExternal(external_id) orelse continue;

            if (import_record.kind == .namespace) {
                var properties: std.ArrayList(types.ObjectProperty) = .empty;
                for (external.exports) |exported| {
                    if (exported.type_only) continue;
                    try properties.append(allocator, .{
                        .name = exported.name,
                        .type_id = externalTypeId(&result.type_store.builtins, exported.type_metadata),
                    });
                }
                item.state = .namespace;
                item.runtime_binding = !item.type_only;
                item.target = .{
                    .symbol_id = null,
                    .declaration = types.SemanticDeclId.init(0, ast.invalid_node),
                    .type_id = if (properties.items.len == 0)
                        result.type_store.builtins.unknown
                    else
                        try result.type_store.intern(.{ .object = properties.items }),
                    .namespace = if (item.type_only) .type else .value,
                    .external_module_id = external_id.value(),
                };
                continue;
            }

            const exported = findExternalExport(external.exports, item.imported_name, import_record.kind, item.type_only);
            if (exported == null) {
                item.state = .unresolved;
                item.runtime_binding = false;
                item.target = null;
                result.is_partial = true;
                try self.graph.recordMissingExternalExport(edge.*);
                continue;
            }
            item.target = .{
                .symbol_id = null,
                .declaration = types.SemanticDeclId.init(0, ast.invalid_node),
                .type_id = externalTypeId(&result.type_store.builtins, exported.?.type_metadata),
                .namespace = if (item.type_only) .type else .value,
                .external_module_id = external_id.value(),
            };
            item.runtime_binding = !item.type_only;
        }
    }

    fn findImportRecord(self: *const Project, module_id: semantics.ModuleId, local_name: []const u8) ?binder.ImportRecord {
        const module = self.find(contracts.ModuleId.init(module_id)) orelse return null;
        const result = module.semantic_result orelse return null;
        for (result.frontend.bind.module.imports) |record| {
            if (std.mem.eql(u8, record.local_name, local_name)) return record;
        }
        return null;
    }

    fn findExternalEdge(self: *const Project, importer: semantics.ModuleId, source: []const u8) ?*const project_graph.Edge {
        for (self.graph.edges.items) |*edge| {
            if (edge.importer.value() == importer and edge.state == .external and std.mem.eql(u8, edge.raw_specifier, source)) return edge;
        }
        return null;
    }

    fn findExternal(self: *const Project, id: contracts.ExternalModuleId) ?contracts.ExternalModuleDescriptor {
        for (self.external_modules.items) |module| if (module.descriptor.id == id) return module.descriptor;
        return null;
    }

    fn registerExternalModule(self: *Project, descriptor: contracts.ExternalModuleDescriptor) !void {
        if (self.findExternal(descriptor.id)) |existing| {
            if (externalDescriptorsEqual(existing, descriptor)) return;
            return error.ExternalDescriptorConflict;
        }
        const owned = try self.copyExternalDescriptor(descriptor);
        errdefer self.freeExternalDescriptor(owned);
        try self.external_modules.append(self.allocator, .{ .descriptor = owned });
    }

    fn copyExternalDescriptor(self: *Project, source: contracts.ExternalModuleDescriptor) !contracts.ExternalModuleDescriptor {
        const logical_name = try self.allocator.dupe(u8, source.logical_name);
        errdefer self.allocator.free(logical_name);
        const exports = try self.allocator.alloc(contracts.ExternalExportDescriptor, source.exports.len);
        var initialized: usize = 0;
        errdefer {
            for (exports[0..initialized]) |item| self.allocator.free(item.name);
            self.allocator.free(exports);
        }
        for (source.exports, 0..) |item, index| {
            exports[index] = item;
            exports[index].name = try self.allocator.dupe(u8, item.name);
            initialized += 1;
        }
        return .{ .id = source.id, .logical_name = logical_name, .exports = exports };
    }

    fn freeExternalDescriptor(self: *Project, descriptor: contracts.ExternalModuleDescriptor) void {
        for (descriptor.exports) |item| self.allocator.free(item.name);
        self.allocator.free(descriptor.exports);
        self.allocator.free(descriptor.logical_name);
    }

    fn findSemanticModule(items: []const modules_mod.Module, id: modules_mod.ModuleId) ?*const modules_mod.Module {
        for (items) |*module| if (module.id == id) return module;
        return null;
    }

    fn findSemanticEdge(items: []const modules_mod.ImportEdge, from: modules_mod.ModuleId, specifier: []const u8, re_export: bool) ?modules_mod.ImportEdge {
        for (items) |edge| {
            if (edge.from == from and edge.re_export == re_export and std.mem.eql(u8, edge.specifier, specifier)) return edge;
        }
        return null;
    }

    fn findImportSymbol(symbols: []const binder.Symbol, local_name: []const u8) ?binder.SymbolId {
        for (symbols) |symbol| if (symbol.kind == .import and std.mem.eql(u8, symbol.name, local_name)) return symbol.id;
        return null;
    }

    fn find(self: *const Project, id: contracts.ModuleId) ?*const Module {
        for (self.modules.items) |*module| if (module.id == id) return module;
        return null;
    }

    fn findMut(self: *Project, id: contracts.ModuleId) ?*Module {
        for (self.modules.items) |*module| if (module.id == id) return module;
        return null;
    }

    fn clearResult(self: *Project, module: *Module) void {
        if (module.semantic_result) |result| {
            result.deinit();
            self.allocator.destroy(result);
            module.semantic_result = null;
        }
    }

    fn freeSource(self: *Project, source: contracts.ModuleSource) void {
        self.allocator.free(source.logical_name);
        self.allocator.free(source.bytes);
    }

    fn deinitModule(self: *Project, module: *Module) void {
        self.clearResult(module);
        if (module.source) |source| self.freeSource(source);
    }
};

fn validateExternalDescriptor(descriptor: contracts.ExternalModuleDescriptor) !void {
    for (descriptor.exports, 0..) |item, index| {
        if (item.name.len == 0) return error.InvalidExternalExport;
        switch (item.kind) {
            .default => if (!std.mem.eql(u8, item.name, "default")) return error.InvalidExternalExport,
            .named, .namespace => if (std.mem.eql(u8, item.name, "default")) return error.InvalidExternalExport,
        }
        for (descriptor.exports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, item.name)) return error.DuplicateExternalExport;
        }
    }
}

fn externalDescriptorsEqual(left: contracts.ExternalModuleDescriptor, right: contracts.ExternalModuleDescriptor) bool {
    if (left.id != right.id or !std.mem.eql(u8, left.logical_name, right.logical_name) or left.exports.len != right.exports.len) return false;
    for (left.exports, right.exports) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.kind != b.kind or a.type_only != b.type_only or a.type_metadata != b.type_metadata) return false;
    }
    return true;
}

fn findExternalExport(
    exports: []const contracts.ExternalExportDescriptor,
    name: []const u8,
    import_kind: ast.ImportSpecifierKind,
    type_only: bool,
) ?contracts.ExternalExportDescriptor {
    for (exports) |item| {
        const kind_matches = switch (import_kind) {
            .default => item.kind == .default,
            .named => item.kind == .named or item.kind == .namespace,
            .namespace => unreachable,
        };
        if (!kind_matches or item.type_only != type_only or !std.mem.eql(u8, item.name, name)) continue;
        return item;
    }
    return null;
}

fn externalTypeId(builtins: *const types.Builtins, metadata: ?contracts.ExternalType) types.TypeId {
    return switch (metadata orelse .unknown) {
        .unknown => builtins.unknown,
        .any => builtins.any,
        .never => builtins.never,
        .void => builtins.void,
        .undefined => builtins.undefined,
        .null_ => builtins.null_,
        .boolean => builtins.boolean,
        .number => builtins.number,
        .bigint => builtins.bigint,
        .string => builtins.string,
        .symbol => builtins.symbol,
        .object => builtins.object,
    };
}

test "project copies host buffers and analyzes one in-memory root" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    const name = try std.testing.allocator.dupe(u8, "memory:root");
    const bytes = try std.testing.allocator.dupe(u8, "export const answer = 42;");
    try project.addRoot(.{ .id = .init(1), .logical_name = name, .bytes = bytes });
    std.testing.allocator.free(name);
    std.testing.allocator.free(bytes);

    const result = try project.analyzeModule(.init(1));
    try std.testing.expectEqual(ModuleState.complete, project.state(.init(1)));
    try std.testing.expectEqualStrings("memory:root", result.module.path);
    try std.testing.expectEqual(@as(usize, 0), result.syntax_diagnostics.len);
}

test "multiple roots share one requested dependency identity" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    try project.addRoot(.{ .id = .init(1), .logical_name = "root-a", .bytes = "import './shared';" });
    try project.addRoot(.{ .id = .init(2), .logical_name = "root-b", .bytes = "import './shared';" });
    try project.requestModule(.init(3));
    try project.requestModule(.init(3));
    try project.supplySource(.{ .id = .init(3), .logical_name = "shared", .bytes = "export {};" });

    try std.testing.expectEqual(@as(usize, 3), project.moduleCount());
    try std.testing.expectEqual(ModuleState.supplied, project.state(.init(3)));
}

test "duplicate identities and revisions have explicit behavior" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    const original: contracts.ModuleSource = .{ .id = .init(7), .logical_name = "item", .bytes = "let x = 1;", .revision = 4 };
    try project.supplySource(original);
    try std.testing.expectError(error.DuplicateModule, project.supplySource(original));
    try std.testing.expectError(error.RevisionConflict, project.supplySource(.{ .id = .init(7), .logical_name = "item", .bytes = "let x = 2;", .revision = 4 }));
    try std.testing.expectError(error.StaleRevision, project.supplySource(.{ .id = .init(7), .logical_name = "item", .bytes = "old", .revision = 3 }));
    try project.supplySource(.{ .id = .init(7), .logical_name = "renamed", .bytes = "let x = 2;", .revision = 5 });
    try std.testing.expectEqualStrings("renamed", project.lookup(.init(7)).?.source.?.logical_name);
}

test "repeated analysis reuses a completed revision and replacement reanalyzes" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    try project.addRoot(.{ .id = .init(8), .logical_name = "root", .bytes = "let x = 1;", .revision = 1 });
    const first = try project.analyzeModule(.init(8));
    const repeated = try project.analyzeModule(.init(8));
    try std.testing.expectEqual(first, repeated);

    try project.supplySource(.{ .id = .init(8), .logical_name = "root", .bytes = "let x = 2;", .revision = 2 });
    try std.testing.expectEqual(ModuleState.supplied, project.state(.init(8)));
    _ = try project.analyzeModule(.init(8));
    try std.testing.expectEqual(ModuleState.complete, project.state(.init(8)));
}

test "failed module preserves completed module and teardown remains complete" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var project = Project.init(failing.allocator());
    defer project.deinit();

    try project.addRoot(.{ .id = .init(1), .logical_name = "good", .bytes = "export {};" });
    try project.supplySource(.{ .id = .init(2), .logical_name = "bad", .bytes = "let x = 1;" });
    _ = try project.analyzeModule(.init(1));

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, project.analyzeModule(.init(2)));
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(ModuleState.complete, project.state(.init(1)));
    try std.testing.expectEqual(ModuleState.failed, project.state(.init(2)));
    try std.testing.expectEqual(@as(usize, 0), project.lookup(.init(1)).?.diagnostics().len);
}

test "step is deterministic, deduplicates requests, and enforces response order" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(1), .logical_name = "root", .bytes = "export {};" });
    _ = try project.analyzeModule(.init(1));

    const first = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./a", .kind = .static, .span = .{ .start = 1, .end = 4, .line = 1, .column = 1 } });
    const duplicate = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./a", .kind = .static, .span = .{ .start = 10, .end = 13, .line = 2, .column = 1 } });
    const second = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./b", .kind = .dynamic, .span = .{ .start = 20, .end = 23, .line = 3, .column = 1 } });
    try std.testing.expectEqual(first, duplicate);

    const dispatched = (try project.step()).request;
    try std.testing.expectEqual(first, dispatched.id);
    try std.testing.expectEqual(first, (try project.step()).request.id);
    try std.testing.expectError(error.InvalidResponseOrder, project.respondDenied(second));
    try project.respondNotFound(first);
    try std.testing.expectEqual(second, (try project.step()).request.id);
    try project.respondDenied(second);
    try std.testing.expect((try project.step()) == .complete);

    const finished = try project.finish();
    try std.testing.expect(finished.has_failures);
}

test "responses reject foreign duplicate and stale request ids without mutation" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(4), .logical_name = "root", .bytes = "export {};", .revision = 1 });
    _ = try project.analyzeModule(.init(4));

    const external_id = try project.queueRequest(.{ .importer = .init(4), .raw_specifier = "runtime", .kind = .static, .span = .{ .start = 0, .end = 7, .line = 1, .column = 0 } });
    _ = try project.step();
    const external: contracts.ExternalModuleDescriptor = .{
        .id = .init(40),
        .logical_name = "runtime",
        .exports = &.{},
    };
    try std.testing.expectError(error.ForeignRequest, project.respondExternalModule(.init(999), external));
    try project.respondExternalModule(external_id, external);
    try std.testing.expectError(error.DuplicateResponse, project.respondExternalModule(external_id, external));

    const stale_id = try project.queueRequest(.{ .importer = .init(4), .raw_specifier = "./old", .kind = .re_export, .span = .{ .start = 8, .end = 13, .line = 2, .column = 0 } });
    _ = try project.step();
    try project.supplySource(.{ .id = .init(4), .logical_name = "root", .bytes = "export const next = 1;", .revision = 2 });
    try std.testing.expectError(error.StaleRequest, project.respondFailed(stale_id));
    try std.testing.expectEqual(ModuleState.supplied, project.state(.init(4)));
}

test "source responses close cycles without recursive callbacks" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    const source_a: contracts.ModuleSource = .{ .id = .init(11), .logical_name = "a", .bytes = "import './b'; export {};" };
    const source_b: contracts.ModuleSource = .{ .id = .init(12), .logical_name = "b", .bytes = "import './a'; export {};" };
    try project.addRoot(source_a);
    try project.supplySource(source_b);
    _ = try project.analyzeModule(source_a.id);
    _ = try project.analyzeModule(source_b.id);

    const a_to_b = try project.queueRequest(.{ .importer = source_a.id, .raw_specifier = "./b", .kind = .static, .span = .{ .start = 7, .end = 10, .line = 1, .column = 7 } });
    const b_to_a = try project.queueRequest(.{ .importer = source_b.id, .raw_specifier = "./a", .kind = .static, .span = .{ .start = 7, .end = 10, .line = 1, .column = 7 } });
    try std.testing.expectEqual(a_to_b, (try project.step()).request.id);
    try project.respondSource(a_to_b, source_b);
    try std.testing.expectEqual(b_to_a, (try project.step()).request.id);
    try project.respondSource(b_to_a, source_a);
    try std.testing.expect((try project.step()) == .complete);
    try std.testing.expect(!(try project.finish()).has_failures);
}

test "all terminal response kinds are inspectable and finish rejects pending work" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(20), .logical_name = "root", .bytes = "export {};" });
    _ = try project.analyzeModule(.init(20));

    const source_id = try project.queueRequest(.{ .importer = .init(20), .raw_specifier = "source", .kind = .static, .span = .{ .start = 0, .end = 1, .line = 1, .column = 0 } });
    try std.testing.expectError(error.PendingRequests, project.finish());
    _ = try project.step();
    try project.respondSource(source_id, .{ .id = .init(21), .logical_name = "dependency", .bytes = "export {};" });
    try std.testing.expectError(error.IncompleteModules, project.finish());
    _ = try project.analyzeModule(.init(21));

    const failed_id = try project.queueRequest(.{ .importer = .init(20), .raw_specifier = "failed", .kind = .type_only, .span = .{ .start = 2, .end = 3, .line = 1, .column = 2 } });
    _ = try project.step();
    try project.respondFailed(failed_id);
    try std.testing.expectEqual(state_machine.ResponseKind.source, project.lookupRequest(source_id).?.resolution.?.kind);
    try std.testing.expectEqual(state_machine.ResponseKind.failed, project.lookupRequest(failed_id).?.resolution.?.kind);
    try std.testing.expect((try project.finish()).has_failures);
}

test "source graph derives requests and preserves semantic identities with opaque module ids" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    const root_id = contracts.ModuleId.init(0x1_0000_0001);
    const dep_id = contracts.ModuleId.init(0x2_0000_0002);
    const types_id = contracts.ModuleId.init(0x3_0000_0003);
    const dep_source: contracts.ModuleSource = .{
        .id = dep_id,
        .logical_name = "dep",
        .bytes = "export default function main() {} export const value = 1;",
    };
    const types_source: contracts.ModuleSource = .{
        .id = types_id,
        .logical_name = "types",
        .bytes = "export interface Shape {}",
    };
    try project.addRoot(.{
        .id = root_id,
        .logical_name = "root",
        .bytes =
        \\import primary, { value as alias } from './dep';
        \\import * as ns from './dep';
        \\import type { Shape } from './types';
        \\export { value as again } from './dep';
        \\const lazy = import('./lazy');
        ,
    });

    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "./dep")) {
                try project.respondSource(request.id, dep_source);
            } else if (std.mem.eql(u8, request.raw_specifier, "./types")) {
                try project.respondSource(request.id, types_source);
            } else {
                try std.testing.expectEqual(contracts.RequestKind.dynamic, request.kind);
                try project.respondExternalModule(request.id, .{
                    .id = .init(0x4_0000_0004),
                    .logical_name = "lazy",
                    .exports = &.{},
                });
            }
        },
    };
    try std.testing.expect(!(try project.finish()).has_failures);

    var static_dep_edges: usize = 0;
    var saw_re_export = false;
    var saw_type_only = false;
    var saw_dynamic = false;
    for (project.edges()) |edge| {
        try std.testing.expectEqual(root_id, edge.importer);
        if (edge.kind == .static and std.mem.eql(u8, edge.raw_specifier, "./dep")) static_dep_edges += 1;
        if (edge.kind == .re_export) saw_re_export = edge.target == dep_id;
        if (edge.kind == .type_only) saw_type_only = edge.target == types_id;
        if (edge.kind == .dynamic) saw_dynamic = edge.state == .external;
    }
    try std.testing.expectEqual(@as(usize, 2), static_dep_edges);
    try std.testing.expect(saw_re_export and saw_type_only and saw_dynamic);

    const semantic = project.semanticResult().?;
    try std.testing.expect(semantic.lookupModule(root_id.value()) != null);
    try std.testing.expect(semantic.lookupExport(root_id.value(), "again") != null);
    var saw_default = false;
    var saw_named = false;
    var saw_namespace = false;
    var saw_type = false;
    for (semantic.imports) |item| {
        if (std.mem.eql(u8, item.local_name, "primary")) saw_default = item.state == .resolved;
        if (std.mem.eql(u8, item.local_name, "alias")) saw_named = item.state == .resolved;
        if (std.mem.eql(u8, item.local_name, "ns")) saw_namespace = item.state == .namespace;
        if (std.mem.eql(u8, item.local_name, "Shape")) saw_type = item.type_only and item.state == .resolved;
    }
    try std.testing.expect(saw_default and saw_named and saw_namespace and saw_type);
}

test "source graph closes cycles and reports stable host failures" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    const source_a: contracts.ModuleSource = .{
        .id = .init(71),
        .logical_name = "a",
        .bytes = "import { b } from './b'; import './missing'; export const a = b;",
    };
    const source_b: contracts.ModuleSource = .{
        .id = .init(72),
        .logical_name = "b",
        .bytes = "import { a } from './a'; export const b = a;",
    };
    try project.addRoot(source_a);

    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "./a")) {
                try project.respondSource(request.id, source_a);
            } else if (std.mem.eql(u8, request.raw_specifier, "./b")) {
                try project.respondSource(request.id, source_b);
            } else {
                try project.respondNotFound(request.id);
            }
        },
    };
    const finished = try project.finish();
    try std.testing.expect(finished.has_failures);
    try std.testing.expectEqual(@as(usize, 1), project.graphDiagnostics().len);
    const diagnostic = project.graphDiagnostics()[0];
    try std.testing.expectEqual(project_graph.DiagnosticCode.module_not_found, diagnostic.code);
    try std.testing.expectEqualStrings("./missing", diagnostic.raw_specifier);
    try std.testing.expect(project.semanticResult().?.lookupModule(source_b.id.value()) != null);
}

test "external descriptors link default named namespace exports with explicit type policy" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    const shared_numeric_id: u64 = 401;
    try project.addRoot(.{
        .id = .init(shared_numeric_id),
        .logical_name = "root",
        .bytes =
        \\import main, { readFile, loose, unsafe, platform } from 'native:fs';
        \\import * as runtime from 'native:fs';
        ,
    });
    const request = switch (try project.step()) {
        .request => |value| value,
        .complete => return error.TestExpectedRequest,
    };
    var logical_name = [_]u8{ 'n', 'a', 't', 'i', 'v', 'e', ':', 'f', 's' };
    var read_file_name = [_]u8{ 'r', 'e', 'a', 'd', 'F', 'i', 'l', 'e' };
    const exports = [_]contracts.ExternalExportDescriptor{
        .{ .name = "default", .kind = .default, .type_metadata = .object },
        .{ .name = read_file_name[0..], .type_metadata = .string },
        .{ .name = "loose" },
        .{ .name = "unsafe", .type_metadata = .any },
        .{ .name = "platform", .kind = .namespace, .type_metadata = .object },
    };
    try project.respondExternalModule(request.id, .{
        .id = .init(shared_numeric_id),
        .logical_name = logical_name[0..],
        .exports = &exports,
    });
    logical_name[0] = 'X';
    read_file_name[0] = 'X';
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |duplicate| try project.respondExternalModule(duplicate.id, .{
            .id = .init(shared_numeric_id),
            .logical_name = "native:fs",
            .exports = &exports,
        }),
    };
    try std.testing.expect(!(try project.finish()).has_failures);

    const result = project.semanticResult().?;
    var saw: usize = 0;
    for (result.imports) |item| {
        const target = item.target orelse continue;
        try std.testing.expectEqual(shared_numeric_id, target.external_module_id.?);
        if (std.mem.eql(u8, item.local_name, "main")) {
            try std.testing.expectEqual(result.type_store.builtins.object, target.type_id);
            saw += 1;
        } else if (std.mem.eql(u8, item.local_name, "readFile")) {
            try std.testing.expectEqual(result.type_store.builtins.string, target.type_id);
            saw += 1;
        } else if (std.mem.eql(u8, item.local_name, "loose")) {
            try std.testing.expectEqual(result.type_store.builtins.unknown, target.type_id);
            saw += 1;
        } else if (std.mem.eql(u8, item.local_name, "unsafe")) {
            try std.testing.expectEqual(result.type_store.builtins.any, target.type_id);
            saw += 1;
        } else if (std.mem.eql(u8, item.local_name, "platform")) {
            try std.testing.expectEqual(result.type_store.builtins.object, target.type_id);
            saw += 1;
        } else if (std.mem.eql(u8, item.local_name, "runtime")) {
            try std.testing.expectEqual(semantics.SemanticLinkState.namespace, item.state);
            try std.testing.expect(target.type_id != result.type_store.builtins.unknown);
            saw += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 6), saw);
    try std.testing.expectEqual(contracts.ExternalModuleId.init(shared_numeric_id), project.edges()[0].external_target.?);
    try std.testing.expect(project.edges()[0].target == null);
}

test "external descriptors report missing members and preserve type-only imports" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(402),
        .logical_name = "root",
        .bytes =
        \\import { absent } from 'native:types';
        \\import type { NativeShape } from 'native:types';
        ,
    });
    const descriptor: contracts.ExternalModuleDescriptor = .{
        .id = .init(9002),
        .logical_name = "native:types",
        .exports = &.{
            .{ .name = "present", .type_metadata = .boolean },
            .{ .name = "NativeShape", .type_only = true, .type_metadata = .object },
        },
    };
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, descriptor),
    };
    _ = try project.finish();

    const result = project.semanticResult().?;
    try std.testing.expect(result.is_partial);
    var saw_missing = false;
    var saw_type = false;
    for (result.imports) |item| {
        if (std.mem.eql(u8, item.local_name, "absent")) {
            saw_missing = item.state == .unresolved and item.target == null;
        } else if (std.mem.eql(u8, item.local_name, "NativeShape")) {
            saw_type = item.type_only and !item.runtime_binding and item.target.?.namespace == .type and
                item.target.?.type_id == result.type_store.builtins.object and
                item.target.?.external_module_id.? == descriptor.id.value();
        }
    }
    try std.testing.expect(saw_missing and saw_type);
    try std.testing.expectEqual(@as(usize, 1), project.graphDiagnostics().len);
    try std.testing.expectEqual(project_graph.DiagnosticCode.external_missing_export, project.graphDiagnostics()[0].code);
}

test "external descriptor validation rejects malformed duplicate and conflicting tables" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(403),
        .logical_name = "root",
        .bytes = "import { one } from 'first'; import { two } from 'second';",
    });
    const first = switch (try project.step()) {
        .request => |value| value,
        .complete => return error.TestExpectedRequest,
    };
    try std.testing.expectError(error.InvalidExternalExport, project.respondExternalModule(first.id, .{
        .id = .init(1),
        .logical_name = "bad",
        .exports = &.{.{ .name = "wrong", .kind = .default }},
    }));
    try std.testing.expectError(error.DuplicateExternalExport, project.respondExternalModule(first.id, .{
        .id = .init(1),
        .logical_name = "bad",
        .exports = &.{ .{ .name = "one" }, .{ .name = "one", .type_metadata = .number } },
    }));
    const accepted: contracts.ExternalModuleDescriptor = .{
        .id = .init(1),
        .logical_name = "native:first",
        .exports = &.{.{ .name = "one", .type_metadata = .number }},
    };
    try project.respondExternalModule(first.id, accepted);

    const second = switch (try project.step()) {
        .request => |value| value,
        .complete => return error.TestExpectedRequest,
    };
    try std.testing.expectError(error.ExternalDescriptorConflict, project.respondExternalModule(second.id, .{
        .id = accepted.id,
        .logical_name = accepted.logical_name,
        .exports = &.{.{ .name = "two", .type_metadata = .string }},
    }));
    try project.respondExternalModule(second.id, .{
        .id = .init(2),
        .logical_name = "native:second",
        .exports = &.{.{ .name = "two", .type_metadata = .string }},
    });
    while (try project.step() != .complete) {}
    try std.testing.expect(!(try project.finish()).has_failures);
}
