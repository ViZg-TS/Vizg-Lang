//! Deterministic lowering of one source-module shell.

const std = @import("std");
const builder_mod = @import("builder.zig");
const lower_body = @import("lower_body.zig");
const model = @import("model.zig");
const project_mod = @import("../project/root.zig");
const region_validation = @import("region_validation.zig");
const semantics = @import("../semantics/root.zig");

pub fn lower(builder: *builder_mod.Builder, project: *const project_mod.Project, module: *const project_mod.ProjectModule) !void {
    const semantic_result = builder.result.semanticResult();
    const module_id = module.id.value();
    const source = module.source.?;

    var dependency_ids: std.ArrayList(project_mod.ModuleId) = .empty;
    for (project.edges()) |edge| {
        if (edge.importer != module.id or edge.state != .resolved) continue;
        if (edge.kind == .dynamic or edge.kind == .type_only) continue;
        const target = edge.target orelse continue;
        if (!containsModule(dependency_ids.items, target)) try dependency_ids.append(builder.allocator, target);
    }
    std.mem.sort(project_mod.ModuleId, dependency_ids.items, {}, lessModuleId);
    const dependencies = try builder.allocator.alloc(model.HirModuleDependency, dependency_ids.items.len);
    for (dependency_ids.items, 0..) |target, index| dependencies[index] = .{
        .module_id = target,
        .initialization_required = true,
    };

    var semantic_imports: std.ArrayList(semantics.SemanticImport) = .empty;
    for (semantic_result.imports) |item| if (item.module_id == module_id) try semantic_imports.append(builder.allocator, item);
    std.mem.sort(semantics.SemanticImport, semantic_imports.items, {}, lessImport);

    const imports = try builder.allocator.alloc(model.HirImportBinding, semantic_imports.items.len);
    var bindings: std.ArrayList(model.HirBinding) = .empty;
    var imported_symbols: std.ArrayList(lower_body.SymbolBinding) = .empty;
    for (semantic_imports.items, 0..) |item, index| {
        const target = item.target.?;
        const local_id = if (item.runtime_binding) blk: {
            const id = try builder.makeId(@import("ids.zig").BindingId, builder.budget.usage.bindings);
            try builder.appendImportBinding(&bindings, .{
                .id = id,
                .name = try builder.copyString(item.local_name),
                .kind = .import,
                .type_id = target.type_id,
                .declaration = if (target.external_module_id == null) target.declaration else null,
                .mutable = false,
                .initial_state = .live_import,
                .origin = .invalid,
            });
            break :blk id;
        } else null;
        if (local_id) |binding_id| {
            const symbol_id = item.import_symbol orelse return error.MissingSemanticIdentity;
            try imported_symbols.append(builder.allocator, .{ .symbol = symbol_id, .binding = binding_id });
        }
        imports[index] = .{
            .local = local_id,
            .source = if (target.external_module_id) |external|
                .{ .external = .init(external) }
            else
                .{ .source = .init(target.declaration.module_id) },
            .exported_name = try builder.copyString(item.imported_name),
            .target = semanticIdentity(target),
            .type_only = item.type_only,
        };
    }

    var semantic_exports: std.ArrayList(semantics.SemanticExport) = .empty;
    for (semantic_result.exports) |item| if (item.module_id == module_id) try semantic_exports.append(builder.allocator, item);
    std.mem.sort(semantics.SemanticExport, semantic_exports.items, {}, lessExport);
    const body = try lower_body.lower(builder, module, @import("ids.zig").FunctionId.invalid, bindings.items, imported_symbols.items);
    const exports = try builder.allocator.alloc(model.HirExportBinding, semantic_exports.items.len);
    for (semantic_exports.items, 0..) |item, index| {
        const is_local = item.identity.declaration.module_id == module_id;
        const symbol_id = item.identity.symbol_id;
        const binding_id = if (is_local and symbol_id != null) bindingForSymbol(body.symbol_bindings, symbol_id.?) else null;
        const entity_id = if (is_local and symbol_id != null) lower_body.entityForSymbol(body, symbol_id.?) else null;
        exports[index] = if (item.type_only or (!is_local and item.re_export))
            model.HirExportBinding.initShell(
                try builder.copyString(item.name),
                semanticIdentity(item.identity),
                item.type_only,
            )
        else
            try model.HirExportBinding.init(
                try builder.copyString(item.name),
                binding_id,
                if (binding_id == null) entity_id else null,
                semanticIdentity(item.identity),
                false,
            );
    }

    const function_id = try builder.makeId(@import("ids.zig").FunctionId, builder.functions.items.len);
    try builder.reserve(.functions, 1);
    const function: model.HirFunction = .{
        .id = function_id,
        .module_id = module.id,
        .symbol = null,
        .kind = .module_initialization,
        .flags = .{},
        .signature_type = semantic_result.type_store.builtins.void,
        .bindings = body.bindings,
        .places = body.places,
        .blocks = body.blocks,
        .entry = body.entry,
        .regions = body.regions,
        .origin = .invalid,
    };
    for (body.regions) |region_id| {
        const index: usize = @intCast(region_id.index().?);
        builder.regions.items[index].function = function_id;
    }
    try region_validation.validateFunction(builder.allocator, &function, builder.regions.items);
    try builder.appendFunction(function);
    try builder.appendModule(.{
        .module_id = module.id,
        .logical_name = try builder.copyString(source.logical_name),
        .initialization = function_id,
        .dependencies = dependencies,
        .imports = imports,
        .exports = exports,
        .entities = body.entities,
        .origin = .invalid,
    });
}

fn bindingForSymbol(items: []const lower_body.SymbolBinding, symbol: @import("../frontend/binder.zig").SymbolId) ?@import("ids.zig").BindingId {
    for (items) |item| if (item.symbol == symbol) return item.binding;
    return null;
}

fn semanticIdentity(identity: semantics.SemanticIdentity) model.HirSemanticIdentity {
    return .{
        .symbol_id = identity.symbol_id,
        .declaration = identity.declaration,
        .type_id = identity.type_id,
        .namespace = switch (identity.namespace) {
            .value => .value,
            .type => .type,
        },
        .external_module_id = if (identity.external_module_id) |id| .init(id) else null,
        .external_symbol_id = if (identity.external_symbol_id) |id| .init(id) else null,
    };
}

fn containsModule(items: []const project_mod.ModuleId, target: project_mod.ModuleId) bool {
    for (items) |item| if (item == target) return true;
    return false;
}

fn lessModuleId(_: void, left: project_mod.ModuleId, right: project_mod.ModuleId) bool {
    return left.value() < right.value();
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
