//! Owned, environment-neutral project session.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const contracts = @import("contracts.zig");
const diagnostics = @import("../diagnostics/root.zig");
const frontend = @import("../frontend/frontend.zig");
const hir_result = @import("../hir/result.zig");
const tokens = @import("../frontend/tokens.zig");
const modules_mod = @import("../modules/root.zig");
const semantics = @import("../semantics/root.zig");
const types = @import("../types/root.zig");
const project_graph = @import("graph.zig");
const state_machine = @import("state_machine.zig");

const ReachableClosure = std.AutoHashMap(u64, void);

pub const ProjectLimits = struct {
    max_source_bytes: usize = tokens.MAX_SOURCE_LENGTH,
    max_total_source_bytes: usize = std.math.maxInt(usize),
    max_modules: usize = std.math.maxInt(usize),
    max_requests: usize = std.math.maxInt(usize),
    max_edges: usize = std.math.maxInt(usize),
    max_diagnostics: usize = std.math.maxInt(usize),
    max_graph_depth: usize = std.math.maxInt(usize),
    max_semantic_types: usize = std.math.maxInt(usize),
};

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

/// Stable project-result diagnostic phases. These deliberately describe the
/// public project pipeline rather than every internal implementation pass.
pub const ProjectDiagnosticPhase = enum(u8) {
    scanner,
    parser,
    binder,
    resolver,
    types,
    checker,
    module_host,
    project,
};

/// One project-owned canonical diagnostic. `logical_name` is descriptive
/// only; `module_id` is the sole module identity carried by this record.
pub const ProjectDiagnostic = struct {
    module_id: ?contracts.ModuleId,
    phase: ProjectDiagnosticPhase,
    severity: diagnostics.Severity,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
    logical_name: []const u8,
    span: contracts.SourceSpan,
};

/// One project-owned module record. Source slices and the semantic result stay
/// valid until the Project is deinitialized. Projects are one-shot: a ModuleId
/// may receive source exactly once and finish is terminal.
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
    project_diagnostics: std.ArrayList(ProjectDiagnostic) = .empty,
    external_modules: std.ArrayList(OwnedExternalModule) = .empty,
    limits: ProjectLimits,
    total_source_bytes: usize = 0,
    finished: bool = false,
    finish_result: ?FinishResult = null,
    ambient_globals: std.ArrayList(contracts.AmbientGlobal) = .empty,
    source_host_bindings: std.ArrayList(contracts.SourceHostBinding) = .empty,

    pub fn init(allocator: std.mem.Allocator) Project {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: ProjectLimits) Project {
        return .{
            .allocator = allocator,
            .requests = .initWithLimit(allocator, limits.max_requests),
            .graph = .initWithLimits(allocator, .{
                .max_modules = limits.max_modules,
                .max_edges = limits.max_edges,
                .max_diagnostics = limits.max_diagnostics,
            }),
            .limits = limits,
        };
    }

    pub fn deinit(self: *Project) void {
        self.clearProjectSemantics();
        self.project_diagnostics.deinit(self.allocator);
        for (self.modules.items) |*module| self.deinitModule(module);
        self.modules.deinit(self.allocator);
        for (self.external_modules.items) |module| self.freeExternalDescriptor(module.descriptor);
        self.external_modules.deinit(self.allocator);
        for (self.ambient_globals.items) |g| {
            self.allocator.free(g.name);
            for (g.members) |member| self.allocator.free(member.name);
            self.allocator.free(g.members);
        }
        self.ambient_globals.deinit(self.allocator);
        for (self.source_host_bindings.items) |binding| self.allocator.free(binding.name);
        self.source_host_bindings.deinit(self.allocator);
        self.graph.deinit();
        self.requests.deinit();
        self.* = undefined;
    }

    pub fn moduleCount(self: *const Project) usize {
        return self.modules.items.len;
    }

    pub fn modulesView(self: *const Project) []const Module {
        return self.modules.items;
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
        defer self.debugAssertInvariants();
        if (self.findMut(id) != null) return;
        if (self.modules.items.len >= self.limits.max_modules) return error.ModuleLimitExceeded;
        try self.modules.append(self.allocator, .{
            .id = id,
            .state = .requested,
            .is_root = false,
            .source = null,
            .semantic_result = null,
            .metadata_derived = false,
        });
    }

    fn ensureOpen(self: *const Project) !void {
        if (self.finished) return error.ProjectFinished;
    }

    pub fn addRoot(self: *Project, source: contracts.ModuleSource) !void {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.submit(source, true);
    }

    /// Register ambient globals (e.g. a host clock) before any
    /// source is added so analysis can resolve them without synthetic source
    /// declarations. Copies the descriptor and all names. Must be called before `addRoot`/
    /// `supplySource`; late registration is rejected.
    pub fn registerAmbientGlobals(self: *Project, globals: []const contracts.AmbientGlobal) !void {
        try self.ensureOpen();
        if (self.modules.items.len > 0) return error.AmbientGlobalsLateRegistration;
        for (globals) |g| {
            if (g.name.len == 0) return error.InvalidAmbientGlobal;
            if (!g.namespace.isValid()) return error.InvalidAmbientGlobal;
            for (g.members) |member| {
                if (member.name.len == 0) return error.InvalidAmbientGlobal;
                if (member.self_reference) {
                    if (!member.readonly or member.optional or member.type_metadata != null) return error.InvalidAmbientGlobal;
                } else if (member.type_metadata == null) return error.InvalidAmbientGlobal;
            }
            for (self.ambient_globals.items) |existing| {
                const namespaces_overlap =
                    (existing.namespace.value and g.namespace.value) or
                    (existing.namespace.type and g.namespace.type);
                if (namespaces_overlap and std.mem.eql(u8, existing.name, g.name)) {
                    return error.DuplicateAmbientGlobal;
                }
            }
            const name_copy = try self.allocator.dupe(u8, g.name);
            errdefer self.allocator.free(name_copy);
            const members_copy = try self.allocator.alloc(contracts.AmbientMember, g.members.len);
            errdefer self.allocator.free(members_copy);
            var copied_members: usize = 0;
            errdefer for (members_copy[0..copied_members]) |member| self.allocator.free(member.name);
            for (g.members, 0..) |member, index| {
                members_copy[index] = member;
                members_copy[index].name = try self.allocator.dupe(u8, member.name);
                copied_members += 1;
            }
            try self.ambient_globals.append(self.allocator, .{
                .name = name_copy,
                .namespace = g.namespace,
                .type_metadata = g.type_metadata,
                .host_binding_id = g.host_binding_id,
                .members = members_copy,
            });
        }
    }

    /// Attach stable host identities to matching top-level source value
    /// declarations. Registration copies names and must precede all sources.
    pub fn registerSourceHostBindings(self: *Project, bindings: []const contracts.SourceHostBinding) !void {
        try self.ensureOpen();
        if (self.modules.items.len > 0) return error.SourceHostBindingsLateRegistration;
        for (bindings) |binding| {
            if (binding.name.len == 0) return error.InvalidSourceHostBinding;
            for (self.source_host_bindings.items) |existing| {
                if (std.mem.eql(u8, existing.name, binding.name) or
                    existing.host_binding_id == binding.host_binding_id)
                    return error.DuplicateSourceHostBinding;
            }
            const name_copy = try self.allocator.dupe(u8, binding.name);
            errdefer self.allocator.free(name_copy);
            try self.source_host_bindings.append(self.allocator, .{
                .name = name_copy,
                .host_binding_id = binding.host_binding_id,
            });
        }
    }

    pub fn supplySource(self: *Project, source: contracts.ModuleSource) !void {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.submit(source, false);
    }

    fn queueRequest(self: *Project, input: contracts.ModuleRequestInput) !contracts.RequestId {
        defer self.debugAssertInvariants();
        if (self.find(input.importer) == null) return error.UnknownImporter;
        return self.requests.enqueue(input);
    }

    pub fn step(self: *Project) !state_machine.Step {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.analyze();
        return self.requests.step();
    }

    pub fn edges(self: *const Project) []const project_graph.Edge {
        return self.graph.edges.items;
    }

    pub fn requestCount(self: *const Project) usize {
        return self.requests.count();
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
    pub fn installHirResult(self: *Project, result: hir_result.HirResult) !*const hir_result.HirResult {
        if (self.project_hir != null) return error.HirAlreadyDerived;
        const owned = try self.allocator.create(hir_result.HirResult);
        owned.* = result;
        self.project_hir = owned;
        return owned;
    }

    pub fn diagnostics(self: *const Project) []const ProjectDiagnostic {
        return self.project_diagnostics.items;
    }

    pub fn lookupRequest(self: *const Project, id: contracts.RequestId) ?state_machine.RequestRecord {
        return self.requests.lookup(id);
    }

    pub fn respondSource(self: *Project, id: contracts.RequestId, source: contracts.ModuleSource) !void {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.requests.validateResponse(id);
        var needs_supply = true;
        if (self.find(source.id)) |existing| {
            if (existing.source) |owned| {
                const identical = source.kind == owned.kind and
                    std.mem.eql(u8, source.logical_name, owned.logical_name) and
                    std.mem.eql(u8, source.bytes, owned.bytes);
                if (!identical) return error.DuplicateModule;
                needs_supply = false;
            }
        }
        if (needs_supply) try self.validateSubmission(source);
        try self.validateGraphDepthWithResolution(id, source.id);
        if (needs_supply) try self.supplySource(source);
        try self.requests.commitResponse(id, .{ .kind = .source, .module_id = source.id });
        try self.graph.resolve(id, .resolved, source.id);
        self.clearProjectSemantics();
    }

    /// Satisfy one request with copied source-less module metadata.
    pub fn respondExternalModule(self: *Project, id: contracts.RequestId, descriptor: contracts.ExternalModuleDescriptor) !void {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.requests.validateResponse(id);
        try validateExternalDescriptor(descriptor);
        try self.registerExternalModule(descriptor);
        try self.requests.commitResponse(id, .{ .kind = .external, .external_module_id = descriptor.id });
        self.graph.resolveExternal(id, descriptor.id);
        self.clearProjectSemantics();
    }

    pub fn respondNotFound(self: *Project, id: contracts.RequestId) !void {
        try self.commitFailureResponse(id, .not_found, .not_found);
    }

    pub fn respondDenied(self: *Project, id: contracts.RequestId) !void {
        try self.commitFailureResponse(id, .denied, .denied);
    }

    pub fn respondFailed(self: *Project, id: contracts.RequestId) !void {
        try self.commitFailureResponse(id, .failed, .failed);
    }

    fn commitFailureResponse(
        self: *Project,
        id: contracts.RequestId,
        response_kind: state_machine.ResponseKind,
        edge_state: project_graph.EdgeState,
    ) !void {
        defer self.debugAssertInvariants();
        try self.ensureOpen();
        try self.requests.validateResponse(id);
        const graph_checkpoint = self.graph.checkpoint();
        errdefer self.graph.rollback(graph_checkpoint);
        try self.graph.resolve(id, edge_state, null);
        try self.requests.commitResponse(id, .{ .kind = response_kind });
        self.clearProjectSemantics();
    }

    /// Finish is legal only after every request has a response and every source
    /// has reached complete or failed. It never performs hidden analysis.
    pub fn finish(self: *Project) !FinishResult {
        defer self.debugAssertInvariants();
        if (self.finish_result) |result| return result;
        var reachable = try self.computeReachableClosure();
        defer reachable.deinit();

        var has_failures = false;
        for (self.requests.recordsView()) |record| {
            if (!reachable.contains(record.request.importer.value())) continue;
            if (record.status == .queued or record.status == .waiting) return error.PendingRequests;
            if (record.resolution) |resolution| switch (resolution.kind) {
                .not_found, .denied, .failed => has_failures = true,
                .source, .external => {},
            };
        }
        for (self.modules.items) |module| {
            if (!reachable.contains(module.id.value())) continue;
            switch (module.state) {
                .complete => {},
                .failed => has_failures = true,
                .unseen, .requested, .supplied, .parsing, .analyzed, .external => return error.IncompleteModules,
            }
        }
        try self.validateGraphDepth();
        self.retainReachableClosure(&reachable);
        if (self.project_semantics == null) try self.buildProjectSemantics();
        const result: FinishResult = .{ .module_count = self.modules.items.len, .has_failures = has_failures };
        self.finish_result = result;
        self.finished = true;
        return result;
    }

    fn computeReachableClosure(self: *const Project) !ReachableClosure {
        var reachable = ReachableClosure.init(self.allocator);
        errdefer reachable.deinit();
        var pending: std.ArrayList(contracts.ModuleId) = .empty;
        defer pending.deinit(self.allocator);

        for (self.modules.items) |module| {
            if (!module.is_root) continue;
            const result = try reachable.getOrPut(module.id.value());
            if (!result.found_existing) try pending.append(self.allocator, module.id);
        }

        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const importer = pending.items[index];
            for (self.graph.edges.items) |edge| {
                if (edge.importer != importer or edge.state != .resolved) continue;
                const target = edge.target orelse continue;
                const result = try reachable.getOrPut(target.value());
                if (!result.found_existing) try pending.append(self.allocator, target);
            }
            for (self.requests.recordsView()) |record| {
                if (record.request.importer != importer) continue;
                const resolution = record.resolution orelse continue;
                const target = resolution.module_id orelse continue;
                const result = try reachable.getOrPut(target.value());
                if (!result.found_existing) try pending.append(self.allocator, target);
            }
        }
        return reachable;
    }

    fn validateGraphDepth(self: *const Project) !void {
        try self.validateGraphDepthWithResolution(null, null);
    }

    fn validateGraphDepthWithResolution(
        self: *const Project,
        request_id: ?contracts.RequestId,
        target: ?contracts.ModuleId,
    ) !void {
        var roots: std.ArrayList(contracts.ModuleId) = .empty;
        defer roots.deinit(self.allocator);
        for (self.modules.items) |module| if (module.is_root) try roots.append(self.allocator, module.id);

        var depths = try self.graph.shortestDepthsWithResolution(self.allocator, roots.items, request_id, target);
        defer depths.deinit();
        var iterator = depths.valueIterator();
        while (iterator.next()) |depth| {
            if (depth.* > self.limits.max_graph_depth) return error.GraphDepthLimitExceeded;
        }
    }

    fn retainReachableClosure(self: *Project, reachable: *const ReachableClosure) void {
        var write_index: usize = 0;
        for (self.modules.items, 0..) |*module, read_index| {
            if (!reachable.contains(module.id.value())) {
                self.deinitModule(module);
                continue;
            }
            if (write_index != read_index) {
                self.modules.items[write_index] = module.*;
            }
            write_index += 1;
        }
        self.modules.items.len = write_index;

        write_index = 0;
        for (self.graph.modules.items) |item| {
            if (!reachable.contains(item.id.value())) continue;
            self.graph.modules.items[write_index] = item;
            write_index += 1;
        }
        self.graph.modules.items.len = write_index;

        write_index = 0;
        for (self.graph.edges.items) |item| {
            if (!reachable.contains(item.importer.value())) continue;
            self.graph.edges.items[write_index] = item;
            write_index += 1;
        }
        self.graph.edges.items.len = write_index;

        write_index = 0;
        for (self.graph.diagnostics.items) |item| {
            if (!reachable.contains(item.importer.value())) continue;
            self.graph.diagnostics.items[write_index] = item;
            write_index += 1;
        }
        self.graph.diagnostics.items.len = write_index;
    }

    /// Analyze a supplied module. A completed module is returned without
    /// re-analysis. Allocation or internal analysis failures leave this
    /// module inspectably failed and do not modify other completed modules.
    fn analyzeModule(self: *Project, id: contracts.ModuleId) !*const semantics.SemanticResult {
        defer self.debugAssertInvariants();
        const initial = self.find(id) orelse return error.UnknownModule;
        if (initial.state == .complete) {
            if (!initial.metadata_derived) {
                try self.deriveModuleMetadata(id, initial.semantic_result.?);
                self.findMut(id).?.metadata_derived = true;
            }
            return self.find(id).?.semantic_result.?;
        }
        if (initial.source == null) return error.SourceNotSupplied;

        self.findMut(id).?.state = .parsing;
        const result_ptr = self.allocator.create(semantics.SemanticResult) catch |err| {
            self.findMut(id).?.state = .failed;
            return err;
        };
        var result_initialized = false;
        errdefer {
            if (result_initialized) result_ptr.deinit();
            self.allocator.destroy(result_ptr);
            const failed = self.findMut(id).?;
            failed.semantic_result = null;
            failed.metadata_derived = false;
            failed.state = .failed;
        }

        const source = self.find(id).?.source.?;
        result_ptr.* = try semantics.analyzeSourceWithLimits(self.allocator, .{
            .path = source.logical_name,
            .text = source.bytes,
            .kind = switch (source.kind) {
                .script => .script,
                .module => .module,
            },
        }, .{
            .ambient_globals = self.ambient_globals.items,
            .source_host_bindings = self.source_host_bindings.items,
        }, .{
            .max_types = self.limits.max_semantic_types,
            .max_diagnostics = self.limits.max_diagnostics,
        });
        result_initialized = true;

        const request_checkpoint = self.requests.checkpoint();
        const graph_checkpoint = self.graph.checkpoint();
        errdefer {
            self.requests.rollback(request_checkpoint);
            self.graph.rollback(graph_checkpoint);
        }

        try self.deriveModuleMetadata(id, result_ptr);
        const module = self.findMut(id).?;
        module.semantic_result = result_ptr;
        module.metadata_derived = true;
        module.state = .complete;
        self.clearProjectSemantics();
        return result_ptr;
    }

    /// Analyze every supplied or previously failed module. Completed modules
    /// remain available if a later module fails.
    fn analyze(self: *Project) !void {
        var index: usize = 0;
        while (index < self.modules.items.len) : (index += 1) {
            const module = &self.modules.items[index];
            if (module.source != null and module.state != .complete and self.isReachable(module.id)) {
                _ = try self.analyzeModule(module.id);
            }
        }
    }

    fn isReachable(self: *const Project, id: contracts.ModuleId) bool {
        const module = self.find(id) orelse return false;
        if (module.is_root) return true;
        for (self.graph.edges.items) |edge| {
            if (edge.state == .resolved and edge.target != null and edge.target.? == id) return true;
        }
        return false;
    }

    fn submit(self: *Project, source: contracts.ModuleSource, is_root: bool) !void {
        const existing = self.findMut(source.id);
        if (existing) |module| if (module.source != null) return error.DuplicateModule;
        try self.validateSubmission(source);

        const next_total = std.math.add(usize, self.total_source_bytes, source.bytes.len) catch unreachable;

        const logical_name = try self.allocator.dupe(u8, source.logical_name);
        errdefer self.allocator.free(logical_name);
        const bytes = try self.allocator.dupe(u8, source.bytes);
        errdefer self.allocator.free(bytes);
        const owned: contracts.ModuleSource = .{
            .id = source.id,
            .logical_name = logical_name,
            .bytes = bytes,
            .kind = source.kind,
        };

        if (existing) |module| {
            module.source = owned;
            module.state = .supplied;
            module.metadata_derived = false;
            module.is_root = module.is_root or is_root;
            self.total_source_bytes = next_total;
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
        self.total_source_bytes = next_total;
    }

    fn validateSubmission(self: *const Project, source: contracts.ModuleSource) !void {
        if (source.bytes.len > tokens.MAX_SOURCE_LENGTH) return error.SourceLimitExceeded;
        if (source.bytes.len > self.limits.max_source_bytes) return error.SourceLimitExceeded;
        const next_total = std.math.add(usize, self.total_source_bytes, source.bytes.len) catch
            return error.TotalSourceLimitExceeded;
        if (next_total > self.limits.max_total_source_bytes) return error.TotalSourceLimitExceeded;
        if (self.find(source.id) == null and self.modules.items.len >= self.limits.max_modules)
            return error.ModuleLimitExceeded;
    }

    fn clearProjectSemantics(self: *Project) void {
        if (self.project_hir) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.project_hir = null;
        }
        self.clearProjectDiagnostics();
        if (self.project_semantics) |result| {
            result.deinit();
            self.allocator.destroy(result);
            self.project_semantics = null;
        }
    }

    fn clearProjectDiagnostics(self: *Project) void {
        for (self.project_diagnostics.items) |item| {
            self.allocator.free(item.message);
            self.allocator.free(item.logical_name);
        }
        self.project_diagnostics.clearRetainingCapacity();
    }

    fn deriveModuleMetadata(self: *Project, id: contracts.ModuleId, result: *const semantics.SemanticResult) !void {
        const module = self.find(id) orelse return error.UnknownModule;
        if (module.metadata_derived) return;
        const edge_start = self.graph.edges.items.len;
        errdefer self.graph.edges.shrinkRetainingCapacity(edge_start);

        for (result.frontend.ast.nodes) |node| switch (node.data) {
            .ImportDeclaration => |decl| try self.appendDerivedEdge(
                id,
                decl.source,
                .static_import,
                decl.type_only,
                decl.kind,
                decl.attributes,
                decl.source_span,
                result,
            ),
            .ExportDeclaration => |decl| if (decl.source.len != 0) try self.appendDerivedEdge(
                id,
                decl.source,
                .re_export,
                decl.type_only,
                .named,
                null,
                decl.source_span orelse node.span,
                result,
            ),
            .ImportExpression => |expr| switch (result.frontend.ast.node(expr.source).data) {
                .Literal => |literal| try self.appendDerivedEdge(
                    id,
                    literal.value,
                    .dynamic_import,
                    false,
                    .side_effect,
                    expr.attributes,
                    result.frontend.ast.node(expr.source).span,
                    result,
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
    }

    fn appendDerivedEdge(
        self: *Project,
        importer: contracts.ModuleId,
        raw_specifier: []const u8,
        operation: contracts.RequestOperation,
        type_only: bool,
        import_kind: ast.ImportKind,
        source_attributes: ?ast.ImportAttributes,
        span: contracts.SourceSpan,
        semantic_result: *const semantics.SemanticResult,
    ) !void {
        try self.graph.ensureEdgeAvailable();
        var attributes: std.ArrayList(contracts.RequestAttribute) = .empty;
        defer attributes.deinit(self.allocator);
        if (source_attributes) |source| for (source.entries) |attribute| {
            const value = switch (semantic_result.frontend.ast.node(attribute.value).data) {
                .Literal => |literal| literal.value,
                else => "",
            };
            try attributes.append(self.allocator, .{ .key = attribute.key, .value = value, .span = attribute.span });
        };
        const request_id = try self.queueRequest(.{
            .importer = importer,
            .raw_specifier = raw_specifier,
            .operation = operation,
            .type_only = type_only,
            .attributes = attributes.items,
            .span = span,
        });
        const owned_request = self.requests.lookup(request_id).?.request;
        try self.graph.appendEdge(.{
            .request_id = request_id,
            .importer = importer,
            .raw_specifier = owned_request.raw_specifier,
            .operation = operation,
            .type_only = type_only,
            .import_kind = import_kind,
            .span = span,
        });
    }

    fn buildProjectSemantics(self: *Project) !void {
        self.clearProjectSemantics();
        const graph_checkpoint = self.graph.checkpoint();
        errdefer self.graph.rollback(graph_checkpoint);
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
        for (self.graph.edges.items, 0..) |edge, project_edge_index| {
            if (edge.operation == .dynamic_import) continue;
            const status: modules_mod.ImportStatus = switch (edge.state) {
                .resolved => .local,
                .external => .external,
                .unresolved, .not_found, .denied, .failed => .missing,
            };
            try graph_edges.append(allocator, .{
                .id = @intCast(graph_edges.items.len),
                .project_edge_index = project_edge_index,
                .from = edge.importer.value(),
                .to = if (edge.target) |target| target.value() else null,
                .external_to = if (edge.external_target) |target| target.value() else null,
                .specifier = edge.raw_specifier,
                .kind = edge.import_kind,
                .type_only = edge.type_only,
                .re_export = edge.operation == .re_export,
                .status = status,
                .span = edge.span,
            });
        }

        var graph_external_modules: std.ArrayList(modules_mod.graph.ExternalModule) = .empty;
        for (self.external_modules.items) |owned| {
            const descriptor = owned.descriptor;
            const graph_exports = try allocator.alloc(modules_mod.graph.ExternalExport, descriptor.exports.len);
            for (descriptor.exports, 0..) |exported, index| graph_exports[index] = .{
                .name = exported.name,
                .kind = @enumFromInt(@intFromEnum(exported.kind)),
                .namespace = .{ .value = exported.namespace.value, .type = exported.namespace.type },
                // A detailed function signature supersedes the coarse primitive
                // fallback. It is attached after graph linking, so exposing an
                // `object` fallback here would produce a premature not-callable
                // diagnostic before the external identity is enriched.
                .type_metadata = if (exported.function != null)
                    null
                else if (exported.type_metadata) |metadata|
                    @enumFromInt(@intFromEnum(metadata))
                else
                    null,
            };
            try graph_external_modules.append(allocator, .{
                .id = descriptor.id.value(),
                .logical_name = descriptor.logical_name,
                .exports = graph_exports,
            });
        }

        var linked_imports: std.ArrayList(modules_mod.LinkedImport) = .empty;
        for (graph_modules.items) |module| {
            for (module.result.ast.nodes) |node| {
                if (node.data != .ImportDeclaration) continue;
                const decl = node.data.ImportDeclaration;
                const edge = findSemanticEdge(graph_edges.items, module.id, decl.source_span, false) orelse continue;
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
            .external_modules = graph_external_modules.items,
            .diagnostics = &.{},
        };
        const result = try self.allocator.create(semantics.BorrowedProjectSemanticResult);
        errdefer self.allocator.destroy(result);
        result.* = try semantics.analyzeBorrowedModuleGraphWithLimits(
            self.allocator,
            &semantic_graph,
            .{
                .max_types = self.limits.max_semantic_types,
                .max_diagnostics = self.limits.max_diagnostics,
            },
        );
        errdefer result.deinit();
        try self.recordExternalLinkDiagnostics(result);
        try self.buildProjectDiagnostics(result);
        self.project_semantics = result;
    }

    fn buildProjectDiagnostics(self: *Project, result: *const semantics.BorrowedProjectSemanticResult) !void {
        std.debug.assert(self.project_diagnostics.items.len == 0);
        errdefer self.clearProjectDiagnostics();

        // Preserve every diagnostic produced by each reachable single-file
        // analysis while attaching its already-known host identity directly.
        for (self.modules.items) |module| {
            const semantic = module.semantic_result orelse continue;
            const source = module.source orelse continue;
            for (semantic.diagnostics) |item| try self.appendProjectDiagnostic(.{
                .module_id = module.id,
                .phase = canonicalPhase(item),
                .severity = item.severity,
                .code = item.code,
                .message = item.message,
                .logical_name = source.logical_name,
                .span = item.span,
            });
        }

        // Project semantic passes may add diagnostics beyond the single-file
        // result. Iterate modules, not the flattened diagnostic slice, so the
        // identity remains explicit even when logical names are duplicated.
        for (result.modules) |module| {
            const module_id = contracts.ModuleId.init(module.id);
            const source_module = self.find(module_id);
            const logical_name = if (source_module) |value|
                if (value.source) |source| source.logical_name else module.path
            else
                module.path;
            for (module.type_info.diagnostics) |item| try self.appendProjectDiagnostic(.{
                .module_id = module_id,
                .phase = canonicalPhase(item),
                .severity = item.severity,
                .code = item.code,
                .message = item.message,
                .logical_name = logical_name,
                .span = item.span,
            });
        }

        for (self.graph.diagnostics.items) |item| {
            const module = self.find(item.importer);
            const logical_name = if (module) |value|
                if (value.source) |source| source.logical_name else ""
            else
                "";
            const mapped = graphProjectDiagnostic(item.code);
            try self.appendProjectDiagnostic(.{
                .module_id = item.importer,
                .phase = mapped.phase,
                .severity = .@"error",
                .code = mapped.code,
                .message = mapped.message,
                .logical_name = logical_name,
                .span = item.span,
            });
        }
    }

    fn appendProjectDiagnostic(self: *Project, candidate: ProjectDiagnostic) !void {
        for (self.project_diagnostics.items) |existing| {
            if (projectDiagnosticsEqual(existing, candidate)) return;
        }
        if (self.project_diagnostics.items.len >= self.limits.max_diagnostics)
            return error.DiagnosticLimitExceeded;
        const message = try self.allocator.dupe(u8, candidate.message);
        errdefer self.allocator.free(message);
        const logical_name = try self.allocator.dupe(u8, candidate.logical_name);
        errdefer self.allocator.free(logical_name);
        var owned = candidate;
        owned.message = message;
        owned.logical_name = logical_name;
        try self.project_diagnostics.append(self.allocator, owned);
    }

    fn recordExternalLinkDiagnostics(self: *Project, result: *semantics.BorrowedProjectSemanticResult) !void {
        const allocator = result.arena.allocator();
        for (result.imports) |*item| {
            if (item.edge_index >= self.graph.edges.items.len) continue;
            const edge = self.graph.edges.items[item.edge_index];
            if (edge.state != .external) continue;
            const external_id = edge.external_target orelse continue;
            const external = self.findExternal(external_id) orelse continue;
            if (item.state == .namespace) continue;
            const import_kind: ast.ImportSpecifierKind = if (std.mem.eql(u8, item.imported_name, "default")) .default else .named;
            const exported = findExternalExport(external.exports, item.imported_name, import_kind, item.type_only);
            if (exported == null) {
                try self.graph.recordMissingExternalExport(edge);
                result.is_partial = true;
                continue;
            }
            const existing = item.target;
            item.target = .{
                .symbol_id = null,
                .declaration = if (existing) |identity|
                    identity.declaration
                else
                    types.SemanticDeclId.initExternal(external_id.value(), ast.invalid_node),
                .type_id = try externalDeclarationTypeId(
                    allocator,
                    &result.type_store,
                    exported.?,
                    if (existing) |identity| identity.type_id else null,
                ),
                .namespace = if (item.type_only) .type else .value,
                .external_module_id = external_id.value(),
                .external_symbol_id = if (exported.?.symbol_id) |id| id.value() else null,
                .external_declaration_kind = exported.?.declaration_kind,
                .external_effects = exported.?.effects,
            };
            if (item.type_only) item.type_target = item.target;
            item.state = .resolved;
            item.runtime_binding = !item.type_only;
        }

        for (result.exports) |*item| {
            const external_module_id = item.identity.external_module_id orelse continue;
            const external = self.findExternal(.init(external_module_id)) orelse continue;
            const import_kind: ast.ImportSpecifierKind = if (std.mem.eql(u8, item.name, "default")) .default else .named;
            const exported = findExternalExport(external.exports, item.name, import_kind, item.type_only) orelse continue;
            item.identity = try enrichExternalIdentity(allocator, &result.type_store, item.identity, exported);
            if (item.type_identity) |identity| {
                item.type_identity = try enrichExternalIdentity(allocator, &result.type_store, identity, exported);
            }
        }

        for (self.modules.items) |module| {
            const source_result = module.semantic_result orelse continue;
            for (source_result.frontend.bind.module.exports) |record| {
                if (record.source.len == 0 or record.kind == .export_all) continue;
                const node = source_result.frontend.ast.node(record.node);
                const source_span = node.data.ExportDeclaration.source_span orelse continue;
                const edge_index = self.findExternalReExportEdge(module.id, source_span) orelse continue;
                const edge = self.graph.edges.items[edge_index];
                const external_id = edge.external_target orelse continue;
                const external = self.findExternal(external_id) orelse continue;
                const import_kind: ast.ImportSpecifierKind = if (std.mem.eql(u8, record.local_name, "default")) .default else .named;
                if (findExternalExport(external.exports, record.local_name, import_kind, record.type_only) == null) {
                    try self.graph.recordMissingExternalExport(edge);
                    result.is_partial = true;
                }
            }
        }
    }

    fn findExternalReExportEdge(self: *const Project, importer: contracts.ModuleId, source_span: contracts.SourceSpan) ?usize {
        for (self.graph.edges.items, 0..) |edge, index| {
            if (edge.importer == importer and
                edge.operation == .re_export and
                edge.state == .external and
                std.meta.eql(edge.span, source_span)) return index;
        }
        return null;
    }

    fn findExternal(self: *const Project, id: contracts.ExternalModuleId) ?contracts.ExternalModuleDescriptor {
        for (self.external_modules.items) |module| if (module.descriptor.id == id) return module.descriptor;
        return null;
    }

    pub fn lookupExternalModule(self: *const Project, id: contracts.ExternalModuleId) ?contracts.ExternalModuleDescriptor {
        return self.findExternal(id);
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
            for (exports[0..initialized]) |item| freeExternalExport(self.allocator, item);
            self.allocator.free(exports);
        }
        for (source.exports, 0..) |item, index| {
            exports[index] = item;
            exports[index].name = try self.allocator.dupe(u8, item.name);
            if (item.function) |function| {
                const parameters = try self.allocator.alloc(contracts.ExternalParameterDescriptor, function.parameters.len);
                var parameter_count: usize = 0;
                errdefer {
                    for (parameters[0..parameter_count]) |parameter| self.allocator.free(parameter.name);
                    self.allocator.free(parameters);
                }
                for (function.parameters, 0..) |parameter, parameter_index| {
                    parameters[parameter_index] = parameter;
                    parameters[parameter_index].name = try self.allocator.dupe(u8, parameter.name);
                    parameter_count += 1;
                }
                exports[index].function.?.parameters = parameters;
            }
            initialized += 1;
        }
        return .{ .id = source.id, .logical_name = logical_name, .exports = exports };
    }

    fn freeExternalDescriptor(self: *Project, descriptor: contracts.ExternalModuleDescriptor) void {
        for (descriptor.exports) |item| freeExternalExport(self.allocator, item);
        self.allocator.free(descriptor.exports);
        self.allocator.free(descriptor.logical_name);
    }

    fn findSemanticModule(items: []const modules_mod.Module, id: modules_mod.ModuleId) ?*const modules_mod.Module {
        for (items) |*module| if (module.id == id) return module;
        return null;
    }

    fn findSemanticEdge(items: []const modules_mod.ImportEdge, from: modules_mod.ModuleId, span_value: contracts.SourceSpan, re_export: bool) ?modules_mod.ImportEdge {
        for (items) |edge| {
            if (edge.from == from and edge.re_export == re_export and std.meta.eql(edge.span, span_value)) return edge;
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

    /// Assert ownership and publication invariants at debug/test mutation boundaries.
    fn debugAssertInvariants(self: *const Project) void {
        self.requests.assertInvariants();
        std.debug.assert(self.modules.items.len <= self.limits.max_modules);
        std.debug.assert(self.graph.edges.items.len <= self.limits.max_edges);
        std.debug.assert(self.project_diagnostics.items.len <= self.limits.max_diagnostics);

        var source_bytes: usize = 0;
        for (self.modules.items, 0..) |module, index| {
            for (self.modules.items[0..index]) |previous| std.debug.assert(previous.id != module.id);
            if (module.source) |source| source_bytes += source.bytes.len;
            if (module.semantic_result == null) std.debug.assert(!module.metadata_derived);
            if (module.metadata_derived) {
                std.debug.assert(module.semantic_result != null);
                std.debug.assert(module.state == .complete);
            }
            switch (module.state) {
                .requested => std.debug.assert(module.source == null and module.semantic_result == null),
                .supplied, .parsing, .failed => std.debug.assert(module.semantic_result == null),
                .analyzed, .complete => std.debug.assert(module.semantic_result != null),
                .unseen, .external => {},
            }
        }
        std.debug.assert(source_bytes <= self.total_source_bytes);
        std.debug.assert(self.total_source_bytes <= self.limits.max_total_source_bytes);

        for (self.graph.edges.items) |edge| {
            const record = self.requests.lookup(edge.request_id) orelse unreachable;
            std.debug.assert(record.request.importer == edge.importer);
            std.debug.assert(std.mem.eql(u8, record.request.raw_specifier, edge.raw_specifier));
        }
        for (self.external_modules.items) |module| {
            for (module.descriptor.exports) |item| std.debug.assert(item.name.len != 0 and item.namespace.isValid());
        }
        if (self.project_semantics != null) {
            for (self.modules.items) |module| std.debug.assert(module.state == .complete or module.state == .failed);
        }
        std.debug.assert((self.finish_result != null) == self.finished);
    }
};

fn canonicalPhase(item: diagnostics.Diagnostic) ProjectDiagnosticPhase {
    return switch (item.phase) {
        .scanner => .scanner,
        .parser => .parser,
        .binder => .binder,
        .resolver => .resolver,
        .type_checker => if (item.code == .unknown_type_name) .types else .checker,
        .cfg => .checker,
        .module_graph, .lowering, .runtime, .internal => .project,
    };
}

const MappedGraphDiagnostic = struct {
    phase: ProjectDiagnosticPhase,
    code: diagnostics.DiagnosticCode,
    message: []const u8,
};

fn graphProjectDiagnostic(code: project_graph.DiagnosticCode) MappedGraphDiagnostic {
    return switch (code) {
        .module_not_found => .{ .phase = .module_host, .code = .module_not_found, .message = "module not found" },
        .module_denied => .{ .phase = .module_host, .code = .module_access_denied, .message = "module access denied" },
        .module_failed => .{ .phase = .module_host, .code = .module_host_failed, .message = "module host failed" },
        .external_missing_export => .{ .phase = .project, .code = .missing_export, .message = "external module is missing the requested export" },
    };
}

fn projectDiagnosticsEqual(left: ProjectDiagnostic, right: ProjectDiagnostic) bool {
    const module_equal = if (left.module_id) |left_id|
        if (right.module_id) |right_id| left_id == right_id else false
    else
        right.module_id == null;
    return module_equal and
        left.phase == right.phase and
        left.severity == right.severity and
        left.code == right.code and
        std.mem.eql(u8, left.message, right.message) and
        std.mem.eql(u8, left.logical_name, right.logical_name) and
        left.span.start == right.span.start and
        left.span.end == right.span.end and
        left.span.line == right.span.line and
        left.span.column == right.span.column;
}

fn validateExternalDescriptor(descriptor: contracts.ExternalModuleDescriptor) !void {
    for (descriptor.exports, 0..) |item, index| {
        if (item.name.len == 0 or !item.namespace.isValid()) return error.InvalidExternalExport;
        switch (item.kind) {
            .default => if (!std.mem.eql(u8, item.name, "default")) return error.InvalidExternalExport,
            .named, .namespace => if (std.mem.eql(u8, item.name, "default")) return error.InvalidExternalExport,
        }
        for (descriptor.exports[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, item.name)) return error.DuplicateExternalExport;
            if (item.symbol_id != null and previous.symbol_id == item.symbol_id) return error.DuplicateExternalSymbol;
        }
        if (item.function != null and item.declaration_kind != .function) return error.InvalidExternalExport;
        if (item.declaration_kind == .function and item.function == null) return error.InvalidExternalExport;
        if (item.declaration_kind == .type and (!item.namespace.type or item.namespace.value)) return error.InvalidExternalExport;
        if (item.function) |function| {
            for (function.parameters, 0..) |parameter, parameter_index| {
                if (parameter.rest and parameter_index + 1 != function.parameters.len) return error.InvalidExternalExport;
            }
        }
    }
}

fn externalDescriptorsEqual(left: contracts.ExternalModuleDescriptor, right: contracts.ExternalModuleDescriptor) bool {
    if (left.id != right.id or !std.mem.eql(u8, left.logical_name, right.logical_name) or left.exports.len != right.exports.len) return false;
    for (left.exports, right.exports) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.kind != b.kind or !std.meta.eql(a.namespace, b.namespace) or
            a.type_metadata != b.type_metadata or a.symbol_id != b.symbol_id or
            a.declaration_kind != b.declaration_kind or a.effects != b.effects or
            !externalFunctionsEqual(a.function, b.function)) return false;
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
        if (!kind_matches or !item.namespace.supports(type_only) or !std.mem.eql(u8, item.name, name)) continue;
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

fn externalDeclarationTypeId(
    allocator: std.mem.Allocator,
    store: *types.TypeStore,
    descriptor: contracts.ExternalExportDescriptor,
    fallback: ?types.TypeId,
) !types.TypeId {
    const function = descriptor.function orelse return fallback orelse externalTypeId(&store.builtins, descriptor.type_metadata);
    const parameters = try allocator.alloc(types.ParameterType, function.parameters.len);
    for (function.parameters, 0..) |parameter, index| parameters[index] = .{
        .name = parameter.name,
        .type_id = externalTypeId(&store.builtins, parameter.type_metadata),
        .optional = parameter.optional,
        .has_default = parameter.has_default,
        .rest = parameter.rest,
    };
    return store.addFunctionDetailed(
        parameters,
        externalTypeId(&store.builtins, function.return_type),
        function.type_parameter_count,
        .{
            .is_async = function.is_async,
            .is_generator = function.is_generator,
            .is_constructor = function.is_constructor,
        },
    );
}

fn enrichExternalIdentity(
    allocator: std.mem.Allocator,
    store: *types.TypeStore,
    identity: semantics.SemanticIdentity,
    descriptor: contracts.ExternalExportDescriptor,
) !semantics.SemanticIdentity {
    var enriched = identity;
    enriched.type_id = try externalDeclarationTypeId(allocator, store, descriptor, identity.type_id);
    enriched.external_symbol_id = if (descriptor.symbol_id) |id| id.value() else null;
    enriched.external_declaration_kind = descriptor.declaration_kind;
    enriched.external_effects = descriptor.effects;
    return enriched;
}

fn freeExternalExport(allocator: std.mem.Allocator, item: contracts.ExternalExportDescriptor) void {
    if (item.function) |function| {
        for (function.parameters) |parameter| allocator.free(parameter.name);
        allocator.free(function.parameters);
    }
    allocator.free(item.name);
}

fn externalFunctionsEqual(left: ?contracts.ExternalFunctionDescriptor, right: ?contracts.ExternalFunctionDescriptor) bool {
    if (left == null or right == null) return left == null and right == null;
    const a = left.?;
    const b = right.?;
    if (a.return_type != b.return_type or a.type_parameter_count != b.type_parameter_count or
        a.is_async != b.is_async or a.is_generator != b.is_generator or
        a.is_constructor != b.is_constructor or a.parameters.len != b.parameters.len) return false;
    for (a.parameters, b.parameters) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or x.type_metadata != y.type_metadata or
            x.optional != y.optional or x.has_default != y.has_default or x.rest != y.rest) return false;
    }
    return true;
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

test "first project module enforces exact semantic type and diagnostic boundaries" {
    const typed_source = "type Box = { value: number }; const box: Box = { value: 1 };";
    var typed_baseline = try semantics.analyze(std.testing.allocator, typed_source);
    const exact_type_count = typed_baseline.type_store.count();
    typed_baseline.deinit();
    try std.testing.expect(exact_type_count > 0);

    var exact_types = Project.initWithLimits(std.testing.allocator, .{ .max_semantic_types = exact_type_count });
    defer exact_types.deinit();
    try exact_types.addRoot(.{ .id = .init(1), .logical_name = "types.ts", .bytes = typed_source });
    _ = try exact_types.analyzeModule(.init(1));

    var excess_types = Project.initWithLimits(std.testing.allocator, .{ .max_semantic_types = exact_type_count - 1 });
    defer excess_types.deinit();
    try excess_types.addRoot(.{ .id = .init(1), .logical_name = "types.ts", .bytes = typed_source });
    try std.testing.expectError(error.SemanticTypeLimitExceeded, excess_types.analyzeModule(.init(1)));

    const diagnostic_source = "const first: number = 'wrong'; const second: number = 'wrong';";
    var diagnostic_baseline = try semantics.analyze(std.testing.allocator, diagnostic_source);
    const exact_diagnostic_count = diagnostic_baseline.diagnostics.len;
    diagnostic_baseline.deinit();
    try std.testing.expect(exact_diagnostic_count > 0);

    var exact_diagnostics = Project.initWithLimits(std.testing.allocator, .{ .max_diagnostics = exact_diagnostic_count });
    defer exact_diagnostics.deinit();
    try exact_diagnostics.addRoot(.{ .id = .init(2), .logical_name = "diagnostics.ts", .bytes = diagnostic_source });
    _ = try exact_diagnostics.analyzeModule(.init(2));

    var excess_diagnostics = Project.initWithLimits(std.testing.allocator, .{ .max_diagnostics = exact_diagnostic_count - 1 });
    defer excess_diagnostics.deinit();
    try excess_diagnostics.addRoot(.{ .id = .init(2), .logical_name = "diagnostics.ts", .bytes = diagnostic_source });
    try std.testing.expectError(error.DiagnosticLimitExceeded, excess_diagnostics.analyzeModule(.init(2)));
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

test "duplicate module identities are rejected in one-shot projects" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    const original: contracts.ModuleSource = .{ .id = .init(7), .logical_name = "item", .bytes = "let x = 1;" };
    try project.supplySource(original);
    try std.testing.expectError(error.DuplicateModule, project.supplySource(original));
    try std.testing.expectError(error.DuplicateModule, project.supplySource(.{ .id = .init(7), .logical_name = "item", .bytes = "let x = 2;" }));
}

test "finish is terminal and returns the cached result" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    try project.addRoot(.{ .id = .init(8), .logical_name = "root", .bytes = "let x = 1;" });
    _ = try project.step();
    const first = try project.finish();
    const repeated = try project.finish();
    try std.testing.expectEqualDeep(first, repeated);
    try std.testing.expectError(error.ProjectFinished, project.addRoot(.{ .id = .init(9), .logical_name = "late", .bytes = "" }));
}

test "unreachable pre-supplied modules are not analyzed" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    try project.addRoot(.{ .id = .init(1), .logical_name = "root", .bytes = "export {};" });
    try project.supplySource(.{ .id = .init(2), .logical_name = "unreachable", .bytes = "import './missing';" });
    const step_value = try project.step();
    try std.testing.expect(step_value == .complete);
    try std.testing.expectEqual(ModuleState.supplied, project.state(.init(2)));

    const finished = try project.finish();
    try std.testing.expectEqual(@as(usize, 1), finished.module_count);
    try std.testing.expect(!finished.has_failures);
    try std.testing.expectEqual(@as(usize, 1), project.moduleCount());
    try std.testing.expect(project.lookup(.init(1)) != null);
    try std.testing.expect(project.lookup(.init(2)) == null);
    try std.testing.expectEqual(@as(usize, 0), project.edges().len);
    try std.testing.expectEqual(@as(usize, 0), project.graphDiagnostics().len);
    try std.testing.expectEqual(@as(usize, 0), project.diagnostics().len);

    const semantic = project.semanticResult().?;
    try std.testing.expect(semantic.lookupModule(1) != null);
    try std.testing.expect(semantic.lookupModule(2) == null);
    for (semantic.imports) |item| try std.testing.expectEqual(@as(u64, 1), item.module_id);
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

    const first = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./a", .operation = .static_import, .span = .{ .start = 1, .end = 4, .line = 1, .column = 1 } });
    const duplicate = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./a", .operation = .static_import, .span = .{ .start = 10, .end = 13, .line = 2, .column = 1 } });
    const second = try project.queueRequest(.{ .importer = .init(1), .raw_specifier = "./b", .operation = .dynamic_import, .span = .{ .start = 20, .end = 23, .line = 3, .column = 1 } });
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

test "responses reject foreign and duplicate request ids without mutation" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(4), .logical_name = "root", .bytes = "export {};" });
    _ = try project.analyzeModule(.init(4));

    const external_id = try project.queueRequest(.{ .importer = .init(4), .raw_specifier = "runtime", .operation = .static_import, .span = .{ .start = 0, .end = 7, .line = 1, .column = 0 } });
    _ = try project.step();
    const external: contracts.ExternalModuleDescriptor = .{
        .id = .init(40),
        .logical_name = "runtime",
        .exports = &.{},
    };
    try std.testing.expectError(error.ForeignRequest, project.respondExternalModule(.init(999), external));
    try project.respondExternalModule(external_id, external);
    try std.testing.expectError(error.DuplicateResponse, project.respondExternalModule(external_id, external));
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

    const a_to_b = try project.queueRequest(.{ .importer = source_a.id, .raw_specifier = "./b", .operation = .static_import, .span = .{ .start = 7, .end = 10, .line = 1, .column = 7 } });
    const b_to_a = try project.queueRequest(.{ .importer = source_b.id, .raw_specifier = "./a", .operation = .static_import, .span = .{ .start = 7, .end = 10, .line = 1, .column = 7 } });
    try std.testing.expectEqual(a_to_b, (try project.step()).request.id);
    try project.respondSource(a_to_b, source_b);
    try std.testing.expectEqual(b_to_a, (try project.step()).request.id);
    try project.respondSource(b_to_a, source_a);
    try std.testing.expect((try project.step()) == .complete);
    try std.testing.expect(!(try project.finish()).has_failures);
}

test "source response rejects prospective graph depth without mutation" {
    var project = Project.initWithLimits(std.testing.allocator, .{ .max_graph_depth = 1 });
    defer project.deinit();
    const root: contracts.ModuleSource = .{ .id = .init(1), .logical_name = "root", .bytes = "import './dep';" };
    try project.addRoot(root);

    const root_request = (try project.step()).request;
    try project.respondSource(root_request.id, .{
        .id = .init(2),
        .logical_name = "dep",
        .bytes = "import './deep';",
    });
    const deep_request = (try project.step()).request;
    const module_count = project.moduleCount();
    const total_source_bytes = project.total_source_bytes;
    const edge_index = project.graph.edges.items.len - 1;

    try std.testing.expectError(error.GraphDepthLimitExceeded, project.respondSource(deep_request.id, .{
        .id = .init(3),
        .logical_name = "deep",
        .bytes = "export {};",
    }));
    try std.testing.expectEqual(module_count, project.moduleCount());
    try std.testing.expectEqual(total_source_bytes, project.total_source_bytes);
    try std.testing.expect(project.lookup(.init(3)) == null);
    try std.testing.expect(project.lookupRequest(deep_request.id).?.resolution == null);
    try std.testing.expectEqual(project_graph.EdgeState.unresolved, project.graph.edges.items[edge_index].state);

    try project.respondSource(deep_request.id, root);
    try std.testing.expect((try project.step()) == .complete);
    try std.testing.expect(!(try project.finish()).has_failures);
}

test "all terminal response kinds are inspectable and finish rejects pending work" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(20), .logical_name = "root", .bytes = "export {};" });
    _ = try project.analyzeModule(.init(20));

    const source_id = try project.queueRequest(.{ .importer = .init(20), .raw_specifier = "source", .operation = .static_import, .span = .{ .start = 0, .end = 1, .line = 1, .column = 0 } });
    try std.testing.expectError(error.PendingRequests, project.finish());
    _ = try project.step();
    try project.respondSource(source_id, .{ .id = .init(21), .logical_name = "dependency", .bytes = "export {};" });
    try std.testing.expectError(error.IncompleteModules, project.finish());
    _ = try project.analyzeModule(.init(21));

    const failed_id = try project.queueRequest(.{ .importer = .init(20), .raw_specifier = "failed", .operation = .static_import, .type_only = true, .span = .{ .start = 2, .end = 3, .line = 1, .column = 2 } });
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
                try std.testing.expectEqual(contracts.RequestOperation.dynamic_import, request.operation);
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
        if (edge.operation == .static_import and std.mem.eql(u8, edge.raw_specifier, "./dep")) static_dep_edges += 1;
        if (edge.operation == .re_export) saw_re_export = edge.target == dep_id;
        if (edge.type_only) saw_type_only = edge.target == types_id;
        if (edge.operation == .dynamic_import) saw_dynamic = edge.state == .external;
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
            .{ .name = "NativeShape", .namespace = .{ .type = true }, .type_metadata = .object },
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

test "external value type reaches checker and final node and symbol tables" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(408),
        .logical_name = "root",
        .bytes =
        \\import { numberValue } from 'native:numbers';
        \\const invalid: string = numberValue;
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9008),
            .logical_name = "native:numbers",
            .exports = &.{.{
                .name = "numberValue",
                .namespace = .{ .value = true },
                .type_metadata = .number,
            }},
        }),
    };
    _ = try project.finish();

    const result = project.semanticResult().?;
    const root = result.lookupModule(408).?;
    var saw_mismatch = false;
    for (root.type_info.diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch and diagnostic.label != null and
            std.mem.eql(u8, diagnostic.label.?, "incompatible initializer")) saw_mismatch = true;
    }
    try std.testing.expect(saw_mismatch);

    var imported_type: ?types.TypeId = null;
    for (result.imports) |item| {
        if (!std.mem.eql(u8, item.local_name, "numberValue")) continue;
        imported_type = item.target.?.type_id;
        try std.testing.expectEqual(result.type_store.builtins.number, imported_type.?);
        try std.testing.expectEqual(imported_type, root.type_info.lookupSymbol(item.import_symbol.?).?.effective());
    }
    try std.testing.expect(imported_type != null);

    const frontend_result = project.lookup(.init(408)).?.semantic_result.?.frontend;
    var initializer_type: ?types.TypeId = null;
    for (frontend_result.ast.nodes) |node| switch (node.data) {
        .VariableDeclarator => |declaration| if (std.mem.eql(u8, declaration.name, "invalid")) {
            initializer_type = root.type_info.lookupNode(declaration.init.?);
        },
        else => {},
    };
    try std.testing.expectEqual(imported_type, initializer_type);
}

test "external function signature supersedes coarse type metadata before checking" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(409),
        .logical_name = "root",
        .bytes =
        \\import { nativeValue } from 'native:functions';
        \\export const answer: number = nativeValue();
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9009),
            .logical_name = "native:functions",
            .exports = &.{.{
                .name = "nativeValue",
                .type_metadata = .object,
                .symbol_id = .init(9010),
                .declaration_kind = .function,
                .function = .{ .return_type = .number },
            }},
        }),
    };
    try std.testing.expect(!(try project.finish()).has_failures);

    const result = project.semanticResult().?;
    const root = result.lookupModule(409).?;
    try std.testing.expectEqual(@as(usize, 0), root.type_info.diagnostics.len);
    for (result.imports) |item| {
        if (!std.mem.eql(u8, item.local_name, "nativeValue")) continue;
        const imported_type = result.type_store.lookup(item.target.?.type_id).?;
        try std.testing.expect(imported_type.isFunction());
        const signature_id = switch (imported_type.kind) {
            .function => |id| id,
            else => unreachable,
        };
        const signature = result.type_store.lookupFunctionSignature(signature_id).?;
        try std.testing.expectEqual(result.type_store.builtins.number, signature.return_type);
        return;
    }
    return error.TestUnexpectedResult;
}

test "value-only external import is rejected in the type namespace" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(405),
        .logical_name = "root",
        .bytes =
        \\import { ValueOnly } from 'native:value-only';
        \\let invalid: ValueOnly;
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9006),
            .logical_name = "native:value-only",
            .exports = &.{.{
                .name = "ValueOnly",
                .namespace = .{ .value = true },
                .type_metadata = .object,
            }},
        }),
    };
    _ = try project.finish();

    const result = project.semanticResult().?;
    const root = result.lookupModule(405).?;
    var saw_value_import = false;
    for (result.imports) |item| {
        if (!std.mem.eql(u8, item.local_name, "ValueOnly")) continue;
        saw_value_import = !item.type_only and item.state == .resolved and item.target != null and item.type_target == null;
    }
    try std.testing.expect(saw_value_import);
    var saw_value_only_type_error = false;
    for (root.type_info.diagnostics) |diagnostic| {
        if (diagnostic.code == .unknown_type_name) saw_value_only_type_error = true;
    }
    try std.testing.expect(saw_value_only_type_error);
    try std.testing.expectEqual(@as(usize, 0), project.graphDiagnostics().len);
}

test "external class exists in value and type namespaces" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(404),
        .logical_name = "root",
        .bytes =
        \\import { ExternalClass } from 'native:classes';
        \\const instance = new ExternalClass();
        \\let typed: ExternalClass;
        ,
    });
    const descriptor: contracts.ExternalModuleDescriptor = .{
        .id = .init(9004),
        .logical_name = "native:classes",
        .exports = &.{.{
            .name = "ExternalClass",
            .namespace = .{ .value = true, .type = true },
            .type_metadata = .object,
        }},
    };
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, descriptor),
    };
    try std.testing.expect(!(try project.finish()).has_failures);

    const result = project.semanticResult().?;
    const root = result.lookupModule(404).?;
    try std.testing.expectEqual(@as(usize, 0), root.type_info.diagnostics.len);
    var saw_external = false;
    var constructor_type: ?types.TypeId = null;
    var instance_type: ?types.TypeId = null;
    for (result.imports) |item| {
        if (!std.mem.eql(u8, item.local_name, "ExternalClass")) continue;
        constructor_type = item.target.?.type_id;
        instance_type = item.type_target.?.type_id;
        saw_external = item.runtime_binding and !item.type_only and item.target != null and
            item.target.?.namespace == .value and
            result.type_store.lookup(item.target.?.type_id).?.kind == .class_constructor and
            result.type_store.lookup(item.type_target.?.type_id).?.kind == .class and
            item.target.?.declaration.eql(item.type_target.?.declaration) and
            item.target.?.external_module_id.? == descriptor.id.value();
        try std.testing.expectEqual(constructor_type, root.type_info.lookupSymbol(item.import_symbol.?).?.effective());
    }
    try std.testing.expect(saw_external);
    try std.testing.expect(constructor_type.? != instance_type.?);

    const frontend_result = project.lookup(.init(404)).?.semantic_result.?.frontend;
    var saw_instance = false;
    var saw_typed = false;
    for (frontend_result.bind.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "instance")) {
            try std.testing.expectEqual(instance_type, root.type_info.lookupSymbol(symbol.id).?.effective());
            saw_instance = true;
        } else if (std.mem.eql(u8, symbol.name, "typed")) {
            try std.testing.expectEqual(instance_type, root.type_info.lookupSymbol(symbol.id).?.declared_type);
            saw_typed = true;
        }
    }
    try std.testing.expect(saw_instance and saw_typed);
}

test "external re-export reaches a downstream consumer before checking" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(406),
        .logical_name = "root",
        .bytes =
        \\import { ForwardedValue } from './bridge';
        \\const invalid: string = ForwardedValue;
        ,
    });
    const bridge: contracts.ModuleSource = .{
        .id = .init(407),
        .logical_name = "bridge",
        .bytes =
        \\export { ValueOnly as ForwardedValue } from 'native:exports';
        \\export type { TypeOnly as ForwardedType, Both as ForwardedBothType } from 'native:exports';
        \\export * from 'native:exports';
        ,
    };
    const descriptor: contracts.ExternalModuleDescriptor = .{
        .id = .init(9007),
        .logical_name = "native:exports",
        .exports = &.{
            .{ .name = "default", .kind = .default, .type_metadata = .object },
            .{ .name = "ValueOnly", .namespace = .{ .value = true }, .type_metadata = .number },
            .{ .name = "TypeOnly", .namespace = .{ .type = true }, .type_metadata = .string },
            .{ .name = "Both", .namespace = .{ .value = true, .type = true }, .type_metadata = .object },
        },
    };
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| if (std.mem.eql(u8, request.raw_specifier, "./bridge"))
            try project.respondSource(request.id, bridge)
        else
            try project.respondExternalModule(request.id, descriptor),
    };
    _ = try project.finish();

    const result = project.semanticResult().?;
    const root = result.lookupModule(406).?;
    var saw_mismatch = false;
    for (root.type_info.diagnostics) |diagnostic| {
        if (diagnostic.code == .type_mismatch) saw_mismatch = true;
    }
    try std.testing.expect(saw_mismatch);

    var downstream_type: ?types.TypeId = null;
    for (result.imports) |item| {
        if (item.module_id != 406 or !std.mem.eql(u8, item.local_name, "ForwardedValue")) continue;
        downstream_type = item.target.?.type_id;
        try std.testing.expectEqual(result.type_store.builtins.number, downstream_type.?);
        try std.testing.expectEqual(downstream_type, root.type_info.lookupSymbol(item.import_symbol.?).?.effective());
    }
    try std.testing.expect(downstream_type != null);

    const expected = [_]struct { name: []const u8, type_only: bool, type_id: ?types.TypeId }{
        .{ .name = "ForwardedValue", .type_only = false, .type_id = result.type_store.builtins.number },
        .{ .name = "ForwardedType", .type_only = true, .type_id = result.type_store.builtins.string },
        .{ .name = "ForwardedBothType", .type_only = true, .type_id = null },
        .{ .name = "ValueOnly", .type_only = false, .type_id = result.type_store.builtins.number },
        .{ .name = "TypeOnly", .type_only = true, .type_id = result.type_store.builtins.string },
        .{ .name = "Both", .type_only = false, .type_id = null },
    };
    for (expected) |wanted| {
        var found = false;
        for (result.exports) |item| {
            if (item.module_id != 407 or !std.mem.eql(u8, item.name, wanted.name)) continue;
            try std.testing.expect(item.re_export);
            try std.testing.expectEqual(wanted.type_only, item.type_only);
            if (wanted.type_id) |type_id| {
                try std.testing.expectEqual(type_id, item.identity.type_id);
            } else if (wanted.type_only) {
                try std.testing.expect(result.type_store.lookup(item.identity.type_id).?.kind == .class);
            } else {
                try std.testing.expect(result.type_store.lookup(item.identity.type_id).?.kind == .class_constructor);
                try std.testing.expect(result.type_store.lookup(item.type_identity.?.type_id).?.kind == .class);
            }
            try std.testing.expectEqual(@as(?u64, descriptor.id.value()), item.identity.external_module_id);
            try std.testing.expect(item.edge_index != null);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
    try std.testing.expect(result.lookupExport(407, "default") == null);
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
    try std.testing.expectError(error.InvalidExternalExport, project.respondExternalModule(first.id, .{
        .id = .init(1),
        .logical_name = "bad",
        .exports = &.{.{ .name = "one", .namespace = .{} }},
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

test "source aggregate and module limits hold their N boundaries" {
    var per_source = Project.initWithLimits(std.testing.allocator, .{
        .max_source_bytes = 3,
        .max_total_source_bytes = 32,
    });
    defer per_source.deinit();
    try per_source.addRoot(.{ .id = .init(1), .logical_name = "root", .bytes = "abc" });
    try std.testing.expectError(error.SourceLimitExceeded, per_source.supplySource(.{
        .id = .init(2),
        .logical_name = "large",
        .bytes = "abcd",
    }));
    try std.testing.expectEqual(@as(usize, 1), per_source.moduleCount());

    var aggregate = Project.initWithLimits(std.testing.allocator, .{
        .max_source_bytes = 32,
        .max_total_source_bytes = 3,
    });
    defer aggregate.deinit();
    try aggregate.addRoot(.{ .id = .init(1), .logical_name = "root", .bytes = "ab" });
    try aggregate.supplySource(.{ .id = .init(2), .logical_name = "dep", .bytes = "c" });
    try std.testing.expectError(error.TotalSourceLimitExceeded, aggregate.supplySource(.{
        .id = .init(3),
        .logical_name = "extra",
        .bytes = "d",
    }));
    try std.testing.expectEqual(@as(usize, 2), aggregate.moduleCount());

    var modules = Project.initWithLimits(std.testing.allocator, .{ .max_modules = 2 });
    defer modules.deinit();
    try modules.addRoot(.{ .id = .init(1), .logical_name = "root", .bytes = "" });
    try modules.supplySource(.{ .id = .init(2), .logical_name = "dep", .bytes = "" });
    try std.testing.expectError(error.ModuleLimitExceeded, modules.supplySource(.{
        .id = .init(3),
        .logical_name = "extra",
        .bytes = "",
    }));
    try std.testing.expectEqual(@as(usize, 2), modules.moduleCount());
}

test "aggregate source-byte addition rejects usize overflow before mutation" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    project.total_source_bytes = std.math.maxInt(usize);

    try std.testing.expectError(error.TotalSourceLimitExceeded, project.validateSubmission(.{
        .id = .init(1),
        .logical_name = "overflow",
        .bytes = "x",
    }));
    try std.testing.expectEqual(std.math.maxInt(usize), project.total_source_bytes);

    // Restore the synthetic counter so deinitialization invariants describe the
    // actually retained (empty) project.
    project.total_source_bytes = 0;
}

test "project diagnostic limit is checked before copying messages" {
    var no_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_storage);
    var project = Project.initWithLimits(fixed.allocator(), .{ .max_diagnostics = 0 });
    defer project.deinit();

    try std.testing.expectError(error.DiagnosticLimitExceeded, project.appendProjectDiagnostic(.{
        .module_id = .init(1),
        .phase = .scanner,
        .severity = .@"error",
        .code = .invalid_character,
        .message = "must not be copied",
        .logical_name = "must not be copied either",
        .span = .{ .start = 0, .end = 1, .line = 1, .column = 0 },
    }));
    try std.testing.expectEqual(@as(usize, 0), project.diagnostics().len);
}

fn allocationFailureProject(allocator: std.mem.Allocator) !*Project {
    const project = try allocator.create(Project);
    project.* = Project.init(allocator);
    return project;
}

fn destroyAllocationFailureProject(allocator: std.mem.Allocator, project: *Project) void {
    project.deinit();
    allocator.destroy(project);
}

fn allocationFailureSourceAcquisition(allocator: std.mem.Allocator) !void {
    const project = try allocationFailureProject(allocator);
    defer destroyAllocationFailureProject(allocator, project);
    project.addRoot(.{
        .id = .init(701),
        .logical_name = "fault:root",
        .bytes = "export const answer = 42;",
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), project.moduleCount());
        try std.testing.expectEqual(@as(usize, 0), project.total_source_bytes);
        return err;
    };
    try std.testing.expectEqualStrings("fault:root", project.lookup(.init(701)).?.source.?.logical_name);
    try std.testing.expectEqualStrings("export const answer = 42;", project.lookup(.init(701)).?.source.?.bytes);
}

fn allocationFailureModulePipeline(allocator: std.mem.Allocator) !void {
    const project = try allocationFailureProject(allocator);
    defer destroyAllocationFailureProject(allocator, project);
    try project.addRoot(.{
        .id = .init(702),
        .logical_name = "fault:pipeline",
        .bytes = "import { item } from './dependency' with { mode: 'strict' }; export const value = item;",
    });
    const next = project.step() catch |err| {
        try std.testing.expect(project.semanticResult() == null);
        try std.testing.expect(project.lookup(.init(702)).?.semantic_result == null);
        try std.testing.expect(!project.lookup(.init(702)).?.metadata_derived);
        try std.testing.expectEqual(@as(usize, 0), project.requestCount());
        try std.testing.expectEqual(@as(usize, 0), project.edges().len);
        return err;
    };
    const request = next.request;
    try std.testing.expectEqualStrings("./dependency", request.raw_specifier);
    try std.testing.expectEqual(@as(usize, 1), request.attributes.len);
    try std.testing.expectEqual(@as(usize, 1), project.requestCount());
    try std.testing.expectEqual(@as(usize, 1), project.edges().len);
    try std.testing.expect(project.lookup(.init(702)).?.semantic_result != null);
    try std.testing.expect(project.lookup(.init(702)).?.metadata_derived);
}

fn allocationFailureExternalCopy(allocator: std.mem.Allocator) !void {
    const project = try allocationFailureProject(allocator);
    defer destroyAllocationFailureProject(allocator, project);
    try project.addRoot(.{
        .id = .init(703),
        .logical_name = "fault:external",
        .bytes = "import { ExternalClass } from 'native:classes';",
    });
    const request = (try project.step()).request;
    project.respondExternalModule(request.id, .{
        .id = .init(9703),
        .logical_name = "native:classes",
        .exports = &.{.{
            .name = "ExternalClass",
            .namespace = .{ .value = true, .type = true },
            .type_metadata = .object,
        }},
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), project.external_modules.items.len);
        try std.testing.expect(project.lookupRequest(request.id).?.resolution == null);
        try std.testing.expectEqual(project_graph.EdgeState.unresolved, project.edges()[0].state);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), project.external_modules.items.len);
    try std.testing.expectEqual(project_graph.EdgeState.external, project.edges()[0].state);
}

fn allocationFailureProjectResult(allocator: std.mem.Allocator) !void {
    const project = try allocationFailureProject(allocator);
    defer destroyAllocationFailureProject(allocator, project);
    try project.addRoot(.{
        .id = .init(704),
        .logical_name = "fault:finish",
        .bytes =
        \\import { Missing, ExternalClass } from 'native:classes';
        \\export { ExternalClass as ForwardedClass } from 'native:classes';
        \\const instance = new ExternalClass();
        \\let typed: ExternalClass;
        ,
    });
    const descriptor: contracts.ExternalModuleDescriptor = .{
        .id = .init(9704),
        .logical_name = "native:classes",
        .exports = &.{.{
            .name = "ExternalClass",
            .namespace = .{ .value = true, .type = true },
            .type_metadata = .object,
        }},
    };
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, descriptor),
    };
    const finished = project.finish() catch |err| {
        try std.testing.expect(project.semanticResult() == null);
        try std.testing.expectEqual(@as(usize, 0), project.diagnostics().len);
        try std.testing.expect(project.finish_result == null);
        try std.testing.expect(!project.finished);
        return err;
    };
    try std.testing.expect(!finished.has_failures);
    try std.testing.expect(project.semanticResult() != null);
    try std.testing.expect(project.semanticResult().?.is_partial);
    try std.testing.expect(project.diagnostics().len != 0);
}

test "allocation failure matrix covers project creation and source acquisition" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureSourceAcquisition, .{});
}

test "allocation failure matrix covers frontend semantic metadata request and graph phases" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureModulePipeline, .{});
}

test "allocation failure matrix covers external descriptor copying" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureExternalCopy, .{});
}

test "allocation failure matrix covers external linking project result and canonical diagnostics" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureProjectResult, .{});
}

test "ambient global registration propagates host binding id and resolves references" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.registerAmbientGlobals(&.{
        .{ .name = "ambient_a", .namespace = .{ .value = true }, .type_metadata = .object, .host_binding_id = 42 },
    });
    try project.addRoot(.{
        .id = .init(1),
        .logical_name = "ambient_root",
        .bytes = "ambient_a;",
    });
    const result = try project.analyzeModule(.init(1));
    try std.testing.expectEqual(ModuleState.complete, project.state(.init(1)));
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var seen = false;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind == .ambient and std.mem.eql(u8, symbol.name, "ambient_a")) {
            try std.testing.expectEqual(@as(u64, 42), symbol.host_binding_id);
            seen = true;
        }
    }
    try std.testing.expect(seen);
}

test "source host binding registration owns names and annotates source declarations" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    var name = [_]u8{ 'h', 'o', 's', 't', 'V', 'a', 'l', 'u', 'e' };
    try project.registerSourceHostBindings(&.{.{
        .name = &name,
        .host_binding_id = 41,
    }});
    name[0] = 'x';
    try std.testing.expectEqualStrings("hostValue", project.source_host_bindings.items[0].name);

    try project.addRoot(.{
        .id = .init(2),
        .logical_name = "source-host-binding.ts",
        .bytes =
        \\interface HostValue { invoke(value: number): void; }
        \\const hostValue: HostValue;
        \\hostValue;
        ,
    });
    const result = try project.analyzeModule(.init(2));
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var saw_host_value = false;
    for (result.frontend.bind.symbols) |symbol| {
        if (symbol.kind == .variable and std.mem.eql(u8, symbol.name, "hostValue")) {
            try std.testing.expect(symbol.host_bound);
            try std.testing.expectEqual(@as(u64, 41), symbol.host_binding_id);
            saw_host_value = true;
        }
    }
    try std.testing.expect(saw_host_value);
}

test "source host binding registration rejects invalid duplicate and late descriptors" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    try std.testing.expectError(
        error.InvalidSourceHostBinding,
        project.registerSourceHostBindings(&.{.{ .name = "", .host_binding_id = 1 }}),
    );
    try project.registerSourceHostBindings(&.{.{ .name = "hostValue", .host_binding_id = 1 }});
    try std.testing.expectError(
        error.DuplicateSourceHostBinding,
        project.registerSourceHostBindings(&.{.{ .name = "hostValue", .host_binding_id = 2 }}),
    );
    try std.testing.expectError(
        error.DuplicateSourceHostBinding,
        project.registerSourceHostBindings(&.{.{ .name = "other", .host_binding_id = 1 }}),
    );

    try project.addRoot(.{
        .id = .init(3),
        .logical_name = "late-source-host-binding.ts",
        .bytes = "export {};",
    });
    try std.testing.expectError(
        error.SourceHostBindingsLateRegistration,
        project.registerSourceHostBindings(&.{.{ .name = "late", .host_binding_id = 3 }}),
    );
}

test "ambient registration owns recursive member descriptors and rejects mutable self references" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();

    var global_name = [_]u8{ 'a', 'm', 'b', 'i', 'e', 'n', 't' };
    var member_name = [_]u8{ 's', 'e', 'l', 'f' };
    try project.registerAmbientGlobals(&.{.{
        .name = &global_name,
        .namespace = .{ .value = true },
        .type_metadata = .object,
        .host_binding_id = 7,
        .members = &.{.{ .name = &member_name, .readonly = true, .self_reference = true }},
    }});
    global_name[0] = 'x';
    member_name[0] = 'x';

    try std.testing.expectEqualStrings("ambient", project.ambient_globals.items[0].name);
    try std.testing.expectEqualStrings("self", project.ambient_globals.items[0].members[0].name);
    try std.testing.expect(project.ambient_globals.items[0].members[0].readonly);
    try std.testing.expect(project.ambient_globals.items[0].members[0].self_reference);

    var invalid = Project.init(std.testing.allocator);
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidAmbientGlobal, invalid.registerAmbientGlobals(&.{.{
        .name = "mutable_self",
        .namespace = .{ .value = true },
        .type_metadata = .object,
        .members = &.{.{ .name = "self", .self_reference = true }},
    }}));
}

test "referencing an unregistered ambient name produces cannot_find_name" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1),
        .logical_name = "ambient_root",
        .bytes = "ambient_a;",
    });
    const result = try project.analyzeModule(.init(1));
    try std.testing.expectEqual(ModuleState.complete, project.state(.init(1)));
    var found = false;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.code == .cannot_find_name) found = true;
    }
    try std.testing.expect(found);
}

test "duplicate ambient global registration is rejected" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.registerAmbientGlobals(&.{
        .{ .name = "ambient_a", .namespace = .{ .value = true }, .type_metadata = .object, .host_binding_id = 1 },
    });
    try std.testing.expectError(
        error.DuplicateAmbientGlobal,
        project.registerAmbientGlobals(&.{
            .{ .name = "ambient_a", .namespace = .{ .value = true }, .type_metadata = .object, .host_binding_id = 2 },
        }),
    );
}

test "ambient registration enforces overlapping namespaces and permits disjoint namespaces" {
    var project = Project.init(std.testing.allocator);
    defer project.deinit();
    try project.registerAmbientGlobals(&.{
        .{ .name = "ambient_both", .namespace = .{ .value = true, .type = true }, .type_metadata = .object, .host_binding_id = 40 },
    });
    try std.testing.expectError(
        error.DuplicateAmbientGlobal,
        project.registerAmbientGlobals(&.{
            .{ .name = "ambient_both", .namespace = .{ .type = true }, .type_metadata = .object, .host_binding_id = 41 },
        }),
    );

    var disjoint = Project.init(std.testing.allocator);
    defer disjoint.deinit();
    try disjoint.registerAmbientGlobals(&.{
        .{ .name = "ambient_split", .namespace = .{ .value = true }, .type_metadata = .object, .host_binding_id = 42 },
        .{ .name = "ambient_split", .namespace = .{ .type = true }, .type_metadata = .object, .host_binding_id = 43 },
    });
}
