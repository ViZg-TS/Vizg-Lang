//! Deterministic post-lowering provenance attachment. This pass changes only
//! metadata fields and side tables; operations, IDs, CFG, and types are kept.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const builder_mod = @import("builder.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const origin = @import("origin.zig");
const project_mod = @import("../project/root.zig");
const trace = @import("trace.zig");

pub fn attach(builder: *builder_mod.Builder, project: *const project_mod.Project) !void {
    if (builder.debug_level == .none) return;
    for (builder.modules.items) |*module| {
        const source_module = project.lookup(module.module_id) orelse return error.MissingModule;
        const semantic = source_module.semantic_result orelse return error.MissingSemanticResult;
        const tree = semantic.frontend.ast;
        const root = tree.node(tree.root);
        const nodes = try builder.allocator.dupe(ast.NodeId, &.{tree.root});
        const root_origin = try builder.appendOrigin(.{
            .module_id = module.module_id,
            .primary_span = root.span,
            .ast_nodes = nodes,
            .original_syntax = std.meta.activeTag(root.data),
            .type_id = semantic.lookupNodeType(tree.root),
            .lowering_rule = .module_initialization,
            .synthetic_reason = .module_entry,
        });
        module.origin = root_origin;
        try attachModule(builder, module.module_id, root_origin);
        if (builder.debug_level == .full) try recordSourceTransformations(builder, module.module_id, semantic.frontend.ast, root_origin);
    }
}

fn attachModule(builder: *builder_mod.Builder, module_id: model.ModuleId, value: ids.OriginId) !void {
    for (builder.entities.items) |*entity| {
        if (entity.module_id.value() == module_id.value()) entity.origin = value;
    }
    for (builder.functions.items) |*function| {
        if (function.module_id.value() != module_id.value()) continue;
        function.origin = value;
        const parameters = try builder.allocator.dupe(model.HirParameter, function.parameters);
        for (parameters) |*parameter| parameter.origin = value;
        function.parameters = parameters;
        const bindings = try builder.allocator.dupe(model.HirBinding, function.bindings);
        for (bindings) |*binding| binding.origin = value;
        function.bindings = bindings;
        const places = try builder.allocator.dupe(model.HirPlace, function.places);
        for (places) |*place| place.origin = value;
        function.places = places;
        const blocks = try builder.allocator.dupe(model.HirBlock, function.blocks);
        for (blocks) |*block| {
            block.origin = value;
            const block_parameters = try builder.allocator.dupe(model.HirBlockParameter, block.parameters);
            for (block_parameters) |*parameter| parameter.origin = value;
            block.parameters = block_parameters;
            const instructions = try builder.allocator.dupe(model.HirInstruction, block.instructions);
            for (instructions) |*instruction| instruction.origin = value;
            block.instructions = instructions;
        }
        function.blocks = blocks;
    }
    for (builder.regions.items) |*region| {
        const function_index = region.function.index() orelse continue;
        if (function_index < builder.functions.items.len and builder.functions.items[function_index].module_id.value() == module_id.value()) region.origin = value;
    }
}

fn recordSourceTransformations(builder: *builder_mod.Builder, module_id: model.ModuleId, tree: ast.Ast, parent: ids.OriginId) !void {
    for (tree.nodes, 0..) |node, index| {
        const kind: ?trace.EventKind = switch (node.data) {
            .SwitchStatement => .switch_to_dispatch,
            .ConditionalExpression => .conditional_to_branch,
            .BinaryExpression => |expression| if (expression.operator == .AmpersandAmpersand) .logical_and_to_branch else null,
            .AssignmentExpression => |expression| if (expression.operator != .Equal) .compound_assignment_to_place_load_store else null,
            .CallExpression => |expression| if (expression.optional) .optional_chain_to_nullish_branch else null,
            .MemberExpression => |expression| if (expression.optional) .optional_chain_to_nullish_branch else null,
            .ElementAccessExpression => |expression| if (expression.optional) .optional_chain_to_nullish_branch else null,
            .ArrowFunctionExpression => .arrow_to_function,
            .InterfaceDeclaration => .interface_erased,
            .TypeAliasDeclaration => .type_alias_erased,
            else => null,
        };
        const event_kind = kind orelse continue;
        const node_id: ast.NodeId = @intCast(index);
        const nodes = try builder.allocator.dupe(ast.NodeId, &.{node_id});
        const event_origin = try builder.appendOrigin(.{
            .module_id = module_id,
            .primary_span = node.span,
            .ast_nodes = nodes,
            .original_syntax = std.meta.activeTag(node.data),
            .parent = parent,
            .lowering_rule = if (event_kind == .interface_erased or event_kind == .type_alias_erased) .declaration else .control_flow,
            .synthetic_reason = if (event_kind == .interface_erased or event_kind == .type_alias_erased) .missing_source else .control_flow,
        });
        const inputs = try builder.allocator.dupe(ids.OriginId, &.{event_origin});
        try builder.appendTrace(.{ .kind = event_kind, .inputs = inputs, .output = if (event_kind == .interface_erased or event_kind == .type_alias_erased) null else parent });
    }
}
