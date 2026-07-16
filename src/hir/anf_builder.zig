//! Block-aware ANF construction. Every operand must already be defined.

const std = @import("std");
const builder_mod = @import("builder.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");

const Draft = struct {
    id: ids.BlockId,
    parameters: std.ArrayList(model.HirBlockParameter) = .empty,
    instructions: std.ArrayList(model.HirInstruction) = .empty,
    terminator: ?model.HirTerminator = null,
};

pub const AnfBuilder = struct {
    builder: *builder_mod.Builder,
    drafts: std.ArrayList(Draft) = .empty,
    places: std.ArrayList(model.HirPlace) = .empty,
    defined_values: std.ArrayList(bool) = .empty,
    defined_places: std.ArrayList(bool) = .empty,
    value_types: std.ArrayList(?model.TypeId) = .empty,
    current: usize = 0,
    entry: ids.BlockId,

    pub fn init(builder: *builder_mod.Builder) !AnfBuilder {
        var self: AnfBuilder = .{ .builder = builder, .entry = .invalid };
        self.entry = try self.createBlock();
        return self;
    }

    pub fn createBlock(self: *AnfBuilder) !ids.BlockId {
        try self.builder.reserve(.blocks_per_function, 1);
        try self.builder.reserve(.blocks, 1);
        const id = try self.builder.makeId(ids.BlockId, self.builder.budget.usage.blocks - 1);
        try self.drafts.append(self.builder.allocator, .{ .id = id });
        return id;
    }

    pub fn beginBlock(self: *AnfBuilder, block: ids.BlockId) !void {
        for (self.drafts.items, 0..) |draft, index| if (draft.id.eql(block)) {
            self.current = index;
            return;
        };
        return error.UnknownBlock;
    }

    pub fn addParameter(self: *AnfBuilder, block: ids.BlockId, type_id: model.TypeId) !ids.ValueId {
        const index = self.blockIndex(block) orelse return error.UnknownBlock;
        const value = try self.allocateValue(type_id);
        try self.drafts.items[index].parameters.append(self.builder.allocator, .{
            .value = value,
            .type_id = type_id,
            .origin = .invalid,
        });
        return value;
    }

    pub fn emitValue(self: *AnfBuilder, operation: model.HirOperation, type_id: model.TypeId) !ids.ValueId {
        return self.emitValueAt(operation, type_id, .invalid);
    }

    pub fn emitValueAt(self: *AnfBuilder, operation: model.HirOperation, type_id: model.TypeId, origin: ids.OriginId) !ids.ValueId {
        try self.ensureOperationOperands(operation);
        try self.builder.reserve(.instructions, 1);
        const instruction = try self.builder.makeId(ids.InstructionId, self.builder.budget.usage.instructions - 1);
        const value = try self.allocateValue(type_id);
        try self.drafts.items[self.current].instructions.append(self.builder.allocator, try model.HirInstruction.init(
            instruction,
            value,
            type_id,
            operation,
            origin,
        ));
        return value;
    }

    pub fn emitVoid(self: *AnfBuilder, operation: model.HirOperation) !void {
        try self.ensureOperationOperands(operation);
        try self.builder.reserve(.instructions, 1);
        const instruction = try self.builder.makeId(ids.InstructionId, self.builder.budget.usage.instructions - 1);
        try self.drafts.items[self.current].instructions.append(self.builder.allocator, try model.HirInstruction.init(
            instruction,
            null,
            null,
            operation,
            .invalid,
        ));
    }

    pub fn emitPlace(self: *AnfBuilder, kind: model.HirPlace.Kind) !ids.PlaceId {
        switch (kind) {
            .binding => {},
            .property => |property| {
                try self.requireValue(property.base);
                try self.requireKey(property.key);
            },
            .element => |element| {
                try self.requireValue(element.base);
                try self.requireValue(element.key);
            },
            .super_property => |property| {
                try self.requireValue(property.receiver);
                try self.requireKey(property.key);
            },
        }
        try self.builder.reserve(.places, 1);
        const place = try self.builder.makeId(ids.PlaceId, self.builder.budget.usage.places - 1);
        const index: usize = @intCast(place.index().?);
        while (self.defined_places.items.len <= index) try self.defined_places.append(self.builder.allocator, false);
        if (self.defined_places.items[index]) return error.PlaceAlreadyDefined;
        self.defined_places.items[index] = true;
        try self.places.append(self.builder.allocator, .{ .id = place, .kind = kind, .origin = .invalid });
        try self.emitVoid(switch (kind) {
            .binding => |binding| .{ .make_binding_place = .{ .result = place, .binding = binding } },
            .property => |property| .{ .make_property_place = .{ .result = place, .base = property.base, .key = property.key } },
            .element => |element| .{ .make_element_place = .{ .result = place, .base = element.base, .key = element.key } },
            .super_property => |property| .{ .make_super_place = .{ .result = place, .receiver = property.receiver, .key = property.key } },
        });
        return place;
    }

    pub fn terminate(self: *AnfBuilder, terminator: model.HirTerminator) !void {
        const draft = &self.drafts.items[self.current];
        if (draft.terminator != null) return error.BlockAlreadyTerminated;
        try self.ensureTerminatorOperands(terminator);
        draft.terminator = terminator;
    }

    pub fn currentTerminated(self: *const AnfBuilder) bool {
        return self.drafts.items[self.current].terminator != null;
    }

    pub fn blockCount(self: *const AnfBuilder) usize {
        return self.drafts.items.len;
    }

    pub fn blockIdsSince(self: *AnfBuilder, start: usize) ![]const ids.BlockId {
        const result = try self.builder.allocator.alloc(ids.BlockId, self.drafts.items.len - start);
        for (self.drafts.items[start..], 0..) |draft, index| result[index] = draft.id;
        return result;
    }

    pub fn finish(self: *AnfBuilder) ![]const model.HirBlock {
        const blocks = try self.builder.allocator.alloc(model.HirBlock, self.drafts.items.len);
        for (self.drafts.items, 0..) |*draft, index| blocks[index] = .{
            .id = draft.id,
            .parameters = try draft.parameters.toOwnedSlice(self.builder.allocator),
            .instructions = try draft.instructions.toOwnedSlice(self.builder.allocator),
            .terminator = draft.terminator orelse return error.MissingTerminator,
            .origin = .invalid,
        };
        return blocks;
    }

    pub fn finishPlaces(self: *AnfBuilder) ![]const model.HirPlace {
        return self.places.toOwnedSlice(self.builder.allocator);
    }

    fn allocateValue(self: *AnfBuilder, type_id: model.TypeId) !ids.ValueId {
        try self.builder.reserve(.values, 1);
        const value = try self.builder.makeId(ids.ValueId, self.builder.budget.usage.values - 1);
        const index: usize = @intCast(value.index().?);
        while (self.defined_values.items.len <= index) {
            try self.defined_values.append(self.builder.allocator, false);
            try self.value_types.append(self.builder.allocator, null);
        }
        if (self.defined_values.items[index]) return error.ValueAlreadyDefined;
        self.defined_values.items[index] = true;
        self.value_types.items[index] = type_id;
        return value;
    }

    fn requireValue(self: *const AnfBuilder, value: ids.ValueId) !void {
        try self.builder.result.requireOwnedId(value);
        const raw = value.index() orelse return error.ValueUseBeforeDefinition;
        const index: usize = @intCast(raw);
        if (index >= self.defined_values.items.len or !self.defined_values.items[index]) return error.ValueUseBeforeDefinition;
    }

    fn requireValues(self: *const AnfBuilder, values: []const ids.ValueId) !void {
        for (values) |value| try self.requireValue(value);
    }

    fn requirePlace(self: *const AnfBuilder, place: ids.PlaceId) !void {
        try self.builder.result.requireOwnedId(place);
        const raw = place.index() orelse return error.PlaceUseBeforeDefinition;
        const index: usize = @intCast(raw);
        if (index >= self.defined_places.items.len or !self.defined_places.items[index]) return error.PlaceUseBeforeDefinition;
    }

    fn requireKey(self: *const AnfBuilder, key: model.PropertyKey) !void {
        if (key == .computed) try self.requireValue(key.computed);
    }

    fn ensureOperationOperands(self: *const AnfBuilder, operation: model.HirOperation) !void {
        switch (operation) {
            .copy,
            .to_boolean,
            .is_nullish,
            .typeof_value,
            .void_value,
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
            .array_append_hole,
            => |value| try self.requireValue(value),
            .initialize_binding => |item| try self.requireValue(item.value),
            .store_binding => |item| try self.requireValue(item.value),
            .make_binding_place => |item| try self.requirePlace(item.result),
            .make_property_place => |item| {
                try self.requirePlace(item.result);
                try self.requireValue(item.base);
                try self.requireKey(item.key);
            },
            .make_element_place => |item| {
                try self.requirePlace(item.result);
                try self.requireValue(item.base);
                try self.requireValue(item.key);
            },
            .make_super_place => |item| {
                try self.requirePlace(item.result);
                try self.requireValue(item.receiver);
                try self.requireKey(item.key);
            },
            .load_place, .delete_place => |place| try self.requirePlace(place),
            .store_place => |item| {
                try self.requirePlace(item.place);
                try self.requireValue(item.value);
            },
            .unary => |item| try self.requireValue(item.operand),
            .binary => |item| {
                try self.requireValue(item.left);
                try self.requireValue(item.right);
            },
            .add => |item| {
                try self.requireValue(item.left);
                try self.requireValue(item.right);
            },
            .call, .construct => |item| {
                try self.requireValue(item.callee);
                for (item.arguments) |argument| try self.requireValue(argument.operand());
            },
            .call_method, .call_super_method => |item| {
                if (item.callee) |callee| try self.requireValue(callee);
                try self.requireValue(item.receiver);
                try self.requireKey(item.key);
                for (item.arguments) |argument| try self.requireValue(argument.operand());
            },
            .call_super_constructor => |arguments| for (arguments) |argument| try self.requireValue(argument.operand()),
            .dynamic_import => |item| {
                try self.requireValue(item.source);
                if (item.options) |options| try self.requireValue(options);
            },
            .tagged_template_call => |item| {
                try self.requireValue(item.tag);
                if (item.receiver) |receiver| try self.requireValue(receiver);
                try self.requireValue(item.template_site);
                try self.requireValues(item.substitutions);
            },
            .define_property => |item| {
                try self.requireValue(item.object);
                try self.requireKey(item.key);
                try self.requireValue(item.value);
            },
            .define_method => |item| {
                try self.requireValue(item.object);
                try self.requireKey(item.key);
            },
            .copy_object_properties => |item| {
                try self.requireValue(item.target);
                try self.requireValue(item.source);
            },
            .array_append => |item| {
                try self.requireValue(item.array);
                try self.requireValue(item.value);
            },
            .array_append_iterable => |item| {
                try self.requireValue(item.array);
                try self.requireValue(item.iterable);
            },
            .build_string => |parts| for (parts) |part| if (part == .value) try self.requireValue(part.value),
            .to_string => |value| try self.requireValue(value),
            .constant,
            .load_binding,
            .load_this,
            .load_super,
            .load_meta,
            .create_object,
            .create_array,
            .create_closure,
            .create_enum_object,
            .create_regexp,
            .create_template_site,
            .collect_rest_arguments,
            .read_argument,
            .create_arguments_object,
            .debugger_trap,
            => {},
            .create_class => |item| if (item.base) |base| try self.requireValue(base),
        }
    }

    fn ensureTerminatorOperands(self: *const AnfBuilder, terminator: model.HirTerminator) !void {
        switch (terminator) {
            .jump => |jump| {
                try self.requireValues(jump.arguments);
                const target_index = self.blockIndex(jump.target) orelse return error.UnknownBlock;
                const parameters = self.drafts.items[target_index].parameters.items;
                if (parameters.len != jump.arguments.len) return error.BlockArgumentArityMismatch;
                for (parameters, jump.arguments) |parameter, argument| {
                    const argument_index: usize = @intCast(argument.index().?);
                    if (self.value_types.items[argument_index].? != parameter.type_id) return error.BlockArgumentTypeMismatch;
                }
            },
            .branch => |branch| try self.requireValue(branch.condition),
            .return_ => |value| if (value) |item| try self.requireValue(item),
            .throw => |value| try self.requireValue(value),
            .leave_region => |leave| switch (leave.completion) {
                .return_ => |value| if (value) |item| try self.requireValue(item),
                .throw => |value| try self.requireValue(value),
                else => {},
            },
            .unreachable_, .resume_completion => {},
        }
    }

    fn blockIndex(self: *const AnfBuilder, block: ids.BlockId) ?usize {
        for (self.drafts.items, 0..) |draft, index| if (draft.id.eql(block)) return index;
        return null;
    }
};
