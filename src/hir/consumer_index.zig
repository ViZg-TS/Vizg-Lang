const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");

pub const BlockLocation = struct {
    function_index: u32,
    block_index: u32,
};

pub const InstructionLocation = struct {
    function_index: u32,
    block_index: u32,
    instruction_index: u32,
};

pub const BindingLocation = struct {
    function_index: u32,
    binding_index: u32,
};

pub const ImportLocation = struct {
    module_index: u32,
    import_index: u32,
};

pub const SemanticProvider = struct {
    binding_ordinal: ?u32 = null,
    entity_ordinal: ?u32 = null,
    function_ordinal: ?u32 = null,
};

/// Immutable, root-independent index over the final canonical HIR. Every
/// ordinal here is a canonical flattened ordinal; raw HIR IDs remain identity
/// keys only and are never treated as ordinals.
pub const Index = struct {
    allocator: std.mem.Allocator,
    identity_domain: *const ids.IdentityDomain,

    blocks: []const BlockLocation,
    instructions: []const InstructionLocation,
    bindings: []const BindingLocation,
    function_names: []const []const u8,

    module_ordinals: std.AutoHashMap(u64, u32),
    entity_ordinals: std.AutoHashMap(u32, u32),
    function_ordinals: std.AutoHashMap(u32, u32),
    block_ordinals: std.AutoHashMap(u32, u32),
    instruction_ordinals: std.AutoHashMap(u32, u32),
    binding_ordinals: std.AutoHashMap(u32, u32),
    value_ordinals: std.AutoHashMap(u32, u32),

    external_module_ordinals: std.AutoHashMap(u64, u32),
    external_module_ids: []const u64,
    language_item_functions: std.AutoHashMap(u64, u32),

    /// Indexed by canonical value ordinal. The value is a canonical
    /// instruction ordinal; block parameters have no producer.
    value_producers: []const ?u32,
    value_types: []const model.TypeId,
    /// Indexed by canonical binding ordinal.
    binding_imports: []const ?ImportLocation,
    capture_sources: []const ?ids.BindingId,
    binding_writer_offsets: []const u32,
    binding_writer_instructions: []const u32,

    place_bindings: std.AutoHashMap(u32, ids.BindingId),
    consumed_places: std.AutoHashMap(u32, void),
    deleted_places: std.AutoHashMap(u32, void),
    semantic_providers: std.AutoHashMap(model.SemanticDeclId, SemanticProvider),

    pub fn build(
        allocator: std.mem.Allocator,
        identity_domain: *const ids.IdentityDomain,
        project: model.HirProject,
    ) !Index {
        var result: Index = .{
            .allocator = allocator,
            .identity_domain = identity_domain,
            .blocks = &.{},
            .instructions = &.{},
            .bindings = &.{},
            .function_names = &.{},
            .module_ordinals = std.AutoHashMap(u64, u32).init(allocator),
            .entity_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .function_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .block_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .instruction_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .binding_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .value_ordinals = std.AutoHashMap(u32, u32).init(allocator),
            .external_module_ordinals = std.AutoHashMap(u64, u32).init(allocator),
            .external_module_ids = &.{},
            .language_item_functions = std.AutoHashMap(u64, u32).init(allocator),
            .value_producers = &.{},
            .value_types = &.{},
            .binding_imports = &.{},
            .capture_sources = &.{},
            .binding_writer_offsets = &.{},
            .binding_writer_instructions = &.{},
            .place_bindings = std.AutoHashMap(u32, ids.BindingId).init(allocator),
            .consumed_places = std.AutoHashMap(u32, void).init(allocator),
            .deleted_places = std.AutoHashMap(u32, void).init(allocator),
            .semantic_providers = std.AutoHashMap(model.SemanticDeclId, SemanticProvider).init(allocator),
        };
        errdefer result.deinit();

        var block_count: usize = 0;
        var instruction_count: usize = 0;
        var binding_count: usize = 0;
        var value_count: usize = 0;
        for (project.functions) |hir_function| {
            block_count += hir_function.blocks.len;
            binding_count += hir_function.bindings.len;
            for (hir_function.blocks) |hir_block| {
                instruction_count += hir_block.instructions.len;
                value_count += hir_block.parameters.len;
                for (hir_block.instructions) |hir_instruction| value_count += @intFromBool(hir_instruction.result != null);
            }
        }
        if (block_count > std.math.maxInt(u32) or instruction_count > std.math.maxInt(u32) or
            binding_count > std.math.maxInt(u32) or value_count > std.math.maxInt(u32) or
            project.functions.len > std.math.maxInt(u32) or project.modules.len > std.math.maxInt(u32) or
            project.entities.len > std.math.maxInt(u32)) return error.IndexOverflow;

        const blocks = try allocator.alloc(BlockLocation, block_count);
        result.blocks = blocks;
        const instructions = try allocator.alloc(InstructionLocation, instruction_count);
        result.instructions = instructions;
        const bindings = try allocator.alloc(BindingLocation, binding_count);
        result.bindings = bindings;
        const function_names = try allocator.alloc([]const u8, project.functions.len);
        result.function_names = function_names;
        for (function_names) |*name| name.* = "";
        const value_producers = try allocator.alloc(?u32, value_count);
        result.value_producers = value_producers;
        @memset(value_producers, null);
        const value_types = try allocator.alloc(model.TypeId, value_count);
        result.value_types = value_types;
        const binding_imports = try allocator.alloc(?ImportLocation, binding_count);
        result.binding_imports = binding_imports;
        @memset(binding_imports, null);
        const capture_sources = try allocator.alloc(?ids.BindingId, binding_count);
        result.capture_sources = capture_sources;
        @memset(capture_sources, null);
        const writer_offsets = try allocator.alloc(u32, binding_count + 1);
        result.binding_writer_offsets = writer_offsets;
        @memset(writer_offsets, 0);

        for (project.modules, 0..) |module, ordinal| {
            try putUnique(&result.module_ordinals, module.module_id.value(), @as(u32, @intCast(ordinal)));
        }
        for (project.external_declarations) |declaration|
            try indexExternalModule(&result, declaration.module_id.value());
        for (project.modules) |module| {
            for (module.imports) |import_binding| switch (import_binding.source) {
                .external => |external| try indexExternalModule(&result, external.value()),
                .source => {},
            };
            for (module.exports) |export_binding|
                if (export_binding.target.external_module_id) |external|
                    try indexExternalModule(&result, external.value());
        }
        for (project.entities, 0..) |hir_entity, ordinal| {
            const ordinal_u32: u32 = @intCast(ordinal);
            const raw = try rawIdOwned(identity_domain, hir_entity.id);
            try putUnique(&result.entity_ordinals, raw, ordinal_u32);
            if (hir_entity.declaration) |declaration| {
                var provider = result.semantic_providers.get(declaration) orelse SemanticProvider{};
                if (provider.entity_ordinal != null and provider.entity_ordinal.? != ordinal_u32) return error.DuplicateSemanticProvider;
                provider.entity_ordinal = ordinal_u32;
                try result.semantic_providers.put(declaration, provider);
            }
        }

        var block_ordinal: usize = 0;
        var instruction_ordinal: usize = 0;
        var binding_ordinal: usize = 0;
        var value_ordinal: usize = 0;

        for (project.functions, 0..) |hir_function, function_index| {
            const function_ordinal_u32: u32 = @intCast(function_index);
            const function_raw = try rawIdOwned(identity_domain, hir_function.id);
            try putUnique(&result.function_ordinals, function_raw, function_ordinal_u32);
            if (hir_function.symbol) |declaration| {
                var provider = result.semantic_providers.get(declaration) orelse SemanticProvider{};
                // A declaration may own multiple physical functions (notably a
                // class constructor plus hidden instance/static field
                // initializers). When an entity shell exists it is the
                // authoritative semantic provider and reaches those functions
                // structurally. Only declarations without an entity use a
                // direct function provider.
                if (provider.entity_ordinal == null) {
                    if (provider.function_ordinal != null and provider.function_ordinal.? != function_ordinal_u32)
                        return error.DuplicateSemanticProvider;
                    provider.function_ordinal = function_ordinal_u32;
                    try result.semantic_providers.put(declaration, provider);
                }
            }

            for (hir_function.bindings, 0..) |hir_binding, local_binding_index| {
                const raw = try rawIdOwned(identity_domain, hir_binding.id);
                bindings[binding_ordinal] = .{
                    .function_index = @intCast(function_index),
                    .binding_index = @intCast(local_binding_index),
                };
                try putUnique(&result.binding_ordinals, raw, @as(u32, @intCast(binding_ordinal)));
                if (hir_binding.kind != .import) {
                    if (hir_binding.declaration) |declaration| {
                        const binding_ordinal_u32: u32 = @intCast(binding_ordinal);
                        var provider = result.semantic_providers.get(declaration) orelse SemanticProvider{};
                        if (provider.binding_ordinal != null and provider.binding_ordinal.? != binding_ordinal_u32)
                            return error.DuplicateSemanticProvider;
                        provider.binding_ordinal = binding_ordinal_u32;
                        try result.semantic_providers.put(declaration, provider);
                    }
                }
                binding_ordinal += 1;
            }

            for (hir_function.captures) |capture| {
                const local_ordinal = result.bindingOrdinal(capture.local) orelse return error.InconsistentProjection;
                switch (capture.source) {
                    .binding => |source| capture_sources[local_ordinal] = source,
                    else => {},
                }
            }
            for (hir_function.places) |place| switch (place.kind) {
                .binding => |binding_id| try putUnique(&result.place_bindings, try rawIdOwned(identity_domain, place.id), binding_id),
                else => {},
            };

            for (hir_function.blocks, 0..) |hir_block, local_block_index| {
                blocks[block_ordinal] = .{
                    .function_index = @intCast(function_index),
                    .block_index = @intCast(local_block_index),
                };
                try putUnique(&result.block_ordinals, try rawIdOwned(identity_domain, hir_block.id), @as(u32, @intCast(block_ordinal)));

                for (hir_block.parameters) |parameter| {
                    try putUnique(&result.value_ordinals, try rawIdOwned(identity_domain, parameter.value), @as(u32, @intCast(value_ordinal)));
                    value_types[value_ordinal] = parameter.type_id;
                    value_ordinal += 1;
                }

                for (hir_block.instructions, 0..) |hir_instruction, local_instruction_index| {
                    instructions[instruction_ordinal] = .{
                        .function_index = @intCast(function_index),
                        .block_index = @intCast(local_block_index),
                        .instruction_index = @intCast(local_instruction_index),
                    };
                    try putUnique(&result.instruction_ordinals, try rawIdOwned(identity_domain, hir_instruction.id), @as(u32, @intCast(instruction_ordinal)));
                    if (hir_instruction.result) |value| {
                        try putUnique(&result.value_ordinals, try rawIdOwned(identity_domain, value), @as(u32, @intCast(value_ordinal)));
                        value_producers[value_ordinal] = @intCast(instruction_ordinal);
                        value_types[value_ordinal] = hir_instruction.result_type orelse return error.InconsistentProjection;
                        value_ordinal += 1;
                    }
                    switch (hir_instruction.operation) {
                        .dynamic_import => |payload| if (payload.resolved) |resolved| switch (resolved) {
                            .external => |external| try indexExternalModule(&result, external.value()),
                            .source => {},
                        },
                        .initialize_binding => |payload| try incrementWriterCount(&result, writer_offsets, payload.binding),
                        .store_binding => |payload| try incrementWriterCount(&result, writer_offsets, payload.binding),
                        .load_place => |place| try result.consumed_places.put(try rawIdOwned(identity_domain, place), {}),
                        .store_place => |payload| {
                            try result.consumed_places.put(try rawIdOwned(identity_domain, payload.place), {});
                            if (result.bindingForPlace(payload.place)) |binding_id|
                                try incrementWriterCount(&result, writer_offsets, binding_id);
                        },
                        .delete_place => |place| {
                            const raw = try rawIdOwned(identity_domain, place);
                            try result.consumed_places.put(raw, {});
                            try result.deleted_places.put(raw, {});
                        },
                        .apply_pattern => |plan| for (plan.items) |item| switch (item) {
                            .binding_target => |binding_id| try incrementWriterCount(&result, writer_offsets, binding_id),
                            .place_target => |place| {
                                try result.consumed_places.put(try rawIdOwned(identity_domain, place), {});
                                if (result.bindingForPlace(place)) |binding_id|
                                    try incrementWriterCount(&result, writer_offsets, binding_id);
                            },
                            else => {},
                        },
                        else => {},
                    }
                    instruction_ordinal += 1;
                }
                block_ordinal += 1;
            }
        }

        const external_module_ids = try allocator.alloc(u64, result.external_module_ordinals.count());
        var external_it = result.external_module_ordinals.iterator();
        while (external_it.next()) |entry| external_module_ids[entry.value_ptr.*] = entry.key_ptr.*;
        result.external_module_ids = external_module_ids;

        for (project.language_items) |item| {
            const function_id = item.function orelse continue;
            const function_ordinal = result.functionOrdinal(function_id) orelse return error.InconsistentProjection;
            try putUnique(&result.language_item_functions, item.id.value(), function_ordinal);
        }

        // Imports are module metadata and are deliberately indexed after every
        // binding has a canonical ordinal.
        for (project.modules, 0..) |module, module_index| {
            for (module.imports, 0..) |import_binding, import_index| {
                const local = import_binding.local orelse continue;
                const ordinal = result.bindingOrdinal(local) orelse return error.InconsistentProjection;
                if (binding_imports[ordinal] != null) return error.DuplicateBindingImport;
                binding_imports[ordinal] = .{ .module_index = @intCast(module_index), .import_index = @intCast(import_index) };
            }
        }

        for (0..binding_count) |ordinal|
            writer_offsets[ordinal + 1] = std.math.add(u32, writer_offsets[ordinal], writer_offsets[ordinal + 1]) catch return error.IndexOverflow;
        const writer_instructions = try allocator.alloc(u32, writer_offsets[binding_count]);
        const cursors = try allocator.dupe(u32, writer_offsets[0..binding_count]);
        result.binding_writer_instructions = writer_instructions;

        for (project.functions) |hir_function| {
            for (hir_function.blocks) |hir_block| {
                for (hir_block.instructions) |hir_instruction| {
                    const instruction_ord = result.instructionOrdinal(hir_instruction.id) orelse return error.InconsistentProjection;
                    switch (hir_instruction.operation) {
                        .initialize_binding => |payload| try appendWriter(&result, writer_instructions, cursors, payload.binding, instruction_ord),
                        .store_binding => |payload| try appendWriter(&result, writer_instructions, cursors, payload.binding, instruction_ord),
                        .store_place => |payload| if (result.bindingForPlace(payload.place)) |binding_id|
                            try appendWriter(&result, writer_instructions, cursors, binding_id, instruction_ord),
                        .apply_pattern => |plan| for (plan.items) |item| switch (item) {
                            .binding_target => |binding_id| try appendWriter(&result, writer_instructions, cursors, binding_id, instruction_ord),
                            .place_target => |place| if (result.bindingForPlace(place)) |binding_id|
                                try appendWriter(&result, writer_instructions, cursors, binding_id, instruction_ord),
                            else => {},
                        },
                        else => {},
                    }
                }
            }
        }

        // `cursors` is temporary construction scratch. It is the most recent
        // arena allocation here, so releasing it now avoids retaining it in the
        // sealed HIR result on allocators that can reclaim the last allocation.
        allocator.free(cursors);

        // Names are projection metadata only. Resolve them once by stable
        // declaration identity instead of rescanning every binding per query.
        for (project.functions, 0..) |hir_function, function_index| {
            const symbol = hir_function.symbol orelse continue;
            const provider = result.semantic_providers.get(symbol) orelse continue;
            if (provider.binding_ordinal) |ordinal| {
                const hir_binding = result.binding(project, ordinal) orelse return error.InconsistentProjection;
                if (hir_binding.kind == .function) function_names[function_index] = hir_binding.name;
            }
        }

        return result;
    }

    pub fn deinit(self: *Index) void {
        self.module_ordinals.deinit();
        self.entity_ordinals.deinit();
        self.function_ordinals.deinit();
        self.block_ordinals.deinit();
        self.instruction_ordinals.deinit();
        self.binding_ordinals.deinit();
        self.value_ordinals.deinit();
        self.external_module_ordinals.deinit();
        self.language_item_functions.deinit();
        self.place_bindings.deinit();
        self.consumed_places.deinit();
        self.deleted_places.deinit();
        self.semantic_providers.deinit();
        freeSlice(self.allocator, self.blocks);
        freeSlice(self.allocator, self.instructions);
        freeSlice(self.allocator, self.bindings);
        freeSlice(self.allocator, self.function_names);
        freeSlice(self.allocator, self.external_module_ids);
        freeSlice(self.allocator, self.value_producers);
        freeSlice(self.allocator, self.value_types);
        freeSlice(self.allocator, self.binding_imports);
        freeSlice(self.allocator, self.capture_sources);
        freeSlice(self.allocator, self.binding_writer_offsets);
        freeSlice(self.allocator, self.binding_writer_instructions);
        self.* = undefined;
    }

    pub fn moduleOrdinal(self: *const Index, id: model.ModuleId) ?u32 {
        return self.module_ordinals.get(id.value());
    }

    pub fn entityOrdinal(self: *const Index, id: ids.EntityId) ?u32 {
        return self.entity_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn functionOrdinal(self: *const Index, id: ids.FunctionId) ?u32 {
        return self.function_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn blockOrdinal(self: *const Index, id: ids.BlockId) ?u32 {
        return self.block_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn instructionOrdinal(self: *const Index, id: ids.InstructionId) ?u32 {
        return self.instruction_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn bindingOrdinal(self: *const Index, id: ids.BindingId) ?u32 {
        return self.binding_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn valueOrdinal(self: *const Index, id: ids.ValueId) ?u32 {
        return self.value_ordinals.get(self.rawId(id) orelse return null);
    }

    pub fn entity(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirEntity {
        _ = self;
        if (ordinal >= project.entities.len) return null;
        return &project.entities[ordinal];
    }

    pub fn entityByRaw(self: *const Index, project: model.HirProject, raw_id: u64) ?*const model.HirEntity {
        if (raw_id > std.math.maxInt(u32)) return null;
        const ordinal = self.entity_ordinals.get(@as(u32, @intCast(raw_id))) orelse return null;
        return self.entity(project, ordinal);
    }

    pub fn function(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirFunction {
        _ = self;
        if (ordinal >= project.functions.len) return null;
        return &project.functions[ordinal];
    }

    pub fn functionById(self: *const Index, project: model.HirProject, id: ids.FunctionId) ?*const model.HirFunction {
        const ordinal = self.functionOrdinal(id) orelse return null;
        return self.function(project, ordinal);
    }

    pub fn block(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirBlock {
        if (ordinal >= self.blocks.len) return null;
        const location = self.blocks[ordinal];
        return &project.functions[location.function_index].blocks[location.block_index];
    }

    pub fn blockFunction(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirFunction {
        if (ordinal >= self.blocks.len) return null;
        return &project.functions[self.blocks[ordinal].function_index];
    }

    pub fn instruction(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirInstruction {
        if (ordinal >= self.instructions.len) return null;
        const location = self.instructions[ordinal];
        return &project.functions[location.function_index].blocks[location.block_index].instructions[location.instruction_index];
    }

    pub fn instructionBlock(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirBlock {
        if (ordinal >= self.instructions.len) return null;
        const location = self.instructions[ordinal];
        return &project.functions[location.function_index].blocks[location.block_index];
    }

    pub fn instructionFunction(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirFunction {
        if (ordinal >= self.instructions.len) return null;
        return &project.functions[self.instructions[ordinal].function_index];
    }

    pub fn binding(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirBinding {
        if (ordinal >= self.bindings.len) return null;
        const location = self.bindings[ordinal];
        return &project.functions[location.function_index].bindings[location.binding_index];
    }

    pub fn bindingFunction(self: *const Index, project: model.HirProject, ordinal: usize) ?*const model.HirFunction {
        if (ordinal >= self.bindings.len) return null;
        return &project.functions[self.bindings[ordinal].function_index];
    }

    pub fn producerInstructionOrdinal(self: *const Index, value: ids.ValueId) ?u32 {
        const ordinal = self.valueOrdinal(value) orelse return null;
        return self.value_producers[ordinal];
    }

    pub fn valueType(self: *const Index, value: ids.ValueId) ?model.TypeId {
        const ordinal = self.valueOrdinal(value) orelse return null;
        return self.value_types[ordinal];
    }

    pub fn externalModuleOrdinal(self: *const Index, id: model.ExternalModuleId) ?u32 {
        return self.external_module_ordinals.get(id.value());
    }

    pub fn languageItemFunctionOrdinal(self: *const Index, raw_id: u64) ?u32 {
        return self.language_item_functions.get(raw_id);
    }

    pub fn importForBinding(self: *const Index, project: model.HirProject, binding_id: ids.BindingId) ?*const model.HirImportBinding {
        const ordinal = self.bindingOrdinal(binding_id) orelse return null;
        const location = self.binding_imports[ordinal] orelse return null;
        return &project.modules[location.module_index].imports[location.import_index];
    }

    pub fn captureSource(self: *const Index, binding_id: ids.BindingId) ?ids.BindingId {
        const ordinal = self.bindingOrdinal(binding_id) orelse return null;
        return self.capture_sources[ordinal];
    }

    pub fn writersForBinding(self: *const Index, binding_id: ids.BindingId) []const u32 {
        const ordinal = self.bindingOrdinal(binding_id) orelse return &.{};
        const start = self.binding_writer_offsets[ordinal];
        const end = self.binding_writer_offsets[ordinal + 1];
        return self.binding_writer_instructions[start..end];
    }

    pub fn bindingForPlace(self: *const Index, place: ids.PlaceId) ?ids.BindingId {
        return self.place_bindings.get(self.rawId(place) orelse return null);
    }

    pub fn placeIsConsumed(self: *const Index, place: ids.PlaceId) bool {
        return self.consumed_places.contains(self.rawId(place) orelse return false);
    }

    pub fn placeIsDeleted(self: *const Index, place: ids.PlaceId) bool {
        return self.deleted_places.contains(self.rawId(place) orelse return false);
    }

    fn rawId(self: *const Index, id: anytype) ?u32 {
        if (!id.isValidFor(self.identity_domain)) return null;
        return id.index();
    }

    pub fn semanticProvider(self: *const Index, declaration: model.SemanticDeclId) ?SemanticProvider {
        return self.semantic_providers.get(declaration);
    }
};

fn rawIdOwned(identity_domain: *const ids.IdentityDomain, id: anytype) !u32 {
    if (!id.isValidFor(identity_domain)) return error.ForeignId;
    return id.index() orelse error.ForeignId;
}

fn putUnique(map: anytype, key: anytype, value: anytype) !void {
    const entry = try map.getOrPut(key);
    if (entry.found_existing) return error.DuplicateCanonicalId;
    entry.value_ptr.* = value;
}

fn indexExternalModule(index: *Index, raw_id: u64) !void {
    if (index.external_module_ordinals.contains(raw_id)) return;
    if (index.external_module_ordinals.count() > std.math.maxInt(u32)) return error.IndexOverflow;
    try index.external_module_ordinals.put(raw_id, @as(u32, @intCast(index.external_module_ordinals.count())));
}

fn incrementWriterCount(index: *const Index, offsets: []u32, binding: ids.BindingId) !void {
    const ordinal = index.bindingOrdinal(binding) orelse return error.InconsistentProjection;
    offsets[ordinal + 1] = std.math.add(u32, offsets[ordinal + 1], 1) catch return error.IndexOverflow;
}

fn appendWriter(
    index: *const Index,
    writer_instructions: []u32,
    cursors: []u32,
    binding: ids.BindingId,
    instruction_ordinal: u32,
) !void {
    const ordinal = index.bindingOrdinal(binding) orelse return error.InconsistentProjection;
    const cursor = cursors[ordinal];
    if (cursor >= writer_instructions.len) return error.InconsistentProjection;
    writer_instructions[cursor] = instruction_ordinal;
    cursors[ordinal] = cursor + 1;
}

fn freeSlice(allocator: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) allocator.free(slice);
}
