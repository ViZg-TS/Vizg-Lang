//! Root-independent source/semantic adjacency for project -> HIR lowering.
//!
//! This index exists only while a project is being lowered. It prevents every
//! projected source module from rescanning the complete project edge/import/
//! export tables. Artifact declaration reachability is a later, separate HIR
//! analysis and must not be folded into this index.

const std = @import("std");
const model = @import("model.zig");
const project_mod = @import("../project/root.zig");
const semantics = @import("../semantics/root.zig");

pub const DependencySeed = struct {
    module_id: project_mod.ModuleId,
    /// Unconditional ESM evaluation edge (bare side-effect import/re-export).
    module_evaluation: bool,
    /// Ordinary user binding import whose ESM evaluation may be omitted when
    /// its provider evaluation closure is proven unobservable. Closed-world
    /// STD bindings and unconditional side-effect/re-export edges leave false.
    effect_prunable_evaluation: bool,
};

pub const DynamicImportResolution = struct {
    /// Span of the literal source expression, exactly matching the project
    /// graph request span. The spelling itself has no semantic meaning here.
    span: project_mod.SourceSpan,
    target: model.HirModuleReference,
};

pub const ModuleInputs = struct {
    tree_shakeable: bool,
    projection_targets: []const project_mod.ModuleId,
    dependencies: []const DependencySeed,
    imports: []const semantics.SemanticImport,
    exports: []const semantics.SemanticExport,
    dynamic_imports: []const DynamicImportResolution,
};

const Bucket = struct {
    tree_shakeable: bool = false,
    projection_targets: std.ArrayList(project_mod.ModuleId) = .empty,
    dependencies: std.ArrayList(DependencySeed) = .empty,
    imports: std.ArrayList(semantics.SemanticImport) = .empty,
    exports: std.ArrayList(semantics.SemanticExport) = .empty,
    dynamic_imports: std.ArrayList(DynamicImportResolution) = .empty,

    fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.projection_targets.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.imports.deinit(allocator);
        self.exports.deinit(allocator);
        self.dynamic_imports.deinit(allocator);
    }
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    module_ordinals: std.AutoHashMap(u64, usize),
    buckets: []Bucket,

    pub fn build(
        allocator: std.mem.Allocator,
        project: *const project_mod.Project,
        semantic_result: *const semantics.BorrowedProjectSemanticResult,
    ) !Index {
        const buckets = try allocator.alloc(Bucket, project.modules.items.len);
        for (buckets) |*bucket| bucket.* = .{};

        var result: Index = .{
            .allocator = allocator,
            .module_ordinals = std.AutoHashMap(u64, usize).init(allocator),
            .buckets = buckets,
        };
        errdefer result.deinit();

        for (project.modules.items, 0..) |module, ordinal| {
            const entry = try result.module_ordinals.getOrPut(module.id.value());
            if (entry.found_existing) return error.DuplicateModule;
            entry.value_ptr.* = ordinal;
            result.buckets[ordinal].tree_shakeable = project.isStandardModule(module.id);
        }

        // Project graph edges are authoritative explicit request resolution.
        // Preserve the historical source projection closure (all resolved
        // source edges), while only static runtime edges become unconditional
        // module-evaluation dependencies. Literal dynamic-import resolution is
        // retained separately and reached only from the live HIR operation.
        for (project.edges()) |edge| {
            const bucket = result.bucketFor(edge.importer) orelse return error.InconsistentProjection;
            switch (edge.state) {
                .resolved => {
                    const target = edge.target orelse return error.InconsistentProjection;
                    try bucket.projection_targets.append(allocator, target);
                    if (edge.operation == .dynamic_import) {
                        try bucket.dynamic_imports.append(allocator, .{
                            .span = edge.span,
                            .target = .{ .source = target },
                        });
                    } else if (!edge.type_only) {
                        // Binding imports are represented as conditional
                        // execution edges. Closed-world STD imports become live
                        // only through exact binding demand. Ordinary user
                        // imports additionally evaluate their provider when the
                        // HIR reachability pass proves that provider evaluation
                        // has observable effects. Bare side-effect imports and
                        // re-exports remain unconditional ESM evaluation edges.
                        const binding_import = edge.operation == .static_import and
                            edge.import_kind != .side_effect;
                        const closed_world_binding_import = binding_import and
                            project.isStandardModule(edge.importer);
                        try bucket.dependencies.append(allocator, .{
                            .module_id = target,
                            // Preserve the ABI/public HIR meaning: ordinary
                            // user imports are ESM evaluation edges even when
                            // reachability may later prove that evaluation
                            // observationally removable.
                            .module_evaluation = !closed_world_binding_import,
                            .effect_prunable_evaluation = binding_import and
                                !closed_world_binding_import,
                        });
                    }
                },
                .external => if (edge.operation == .dynamic_import) {
                    const target = edge.external_target orelse return error.InconsistentProjection;
                    try bucket.dynamic_imports.append(allocator, .{
                        .span = edge.span,
                        .target = .{ .external = target },
                    });
                },
                .unresolved, .not_found, .denied, .failed => {},
            }
        }

        // Semantic imports include exact source-backed global/provider edges as
        // well as ordinary imports. Copy each record once for module lowering;
        // only runtime source bindings participate in source projection.
        for (semantic_result.imports) |item| {
            const bucket = result.bucketForRaw(item.module_id) orelse return error.InconsistentProjection;
            try bucket.imports.append(allocator, item);
            if (item.type_only or !item.runtime_binding) continue;
            const target = item.target orelse continue;
            if (target.external_module_id != null) continue;
            const target_id = project_mod.ModuleId.init(target.declaration.module_id);
            if (target_id.value() == item.module_id) continue;
            try bucket.projection_targets.append(allocator, target_id);
            try bucket.dependencies.append(allocator, .{
                .module_id = target_id,
                // Semantic-import records carry exact provider provenance only.
                // Evaluation policy is owned solely by the project-graph edge
                // above; otherwise a dead source-backed/global alias could
                // upgrade its provider back into an execution root.
                .module_evaluation = false,
                .effect_prunable_evaluation = false,
            });
        }

        for (semantic_result.exports) |item| {
            const bucket = result.bucketForRaw(item.module_id) orelse return error.InconsistentProjection;
            try bucket.exports.append(allocator, item);
        }

        for (result.buckets) |*bucket| {
            std.mem.sort(DependencySeed, bucket.dependencies.items, {}, lessDependency);
            std.mem.sort(semantics.SemanticImport, bucket.imports.items, {}, lessImport);
            std.mem.sort(semantics.SemanticExport, bucket.exports.items, {}, lessExport);
            std.mem.sort(DynamicImportResolution, bucket.dynamic_imports.items, {}, lessDynamicImport);
        }
        return result;
    }

    pub fn deinit(self: *Index) void {
        for (self.buckets) |*bucket| bucket.deinit(self.allocator);
        self.allocator.free(self.buckets);
        self.module_ordinals.deinit();
        self.* = undefined;
    }

    pub fn inputsFor(self: *const Index, module_id: project_mod.ModuleId) ?ModuleInputs {
        const ordinal = self.module_ordinals.get(module_id.value()) orelse return null;
        const bucket = self.buckets[ordinal];
        return .{
            .tree_shakeable = bucket.tree_shakeable,
            .projection_targets = bucket.projection_targets.items,
            .dependencies = bucket.dependencies.items,
            .imports = bucket.imports.items,
            .exports = bucket.exports.items,
            .dynamic_imports = bucket.dynamic_imports.items,
        };
    }

    fn bucketFor(self: *Index, module_id: project_mod.ModuleId) ?*Bucket {
        return self.bucketForRaw(module_id.value());
    }

    fn bucketForRaw(self: *Index, module_id: u64) ?*Bucket {
        const ordinal = self.module_ordinals.get(module_id) orelse return null;
        return &self.buckets[ordinal];
    }
};

/// Resolve by source-literal span, not by specifier spelling. Items are sorted
/// once by the transient project index, making lowering lookup logarithmic and
/// avoiding another scan of the project graph.
pub fn dynamicImportResolution(
    items: []const DynamicImportResolution,
    span: project_mod.SourceSpan,
) ?model.HirModuleReference {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const item = items[mid];
        if (spanBefore(item.span, span))
            low = mid + 1
        else
            high = mid;
    }
    if (low >= items.len) return null;
    const item = items[low];
    if (item.span.start != span.start or item.span.end != span.end) return null;
    return item.target;
}

fn lessDependency(_: void, left: DependencySeed, right: DependencySeed) bool {
    return left.module_id.value() < right.module_id.value();
}

fn lessImport(_: void, left: semantics.SemanticImport, right: semantics.SemanticImport) bool {
    const local_order = std.mem.order(u8, left.local_name, right.local_name);
    if (local_order != .eq) return local_order == .lt;
    const imported_order = std.mem.order(u8, left.imported_name, right.imported_name);
    if (imported_order != .eq) return imported_order == .lt;
    return left.span.start < right.span.start;
}

fn lessExport(_: void, left: semantics.SemanticExport, right: semantics.SemanticExport) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order != .eq) return name_order == .lt;
    if (left.type_only != right.type_only) return !left.type_only;
    return left.span.start < right.span.start;
}

fn lessDynamicImport(_: void, left: DynamicImportResolution, right: DynamicImportResolution) bool {
    return spanBefore(left.span, right.span);
}

fn spanBefore(left: project_mod.SourceSpan, right: project_mod.SourceSpan) bool {
    if (left.start != right.start) return left.start < right.start;
    return left.end < right.end;
}
