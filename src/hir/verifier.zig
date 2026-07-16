//! Deterministic structural, semantic, and canonical HIR v1 verification.

const std = @import("std");
const builder_mod = @import("builder.zig");
const canonicalize = @import("canonicalize.zig");
const diagnostics = @import("diagnostics.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");
const region_validation = @import("region_validation.zig");

pub const Phase = enum { raw, canonical };
pub const Error = std.mem.Allocator.Error;

const Definition = struct { block: usize, position: usize };

const Context = struct {
    builder: *const builder_mod.Builder,
    function: *const model.HirFunction,
    definitions: []const ?Definition,
    dominators: []const bool,

    fn validValue(self: Context, value: ids.ValueId, block: usize, position: usize) bool {
        if (!ownedInRange(self.builder, value, self.builder.budget.usage.values)) return false;
        const definition = self.definitions[value.index().?] orelse return false;
        if (definition.block == block) return definition.position < position;
        return self.dominators[block * self.function.blocks.len + definition.block];
    }
};

/// Verifies the current builder state without trusting any ID as an index.
/// The first failure is stable because all walks follow serialized HIR order.
pub fn verifyBuilder(allocator: std.mem.Allocator, builder: *const builder_mod.Builder, phase: Phase) Error!?diagnostics.Code {
    if (builder.result.project.version != model.schema_version) return .internal_invariant;
    if (builder.modules.items.len > builder.result.semanticResult().modules.len) return .invalid_semantic_reference;
    if (!validMetadata(builder)) return .invalid_semantic_reference;

    for (builder.modules.items, 0..) |module, module_index| {
        if (builder.result.semanticResult().lookupModule(module.module_id.value()) == null) return .invalid_semantic_reference;
        for (builder.modules.items[0..module_index]) |prior| if (prior.module_id.value() == module.module_id.value()) return .internal_invariant;
        if (!validOrigin(builder, module.origin)) return .invalid_semantic_reference;
        if (!validFunction(builder, module.initialization)) return .internal_invariant;
        for (module.dependencies) |dependency| if (!hasModule(builder, dependency.module_id)) return .invalid_semantic_reference;
        for (module.entities) |entity| if (!validEntity(builder, entity)) return .internal_invariant;
        for (module.imports) |item| if (item.local) |binding| if (!ownedInRange(builder, binding, builder.budget.usage.bindings)) return .invalid_value_binding_or_place;
        for (module.exports) |item| {
            if (item.binding) |binding| if (!ownedInRange(builder, binding, builder.budget.usage.bindings)) return .invalid_value_binding_or_place;
            if (item.entity) |entity| if (!validEntity(builder, entity)) return .internal_invariant;
        }
    }

    for (builder.entities.items, 0..) |entity, index| {
        if (!ownedAt(builder, entity.id, index) or !hasModule(builder, entity.module_id)) return .internal_invariant;
        if (!validOrigin(builder, entity.origin)) return .invalid_semantic_reference;
        switch (entity.kind) {
            .function => |item| if (!validFunction(builder, item.function)) return .internal_invariant,
            .class => |item| {
                if (!validFunction(builder, item.constructor)) return .internal_invariant;
                if (item.instance_initializer) |id| if (!validFunction(builder, id)) return .internal_invariant;
                if (item.static_initializer) |id| if (!validFunction(builder, id)) return .internal_invariant;
                for (item.methods) |method| if (!validFunction(builder, method.function)) return .internal_invariant;
            },
            .enum_object => |item| if (!ownedInRange(builder, item.binding, builder.budget.usage.bindings)) return .invalid_value_binding_or_place,
            .module_binding => |item| if (!ownedInRange(builder, item.binding, builder.budget.usage.bindings)) return .invalid_value_binding_or_place,
        }
    }
    for (builder.regions.items, 0..) |region, index| {
        if (!ownedAt(builder, region.id, index) or !validFunction(builder, region.function) or !validOrigin(builder, region.origin)) return .invalid_region;
    }
    for (builder.functions.items, 0..) |*function, index| {
        if (!ownedAt(builder, function.id, index) or !hasModule(builder, function.module_id)) return .internal_invariant;
        if (try verifyFunction(allocator, builder, function, phase)) |code| return code;
    }
    return null;
}

fn validMetadata(builder: *const builder_mod.Builder) bool {
    if (builder.debug_level == .none and (builder.origins.items.len != 0 or builder.trace_events.items.len != 0)) return false;
    if (builder.debug_level == .minimal and builder.trace_events.items.len != 0) return false;
    for (builder.origins.items, 0..) |record, index| {
        if (!hasModule(builder, record.module_id) or record.primary_span.start > record.primary_span.end or record.ast_nodes.len == 0) return false;
        if (record.type_id) |type_id| if (!validType(builder, type_id)) return false;
        if (record.symbol) |symbol| if (symbol.module_id != record.module_id.value()) return false;
        if (record.parent) |parent| {
            if (!ownedInRange(builder, parent, builder.origins.items.len)) return false;
            if (parent.index().? >= index) return false;
        }
    }
    for (builder.trace_events.items) |event| {
        if (builder.debug_level != .full or event.inputs.len == 0) return false;
        for (event.inputs) |input| if (!ownedInRange(builder, input, builder.origins.items.len)) return false;
        if (event.output) |output| if (!ownedInRange(builder, output, builder.origins.items.len)) return false;
    }
    return true;
}

fn verifyFunction(allocator: std.mem.Allocator, builder: *const builder_mod.Builder, function: *const model.HirFunction, phase: Phase) Error!?diagnostics.Code {
    if (!validType(builder, function.signature_type) or function.blocks.len == 0 or findBlock(function, function.entry) == null) return .invalid_cfg;
    if (!validOrigin(builder, function.origin)) return .invalid_semantic_reference;
    if (function.kind == .constructor and !function.flags.constructor) return .illegal_operation;
    if (function.kind == .getter and !function.flags.getter) return .illegal_operation;
    if (function.kind == .setter and !function.flags.setter) return .illegal_operation;
    if (function.flags.async_generator and (!function.flags.async_ or function.flags.generator)) return .illegal_operation;

    const seen_bindings = try allocator.alloc(bool, builder.budget.usage.bindings);
    defer allocator.free(seen_bindings);
    @memset(seen_bindings, false);
    for (function.bindings) |binding| {
        if (!markOwned(builder, binding.id, seen_bindings) or !validType(builder, binding.type_id) or !validOrigin(builder, binding.origin)) return .invalid_value_binding_or_place;
    }
    for (function.parameters) |parameter| {
        if (!localBinding(function, parameter.binding) or !validType(builder, parameter.type_id) or !validOrigin(builder, parameter.origin)) return .invalid_value_binding_or_place;
    }
    for (function.captures) |capture| {
        if (!localBinding(function, capture.local)) return .invalid_value_binding_or_place;
        if (capture.source == .binding and !ownedInRange(builder, capture.source.binding, builder.budget.usage.bindings)) return .invalid_value_binding_or_place;
    }

    const seen_blocks = try allocator.alloc(bool, builder.budget.usage.blocks);
    defer allocator.free(seen_blocks);
    @memset(seen_blocks, false);
    const seen_instructions = try allocator.alloc(bool, builder.budget.usage.instructions);
    defer allocator.free(seen_instructions);
    @memset(seen_instructions, false);
    const definitions = try allocator.alloc(?Definition, builder.budget.usage.values);
    defer allocator.free(definitions);
    @memset(definitions, null);

    for (function.blocks, 0..) |block, block_index| {
        if (!markOwned(builder, block.id, seen_blocks) or !validOrigin(builder, block.origin)) return .invalid_cfg;
        for (block.parameters) |parameter| {
            if (!validType(builder, parameter.type_id) or !validOrigin(builder, parameter.origin) or !defineValue(builder, definitions, parameter.value, .{ .block = block_index, .position = 0 })) return .invalid_value_binding_or_place;
        }
        for (block.instructions, 0..) |instruction, instruction_index| {
            if (!markOwned(builder, instruction.id, seen_instructions)) return .internal_invariant;
            if (!validOrigin(builder, instruction.origin)) return .invalid_semantic_reference;
            if ((instruction.result == null) != (instruction.result_type == null)) return .illegal_operation;
            if ((instruction.result != null) != instruction.operation.producesValue()) return .illegal_operation;
            if (instruction.operation.checked()) |checked| {
                _ = checked;
            } else |_| return .illegal_operation;
            if (!std.meta.eql(instruction.effects, instruction.operation.effectSet())) return .illegal_operation;
            if (instruction.result_type) |type_id| if (!validType(builder, type_id)) return .invalid_semantic_reference;
            if (instruction.result) |value| if (!defineValue(builder, definitions, value, .{ .block = block_index, .position = instruction_index + 1 })) return .invalid_value_binding_or_place;
        }
    }

    const matrix_size = std.math.mul(usize, function.blocks.len, function.blocks.len) catch return .internal_invariant;
    const dominators = try computeDominators(allocator, function, builder.regions.items, matrix_size);
    defer allocator.free(dominators);
    const context = Context{ .builder = builder, .function = function, .definitions = definitions, .dominators = dominators };

    const seen_places = try allocator.alloc(bool, builder.budget.usage.places);
    defer allocator.free(seen_places);
    @memset(seen_places, false);
    for (function.places) |place| {
        if (!markOwned(builder, place.id, seen_places) or !validOrigin(builder, place.origin)) return .invalid_value_binding_or_place;
        switch (place.kind) {
            .binding => |binding| if (!localBinding(function, binding)) return .invalid_value_binding_or_place,
            .property => |item| {
                if (!valueDefined(builder, definitions, item.base) or !keyDefined(builder, definitions, item.key)) return .invalid_value_binding_or_place;
            },
            .element => |item| if (!valueDefined(builder, definitions, item.base) or !valueDefined(builder, definitions, item.key)) return .invalid_value_binding_or_place,
            .super_property => |item| if (!function.flags.uses_super or !valueDefined(builder, definitions, item.receiver) or !keyDefined(builder, definitions, item.key)) return .invalid_value_binding_or_place,
        }
    }

    for (function.blocks, 0..) |block, block_index| {
        for (block.instructions, 0..) |instruction, instruction_index| {
            if (verifyOperation(context, instruction, block_index, instruction_index + 1, phase)) |code| return code;
        }
        if (verifyTerminator(context, block.terminator, block_index, block.instructions.len + 1)) |code| return code;
    }
    region_validation.validateFunction(allocator, function, builder.regions.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRegion => return .invalid_region,
    };
    if (phase == .canonical) if (try verifyCanonical(allocator, builder, function)) |code| return code;
    return null;
}

fn verifyOperation(context: Context, instruction: model.HirInstruction, block: usize, position: usize, phase: Phase) ?diagnostics.Code {
    const operation = instruction.operation;
    if (!verifyValueIds(@TypeOf(operation), operation, context, block, position)) return .invalid_value_binding_or_place;
    switch (operation) {
        .load_binding => |binding| if (!localBinding(context.function, binding)) return .invalid_value_binding_or_place,
        .initialize_binding => |item| if (!localBinding(context.function, item.binding)) return .invalid_value_binding_or_place,
        .store_binding => |item| {
            const binding = findBinding(context.function, item.binding) orelse return .invalid_value_binding_or_place;
            if (!binding.mutable or binding.initial_state == .live_import) return .invalid_value_binding_or_place;
        },
        .make_binding_place => |item| if (!matchingPlace(context.function, item.result, .{ .binding = item.binding })) return .invalid_value_binding_or_place,
        .make_property_place => |item| if (!matchingPlace(context.function, item.result, .{ .property = .{ .base = item.base, .key = item.key } })) return .invalid_value_binding_or_place,
        .make_element_place => |item| if (!matchingPlace(context.function, item.result, .{ .element = .{ .base = item.base, .key = item.key } })) return .invalid_value_binding_or_place,
        .make_super_place => |item| if (!context.function.flags.uses_super or !matchingPlace(context.function, item.result, .{ .super_property = .{ .receiver = item.receiver, .key = item.key } })) return .invalid_value_binding_or_place,
        .load_place, .delete_place => |place| if (findPlace(context.function, place) == null) return .invalid_value_binding_or_place,
        .store_place => |item| {
            const place = findPlace(context.function, item.place) orelse return .invalid_value_binding_or_place;
            if (place.kind == .binding) {
                const binding = findBinding(context.function, place.kind.binding) orelse return .invalid_value_binding_or_place;
                if (!binding.mutable or binding.initial_state == .live_import) return .invalid_value_binding_or_place;
            }
        },
        .create_closure => |id| if (!validFunction(context.builder, id)) return .internal_invariant,
        .create_class => |item| if (!validEntity(context.builder, item.entity)) return .internal_invariant,
        .create_enum_object => |id| if (!validEntity(context.builder, id)) return .internal_invariant,
        .define_method => |item| if (!validFunction(context.builder, item.function)) return .internal_invariant,
        .create_regexp => |item| if (!ownedInRange(context.builder, item.source_site, context.builder.source_sites)) return .invalid_semantic_reference,
        .create_template_site => |item| if (!ownedInRange(context.builder, item.source_site, context.builder.source_sites)) return .invalid_semantic_reference,
        .await_ => if (!context.function.flags.async_) return .illegal_operation,
        .yield_, .yield_delegate => if (!context.function.flags.generator and !context.function.flags.async_generator) return .illegal_operation,
        .load_super, .call_super_method => if (!context.function.flags.uses_super) return .illegal_operation,
        .call_super_constructor => if (!context.function.flags.constructor or !context.function.flags.uses_super) return .illegal_operation,
        .load_meta => |kind| if (kind == .new_target and !context.function.flags.uses_new_target) return .illegal_operation,
        else => {},
    }
    if (phase == .canonical and ((operation == .copy and canonicalize.copyCanBeEliminated(context.function, instruction)) or operation == .void_value)) return .internal_invariant;
    return null;
}

fn verifyTerminator(context: Context, terminator: model.HirTerminator, block: usize, position: usize) ?diagnostics.Code {
    if (!verifyValueIds(@TypeOf(terminator), terminator, context, block, position)) return .invalid_value_binding_or_place;
    switch (terminator) {
        .jump => |jump| if (!validTarget(context, jump.target, jump.arguments)) return .invalid_cfg,
        .branch => |branch| {
            if (!validEmptyTarget(context.function, branch.true_target) or !validEmptyTarget(context.function, branch.false_target)) return .invalid_cfg;
        },
        .leave_region => |leave| {
            if (!listedRegion(context.function, leave.region) or !validEmptyTarget(context.function, leave.cleanup)) return .invalid_region;
            switch (leave.completion) {
                .normal => |target| if (target) |id| if (!validEmptyTarget(context.function, id)) return .invalid_cfg,
                .break_, .continue_ => |id| if (!validEmptyTarget(context.function, id)) return .invalid_cfg,
                else => {},
            }
        },
        else => {},
    }
    return null;
}

fn verifyCanonical(allocator: std.mem.Allocator, builder: *const builder_mod.Builder, function: *const model.HirFunction) Error!?diagnostics.Code {
    const uses = try allocator.alloc(usize, builder.budget.usage.values);
    defer allocator.free(uses);
    @memset(uses, 0);
    for (function.places) |place| countValues(@TypeOf(place.kind), place.kind, uses);
    for (function.blocks) |block| {
        for (block.instructions) |instruction| countValues(@TypeOf(instruction.operation), instruction.operation, uses);
        countValues(@TypeOf(block.terminator), block.terminator, uses);
    }
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |value| if (instruction.effects.pure and !instruction.effects.creates_identity and uses[value.index().?] == 0) return .internal_invariant;
    };
    var reachable = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var pending: std.ArrayList(ids.BlockId) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, function.entry);
    for (function.regions) |region_id| if (findRegion(builder.regions.items, region_id)) |region| {
        try pending.append(allocator, region.handler);
        if (region.continuation) |continuation| try pending.append(allocator, continuation);
        try pending.appendSlice(allocator, region.protected_blocks);
    };
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const index = blockIndex(function, pending.items[cursor]) orelse return .invalid_cfg;
        if (reachable[index]) continue;
        reachable[index] = true;
        try appendSuccessors(allocator, &pending, function.blocks[index].terminator);
    }
    for (reachable) |item| if (!item) return .internal_invariant;
    for (function.blocks) |block| {
        if (!block.id.eql(function.entry) and block.parameters.len == 0 and block.instructions.len == 0 and block.terminator == .jump and block.terminator.jump.arguments.len == 0 and !block.terminator.jump.target.eql(block.id) and !regionBoundary(builder, function.id, block.id)) return .internal_invariant;
    }
    return null;
}

fn computeDominators(allocator: std.mem.Allocator, function: *const model.HirFunction, regions: []const model.HirRegion, matrix_size: usize) Error![]bool {
    const count = function.blocks.len;
    const result = try allocator.alloc(bool, matrix_size);
    errdefer allocator.free(result);
    const next = try allocator.alloc(bool, count);
    defer allocator.free(next);
    @memset(result, true);
    for (0..count) |block| {
        var has_predecessor = false;
        for (0..count) |source| if (edgeTo(function, regions, source, block)) {
            has_predecessor = true;
            break;
        };
        if (!has_predecessor or function.blocks[block].id.eql(function.entry)) {
            @memset(result[block * count ..][0..count], false);
            result[block * count + block] = true;
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (0..count) |block| {
            if (function.blocks[block].id.eql(function.entry)) continue;
            var first = true;
            @memset(next, false);
            for (0..count) |source| if (edgeTo(function, regions, source, block)) {
                if (first) {
                    @memcpy(next, result[source * count ..][0..count]);
                    first = false;
                } else for (next, result[source * count ..][0..count]) |*slot, predecessor| slot.* = slot.* and predecessor;
            };
            if (first) continue;
            next[block] = true;
            for (next, result[block * count ..][0..count]) |value, old| if (value != old) {
                changed = true;
                break;
            };
            @memcpy(result[block * count ..][0..count], next);
        }
    }
    return result;
}

fn edgeTo(function: *const model.HirFunction, regions: []const model.HirRegion, source: usize, target: usize) bool {
    const source_id = function.blocks[source].id;
    const target_id = function.blocks[target].id;
    const terminator_edge = switch (function.blocks[source].terminator) {
        .jump => |item| item.target.eql(target_id),
        .branch => |item| item.true_target.eql(target_id) or item.false_target.eql(target_id),
        .leave_region => |item| item.cleanup.eql(target_id) or switch (item.completion) {
            .normal => |id| if (id) |value| value.eql(target_id) else false,
            .break_, .continue_ => |id| id.eql(target_id),
            else => false,
        },
        else => false,
    };
    if (terminator_edge) return true;
    for (function.regions) |region_id| if (findRegion(regions, region_id)) |region| {
        if (region.handler.eql(target_id)) for (region.protected_blocks) |protected| if (protected.eql(source_id)) return true;
    };
    return false;
}

fn verifyValueIds(comptime T: type, input: T, context: Context, block: usize, position: usize) bool {
    if (T == ids.ValueId) return context.validValue(input, block, position);
    return switch (@typeInfo(T)) {
        .optional => if (input) |item| verifyValueIds(@TypeOf(item), item, context, block, position) else true,
        .pointer => |info| if (info.size == .slice) blk: {
            for (input) |item| if (!verifyValueIds(info.child, item, context, block, position)) break :blk false;
            break :blk true;
        } else true,
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (!verifyValueIds(field.type, @field(input, field.name), context, block, position)) break :blk false;
            break :blk true;
        },
        .@"union" => switch (input) {
            inline else => |item| verifyValueIds(@TypeOf(item), item, context, block, position),
        },
        else => true,
    };
}

fn countValues(comptime T: type, input: T, counts: []usize) void {
    if (T == ids.ValueId) {
        if (input.index()) |index| {
            if (index < counts.len) counts[index] += 1;
        }
        return;
    }
    switch (@typeInfo(T)) {
        .optional => if (input) |item| countValues(@TypeOf(item), item, counts),
        .pointer => |info| if (info.size == .slice) for (input) |item| countValues(info.child, item, counts),
        .@"struct" => |info| inline for (info.fields) |field| countValues(field.type, @field(input, field.name), counts),
        .@"union" => switch (input) {
            inline else => |item| countValues(@TypeOf(item), item, counts),
        },
        else => {},
    }
}

fn ownedInRange(builder: *const builder_mod.Builder, id: anytype, limit: usize) bool {
    return id.isValidFor(builder.result.identity_domain) and id.index().? < limit;
}
fn ownedAt(builder: *const builder_mod.Builder, id: anytype, index: usize) bool {
    return ownedInRange(builder, id, index + 1) and id.index().? == index;
}
fn markOwned(builder: *const builder_mod.Builder, id: anytype, seen: []bool) bool {
    if (!ownedInRange(builder, id, seen.len)) return false;
    const index = id.index().?;
    if (seen[index]) return false;
    seen[index] = true;
    return true;
}
fn defineValue(builder: *const builder_mod.Builder, definitions: []?Definition, id: ids.ValueId, definition: Definition) bool {
    if (!ownedInRange(builder, id, definitions.len)) return false;
    const index = id.index().?;
    if (definitions[index] != null) return false;
    definitions[index] = definition;
    return true;
}
fn valueDefined(builder: *const builder_mod.Builder, definitions: []const ?Definition, id: ids.ValueId) bool {
    return ownedInRange(builder, id, definitions.len) and definitions[id.index().?] != null;
}
fn validType(builder: *const builder_mod.Builder, id: model.TypeId) bool {
    return id != 0 and builder.result.semanticResult().type_store.lookup(id) != null;
}
fn validOrigin(builder: *const builder_mod.Builder, id: ids.OriginId) bool {
    if (builder.debug_level == .none) return id.eql(.invalid);
    return ownedInRange(builder, id, builder.origins.items.len);
}
fn hasModule(builder: *const builder_mod.Builder, id: model.ModuleId) bool {
    for (builder.modules.items) |module| if (module.module_id.value() == id.value()) return true;
    return false;
}
fn validFunction(builder: *const builder_mod.Builder, id: ids.FunctionId) bool {
    return ownedInRange(builder, id, builder.functions.items.len) and builder.functions.items[id.index().?].id.eql(id);
}
fn validEntity(builder: *const builder_mod.Builder, id: ids.EntityId) bool {
    return ownedInRange(builder, id, builder.entities.items.len) and builder.entities.items[id.index().?].id.eql(id);
}
fn localBinding(function: *const model.HirFunction, id: ids.BindingId) bool {
    return findBinding(function, id) != null;
}
fn findBinding(function: *const model.HirFunction, id: ids.BindingId) ?*const model.HirBinding {
    for (function.bindings) |*binding| if (binding.id.eql(id)) return binding;
    return null;
}
fn findPlace(function: *const model.HirFunction, id: ids.PlaceId) ?*const model.HirPlace {
    for (function.places) |*place| if (place.id.eql(id)) return place;
    return null;
}
fn matchingPlace(function: *const model.HirFunction, id: ids.PlaceId, expected: model.HirPlace.Kind) bool {
    const place = findPlace(function, id) orelse return false;
    return std.meta.eql(place.kind, expected);
}
fn keyDefined(builder: *const builder_mod.Builder, definitions: []const ?Definition, key: model.PropertyKey) bool {
    return key != .computed or valueDefined(builder, definitions, key.computed);
}
fn findBlock(function: *const model.HirFunction, id: ids.BlockId) ?*const model.HirBlock {
    const index = blockIndex(function, id) orelse return null;
    return &function.blocks[index];
}
fn blockIndex(function: *const model.HirFunction, id: ids.BlockId) ?usize {
    for (function.blocks, 0..) |block, index| if (block.id.eql(id)) return index;
    return null;
}
fn validTarget(context: Context, id: ids.BlockId, arguments: []const ids.ValueId) bool {
    const block = findBlock(context.function, id) orelse return false;
    if (block.parameters.len != arguments.len) return false;
    for (block.parameters, arguments) |parameter, argument| {
        const index = argument.index() orelse return false;
        if (index >= context.definitions.len) return false;
        const definition = context.definitions[index] orelse return false;
        _ = definition;
        const argument_type = valueType(context.function, argument) orelse return false;
        if (argument_type != parameter.type_id) return false;
    }
    return true;
}
fn validEmptyTarget(function: *const model.HirFunction, id: ids.BlockId) bool {
    const block = findBlock(function, id) orelse return false;
    return block.parameters.len == 0;
}
fn valueType(function: *const model.HirFunction, id: ids.ValueId) ?model.TypeId {
    for (function.blocks) |block| {
        for (block.parameters) |parameter| if (parameter.value.eql(id)) return parameter.type_id;
        for (block.instructions) |instruction| if (instruction.result) |result| if (result.eql(id)) return instruction.result_type;
    }
    return null;
}
fn listedRegion(function: *const model.HirFunction, id: ids.RegionId) bool {
    for (function.regions) |item| if (item.eql(id)) return true;
    return false;
}
fn findRegion(regions: []const model.HirRegion, id: ids.RegionId) ?*const model.HirRegion {
    for (regions) |*region| if (region.id.eql(id)) return region;
    return null;
}
fn regionBoundary(builder: *const builder_mod.Builder, function: ids.FunctionId, block: ids.BlockId) bool {
    for (builder.regions.items) |region| if (region.function.eql(function)) {
        if (region.handler.eql(block)) return true;
        if (region.continuation) |id| if (id.eql(block)) return true;
        for (region.protected_blocks) |id| if (id.eql(block)) return true;
    };
    return false;
}
fn appendSuccessors(allocator: std.mem.Allocator, pending: *std.ArrayList(ids.BlockId), terminator: model.HirTerminator) Error!void {
    switch (terminator) {
        .jump => |item| try pending.append(allocator, item.target),
        .branch => |item| {
            try pending.append(allocator, item.true_target);
            try pending.append(allocator, item.false_target);
        },
        .leave_region => |item| {
            try pending.append(allocator, item.cleanup);
            switch (item.completion) {
                .normal => |target| if (target) |id| try pending.append(allocator, id),
                .break_, .continue_ => |id| try pending.append(allocator, id),
                else => {},
            }
        },
        else => {},
    }
}
