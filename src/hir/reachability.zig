const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
const consumer_index = @import("consumer_index.zig");
const types = @import("../types/root.zig");

pub const trigger_canonical_array_base: u32 = 1 << 0;
pub const trigger_place_deleted: u32 = 1 << 1;
pub const trigger_primitive_string_base: u32 = 1 << 2;
pub const trigger_string_concat_add: u32 = 1 << 3;
pub const trigger_primitive_number_base: u32 = 1 << 4;
pub const trigger_primitive_boolean_base: u32 = 1 << 5;
pub const trigger_primitive_bigint_base: u32 = 1 << 6;
pub const trigger_primitive_symbol_base: u32 = 1 << 7;
pub const trigger_function_base: u32 = 1 << 8;
pub const trigger_promise_base: u32 = 1 << 9;
const known_trigger_flags = trigger_canonical_array_base | trigger_place_deleted |
    trigger_primitive_string_base | trigger_string_concat_add |
    trigger_primitive_number_base | trigger_primitive_boolean_base |
    trigger_primitive_bigint_base | trigger_primitive_symbol_base |
    trigger_function_base | trigger_promise_base;

/// Host-defined hidden semantic dependency. `operation_tag` is the stable HIR
/// operation ordinal exported by the HIR ABI; `language_item_id` is opaque to
/// ViZG and is matched only by stable identity.
pub const LanguageItemTrigger = extern struct {
    operation_tag: u32,
    flags: u32,
    language_item_id: u64,
    surface_language_item_id: u64 = 0,
};

pub const property_surface_primitive_string: u32 = 1 << 0;
pub const property_surface_canonical_array: u32 = 1 << 1;
pub const property_surface_has_exposure_intrinsic: u32 = 1 << 8;
const known_property_surface_flags = property_surface_primitive_string |
    property_surface_canonical_array | property_surface_has_exposure_intrinsic;

/// Host-owned description of one hidden property-registration surface. ViZG
/// interprets only stable intrinsic identities, argument positions, and HIR
/// receiver types. Source/module/function spelling never participates.
///
/// Registrations with statically recoverable string keys become conditional
/// reachability edges. Dynamic/symbolic registrations remain ordinary strong
/// edges. `exposure_intrinsic_id` is optional and, when enabled by flags,
/// conservatively activates the whole surface when its receiver is exposed.
pub const PropertySurfaceRule = extern struct {
    registration_intrinsic_id: u64,
    install_intrinsic_id: u64,
    exposure_intrinsic_id: u64,
    flags: u32,
    registration_object_argument: u32,
    registration_key_argument: u32,
    registration_value_argument: u32,
    install_object_argument: u32,
    exposure_object_argument: u32,
};

pub const Request = struct {
    public_modules: []const u64 = &.{},
    application_modules: []const u64 = &.{},
    language_item_triggers: []const LanguageItemTrigger = &.{},
    property_surface_rules: []const PropertySurfaceRule = &.{},
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

const SurfaceIdentity = union(enum) {
    binding: u32,
    value: u32,
};

const SurfaceInstall = struct {
    rule_index: u32,
    identity: SurfaceIdentity,
};

const StaticPropertyCandidate = struct {
    instruction_ordinal: u32,
    identity: SurfaceIdentity,
    key: []const u8,
};

const StaticPropertyDefinition = struct {
    object: ids.ValueId,
    key: []const u8,
};

pub fn wordCount(bit_count: usize) usize {
    return bit_count / 64 + @intFromBool(bit_count % 64 != 0);
}

fn effectPrunableDependencyCount(project: model.HirProject) !usize {
    var count: usize = 0;
    for (project.modules) |module| {
        for (module.dependencies) |dependency| {
            if (!dependency.initialization_required or
                !dependency.module_evaluation or
                !dependency.effect_prunable_evaluation) continue;
            count = std.math.add(usize, count, 1) catch return error.IndexOverflow;
        }
    }
    return count;
}

/// Exact scratch requirement when `scratch` begins at u64 alignment. The
/// analysis uses bounded queues plus private bitsets only; no root-dependent
/// allocation is retained by HirResult.
pub fn scratchSize(project: model.HirProject, index: *const consumer_index.Index) !usize {
    var bytes: usize = 0;
    bytes = try addBytes(bytes, u64, wordCount(index.value_producers.len));
    bytes = try addBytes(bytes, u64, wordCount(project.entities.len));
    bytes = try addBytes(bytes, u64, wordCount(index.external_module_ids.len));
    bytes = try addBytes(bytes, u64, wordCount(project.modules.len));
    bytes = try addBytes(bytes, u32, try std.math.add(usize, project.modules.len, 1));
    bytes = try addBytes(bytes, u32, project.modules.len);
    bytes = try addBytes(bytes, u32, try effectPrunableDependencyCount(project));
    bytes = try addBytes(bytes, u64, wordCount(index.instructions.len));
    bytes = try addBytes(bytes, u64, wordCount(index.instructions.len));
    bytes = try addBytes(bytes, u32, index.instructions.len);
    bytes = try addBytes(bytes, SurfaceInstall, index.instructions.len);
    bytes = try addBytes(bytes, StaticPropertyCandidate, index.instructions.len);
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
    try validatePropertySurfaceRules(request.property_surface_rules);
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
    const observable_module_evaluation_bits = try allocator.alloc(u64, wordCount(project.modules.len));
    const reverse_module_offsets = try allocator.alloc(u32, try std.math.add(usize, project.modules.len, 1));
    const reverse_module_positions = try allocator.alloc(u32, project.modules.len);
    const reverse_module_importers = try allocator.alloc(u32, try effectPrunableDependencyCount(project));
    const selected_registration_bits = try allocator.alloc(u64, wordCount(index.instructions.len));
    const static_property_candidate_bits = try allocator.alloc(u64, wordCount(index.instructions.len));
    const conditional_registration_rules = try allocator.alloc(u32, index.instructions.len);
    const surface_installs = try allocator.alloc(SurfaceInstall, index.instructions.len);
    const static_property_candidates = try allocator.alloc(StaticPropertyCandidate, index.instructions.len);
    @memset(traced_value_bits, 0);
    @memset(traced_entity_bits, 0);
    @memset(external_bits, 0);
    @memset(observable_module_evaluation_bits, 0);
    @memset(reverse_module_offsets, 0);
    @memset(reverse_module_positions, 0);
    @memset(conditional_registration_rules, std.math.maxInt(u32));
    @memset(selected_registration_bits, 0);
    @memset(static_property_candidate_bits, 0);

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
        .observable_module_evaluation_bits = observable_module_evaluation_bits,
        .reverse_module_offsets = reverse_module_offsets,
        .reverse_module_positions = reverse_module_positions,
        .reverse_module_importers = reverse_module_importers,
        .conditional_registration_rules = conditional_registration_rules,
        .selected_registration_bits = selected_registration_bits,
        .static_property_candidate_bits = static_property_candidate_bits,
        .surface_installs = surface_installs,
        .static_property_candidates = static_property_candidates,
        .module_queue = module_queue,
        .function_queue = function_queue,
        .binding_queue = binding_queue,
        .value_queue = value_queue,
        .external_queue = external_queue,
    };
    try state.catalogConditionalRegistrations();
    try state.catalogStaticPropertyCandidates();
    try state.catalogObservableModuleEvaluations();

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
    observable_module_evaluation_bits: []u64,
    reverse_module_offsets: []u32,
    reverse_module_positions: []u32,
    reverse_module_importers: []u32,
    conditional_registration_rules: []u32,
    selected_registration_bits: []u64,
    static_property_candidate_bits: []u64,
    surface_installs: []SurfaceInstall,
    surface_install_len: usize = 0,
    static_property_candidates: []StaticPropertyCandidate,
    static_property_candidate_len: usize = 0,

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

    fn catalogObservableModuleEvaluations(self: *State) !void {
        const module_count = self.project.modules.len;
        if (module_count > std.math.maxInt(u32)) return error.IndexOverflow;
        if (self.reverse_module_offsets.len != module_count + 1 or
            self.reverse_module_positions.len != module_count)
            return error.InconsistentProjection;

        // Build reverse adjacency only for user binding-import evaluation edges
        // that are eligible for purity pruning. Unconditional ESM edges never
        // need propagation through this table: their importer is a direct seed.
        for (self.project.modules) |module| {
            for (module.dependencies) |dependency| {
                if (!dependency.initialization_required or
                    !dependency.module_evaluation or
                    !dependency.effect_prunable_evaluation) continue;
                const target = self.index.moduleOrdinal(dependency.module_id) orelse
                    return error.InconsistentProjection;
                const offset_index = @as(usize, target) + 1;
                self.reverse_module_offsets[offset_index] = std.math.add(
                    u32,
                    self.reverse_module_offsets[offset_index],
                    1,
                ) catch return error.IndexOverflow;
            }
        }

        var running: u32 = 0;
        for (1..self.reverse_module_offsets.len) |index| {
            running = std.math.add(u32, running, self.reverse_module_offsets[index]) catch
                return error.IndexOverflow;
            self.reverse_module_offsets[index] = running;
        }
        if (@as(usize, running) != self.reverse_module_importers.len)
            return error.InconsistentProjection;
        for (0..module_count) |ordinal|
            self.reverse_module_positions[ordinal] = self.reverse_module_offsets[ordinal];

        for (self.project.modules, 0..) |module, importer_ordinal| {
            for (module.dependencies) |dependency| {
                if (!dependency.initialization_required or
                    !dependency.module_evaluation or
                    !dependency.effect_prunable_evaluation) continue;
                const target = self.index.moduleOrdinal(dependency.module_id) orelse
                    return error.InconsistentProjection;
                const position = self.reverse_module_positions[target];
                if (@as(usize, position) >= self.reverse_module_importers.len)
                    return error.InconsistentProjection;
                self.reverse_module_importers[position] = @intCast(importer_ordinal);
                self.reverse_module_positions[target] = std.math.add(u32, position, 1) catch
                    return error.IndexOverflow;
            }
        }

        // Seed direct top-level effects and modules that own an unconditional
        // ESM evaluation edge. The regular module queue is safe to reuse here:
        // observable_module_evaluation_bits guarantees each module is enqueued
        // at most once, and the queue is reset before artifact roots are added.
        for (self.project.modules, 0..) |module, ordinal| {
            var observable = try self.moduleHasDirectObservableEvaluation(@intCast(ordinal));
            if (!observable) {
                for (module.dependencies) |dependency| {
                    if (!dependency.initialization_required or !dependency.module_evaluation) continue;
                    if (dependency.effect_prunable_evaluation) continue;
                    observable = true;
                    break;
                }
            }
            if (observable) try self.enqueueObservableModule(@intCast(ordinal));
        }

        // Linear reverse propagation: once a provider is known observable, only
        // its prunable importers can become newly observable. Pure cycles never
        // seed the queue and therefore remain removable as a group.
        while (self.module_head < self.module_len) {
            const provider = self.module_queue[self.module_head];
            self.module_head += 1;
            const begin = self.reverse_module_offsets[provider];
            const end_offset = self.reverse_module_offsets[@as(usize, provider) + 1];
            if (end_offset < begin or @as(usize, end_offset) > self.reverse_module_importers.len)
                return error.InconsistentProjection;
            for (self.reverse_module_importers[begin..end_offset]) |importer|
                try self.enqueueObservableModule(importer);
        }

        self.module_head = 0;
        self.module_len = 0;
    }

    fn enqueueObservableModule(self: *State, ordinal: u32) !void {
        if (@as(usize, ordinal) >= self.project.modules.len) return error.InconsistentProjection;
        if (!setBitNew(self.observable_module_evaluation_bits, ordinal)) return;
        if (self.module_len >= self.module_queue.len) return error.InconsistentProjection;
        self.module_queue[self.module_len] = ordinal;
        self.module_len += 1;
    }

    fn moduleHasDirectObservableEvaluation(self: *State, module_ordinal: u32) !bool {
        if (@as(usize, module_ordinal) >= self.project.modules.len)
            return error.InconsistentProjection;
        const module = self.project.modules[module_ordinal];
        const function_ordinal = self.index.functionOrdinal(module.initialization) orelse
            return error.InconsistentProjection;
        if (@as(usize, function_ordinal) >= self.project.functions.len)
            return error.InconsistentProjection;
        const function = self.project.functions[function_ordinal];
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (try self.moduleInstructionHasObservableEffect(instruction)) return true;
            }
            if (moduleTerminatorHasObservableEffect(block.terminator)) return true;
        }
        return false;
    }

    fn moduleInstructionHasObservableEffect(
        self: *State,
        instruction: model.HirInstruction,
    ) !bool {
        return switch (instruction.operation) {
            // Pure values, local storage shells, and fresh identities can be
            // omitted when no exported/imported value demands them. Effects in
            // their operand producers are classified independently by the same
            // module scan.
            .constant,
            .copy,
            .initialize_binding,
            .store_binding,
            .make_binding_place,
            .make_property_place,
            .make_element_place,
            .make_super_place,
            .to_boolean,
            .is_nullish,
            .void_value,
            .create_object,
            .create_array,
            .create_closure,
            .create_enum_object,
            .create_regexp,
            .create_template_site,
            .collect_rest_arguments,
            .read_argument,
            .create_arguments_object,
            .load_this,
            .load_super,
            .load_meta,
            => false,

            // An otherwise dead live-import/TDZ read may still throw under an
            // import cycle and therefore participates in module evaluation.
            .load_binding => |binding| try self.bindingReadMustExecuteWithoutValue(binding),

            // Binding stores are local declaration mechanics. Property/element
            // stores remain conservative until general escape analysis exists.
            .store_place => |value| self.index.bindingForPlace(value.place) == null,

            // Class heritage can throw even if the class value is discarded;
            // static initialization may execute arbitrary source code.
            .create_class => |value| blk: {
                if (value.base != null) break :blk true;
                const entity_ordinal = self.index.entityOrdinal(value.entity) orelse
                    return error.InconsistentProjection;
                if (@as(usize, entity_ordinal) >= self.project.entities.len)
                    return error.InconsistentProjection;
                break :blk switch (self.project.entities[entity_ordinal].kind) {
                    .class => |class| class.static_initializer != null,
                    else => return error.InconsistentProjection,
                };
            },

            // Intrinsics are the only operation family carrying host-declared
            // precise effects; a fully pure intrinsic does not anchor module
            // evaluation merely because its result was computed.
            .intrinsic_call => |call| effectSetIsObservable(call.effects),

            // These operations can throw, invoke user code, mutate observable
            // state, suspend, expose dynamic property behavior, or explicitly
            // request debugging. Keep the classifier intentionally conservative
            // until the corresponding escape/effect proof exists.
            .delete_place,
            .load_place,
            .typeof_value,
            .unary,
            .binary,
            .add,
            .call,
            .call_method,
            .call_super_method,
            .call_super_constructor,
            .construct,
            .tagged_template_call,
            .dynamic_import,
            .define_property,
            .define_method,
            .copy_object_properties,
            .array_append,
            .array_append_hole,
            .array_append_iterable,
            .array_initialize,
            .build_string,
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
            .debugger_trap,
            .apply_pattern,
            => true,
        };
    }

    fn moduleEvaluationIsObservable(self: *State, module_id: model.ModuleId) !bool {
        const ordinal = self.index.moduleOrdinal(module_id) orelse return error.InconsistentProjection;
        return bitIsSet(self.observable_module_evaluation_bits, ordinal);
    }

    fn catalogConditionalRegistrations(self: *State) !void {
        if (self.request.property_surface_rules.len == 0) return;

        // First record default-surface installation identities in one linear
        // HIR scan. Registration classification below then compares only
        // against this bounded install list instead of rescanning the whole
        // project once per registration.
        for (self.project.functions) |function| {
            for (function.blocks) |block| {
                for (block.instructions) |instruction| {
                    const call = switch (instruction.operation) {
                        .intrinsic_call => |value| value,
                        else => continue,
                    };
                    for (self.request.property_surface_rules, 0..) |rule, rule_index| {
                        if (call.intrinsic.value() != rule.install_intrinsic_id) continue;
                        const object_value = callArgumentAt(call.arguments, rule.install_object_argument) orelse continue;
                        if (self.surface_install_len >= self.surface_installs.len) return error.InconsistentProjection;
                        self.surface_installs[self.surface_install_len] = .{
                            .rule_index = @intCast(rule_index),
                            .identity = try self.surfaceIdentity(object_value, 0),
                        };
                        self.surface_install_len += 1;
                    }
                }
            }
        }

        // A registration is conditional only when its key is a statically
        // recoverable string and its receiver is one of the host-declared
        // installed hidden surfaces. Symbol/dynamic keys remain strong edges.
        for (self.project.functions) |function| {
            for (function.blocks) |block| {
                for (block.instructions) |instruction| {
                    const call = switch (instruction.operation) {
                        .intrinsic_call => |value| value,
                        else => continue,
                    };
                    for (self.request.property_surface_rules, 0..) |rule, rule_index| {
                        if (call.intrinsic.value() != rule.registration_intrinsic_id) continue;
                        const object_value = callArgumentAt(call.arguments, rule.registration_object_argument) orelse continue;
                        const key_value = callArgumentAt(call.arguments, rule.registration_key_argument) orelse continue;
                        _ = callArgumentAt(call.arguments, rule.registration_value_argument) orelse continue;
                        if ((try self.staticStringValue(key_value, 0)) == null) continue;
                        const object_identity = try self.surfaceIdentity(object_value, 0);
                        if (!self.surfaceInstalled(@intCast(rule_index), object_identity)) continue;

                        const ordinal = self.index.instructionOrdinal(instruction.id) orelse return error.InconsistentProjection;
                        if (self.conditional_registration_rules[ordinal] != std.math.maxInt(u32))
                            return error.InconsistentProjection;
                        self.conditional_registration_rules[ordinal] = @intCast(rule_index);
                        break;
                    }
                }
            }
        }
    }

    fn catalogStaticPropertyCandidates(self: *State) !void {
        // Public-library artifacts are an open world: consumers outside this
        // compilation may read any exported object property. Only closed
        // application artifacts may prune undemanded static property values.
        if (self.request.public_modules.len != 0) return;

        for (self.project.functions) |function| {
            const module_ordinal = self.index.moduleOrdinal(function.module_id) orelse
                return error.InconsistentProjection;
            if (!self.project.modules[module_ordinal].tree_shakeable) continue;
            for (function.blocks) |block| {
                for (block.instructions) |instruction| {
                    const payload: StaticPropertyDefinition = switch (instruction.operation) {
                        .define_property => |value| blk: {
                            const key = switch (value.key) {
                                .static => |name| name,
                                else => continue,
                            };
                            if (!try self.staticPropertyValueIsPure(value.value, 0)) continue;
                            break :blk .{ .object = value.object, .key = key };
                        },
                        // Method/prototype registrations are owned by the
                        // existing property-surface reachability. Treating them
                        // like closed object-literal fields is unsound because
                        // class instances observe them through prototype
                        // dispatch and iterator protocols.
                        .define_method => continue,
                        else => continue,
                    };
                    const identity = try self.surfaceIdentity(payload.object, 0);
                    if (!try self.surfaceIdentityIsExportedFreshObject(identity, module_ordinal)) continue;
                    const ordinal = self.index.instructionOrdinal(instruction.id) orelse
                        return error.InconsistentProjection;
                    if (self.static_property_candidate_len >= self.static_property_candidates.len)
                        return error.InconsistentProjection;
                    self.static_property_candidates[self.static_property_candidate_len] = .{
                        .instruction_ordinal = ordinal,
                        .identity = identity,
                        .key = payload.key,
                    };
                    self.static_property_candidate_len += 1;
                    _ = setBitNew(self.static_property_candidate_bits, ordinal);
                }
            }
        }
    }

    fn staticPropertyValueIsPure(
        self: *State,
        value: ids.ValueId,
        depth: usize,
    ) !bool {
        if (depth > 64) return false;
        const ordinal = self.index.valueOrdinal(value) orelse return error.InconsistentProjection;
        const producer_ordinal = self.index.value_producers[ordinal] orelse return false;
        const producer = self.index.instruction(self.project, producer_ordinal) orelse
            return error.InconsistentProjection;
        return switch (producer.operation) {
            .constant, .create_closure => true,
            .copy => |source| self.staticPropertyValueIsPure(source, depth + 1),
            else => false,
        };
    }

    fn surfaceIdentityIsExportedFreshObject(
        self: *State,
        identity: SurfaceIdentity,
        module_ordinal: u32,
    ) !bool {
        const ordinal = switch (identity) {
            .value => |value| value,
            .binding => return false,
        };
        if (@as(usize, ordinal) >= self.index.value_producers.len)
            return error.InconsistentProjection;
        const producer_ordinal = self.index.value_producers[ordinal] orelse return false;
        const producer = self.index.instruction(self.project, producer_ordinal) orelse
            return error.InconsistentProjection;
        if (producer.operation != .create_object) return false;
        if (@as(usize, module_ordinal) >= self.project.modules.len)
            return error.InconsistentProjection;

        // Only exported top-level object surfaces are closed enough for this
        // optimization. Local object literals may escape through arrays,
        // iterators, closures, or other containers in ways that do not retain
        // a direct surface identity. Pruning their apparently-unused constant
        // fields is therefore unsound.
        for (self.project.modules[module_ordinal].exports) |exported| {
            if (exported.type_only) continue;
            const binding = exported.binding orelse continue;
            const exported_identity = try self.surfaceIdentityForBinding(binding, 0);
            if (sameSurfaceIdentity(identity, exported_identity)) return true;
        }
        return false;
    }

    fn isStaticPropertyCandidate(self: *const State, instruction_ordinal: u32) bool {
        return bitIsSet(self.static_property_candidate_bits, instruction_ordinal);
    }

    fn activateStaticPropertyIdentity(
        self: *State,
        identity: SurfaceIdentity,
        key: ?[]const u8,
    ) anyerror!void {
        for (self.static_property_candidates[0..self.static_property_candidate_len]) |candidate| {
            if (!sameSurfaceIdentity(identity, candidate.identity)) continue;
            if (key) |wanted| {
                if (!std.mem.eql(u8, wanted, candidate.key)) continue;
            }
            try self.selectStaticPropertyCandidate(candidate.instruction_ordinal);
        }
    }

    fn activateStaticPropertyReceiver(
        self: *State,
        receiver: ids.ValueId,
        key: ?[]const u8,
    ) !void {
        const identity = try self.surfaceIdentity(receiver, 0);
        try self.activateStaticPropertyIdentity(identity, key);
    }

    fn exposeStaticPropertyValue(self: *State, value: ids.ValueId) !void {
        const identity = try self.surfaceIdentity(value, 0);
        try self.activateStaticPropertyIdentity(identity, null);
    }

    fn staticPropertyCandidate(
        self: *const State,
        instruction_ordinal: u32,
    ) ?StaticPropertyCandidate {
        for (self.static_property_candidates[0..self.static_property_candidate_len]) |candidate|
            if (candidate.instruction_ordinal == instruction_ordinal) return candidate;
        return null;
    }

    fn staticPropertyFunctionForValue(
        self: *State,
        value: ids.ValueId,
        depth: usize,
    ) !?ids.FunctionId {
        if (depth > 64) return null;
        const ordinal = self.index.valueOrdinal(value) orelse return error.InconsistentProjection;
        const producer_ordinal = self.index.value_producers[ordinal] orelse return null;
        const producer = self.index.instruction(self.project, producer_ordinal) orelse
            return error.InconsistentProjection;
        return switch (producer.operation) {
            .create_closure => |function| function,
            .copy => |source| self.staticPropertyFunctionForValue(source, depth + 1),
            else => null,
        };
    }

    fn functionUsesDynamicThis(
        self: *State,
        function_id: ids.FunctionId,
    ) !bool {
        const ordinal = self.index.functionOrdinal(function_id) orelse
            return error.InconsistentProjection;
        if (@as(usize, ordinal) >= self.project.functions.len)
            return error.InconsistentProjection;
        const function = self.project.functions[ordinal];
        if (!function.flags.dynamic_this) return false;
        for (function.blocks) |block|
            for (block.instructions) |instruction|
                if (instruction.operation == .load_this) return true;
        return false;
    }

    fn selectStaticPropertyCandidate(
        self: *State,
        instruction_ordinal: u32,
    ) anyerror!void {
        if (!setBitNew(self.selected_registration_bits, instruction_ordinal)) return;
        const candidate = self.staticPropertyCandidate(instruction_ordinal) orelse
            return error.InconsistentProjection;
        const instruction = self.index.instruction(self.project, instruction_ordinal) orelse
            return error.InconsistentProjection;
        switch (instruction.operation) {
            .define_property => |value| {
                if (try self.staticPropertyFunctionForValue(value.value, 0)) |function| {
                    // Dynamic this can observe sibling members without an
                    // explicit alias back to the receiver in HIR. Once such a
                    // function is selected, conservatively retain the complete
                    // closed surface for that object.
                    if (try self.functionUsesDynamicThis(function))
                        try self.activateStaticPropertyIdentity(candidate.identity, null);
                }
                try self.traceValue(value.object);
                try self.traceValue(value.value);
            },
            .define_method => return error.InconsistentProjection,
            else => return error.InconsistentProjection,
        }
    }

    fn applyStaticPropertyDemands(
        self: *State,
        instruction: model.HirInstruction,
    ) !void {
        switch (instruction.operation) {
            .make_property_place => |value| {
                if (!self.index.placeIsConsumed(value.result)) return;
                try self.activateStaticPropertyReceiver(
                    value.base,
                    try self.propertyDemandKey(value.key),
                );
            },
            .make_element_place => |value| {
                if (!self.index.placeIsConsumed(value.result)) return;
                try self.activateStaticPropertyReceiver(
                    value.base,
                    try self.staticStringValue(value.key, 0),
                );
            },
            .call_method, .call_super_method => |value| try self.activateStaticPropertyReceiver(
                value.receiver,
                try self.propertyDemandKey(value.key),
            ),
            .enumerate_properties => |value| try self.activateStaticPropertyReceiver(value, null),
            .copy_object_properties => |value| {
                try self.activateStaticPropertyReceiver(value.source, null);
                try self.activateStaticPropertyReceiver(value.target, null);
            },
            .call, .construct => |value| {
                try self.exposeStaticPropertyValue(value.callee);
                for (value.arguments) |argument|
                    try self.exposeStaticPropertyValue(argument.operand());
            },
            .call_super_constructor => |arguments| for (arguments) |argument|
                try self.exposeStaticPropertyValue(argument.operand()),
            .tagged_template_call => |value| {
                try self.exposeStaticPropertyValue(value.tag);
                if (value.receiver) |receiver|
                    try self.exposeStaticPropertyValue(receiver);
                for (value.substitutions) |substitution|
                    try self.exposeStaticPropertyValue(substitution);
            },
            .dynamic_import => |value| {
                try self.exposeStaticPropertyValue(value.source);
                if (value.options) |options| try self.exposeStaticPropertyValue(options);
            },
            .store_place => |value| try self.exposeStaticPropertyValue(value.value),
            .define_property => |value| {
                if (!self.isStaticPropertyCandidate(
                    self.index.instructionOrdinal(instruction.id) orelse
                        return error.InconsistentProjection,
                )) try self.exposeStaticPropertyValue(value.value);
            },
            .array_append => |value| try self.exposeStaticPropertyValue(value.value),
            .array_append_iterable => |value| try self.exposeStaticPropertyValue(value.iterable),
            .array_initialize => |value| switch (value.source) {
                .dynamic => |elements| for (elements) |element|
                    try self.exposeStaticPropertyValue(element),
                .constant => {},
            },
            .to_string,
            .get_iterator,
            .get_async_iterator,
            .iterator_next,
            .iterator_done,
            .iterator_value,
            .iterator_close,
            .enumerator_next,
            .enumerator_done,
            .enumerator_value,
            .await_,
            .yield_,
            .yield_delegate,
            => |value| try self.exposeStaticPropertyValue(value),
            .unary => |value| try self.exposeStaticPropertyValue(value.operand),
            .binary => |value| {
                try self.exposeStaticPropertyValue(value.left);
                try self.exposeStaticPropertyValue(value.right);
            },
            .add => |value| {
                try self.exposeStaticPropertyValue(value.left);
                try self.exposeStaticPropertyValue(value.right);
            },
            .build_string => |parts| for (parts) |part| switch (part) {
                .text => {},
                .value => |value| try self.exposeStaticPropertyValue(value),
            },
            .intrinsic_call => |call| for (call.arguments) |argument|
                try self.exposeStaticPropertyValue(argument.operand()),
            .apply_pattern => |plan| try self.exposeStaticPropertyValue(plan.source),
            else => {},
        }
    }

    fn applyStaticPropertyTerminatorDemands(
        self: *State,
        terminator: model.HirTerminator,
    ) !void {
        switch (terminator) {
            .jump => |jump| for (jump.arguments) |value|
                try self.exposeStaticPropertyValue(value),
            .return_ => |value| if (value) |present|
                try self.exposeStaticPropertyValue(present),
            .throw => |value| try self.exposeStaticPropertyValue(value),
            .leave_region => |leave| switch (leave.completion) {
                .return_ => |value| if (value) |present|
                    try self.exposeStaticPropertyValue(present),
                .throw => |value| try self.exposeStaticPropertyValue(value),
                .normal, .break_, .continue_ => {},
            },
            .branch, .unreachable_, .resume_completion => {},
        }
    }

    fn surfaceInstalled(self: *const State, rule_index: u32, identity: SurfaceIdentity) bool {
        for (self.surface_installs[0..self.surface_install_len]) |install| {
            if (install.rule_index == rule_index and sameSurfaceIdentity(identity, install.identity)) return true;
        }
        return false;
    }

    fn surfaceIdentity(self: *State, value: ids.ValueId, depth: usize) anyerror!SurfaceIdentity {
        if (depth > 64) return error.InconsistentProjection;
        const value_ordinal = self.index.valueOrdinal(value) orelse return error.InconsistentProjection;
        const producer_ordinal = self.index.value_producers[value_ordinal] orelse return .{ .value = value_ordinal };
        const producer = self.index.instruction(self.project, producer_ordinal) orelse return error.InconsistentProjection;
        return switch (producer.operation) {
            .copy => |source| self.surfaceIdentity(source, depth + 1),
            .load_binding => |binding| self.surfaceIdentityForBinding(binding, depth + 1),
            else => .{ .value = value_ordinal },
        };
    }

    fn surfaceIdentityForBinding(
        self: *State,
        binding: ids.BindingId,
        depth: usize,
    ) anyerror!SurfaceIdentity {
        if (depth > 64) return error.InconsistentProjection;
        const ordinal = self.index.bindingOrdinal(binding) orelse return error.InconsistentProjection;

        // Imported and source-backed global bindings are semantic aliases, not
        // independent runtime objects. Canonicalize through the exact provider
        // binding so property demand in a consumer module selects registrations
        // on the provider's object identity.
        if (self.index.importForBinding(self.project, binding)) |import_binding| {
            if (!import_binding.type_only and !import_binding.namespace and
                import_binding.target.external_module_id == null)
            {
                if (self.index.semanticProvider(import_binding.target.declaration)) |provider| {
                    if (provider.binding_ordinal) |provider_ordinal| {
                        const provider_binding = self.index.binding(self.project, provider_ordinal) orelse
                            return error.InconsistentProjection;
                        if (!provider_binding.id.eql(binding))
                            return self.surfaceIdentityForBinding(provider_binding.id, depth + 1);
                    }
                }
            }
        }

        if (self.index.captureSource(binding)) |source|
            return self.surfaceIdentityForBinding(source, depth + 1);

        // Source-backed globals may resolve directly to the provider declaration
        // without materializing a HirImportBinding in the consumer module. The
        // declaration identity is still exact, so canonicalize through its HIR
        // provider before falling back to this binding's local storage.
        const hir_binding = self.index.binding(self.project, ordinal) orelse
            return error.InconsistentProjection;
        if (hir_binding.declaration) |declaration| {
            if (self.index.semanticProvider(declaration)) |provider| {
                if (provider.binding_ordinal) |provider_ordinal| {
                    if (provider_ordinal != ordinal) {
                        const provider_binding = self.index.binding(self.project, provider_ordinal) orelse
                            return error.InconsistentProjection;
                        return self.surfaceIdentityForBinding(provider_binding.id, depth + 1);
                    }
                }
            }
        }

        const writers = self.index.writersForBinding(binding);
        if (writers.len == 1) {
            const writer = self.index.instruction(self.project, writers[0]) orelse return error.InconsistentProjection;
            const source = switch (writer.operation) {
                .initialize_binding => |payload| payload.value,
                .store_binding => |payload| payload.value,
                .store_place => |payload| payload.value,
                else => null,
            };
            if (source) |value| return self.surfaceIdentity(value, depth + 1);
        }
        return .{ .binding = ordinal };
    }

    fn staticStringValue(self: *State, value: ids.ValueId, depth: usize) !?[]const u8 {
        if (depth > 64) return null;
        const value_ordinal = self.index.valueOrdinal(value) orelse return error.InconsistentProjection;
        const producer_ordinal = self.index.value_producers[value_ordinal] orelse return null;
        const producer = self.index.instruction(self.project, producer_ordinal) orelse return error.InconsistentProjection;
        return switch (producer.operation) {
            .constant => |constant| switch (constant) {
                .string => |text| text,
                else => null,
            },
            .copy => |source| self.staticStringValue(source, depth + 1),
            .load_binding => |binding| blk: {
                const writers = self.index.writersForBinding(binding);
                if (writers.len != 1) break :blk null;
                const writer = self.index.instruction(self.project, writers[0]) orelse return error.InconsistentProjection;
                const source = switch (writer.operation) {
                    .initialize_binding => |payload| payload.value,
                    .store_binding => |payload| payload.value,
                    else => break :blk null,
                };
                break :blk try self.staticStringValue(source, depth + 1);
            },
            else => null,
        };
    }

    fn conditionalRuleForInstruction(self: *const State, instruction_ordinal: u32) ?u32 {
        if (@as(usize, instruction_ordinal) >= self.conditional_registration_rules.len) return null;
        const value = self.conditional_registration_rules[instruction_ordinal];
        return if (value == std.math.maxInt(u32)) null else value;
    }

    fn registrationSelected(self: *const State, instruction_ordinal: u32) bool {
        return bitIsSet(self.selected_registration_bits, instruction_ordinal);
    }

    fn selectRegistration(self: *State, instruction_ordinal: u32) !void {
        if (!setBitNew(self.selected_registration_bits, instruction_ordinal)) return;
        const instruction = self.index.instruction(self.project, instruction_ordinal) orelse return error.InconsistentProjection;
        const call = switch (instruction.operation) {
            .intrinsic_call => |value| value,
            else => return error.InconsistentProjection,
        };
        // Once selected, this is an ordinary effectful intrinsic call. Trace
        // every argument so closure creation and its target function enter the
        // same semantic fixed point as any other reached call.
        try self.traceArguments(call.arguments);
    }

    fn activateSurfaceDemand(self: *State, rule_index: u32, key: ?[]const u8) !void {
        if (@as(usize, rule_index) >= self.request.property_surface_rules.len) return error.InconsistentProjection;
        for (self.conditional_registration_rules, 0..) |candidate_rule, instruction_ordinal| {
            if (candidate_rule != rule_index or self.registrationSelected(@intCast(instruction_ordinal))) continue;
            if (key) |wanted| {
                const instruction = self.index.instruction(self.project, @intCast(instruction_ordinal)) orelse return error.InconsistentProjection;
                const call = switch (instruction.operation) {
                    .intrinsic_call => |value| value,
                    else => return error.InconsistentProjection,
                };
                const rule = self.request.property_surface_rules[rule_index];
                const key_value = callArgumentAt(call.arguments, rule.registration_key_argument) orelse return error.InconsistentProjection;
                const candidate_key = (try self.staticStringValue(key_value, 0)) orelse return error.InconsistentProjection;
                if (!std.mem.eql(u8, wanted, candidate_key)) continue;
            }
            try self.selectRegistration(@intCast(instruction_ordinal));
        }
    }

    fn applyPropertySurfaceDemands(self: *State, instruction: model.HirInstruction) !void {
        if (self.request.property_surface_rules.len == 0) return;
        switch (instruction.operation) {
            .make_property_place => |value| {
                if (!self.index.placeIsLoaded(value.result)) return;
                try self.activateRulesForReceiver(value.base, try self.propertyDemandKey(value.key));
            },
            .make_element_place => |value| {
                if (!self.index.placeIsLoaded(value.result)) return;
                const key = try self.staticStringValue(value.key, 0);
                try self.activateRulesForReceiver(value.base, key);
            },
            .call_method, .call_super_method => |value| {
                try self.activateRulesForReceiver(value.receiver, try self.propertyDemandKey(value.key));
            },
            .intrinsic_call => |call| {
                for (self.request.property_surface_rules, 0..) |rule, rule_index| {
                    if ((rule.flags & property_surface_has_exposure_intrinsic) == 0 or
                        call.intrinsic.value() != rule.exposure_intrinsic_id) continue;
                    const receiver = callArgumentAt(call.arguments, rule.exposure_object_argument) orelse continue;
                    if (try self.ruleMatchesReceiver(rule, receiver))
                        try self.activateSurfaceDemand(@intCast(rule_index), null);
                }
            },
            else => {},
        }
    }

    fn propertyDemandKey(self: *State, key: model.PropertyKey) !?[]const u8 {
        return switch (key) {
            .static => |name| name,
            .computed => |value| self.staticStringValue(value, 0),
            .private => null,
        };
    }

    fn activateRulesForReceiver(self: *State, receiver: ids.ValueId, key: ?[]const u8) !void {
        for (self.request.property_surface_rules, 0..) |rule, rule_index| {
            if (try self.ruleMatchesReceiver(rule, receiver))
                try self.activateSurfaceDemand(@intCast(rule_index), key);
        }
    }

    fn ruleMatchesReceiver(self: *State, rule: PropertySurfaceRule, receiver: ids.ValueId) !bool {
        const type_id = self.index.valueType(receiver) orelse return error.InconsistentProjection;
        // `any`/`unknown` can carry every runtime surface. A static property
        // key activates only the matching registration; a dynamic key
        // conservatively activates the whole host-declared surface.
        if (type_id == self.type_store.builtins.any or type_id == self.type_store.builtins.unknown)
            return true;
        if ((rule.flags & property_surface_primitive_string) != 0 and try self.valueIsPrimitiveString(receiver)) return true;
        if ((rule.flags & property_surface_canonical_array) != 0 and try self.valueIsCanonicalArray(receiver)) return true;
        return false;
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
            if (!dependency.effect_prunable_evaluation or
                try self.moduleEvaluationIsObservable(dependency.module_id))
            {
                try self.reachModule(dependency.module_id);
            }
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
            try self.applyStaticPropertyTerminatorDemands(block.terminator);
            try self.traceTerminator(block.terminator);
            for (block.instructions) |instruction| {
                try self.applyPropertySurfaceDemands(instruction);
                try self.applyStaticPropertyDemands(instruction);
                const instruction_ordinal = self.index.instructionOrdinal(instruction.id) orelse return error.InconsistentProjection;
                if (self.conditionalRuleForInstruction(instruction_ordinal) != null and
                    !self.registrationSelected(instruction_ordinal)) continue;
                if (self.isStaticPropertyCandidate(instruction_ordinal) and
                    !self.registrationSelected(instruction_ordinal)) continue;
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
        if (self.conditionalRuleForInstruction(instruction_ordinal) != null and
            !self.registrationSelected(instruction_ordinal))
            try self.selectRegistration(instruction_ordinal);
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

            .load_binding => |binding| {
                // A binding load whose result is not consumed is observable
                // only when the read itself may fail independently of its
                // value. Hoisted/initialized lexical storage is safe to defer
                // to processValue(); doing so is required for conditional
                // property registrations because an unselected registration
                // must not make its function-valued operand reachable merely
                // through the argument's load_binding setup instruction.
                //
                // TDZ and live-import reads remain strong: they may throw even
                // when their produced value is otherwise dead.
                if (try self.bindingReadMustExecuteWithoutValue(binding))
                    try self.traceBinding(binding);
            },

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
            .array_initialize => |value| {
                try self.traceValue(value.array);
                switch (value.source) {
                    .dynamic => |elements| for (elements) |element| try self.traceValue(element),
                    .constant => {},
                }
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
        const foundational_flags = trigger.flags & (trigger_primitive_number_base |
            trigger_primitive_boolean_base | trigger_primitive_bigint_base |
            trigger_primitive_symbol_base | trigger_function_base);
        if ((trigger.flags & trigger_promise_base) != 0) {
            const base = switch (operation) {
                .make_property_place => |value| value.base,
                .make_element_place => |value| value.base,
                .call_method, .call_super_method => |value| value.receiver,
                .await_ => |value| value,
                else => return false,
            };
            if (!try self.valueIsPromise(base, trigger.surface_language_item_id)) return false;
        }
        if (foundational_flags != 0) {
            const base = switch (operation) {
                .make_property_place => |value| value.base,
                .make_element_place => |value| value.base,
                .call_method, .call_super_method => |value| value.receiver,
                else => return false,
            };
            if (!try self.valueMatchesFoundationalFlag(base, foundational_flags)) return false;
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

    fn bindingReadMustExecuteWithoutValue(self: *State, binding_id: ids.BindingId) !bool {
        const ordinal = self.index.bindingOrdinal(binding_id) orelse return error.InconsistentProjection;
        const binding = self.index.binding(self.project, ordinal) orelse return error.InconsistentProjection;
        return switch (binding.initial_state) {
            .temporal_dead_zone, .live_import => true,
            .hoisted_undefined, .hoisted_function, .initialized => false,
        };
    }

    fn valueIsCanonicalArray(self: *State, value: ids.ValueId) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        return self.typeIsCanonicalArray(type_id, 0);
    }

    fn valueIsPromise(self: *State, value: ids.ValueId, surface_language_item_id: u64) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        const ty = self.type_store.lookup(type_id) orelse return error.InconsistentProjection;
        if (ty.kind == .promise) return true;
        if (surface_language_item_id == 0 or ty.kind != .applied_generic) return false;
        const target = ty.kind.applied_generic.resolved_target;
        for (self.project.language_items) |item| {
            if (item.id.value() != surface_language_item_id) continue;
            return item.target.namespace == .type and item.target.type_id == target;
        }
        return false;
    }

    fn valueIsPrimitiveString(self: *State, value: ids.ValueId) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        const ty = self.type_store.lookup(type_id) orelse return error.InconsistentProjection;
        return switch (ty.kind) {
            .primitive => |primitive| primitive == .string,
            // Direct string literals retain literal types in some HIR paths.
            // They are semantically primitive strings for member reachability.
            .literal => |literal| switch (literal) {
                .string => true,
                else => false,
            },
            else => false,
        };
    }

    fn valueMatchesFoundationalFlag(self: *State, value: ids.ValueId, flag: u32) !bool {
        const type_id = self.index.valueType(value) orelse return error.InconsistentProjection;
        const ty = self.type_store.lookup(type_id) orelse return error.InconsistentProjection;
        return switch (ty.kind) {
            .primitive => |primitive| switch (primitive) {
                .number => flag == trigger_primitive_number_base,
                .boolean => flag == trigger_primitive_boolean_base,
                .bigint => flag == trigger_primitive_bigint_base,
                .symbol => flag == trigger_primitive_symbol_base,
                else => false,
            },
            .function => flag == trigger_function_base,
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
        const instruction_ordinal = self.index.instructionOrdinal(instruction.id) orelse return error.InconsistentProjection;
        if (self.conditionalRuleForInstruction(instruction_ordinal) != null and
            !self.registrationSelected(instruction_ordinal)) return true;
        if (self.isStaticPropertyCandidate(instruction_ordinal) and
            !self.registrationSelected(instruction_ordinal)) return true;
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
            .load_binding => |binding| {
                const result = instruction.result orelse return error.InconsistentProjection;
                const ordinal = self.index.valueOrdinal(result) orelse return error.InconsistentProjection;
                if (!bitIsSet(self.traced_value_bits, ordinal) and
                    !try self.bindingReadMustExecuteWithoutValue(binding))
                    return true;
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

fn effectSetIsObservable(effects: model.EffectSet) bool {
    return !effects.pure or effects.may_throw or effects.may_call_user_code or
        effects.reads_state or effects.writes_state or effects.may_suspend or
        effects.creates_identity;
}

fn moduleTerminatorHasObservableEffect(terminator: model.HirTerminator) bool {
    return switch (terminator) {
        .throw => true,
        .leave_region => |leave| switch (leave.completion) {
            .throw => true,
            else => false,
        },
        .jump, .branch, .return_, .unreachable_, .resume_completion => false,
    };
}

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

fn validatePropertySurfaceRules(rules: []const PropertySurfaceRule) !void {
    for (rules, 0..) |rule, rule_index| {
        const surface_flags = rule.flags & (property_surface_primitive_string | property_surface_canonical_array);
        if ((rule.flags & ~known_property_surface_flags) != 0 or @popCount(surface_flags) != 1)
            return error.InvalidPropertySurfaceRule;
        if (rule.registration_intrinsic_id == rule.install_intrinsic_id)
            return error.InvalidPropertySurfaceRule;
        if ((rule.flags & property_surface_has_exposure_intrinsic) != 0 and rule.exposure_intrinsic_id == 0)
            return error.InvalidPropertySurfaceRule;
        for (rules[0..rule_index]) |previous| {
            // One stable install intrinsic identifies exactly one hidden
            // surface. This also bounds the install catalog to instruction
            // count without request-sized scratch allocation.
            if (previous.install_intrinsic_id == rule.install_intrinsic_id)
                return error.InvalidPropertySurfaceRule;
        }
    }
}

fn callArgumentAt(arguments: []const model.CallArgument, index: u32) ?ids.ValueId {
    if (@as(usize, index) >= arguments.len) return null;
    return arguments[@intCast(index)].operand();
}

fn sameSurfaceIdentity(left: SurfaceIdentity, right: SurfaceIdentity) bool {
    return switch (left) {
        .binding => |left_value| switch (right) {
            .binding => |right_value| left_value == right_value,
            .value => false,
        },
        .value => |left_value| switch (right) {
            .binding => false,
            .value => |right_value| left_value == right_value,
        },
    };
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
    // FixedBufferAllocator aligns every raw allocation relative to the aligned
    // scratch base. Account for that padding explicitly so scratchSize remains
    // exact even when allocations switch between u32- and u64-aligned types.
    const alignment = @alignOf(T);
    const remainder = current % alignment;
    const padding = if (remainder == 0) 0 else alignment - remainder;
    const aligned = std.math.add(usize, current, padding) catch return error.IndexOverflow;
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.IndexOverflow;
    return std.math.add(usize, aligned, bytes) catch return error.IndexOverflow;
}
