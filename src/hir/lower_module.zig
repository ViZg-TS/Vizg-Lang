//! Deterministic lowering of one source-module shell.

const std = @import("std");
const builder_mod = @import("builder.zig");
const lower_body = @import("lower_body.zig");
const lower_project_index = @import("lower_project_index.zig");
const model = @import("model.zig");
const project_mod = @import("../project/root.zig");
const region_validation = @import("region_validation.zig");
const semantics = @import("../semantics/root.zig");

pub fn lower(
    builder: *builder_mod.Builder,
    module: *const project_mod.ProjectModule,
    inputs: lower_project_index.ModuleInputs,
) !void {
    const semantic_result = builder.result.semanticResult();
    const module_id = module.id.value();
    const source = module.source.?;
    const dependencies = try lowerDependencies(builder, inputs.dependencies);

    const semantic_imports = inputs.imports;
    const imports = try builder.allocator.alloc(model.HirImportBinding, semantic_imports.len);
    var bindings: std.ArrayList(model.HirBinding) = .empty;
    var imported_symbols: std.ArrayList(lower_body.SymbolBinding) = .empty;
    for (semantic_imports, 0..) |item, index| {
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
            try imported_symbols.append(builder.allocator, .{
                .symbol = symbol_id,
                .binding = binding_id,
                .intrinsic_id = if (target.intrinsic_id) |id| .init(id) else null,
                .intrinsic_effects = if (target.external_effects) |effects| intrinsicEffects(effects) else null,
            });
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
            .namespace = item.state == .namespace,
        };
    }

    const semantic_exports = inputs.exports;
    const body = try lower_body.lower(
        builder,
        module,
        @import("ids.zig").FunctionId.invalid,
        bindings.items,
        imported_symbols.items,
        inputs.dynamic_imports,
    );
    const exports = try builder.allocator.alloc(model.HirExportBinding, semantic_exports.len);
    for (semantic_exports, 0..) |item, index| {
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

pub fn semanticIdentity(identity: semantics.SemanticIdentity) model.HirSemanticIdentity {
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
        .intrinsic_id = if (identity.intrinsic_id) |id| .init(id) else null,
        .host_binding_id = identity.host_binding_id,
    };
}

fn intrinsicEffects(effect_set: project_mod.ExternalEffectSet) model.EffectSet {
    if (effect_set.unknown) return model.EffectSet.call_effect;
    const impure = effect_set.reads_memory or effect_set.writes_memory or effect_set.may_throw or
        effect_set.may_suspend or effect_set.allocates or effect_set.calls_unknown;
    return .{
        .pure = !impure,
        .may_throw = effect_set.may_throw,
        .may_call_user_code = effect_set.calls_unknown,
        .reads_state = effect_set.reads_memory,
        .writes_state = effect_set.writes_memory,
        .may_suspend = effect_set.may_suspend,
        .creates_identity = effect_set.allocates,
    };
}

fn lowerDependencies(
    builder: *builder_mod.Builder,
    seeds: []const lower_project_index.DependencySeed,
) ![]const model.HirModuleDependency {
    var unique_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < seeds.len) {
        unique_count += 1;
        const module_id = seeds[cursor].module_id;
        cursor += 1;
        while (cursor < seeds.len and seeds[cursor].module_id == module_id) : (cursor += 1) {}
    }

    const dependencies = try builder.allocator.alloc(model.HirModuleDependency, unique_count);
    cursor = 0;
    var output_index: usize = 0;
    while (cursor < seeds.len) {
        const module_id = seeds[cursor].module_id;
        var module_evaluation = false;
        while (cursor < seeds.len and seeds[cursor].module_id == module_id) : (cursor += 1)
            module_evaluation = module_evaluation or seeds[cursor].module_evaluation;
        dependencies[output_index] = .{
            .module_id = module_id,
            .initialization_required = true,
            .module_evaluation = module_evaluation,
        };
        output_index += 1;
    }
    return dependencies;
}
