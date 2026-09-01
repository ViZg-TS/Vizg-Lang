const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
const consumer_index = @import("consumer_index.zig");
const types = @import("../types/root.zig");

pub const trigger_canonical_array_base: u32 = 1 << 0;
pub const trigger_place_deleted: u32 = 1 << 1;
pub const trigger_primitive_string_base: u32 = 1 << 2;
pub const trigger_string_concat_add: u32 = 1 << 3;
const known_trigger_flags = trigger_canonical_array_base | trigger_place_deleted | trigger_primitive_string_base | trigger_string_concat_add;

/// Host-defined hidden semantic dependency. `operation_tag` is the stable HIR
/// operation ordinal exported by the HIR ABI; `language_item_id` is opaque to
/// ViZG and is matched only by stable identity.
pub const LanguageItemTrigger = extern struct {
    operation_tag: u32,
    flags: u32,
    language_item_id: u64,
};

pub const Request = struct {
    public_modules: []const u64 = &.{},
    application_modules: []const u64 = &.{},
    language_item_triggers: []const LanguageItemTrigger = &.{},
};

pub const Output = struct {
    module_bits: []u64,
    function_bits: []u64,
    block_bits: []u64,
    instruction_bits: []u64,
    binding_bits: []u64,
    module_ordinals: []u32,
    function_ordinals: []u32,
    block_ordinals: []u32,
    instruction_ordinals: []u32,
    binding_ordinals: []u32,
    external_module_ids: []u64,
};

pub const Summary = struct {
    module_count: usize,
    function_count: usize,
    block_count: usize,
    instruction_count: usize,
    binding_count: usize,
    external_module_count: usize,
};

pub fn wordCount(bit_count: usize) usize {
    return bit_count / 64 + @intFromBool(bit_count % 64 != 0);
}

/// Exact scratch requirement when `scratch` begins at u64 alignment. The
/// analysis uses bounded queues plus private bitsets only; no root-dependent
/// allocation is retained by HirResult.
pub fn scratchSize(project: model.HirProject, index: *const consumer_index.Index) !usize {
    var bytes: usize = 0;
    bytes = try addBytes(bytes, u64, wordCount(index.value_producers.len));
    bytes = try addBytes(bytes, u64, wordCount(project.entities.len));
    bytes = try addBytes(bytes, u64, wordCount(index.external_module_ids.len));
    bytes = try addBytes(bytes, u32, project.modules.len);
    bytes = try addBytes(bytes, u32, project.functions.len);
    bytes = try addBytes(bytes, u32, index.bindings.len);
    bytes = try addBytes(bytes, u32, index.value_producers.len);
    bytes = try addBytes(bytes, u32, index.external_module_ids.len);
    return bytes;
}

pub fn analyze(
    scratch: []align(@alignOf(u64)) u8,
    project: model.HirProject,
    type_store: *const types.TypeStore,
    index: *const consumer_index.Index,
    request: Request,
    output: Output,
) !Summary {
    try validateOutput(project, index, output);
    try validateTriggers(request.language_item_triggers);
    @memset(output.module_bits, 0);
    @memset(output.function_bits, 0);
    @memset(output.block_bits, 0);
    @memset(output.instruction_bits, 0);
    @memset(output.binding_bits, 0);

    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    const allocator = fixed.allocator();
    const traced_value_bits = try allocator.alloc(u64, wordCount(index.value_producers.len));
    const traced_entity_bits = try allocator.alloc(u64, wordCount(project.entities.len));
    const external_bits = try allocator.alloc(u64, wordCount(index.external_module_ids.len));
    @memset(traced_value_bits, 0);
    @memset(traced_entity_bits, 0);
    @memset(external_bits, 0);

    const module_queue = try allocator.alloc(u32, project.modules.len);
    const function_queue = try allocator.alloc(u32, project.functions.len);
    const binding_queue = try allocator.alloc(u32, index.bindings.len);
    const value_queue = try allocator.alloc(u32, index.value_producers.len);
    const external_queue = try allocator.alloc(u32, index.external_module_ids.len);

    var state = State{
        .project = project,
        .type_store = type_store,
        .index = index,
        .request = request,
        .output = output,
        .traced_value_bits = traced_value_bits,
        .traced_entity_bits = traced_entity_bits,
        .external_bits = external_bits,
        .module_queue = module_queue,
        .function_queue = function_queue,
        .binding_queue = binding_queue,
        .value_queue = value_queue,
        .external_queue = external_queue,
    };

    for (request.application_modules) |raw| {
        const ordinal = index.module_ordinals.get(raw) orelse return error.UnknownArtifactRoot;
        try state.reachModuleOrdinal(ordinal);
    }
    for (request.public_modules) |raw| {
        const ordinal = index.module_ordinals.get(raw) orelse return error.UnknownArtifactRoot;
        try state.reachModuleOrdinal(ordinal);
        const module = project.modules[ordinal];
        for (module.exports) |export_binding| {
            if (export_binding.type_only) continue;
            if (export_binding.binding) |binding| {
                try state.traceBinding(binding);
            } else if (export_binding.entity) |entity| {
                try state.traceEntity(entity);
            } else {
                try state.traceSemanticIdentity(export_binding.target);
            }
        }
    }

    while (state.hasWork()) {
        if (state.module_head < state.module_len) {
            const ordinal = state.module_queue[state.module_head];
            state.module_head += 1;
            try state.processModule(ordinal);
            continue;
        }
        if (state.function_head < state.function_len) {
            const ordinal = state.function_queue[state.function_head];
            state.function_head += 1;
            try state.processFunction(ordinal);
            continue;
        }
        if (state.binding_head < state.binding_len) {
            const ordinal = state.binding_queue[state.binding_head];
            state.binding_head += 1;
            try state.processBinding(ordinal);
            continue;
        }
        if (state.value_head < state.value_len) {
            const ordinal = state.value_queue[state.value_head];
            state.value_head += 1;
            try state.processValue(ordinal);
            continue;
        }
    }

    // Expose canonical ordered reached ordinals from the same closure. VZed can
    // therefore traverse only reached HIR without rescanning every bitset or
    // rebuilding semantic membership.
    copySortedOrdinals(output.module_ordinals, state.module_queue[0..state.module_len]);
    copySortedOrdinals(output.function_ordinals, state.function_queue[0..state.function_len]);
    copySortedOrdinals(output.binding_ordinals, state.binding_queue[0..state.binding_len]);

    // Membership is finalized only after the semantic closure, because dead
    // binding-storage and closure-materialization decisions depend on the
    // reached binding/function sets. This is one linear pass over reached HIR,
    // not another semantic fixed point. Functions are consumed in canonical
    // ordinal order so block/instruction ordinal lists are canonical as well.
    const finalized = try state.finalizeInstructions(output.function_ordinals[0..state.function_len]);

    std.mem.sort(u32, state.external_queue[0..state.external_len], {}, lessU32);
    for (state.external_queue[0..state.external_len], 0..) |ordinal, output_index| {
        if (@as(usize, ordinal) >= index.external_module_ids.len) return error.InconsistentProjection;
        output.external_module_ids[output_index] = index.external_module_ids[ordinal];
    }
    return .{
        .module_count = state.module_len,
        .function_count = state.function_len,
        .block_count = finalized.block_count,
        .instruction_count = finalized.instruction_count,
        .binding_count = state.binding_len,
        .external_module_count = state.external_len,
    };
}

const State = struct {
    project: model.HirProject,
    type_store: *const types.TypeStore,
    index: *const consumer_index.Index,
    request: Request,
    output: Output,

    traced_value_bits: []u64,
    traced_entity_bits: []u64,
    external_bits: []u64,

    module_queue: []u32,
    function_queue: []u32,
    binding_queue: []u32,
    value_queue: []u32,
    external_queue: []u32,
    module_head: usize = 0,
    module_len: usize = 0,
    function_head: usize = 0,
    function_len: usize = 0,
    binding_head: usize = 0,
    binding_len: usize = 0,
    value_head: usize = 0,
    value_len: usize = 0,
    external_len: usize = 0,

    fn hasWork(self: *const State) bool {
        return self.module_head < self.module_len or
            self.function_head < self.function_len or
            self.binding_head < self.binding_len or
            self.value_head < self.value_len;
    }

    fn reachModuleOrdinal(self: *State, ordinal: u32) !void {
        if (@as(usize, ordinal) >= self.project.modules.len) return error.InconsistentProjection;
        if (!setBitNew(self.output.module_bits, ordinal)) return;
        if (self.module_len >= self.module_queue.len) return error.InconsistentProjection;
        self.module_queue[self.module_len] = ordinal;
        self.module_len += 1;
    }

    fn reachModule(self: *State, id: model.ModuleId) !void {
        const ordinal = self.index.moduleOrdinal(id) orelse return error.InconsistentProjection;
        try self.reachModuleOrdinal(ordinal);
    }

    fn reachFunctionOrdinal(self: *State, ordinal: u32) !void {
        if (@as(usize, ordinal) >= self.project.functions.len) return error.InconsistentProjection;
        if (!setBitNew(self.output.function_bits, ordinal)) return;
        if (self.function_len >= self.function_queue.len) return error.InconsistentProjection;
        self.function_queue[self.function_len] = ordinal;
        self.function_len += 1;
    }

    fn reachFunction(self: *State, id: ids.FunctionId) !void {
        const ordinal = self.index.functionOrdinal(id) orelse return error.InconsistentProjection;
        try self.reachFunctionOrdinal(ordinal);
    }

    fn traceBinding(self: *State, id: ids.BindingId) !void {
        const ordinal = self.index.bindingOrdinal(id) orelse return error.InconsistentProjection;
        if (!setBitNew(self.output.binding_bits, ordinal)) return;
        if (self.binding_len >= self.binding_queue.len) return error.InconsistentProjection;
        self.binding_queue[self.binding_len] = ordinal;
        self.binding_len += 1;
    }

    fn traceValue(self: *State, id: ids.ValueId) !void {
        const ordinal = self.index.valueOrdinal(id) orelse return error.InconsistentProjection;
        if (!setBitNew(self.traced_value_bits, ordinal)) return;
        if (self.value_len >= self.value_queue.len) return error.InconsistentProjection;
        self.value_queue[self.value_len] = ordinal;
        self.value_len += 1;
    }

    fn traceEntity(self: *State, id: ids.EntityId) !void {
        const ordinal = self.index.entityOrdinal(id) orelse return error.InconsistentProjection;
        if (!setBitNew(self.traced_entity_bits, ordinal)) return;
        const entity = self.project.entities[ordinal];
        switch (entity.kind) {
            .function => |value| try self.reachFunction(value.function),
            .class => |value| {
                try self.reachFunction(value.constructor);
                if (value.instance_initializer) |function| try self.reachFunction(function);
                if (value.static_initializer) |function| try self.reachFunction(function);
                for (value.methods) |method| try self.reachFunction(method.function);
            },
            .enum_object => |value| try self.traceBinding(value.binding),
            .module_binding => |value| try self.traceBinding(value.binding),
        }
    }

    fn traceSemanticIdentity(self: *State, identity: model.HirSemanticIdentity) !void {
        if (identity.external_module_id) |external| {
            try self.reachExternal(external);
            return;
        }
        if (identity.declaration.external) return;
        if (self.index.semanticProvider(identity.declaration)) |provider| {
            if (provider.binding_ordinal) |binding| {
                const item = self.index.binding(self.project, binding) orelse return error.InconsistentProjection;
                try self.traceBinding(item.id);
            }
            if (provider.entity_ordinal) |entity| try self.traceEntity(self.project.entities[entity].id);
            if (provider.function_ordinal) |function| try self.reachFunctionOrdinal(function);
            return;
        }
        // Some host/source-backed declarations carry provenance but no direct
        // local binding/entity shell. Only projected source modules may become
        // execution roots; external provenance is never reinterpreted here.
        if (self.index.module_ordinals.get(identity.declaration.module_id)) |module|
            try self.reachModuleOrdinal(module);
    }

    fn reachExternal(self: *State, id: model.ExternalModuleId) !void {
        const ordinal = self.index.externalModuleOrdinal(id) orelse return error.InconsistentProjection;
        if (!setBitNew(self.external_bits, ordinal)) return;
        if (self.external_len >= self.external_queue.len) return error.InconsistentProjection;
        self.external_queue[self.external_len] = ordinal;
        self.external_len += 1;
    }

    fn processModule(self: *State, ordinal: u32) !void {
        const module = self.project.modules[ordinal];
        try self.reachFunction(module.initialization);
        // HIR construction already owns runtime source-module execution edges.
        // Consume that canonical relationship directly so bare side-effect
        // imports and re-export chains are preserved without reconstructing
        // module execution semantics from local import bindings.
        for (module.dependencies) |dependency| {
            if (!dependency.initialization_required or !dependency.module_evaluation) continue;
            try self.reachModule(dependency.module_id);
        }
    }

    fn processFunction(self: *State, ordinal: u32) !void {
        const function = self.project.functions[ordinal];
        try self.reachModule(function.module_id);
        for (function.captures) |capture| switch (capture.source) {
            .binding => |source| try self.traceBinding(source),
            else => {},
        };
        for (function.blocks) |block| {
            const block_ordinal = self.index.blockOrdinal(block.id) orelse return error.InconsistentProjection;
            _ = setBitNew(self.output.block_bits, block_ordinal);
            try self.traceTerminator(block.terminator);
            for (block.instructions) |instruction| {
                try self.traceOperation(instruction.operation);
                try self.applyLanguageItemTriggers(instruction);
            }
        }
    }

    fn processBinding(self: *State, ordinal: u32) !void {
        const binding = self.index.binding(self.project, ordinal) orelse return error.InconsistentProjection;
        if (self.index.captureSource(binding.id)) |source| try self.traceBinding(source);

        if (self.index.importForBinding(self.project, binding.id)) |import_binding| {
            if (import_binding.type_only) return error.InconsistentProjection;
            switch (import_binding.source) {
                .source => |source| {
                    try self.reachModule(source);
                    if (import_binding.namespace)
                        try self.traceRuntimeExports(source)
                    else
                        try self.traceSemanticIdentity(import_binding.target);
                },
                .external => |external| try self.reachExternal(external),
            }
        } else if (binding.declaration) |declaration| {
            if (!declaration.external) {
                if (self.index.module_ordinals.get(declaration.module_id)) |module|
                    try self.reachModuleOrdinal(module);
            }
        }

        for (self.index.writersForBinding(binding.id)) |instruction_ordinal| {
            const instruction = self.index.instruction(self.project, instruction_ordinal) orelse return error.InconsistentProjection;
            switch (instruction.operation) {
                .initialize_binding => |payload| try self.traceValue(payload.value),
                .store_binding => |payload| try self.traceValue(payload.value),
                .store_place => |payload| try self.traceValue(payload.value),
                .apply_pattern => |plan| {
                    try self.traceValue(plan.source);
                    for (plan.items) |item| switch (item) {
                        .property_computed => |value| try self.traceValue(value),
                        .default_initializer => |value| try self.traceValue(value),
                        else => {},
                    };
                },
                else => return error.InconsistentProjection,
            }
        }
    }

    fn traceRuntimeExports(self: *State, module_id: model.ModuleId) !void {
        const module_ordinal = self.index.moduleOrdinal(module_id) orelse return error.InconsistentProjection;
        const module = self.project.modules[module_ordinal];
        for (module.exports) |export_binding| {
            if (export_binding.type_only) continue;
            if (export_binding.binding) |binding| {
                try self.traceBinding(binding);
            } else if (export_binding.entity) |entity| {
                try self.traceEntity(entity);
            } else {
                try self.traceSemanticIdentity(export_binding.target);
            }
        }
    }

    fn processValue(self: *State, ordinal: u32) !void {
        const instruction_ordinal = self.index.value_producers[ordinal] orelse return;
        const instruction = self.index.instruction(self.project, instruction_ordinal) orelse return error.InconsistentProjection;
        switch (instruction.operation) {
            .create_closure => |function| try self.reachFunction(function),
            .copy => |value| try self.traceValue(value),
            .load_binding => |binding| try self.traceBinding(binding),
            .create_class => |value| try self.traceEntity(value.entity),
            // A live dynamic-import operation always evaluates its resolved
            // module (handled by traceOperation). If the produced value itself
            // escapes/is consumed, the resolved source namespace becomes
            // observable and must retain its runtime export surface.
            .dynamic_import => |value| if (value.resolved) |resolved| switch (resolved) {
                .source => |module_id| try self.traceRuntimeExports(module_id),
                .external => {},
            },
            else => {},
        }
    }

    fn traceTerminator(self: *State, terminator: model.HirTerminator) !void {
        switch (terminator) {
            .jump => |jump| for (jump.arguments) |value| try self.traceValue(value),
            .branch => |branch| try self.traceValue(branch.condition),
            .return_ => |value| if (value) |present| try self.traceValue(present),
            .throw => |value| try self.traceValue(value),
            .unreachable_, .resume_completion => {},
            .leave_region => |leave| switch (leave.completion) {
                .return_ => |value| if (value) |present| try self.traceValue(present),
                .throw => |value| try self.traceValue(value),
                .normal, .break_, .continue_ => {},
            },
        }
    }

    fn traceOperation(self: *State, operation: model.HirOperation) !void {
        switch (operation) {
            // Declaration/storage aliases are reached only by a backwards use.
            .constant,
            .copy,
            .initialize_binding,
            .store_binding,
            .create_closure,
            .make_binding_place,
            .delete_place,
            => {},

            .load_this,
            .load_super,
            .load_meta,
            .create_object,
            .create_array,
            .create_enum_object,
            .create_regexp,
            .create_template_site,
            .collect_rest_arguments,
            .read_argument,
            .create_arguments_object,
            .debugger_trap,
            => {},

            .load_binding => |binding| try self.traceBinding(binding),

            .make_property_place => |value| if (self.index.placeIsConsumed(value.result)) {
                try self.traceValue(value.base);
                try self.tracePropertyKey(value.key);
            },
            .make_element_place => |value| if (self.index.placeIsConsumed(value.result)) {
                try self.traceValue(value.base);
                try self.traceValue(value.key);
            },
            .make_super_place => |value| if (self.index.placeIsConsumed(value.result)) {
                try self.traceValue(value.receiver);
                try self.tracePropertyKey(value.key);
            },
            .load_place => |place| if (self.index.bindingForPlace(place)) |binding|
                try self.traceBinding(binding),
            .store_place => |value| if (self.index.bindingForPlace(value.place) == null)
                try self.traceValue(value.value),

            .to_boolean,
            .is_nullish,
            .typeof_value,
            .void_value,
            .to_string,
            .get_iterator,
            .get_async_iterator,
            .iterator_next,
            .iterator_done,
            .iterator_value,
            .iterator_close,
            .enumerate_properties,
            .enumerator_next,
            .enumerator_done,
            .enumerator_value,
            .await_,
            .yield_,
            .yield_delegate,
            => |value| try self.traceValue(value),

            .unary => |value| try self.traceValue(value.operand),
            .binary => |value| {
                try self.traceValue(value.left);
                try self.traceValue(value.right);
            },
            .add => |value| {
                try self.traceValue(value.left);
                try self.traceValue(value.right);
            },
            .call, .construct => |value| {
                try self.traceValue(value.callee);
                try self.traceArguments(value.arguments);
            },
            .call_method, .call_super_method => |value| {
                if (value.callee) |callee| try self.traceValue(callee);
                try self.traceValue(value.receiver);
                try self.tracePropertyKey(value.key);
                try self.traceArguments(value.arguments);
            },
            .call_super_constructor => |arguments| try self.traceArguments(arguments),
            .tagged_template_call => |value| {
                try self.traceValue(value.tag);
                if (value.receiver) |receiver| try self.traceValue(receiver);
                try self.traceValue(value.template_site);
                for (value.substitutions) |substitution| try self.traceValue(substitution);
            },
            .dynamic_import => |value| {
                try self.traceValue(value.source);
                if (value.options) |options| try self.traceValue(options);
                if (value.resolved) |resolved| switch (resolved) {
                    .source => |module_id| try self.reachModule(module_id),
                    .external => |external_id| try self.reachExternal(external_id),
                };
            },
            .create_class => |value| {
                if (value.base) |base| try self.traceValue(base);
                try self.traceEntity(value.entity);
            },
            .define_property => |value| {
                try self.traceValue(value.object);
                try self.tracePropertyKey(value.key);
                try self.traceValue(value.value);
            },
            .define_method => |value| {
                try self.traceValue(value.object);
                try self.tracePropertyKey(value.key);
                // `function` is a FunctionId, never a ValueId. Keeping this
                // typed avoids the numeric-domain collision in the old ABI
                // fallback traversal.
                try self.reachFunction(value.function);
            },
            .copy_object_properties => |value| {
                try self.traceValue(value.target);
                try self.traceValue(value.source);
            },
            .array_append => |value| {
                try self.traceValue(value.array);
                try self.traceValue(value.value);
            },
            .array_append_hole => |array| try self.traceValue(array),
            .array_append_iterable => |value| {
                try self.traceValue(value.array);
                try self.traceValue(value.iterable);
            },
            .build_string => |parts| for (parts) |part| switch (part) {
                .text => {},
                .value => |value| try self.traceValue(value),
            },
            .apply_pattern => |plan| {
                try self.traceValue(plan.source);
                for (plan.items) |item| switch (item) {
                    .property_computed => |value| try self.traceValue(value),
                    .default_initializer => |value| try self.traceValue(value),
                    else => {},
                };
            },
            .intrinsic_call => |value| try self.traceArguments(value.arguments),
        }
    }

    fn traceArguments(self: *State, arguments: []const model.CallArgument) !void {
        for (arguments) |argument| try self.traceValue(argument.operand());
    }

    fn tracePropertyKey(self: *State, key: model.PropertyKey) !void {
        switch (key) {
            .computed => |value| try self.traceValue(value),
            .static, .private => {},
        }
    }

    fn applyLanguageItemTriggers(self: *State, instruction: model.HirInstruction) !void {
        if (self.deadPlaceDefinition(instruction.operation)) return;
        const operation_tag: u32 = @intFromEnum(std.meta.activeTag(instruction.operation));
        for (self.request.language_item_triggers) |trigger| {
            if (trigger.operation_tag != operation_tag) continue;
            if (!try self.triggerMatches(trigger, instruction.operation)) continue;
            const function = self.index.language_item_functions.get(trigger.language_item_id) orelse
                return error.InconsistentProjection;
            try self.reachFunctionOrdinal(function);
        }
    }

    fn deadPlaceDefinition(self: *const State, operation: model.HirOperation) bool {
        const place = switch (operation) {
            .make_binding_place => |value| value.result,
            .make_property_place => |value| value.result,
            .make_element_place => |value| value.result,
            .make_super_place => |value| value.result,
            else => return false,
        };
        return !self.index.placeIsConsumed(place);
    }

    fn triggerMatches(self: *State, trigger: LanguageItemTrigger, operation: model.HirOperation) !bool {
        if ((trigger.flags & trigger_canonical_array_base) != 0) {
            const base = switch (operation) {
                .make_property_place => |value| value.base,
                .make_element_place => |value| value.base,
                else => return false,
            };
            if (!try self.valueIsCanonicalArray(base)) return false;
        }
        if ((trigger.flags & trigger_primitive_string_base) != 0) {
            const base = switch (operation) {
                .make_property_place => |value| value.base,
                .make_element_place => |value| value.base,
                else => return false,
            };
            if (!try self.valueIsPrimitiveString(base)) return false;
        }
        if ((trigger.flags & trigger_place_deleted) != 0) {
            const place = switch (operation) {
                .make_property_place => |value| value.result,
                .make_element_place => |value| value.result,
                else => return false,
            };
            if (!self.index.placeIsDeleted(place)) return false;
        }
        if ((trigger.flags & trigger_string_concat_add) != 0) {
            const mode = switch (operation) {
                .add => |value| value.mode,
                else => return false,
            };
            if (mode != .string_concat) return false;
        }
        return true;
    }

    fn valueIsCanonicalArray(self: *State, value: ids.ValueId) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        return self.typeIsCanonicalArray(type_id, 0);
    }

    fn valueIsPrimitiveString(self: *State, value: ids.ValueId) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        const ty = self.type_store.lookup(type_id) orelse return error.InconsistentProjection;
        return switch (ty.kind) {
            .primitive => |primitive| primitive == .string,
            else => false,
        };
    }

    fn typeIsCanonicalArray(self: *State, type_id: model.TypeId, depth: usize) !bool {
        if (depth > 32) return error.InconsistentProjection;
        const ty = self.type_store.lookup(type_id) orelse return error.InconsistentProjection;
        return switch (ty.kind) {
            .array, .tuple => true,
            .applied_generic => |applied| try self.typeIsCanonicalArray(applied.resolved_target, depth + 1),
            else => false,
        };
    }

    const FinalizedCounts = struct { block_count: usize, instruction_count: usize };

    fn finalizeInstructions(self: *State, function_ordinals: []const u32) !FinalizedCounts {
        var block_count: usize = 0;
        var instruction_count: usize = 0;
        for (function_ordinals) |function_ordinal| {
            if (@as(usize, function_ordinal) >= self.project.functions.len) return error.InconsistentProjection;
            const function = self.project.functions[function_ordinal];
            for (function.blocks) |block| {
                const block_ordinal = self.index.blockOrdinal(block.id) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.output.block_bits, block_ordinal)) continue;
                if (block_count >= self.output.block_ordinals.len) return error.OutputTooSmall;
                self.output.block_ordinals[block_count] = block_ordinal;
                block_count += 1;
                for (block.instructions) |instruction| {
                    if (try self.omitInstruction(instruction)) continue;
                    const ordinal = self.index.instructionOrdinal(instruction.id) orelse return error.InconsistentProjection;
                    _ = setBitNew(self.output.instruction_bits, ordinal);
                    if (instruction_count >= self.output.instruction_ordinals.len) return error.OutputTooSmall;
                    self.output.instruction_ordinals[instruction_count] = ordinal;
                    instruction_count += 1;
                }
            }
        }
        return .{ .block_count = block_count, .instruction_count = instruction_count };
    }

    fn omitInstruction(self: *State, instruction: model.HirInstruction) !bool {
        if (self.deadPlaceDefinition(instruction.operation)) return true;
        switch (instruction.operation) {
            .create_closure => {
                // Reaching the target function through another semantic edge
                // (for example a method definition) does not make this closure
                // allocation live. Keep it only when the produced closure value
                // itself participates in the artifact closure.
                const result = instruction.result orelse return error.InconsistentProjection;
                const ordinal = self.index.valueOrdinal(result) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.traced_value_bits, ordinal)) return true;
            },
            .make_binding_place => |value| {
                const ordinal = self.index.bindingOrdinal(value.binding) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.output.binding_bits, ordinal)) return true;
            },
            .store_place => |value| if (self.index.bindingForPlace(value.place)) |binding| {
                const ordinal = self.index.bindingOrdinal(binding) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.output.binding_bits, ordinal)) return true;
            },
            .initialize_binding => |value| {
                const ordinal = self.index.bindingOrdinal(value.binding) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.output.binding_bits, ordinal)) return true;
            },
            .store_binding => |value| {
                const ordinal = self.index.bindingOrdinal(value.binding) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.output.binding_bits, ordinal)) return true;
            },
            else => {},
        }
        if (instruction.result) |result| {
            const ordinal = self.index.valueOrdinal(result) orelse return error.InconsistentProjection;
            if (!bitIsSet(self.traced_value_bits, ordinal)) switch (instruction.operation) {
                .constant, .copy => return true,
                else => {},
            };
        }
        return false;
    }
};

fn validateOutput(project: model.HirProject, index: *const consumer_index.Index, output: Output) !void {
    if (output.module_bits.len < wordCount(project.modules.len) or
        output.function_bits.len < wordCount(project.functions.len) or
        output.block_bits.len < wordCount(index.blocks.len) or
        output.instruction_bits.len < wordCount(index.instructions.len) or
        output.binding_bits.len < wordCount(index.bindings.len) or
        output.module_ordinals.len < project.modules.len or
        output.function_ordinals.len < project.functions.len or
        output.block_ordinals.len < index.blocks.len or
        output.instruction_ordinals.len < index.instructions.len or
        output.binding_ordinals.len < index.bindings.len or
        output.external_module_ids.len < index.external_module_ids.len)
        return error.OutputTooSmall;
}

fn copySortedOrdinals(destination: []u32, source: []const u32) void {
    std.debug.assert(destination.len >= source.len);
    @memcpy(destination[0..source.len], source);
    std.mem.sort(u32, destination[0..source.len], {}, lessU32);
}

fn lessU32(_: void, left: u32, right: u32) bool {
    return left < right;
}

fn validateTriggers(triggers: []const LanguageItemTrigger) !void {
    const operation_count = @typeInfo(std.meta.Tag(model.HirOperation)).@"enum".fields.len;
    for (triggers) |trigger| {
        if (@as(usize, trigger.operation_tag) >= operation_count or (trigger.flags & ~known_trigger_flags) != 0)
            return error.InvalidTrigger;
    }
}

fn setBitNew(words: []u64, ordinal: usize) bool {
    const word = ordinal / 64;
    const bit: u6 = @intCast(ordinal % 64);
    const mask = @as(u64, 1) << bit;
    const previous = words[word];
    words[word] = previous | mask;
    return (previous & mask) == 0;
}

fn bitIsSet(words: []const u64, ordinal: usize) bool {
    const word = ordinal / 64;
    if (word >= words.len) return false;
    const bit: u6 = @intCast(ordinal % 64);
    return (words[word] & (@as(u64, 1) << bit)) != 0;
}

fn addBytes(current: usize, comptime T: type, count: usize) !usize {
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.IndexOverflow;
    return std.math.add(usize, current, bytes) catch return error.IndexOverflow;
}
