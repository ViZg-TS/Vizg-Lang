const std = @import("std");
const model = @import("model.zig");

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    builtins: model.Builtins,
    records: std.ArrayList(StoredType),
    signatures: std.ArrayList(model.FunctionSignature),

    /// Qualified keys prevent equal local AST NodeIds in different modules from
    /// colliding. Classes and interfaces have different semantic contracts.
    class_types: std.AutoHashMap(model.SemanticDeclId, model.ClassSemanticType),
    interface_types: std.AutoHashMap(model.SemanticDeclId, model.InterfaceSemanticType),

    const StoredType = struct {
        id: model.TypeId,
        kind: ?model.TypeKind,
    };

    pub fn init(allocator: std.mem.Allocator) TypeStore {
        return .{
            .allocator = allocator,
            .builtins = model.Builtins.init(),
            .records = .empty,
            .signatures = .empty,
            .class_types = std.AutoHashMap(model.SemanticDeclId, model.ClassSemanticType).init(allocator),
            .interface_types = std.AutoHashMap(model.SemanticDeclId, model.InterfaceSemanticType).init(allocator),
        };
    }

    pub fn count(self: *const TypeStore) usize {
        return self.builtins.records.len + self.records.items.len;
    }

    pub fn lookup(self: *const TypeStore, id: model.TypeId) ?model.Type {
        if (self.builtins.lookup(id)) |builtin| return builtin.*;
        const record = self.stored(id) orelse return null;
        return .{ .id = id, .kind = record.kind orelse return null };
    }

    pub fn lookupFunction(self: *const TypeStore, id: model.TypeId) ?model.FunctionSignature {
        for (self.signatures.items) |signature| {
            if (signature.id == id) return signature;
        }
        return null;
    }
    pub fn createClassSemanticType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        name: []const u8,
    ) !model.ClassSemanticType {
        if (self.class_types.get(identity)) |existing| return existing;
        const instance_type = try self.intern(.{ .class = .{ .identity = identity, .name = name } });
        const constructor_type = try self.intern(.{ .class_constructor = .{
            .identity = identity,
            .name = name,
            .instance_type = instance_type,
        } });
        const result: model.ClassSemanticType = .{
            .identity = identity,
            .name = name,
            .constructor_type = constructor_type,
            .instance_type = instance_type,
        };
        try self.class_types.put(identity, result);
        return result;
    }

    pub fn createInterfaceSemanticType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        name: []const u8,
        members: model.MemberTable,
    ) !model.InterfaceSemanticType {
        if (self.interface_types.get(identity)) |existing| return existing;
        const type_id = try self.intern(.{ .interface = .{
            .identity = identity,
            .name = name,
            .members = members,
        } });
        const stored_interface = self.lookup(type_id).?.kind.interface;
        const result: model.InterfaceSemanticType = .{
            .identity = identity,
            .name = stored_interface.name,
            .type_id = type_id,
            .members = stored_interface.members,
        };
        try self.interface_types.put(identity, result);
        return result;
    }

    pub fn lookupClassSemanticType(self: *const TypeStore, identity: model.SemanticDeclId) ?model.ClassSemanticType {
        return self.class_types.get(identity);
    }

    pub fn lookupInterfaceSemanticType(self: *const TypeStore, identity: model.SemanticDeclId) ?model.InterfaceSemanticType {
        return self.interface_types.get(identity);
    }

    /// Complete the member-bearing portion of a predeclared class identity.
    pub fn completeClassSemanticType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        static_members: model.MemberTable,
        instance_members: model.MemberTable,
        constructor_signature: ?model.TypeId,
        inheritance: model.ClassInheritance,
    ) !void {
        const semantic = self.class_types.getPtr(identity) orelse return error.UnknownClassIdentity;
        semantic.static_members = try self.cloneMemberTable(static_members);
        semantic.instance_members = try self.cloneMemberTable(instance_members);
        semantic.constructor_signature = constructor_signature;
        semantic.inheritance = .{
            .extends = inheritance.extends,
            .implements = try self.allocator.dupe(model.TypeId, inheritance.implements),
        };
    }

    /// Complete a predeclared interface while preserving its stable TypeId.
    pub fn completeInterfaceSemanticType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        members: model.MemberTable,
        inheritance: model.InterfaceInheritance,
    ) !void {
        const semantic = self.interface_types.getPtr(identity) orelse return error.UnknownInterfaceIdentity;
        const owned_members = try self.cloneMemberTable(members);
        const record = self.storedMut(semantic.type_id) orelse return error.InvalidTypeId;
        if (record.kind) |*kind| switch (kind.*) {
            .interface => |*interface| interface.members = owned_members,
            else => return error.InvalidInterfaceType,
        } else return error.InvalidInterfaceType;
        semantic.members = owned_members;
        semantic.inheritance = .{ .extends = try self.allocator.dupe(model.TypeId, inheritance.extends) };
    }

    /// Reserve identity before its definition is available. References may safely
    /// point at this id; lookup starts succeeding only after defineReserved.
    pub fn reserve(self: *TypeStore) !model.TypeId {
        const id = model.next_user_type_id + @as(model.TypeId, @intCast(self.records.items.len));
        try self.records.append(self.allocator, .{ .id = id, .kind = null });
        return id;
    }

    pub fn defineReserved(self: *TypeStore, id: model.TypeId, kind: model.TypeKind) !void {
        const record = self.storedMut(id) orelse return error.InvalidTypeId;
        if (record.kind != null) return error.TypeAlreadyDefined;
        record.kind = try self.cloneKind(kind);
    }

    /// Structural shapes and exact nominal identities are interned. Distinct
    /// declarations remain distinct because nominal equality includes identity.
    /// Recursive construction uses reserve/defineReserved instead.
    pub fn intern(self: *TypeStore, kind: model.TypeKind) !model.TypeId {
        for (self.records.items) |record| {
            const existing = record.kind orelse continue;
            if (kindsEqual(existing, kind)) return record.id;
        }
        const id = try self.reserve();
        try self.defineReserved(id, kind);
        return id;
    }

    pub fn addFunction(
        self: *TypeStore,
        parameters: []const model.ParameterType,
        return_type: model.TypeId,
    ) !model.TypeId {
        return self.addFunctionDetailed(parameters, return_type, 0, .{});
    }

    pub fn addFunctionDetailed(
        self: *TypeStore,
        parameters: []const model.ParameterType,
        return_type: model.TypeId,
        type_parameter_count: u32,
        flags: model.FunctionFlags,
    ) !model.TypeId {
        // Function signatures are immutable structural values. Reuse an equal
        // signature; allocate a new TypeId for every changed shape.
        const new_signature: model.FunctionSignature = .{
            .id = undefined, // id not yet assigned; used only for comparison
            .parameters = parameters,
            .return_type = return_type,
            .type_parameter_count = type_parameter_count,
            .flags = flags,
            .declaration_id = null, // Not a real declaration yet
        };

        for (self.signatures.items) |signature| {
            if (!structurallyEqualSignatures(signature, new_signature)) continue;
            return signature.id;
        }

        const id = try self.reserve();
        const owned_parameters = try self.cloneParameters(parameters);
        try self.signatures.append(self.allocator, .{
            .id = id,
            .parameters = owned_parameters,
            .return_type = return_type,
            .type_parameter_count = type_parameter_count,
            .flags = flags,
        });
        try self.defineReserved(id, .{ .function = id });
        return id;
    }

    /// Returns an immutable signature. Changes require addFunctionDetailed and
    /// replacement of the owning symbol's TypeId.
    pub fn lookupFunctionSignature(self: *const TypeStore, id: model.TypeId) ?model.FunctionSignature {
        for (self.signatures.items) |signature| {
            if (signature.id == id) return signature;
        }
        return null;
    }

    /// Canonical union rules: flatten, sort, deduplicate, remove never, and let
    /// any/unknown absorb the union. Invalid ids propagate as unknown.
    pub fn unionOf(self: *TypeStore, members: []const model.TypeId) !model.TypeId {
        var normalized: std.ArrayList(model.TypeId) = .empty;
        for (members) |member| {
            if (member == model.invalid_type or self.lookup(member) == null) return self.builtins.unknown;
            if (member == self.builtins.any) return self.builtins.any;
            if (member == self.builtins.unknown) return self.builtins.unknown;
            if (member == self.builtins.never) continue;
            const ty = self.lookup(member).?;
            if (ty.kind == .union_type) {
                for (ty.kind.union_type) |nested| try appendSortedUnique(self.allocator, &normalized, nested);
            } else {
                try appendSortedUnique(self.allocator, &normalized, member);
            }
        }
        if (normalized.items.len == 0) return self.builtins.never;
        if (normalized.items.len == 1) return normalized.items[0];
        return self.intern(.{ .union_type = normalized.items });
    }

    /// Canonical intersection rules: flatten, sort, deduplicate, remove unknown
    /// and any, while never absorbs. Invalid ids propagate as unknown.
    pub fn intersectionOf(self: *TypeStore, members: []const model.TypeId) !model.TypeId {
        var normalized: std.ArrayList(model.TypeId) = .empty;
        for (members) |member| {
            if (member == model.invalid_type or self.lookup(member) == null) return self.builtins.unknown;
            if (member == self.builtins.never) return self.builtins.never;
            if (member == self.builtins.any or member == self.builtins.unknown) continue;
            const ty = self.lookup(member).?;
            if (ty.kind == .intersection) {
                for (ty.kind.intersection) |nested| try appendSortedUnique(self.allocator, &normalized, nested);
            } else {
                try appendSortedUnique(self.allocator, &normalized, member);
            }
        }
        if (normalized.items.len == 0) return self.builtins.unknown;
        if (normalized.items.len == 1) return normalized.items[0];
        return self.intern(.{ .intersection = normalized.items });
    }

    pub fn identical(_: *const TypeStore, left: model.TypeId, right: model.TypeId) bool {
        return left == right;
    }

    /// Children are canonical ids, so comparing the immediate stored shapes is
    /// structural and cycle-safe; it never recursively allocates or walks cycles.
    pub fn structurallyEqual(self: *const TypeStore, left: model.TypeId, right: model.TypeId) bool {
        if (left == right) return true;
        const left_type = self.lookup(left) orelse return false;
        const right_type = self.lookup(right) orelse return false;
        return kindsEqual(left_type.kind, right_type.kind);
    }

    /// Debug rendering is deliberately lossy and must never drive type decisions.
    pub fn formatDebugAlloc(self: *const TypeStore, allocator: std.mem.Allocator, id: model.TypeId) ![]u8 {
        const ty = self.lookup(id) orelse return std.fmt.allocPrint(allocator, "<invalid:{d}>", .{id});
        return switch (ty.kind) {
            .primitive, .literal => std.fmt.allocPrint(allocator, "{s}#{d}", .{ ty.displayName(), id }),
            .function => |signature_id| if (self.lookupFunctionSignature(signature_id)) |signature|
                std.fmt.allocPrint(allocator, "function#{d}[parameters={d},return={d}]", .{ id, signature.parameters.len, signature.return_type })
            else
                std.fmt.allocPrint(allocator, "function#{d}[signature={d}]", .{ id, signature_id }),
            .promise => |value| std.fmt.allocPrint(allocator, "promise#{d}[value={d}]", .{ id, value.value_type }),
            .generator => |value| std.fmt.allocPrint(allocator, "generator#{d}[yield={d},return={d}]", .{ id, value.yield_type, value.return_type }),
            .union_type => |members| std.fmt.allocPrint(allocator, "union#{d}[members={d}]", .{ id, members.len }),
            .intersection => |members| std.fmt.allocPrint(allocator, "intersection#{d}[members={d}]", .{ id, members.len }),
            .array => |value| std.fmt.allocPrint(allocator, "array#{d}[element={d},readonly={}]", .{ id, value.element_type, value.readonly }),
            .tuple => |value| std.fmt.allocPrint(allocator, "tuple#{d}[elements={d},readonly={}]", .{ id, value.elements.len, value.readonly }),
            .object => |properties| if (properties.len == 0)
                std.fmt.allocPrint(allocator, "object#{d}[properties=0]", .{id})
            else
                std.fmt.allocPrint(allocator, "object#{d}[properties={d},first={s}:{d}]", .{ id, properties.len, properties[0].name, properties[0].type_id }),
            .class => |value| formatNominalDebugAlloc(allocator, "class", value.name, id, value.identity),
            .class_constructor => |value| std.fmt.allocPrint(
                allocator,
                "class-constructor {s}#{d}[module={d},declaration={d},instance={d}]",
                .{ value.name, id, value.identity.module_id, value.identity.declaration_id, value.instance_type },
            ),
            .interface => |value| std.fmt.allocPrint(
                allocator,
                "interface {s}#{d}[module={d},declaration={d},members={d}]",
                .{ value.name, id, value.identity.module_id, value.identity.declaration_id, value.members.members.len },
            ),
            .enum_type => |value| formatNominalDebugAlloc(allocator, "enum", value.name, id, value.identity),
            .type_parameter => |value| std.fmt.allocPrint(
                allocator,
                "type-parameter {s}#{d}[module={d},declaration={d},parameter={d}]",
                .{ value.name, id, value.identity.module_id, value.identity.declaration_id, value.parameter_id },
            ),
        };
    }

    fn stored(self: *const TypeStore, id: model.TypeId) ?*const StoredType {
        if (id < model.next_user_type_id) return null;
        const index: usize = @as(usize, @intCast(id - model.next_user_type_id));
        if (index >= self.records.items.len) return null;
        return &self.records.items[index];
    }

    fn storedMut(self: *TypeStore, id: model.TypeId) ?*StoredType {
        if (id < model.next_user_type_id) return null;
        const index: usize = @as(usize, @intCast(id - model.next_user_type_id));
        if (index >= self.records.items.len) return null;
        return &self.records.items[index];
    }

    fn cloneParameters(self: *TypeStore, parameters: []const model.ParameterType) ![]const model.ParameterType {
        const copy = try self.allocator.alloc(model.ParameterType, parameters.len);
        for (parameters, 0..) |parameter, index| {
            copy[index] = parameter;
            copy[index].name = try self.allocator.dupe(u8, parameter.name);
        }
        return copy;
    }

    fn cloneKind(self: *TypeStore, kind: model.TypeKind) !model.TypeKind {
        return switch (kind) {
            .primitive, .function, .array, .promise, .generator => kind,
            .literal => |literal| .{ .literal = switch (literal) {
                .boolean, .number => literal,
                .bigint => |value| .{ .bigint = try self.allocator.dupe(u8, value) },
                .string => |value| .{ .string = try self.allocator.dupe(u8, value) },
            } },
            .union_type => |items| .{ .union_type = try self.allocator.dupe(model.TypeId, items) },
            .intersection => |items| .{ .intersection = try self.allocator.dupe(model.TypeId, items) },
            .tuple => |tuple| .{ .tuple = .{
                .elements = try self.allocator.dupe(model.TupleElement, tuple.elements),
                .readonly = tuple.readonly,
            } },
            .object => |properties| blk: {
                const copy = try self.allocator.alloc(model.ObjectProperty, properties.len);
                for (properties, 0..) |property, index| {
                    copy[index] = property;
                    copy[index].name = try self.allocator.dupe(u8, property.name);
                }
                break :blk .{ .object = copy };
            },
            .class => |instance| .{ .class = .{
                .identity = instance.identity,
                .name = try self.allocator.dupe(u8, instance.name),
            } },
            .class_constructor => |constructor| .{ .class_constructor = .{
                .identity = constructor.identity,
                .name = try self.allocator.dupe(u8, constructor.name),
                .instance_type = constructor.instance_type,
            } },
            .interface => |interface| .{ .interface = .{
                .identity = interface.identity,
                .name = try self.allocator.dupe(u8, interface.name),
                .members = try self.cloneMemberTable(interface.members),
            } },
            .enum_type => |nominal| .{ .enum_type = try self.cloneNominal(nominal) },
            .type_parameter => |parameter| .{ .type_parameter = .{
                .identity = parameter.identity,
                .parameter_id = parameter.parameter_id,
                .name = try self.allocator.dupe(u8, parameter.name),
                .constraint = parameter.constraint,
                .default = parameter.default,
            } },
        };
    }

    fn cloneNominal(self: *TypeStore, nominal: model.NominalType) !model.NominalType {
        return .{ .identity = nominal.identity, .name = try self.allocator.dupe(u8, nominal.name) };
    }

    fn cloneMemberTable(self: *TypeStore, table: model.MemberTable) !model.MemberTable {
        const members = try self.allocator.alloc(model.SemanticMember, table.members.len);
        for (table.members, 0..) |member, index| {
            members[index] = member;
            members[index].name = try self.allocator.dupe(u8, member.name);
        }
        return .{ .members = members };
    }
};

fn formatNominalDebugAlloc(
    allocator: std.mem.Allocator,
    kind_name: []const u8,
    name: []const u8,
    id: model.TypeId,
    identity: model.SemanticDeclId,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} {s}#{d}[module={d},declaration={d}]",
        .{ kind_name, name, id, identity.module_id, identity.declaration_id },
    );
}

fn appendSortedUnique(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(model.TypeId),
    value: model.TypeId,
) !void {
    var index: usize = 0;
    while (index < values.items.len and values.items[index] < value) : (index += 1) {}
    if (index < values.items.len and values.items[index] == value) return;
    try values.insert(allocator, index, value);
}

/// Compare two FunctionSignatures for structural equality (ignoring declaration_id).
/// Used internally to detect duplicate signatures during interning.
fn structurallyEqualSignatures(
    left: model.FunctionSignature,
    right: model.FunctionSignature,
) bool {
    if (left.return_type == right.return_type and
        left.type_parameter_count == right.type_parameter_count and
        left.flags == right.flags and
        parametersEqual(left.parameters, right.parameters))
    {
        return true;
    }
    return false;
}

fn parametersEqual(left: []const model.ParameterType, right: []const model.ParameterType) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.type_id != b.type_id or a.optional != b.optional or
            a.rest != b.rest or a.has_default != b.has_default) return false;
    }
    return true;
}

fn kindsEqual(left: model.TypeKind, right: model.TypeKind) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .primitive => |value| value == right.primitive,
        .function => |value| value == right.function,
        .literal => |value| literalEqual(value, right.literal),
        .union_type => |value| std.mem.eql(model.TypeId, value, right.union_type),
        .intersection => |value| std.mem.eql(model.TypeId, value, right.intersection),
        .array => |value| value.element_type == right.array.element_type and value.readonly == right.array.readonly,
        .promise => |value| value.value_type == right.promise.value_type,
        .generator => |value| value.yield_type == right.generator.yield_type and value.return_type == right.generator.return_type,
        .tuple => |value| tupleEqual(value, right.tuple),
        .object => |value| propertiesEqual(value, right.object),
        .class => |value| value.identity.eql(right.class.identity),
        .class_constructor => |value| value.identity.eql(right.class_constructor.identity) and
            value.instance_type == right.class_constructor.instance_type,
        .interface => |value| value.identity.eql(right.interface.identity) and
            memberTablesEqual(value.members, right.interface.members),
        .enum_type => |value| value.identity.eql(right.enum_type.identity),
        .type_parameter => |value| value.identity.eql(right.type_parameter.identity) and
            value.parameter_id == right.type_parameter.parameter_id,
    };
}

fn memberTablesEqual(left: model.MemberTable, right: model.MemberTable) bool {
    if (left.members.len != right.members.len) return false;
    for (left.members, right.members) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.type_id != b.type_id or
            a.visibility != b.visibility or a.readonly != b.readonly or a.optional != b.optional) return false;
    }
    return true;
}

fn tupleEqual(left: model.TupleType, right: model.TupleType) bool {
    if (left.readonly != right.readonly or left.elements.len != right.elements.len) return false;
    for (left.elements, right.elements) |a, b| {
        if (a.type_id != b.type_id or a.optional != b.optional or a.hole != b.hole) return false;
    }
    return true;
}

fn literalEqual(left: model.LiteralValue, right: model.LiteralValue) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .boolean => |value| value == right.boolean,
        .number => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number)),
        .bigint => |value| std.mem.eql(u8, value, right.bigint),
        .string => |value| std.mem.eql(u8, value, right.string),
    };
}

fn propertiesEqual(left: []const model.ObjectProperty, right: []const model.ObjectProperty) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.name, b.name) or a.type_id != b.type_id or
            a.optional != b.optional or a.readonly != b.readonly) return false;
    }
    return true;
}

test "TypeStore owns every required shape and interns structural types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());
    const b = &store.builtins;

    const literal = try store.intern(.{ .literal = .{ .string = "x" } });
    const array = try store.intern(.{ .array = .{ .element_type = b.number } });
    const tuple = try store.intern(.{ .tuple = .{ .elements = &.{
        .{ .type_id = b.number }, .{ .type_id = b.string },
    } } });
    const object = try store.intern(.{ .object = &.{.{ .name = "x", .type_id = b.number }} });
    const function = try store.addFunction(&.{.{ .name = "x", .type_id = b.number }}, b.string);
    const class = try store.intern(.{ .class = .{ .identity = model.SemanticDeclId.init(0, 1), .name = "C" } });
    const interface = try store.intern(.{ .interface = .{ .identity = model.SemanticDeclId.init(0, 2), .name = "I" } });
    const enum_type = try store.intern(.{ .enum_type = .{ .identity = model.SemanticDeclId.init(0, 3), .name = "E" } });
    const parameter = try store.intern(.{ .type_parameter = .{
        .identity = model.SemanticDeclId.init(0, 4),
        .parameter_id = 9,
        .name = "T",
    } });
    const union_type = try store.unionOf(&.{ literal, b.never, literal, b.number });
    const intersection = try store.intersectionOf(&.{ object, b.unknown, object, interface });

    for ([_]model.TypeId{ literal, array, tuple, object, function, class, interface, enum_type, parameter, union_type, intersection }) |id| {
        try std.testing.expect(store.lookup(id) != null);
    }
    try std.testing.expectEqual(array, try store.intern(.{ .array = .{ .element_type = b.number } }));
    try std.testing.expect(store.lookupFunction(function) != null);
}

test "Goal 134 inferred function signatures are immutable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const number_signature = try store.addFunction(&.{}, store.builtins.number);
    const string_signature = try store.addFunction(&.{}, store.builtins.string);

    try std.testing.expect(number_signature != string_signature);
    try std.testing.expectEqual(
        store.builtins.number,
        store.lookupFunctionSignature(number_signature).?.return_type,
    );
    try std.testing.expectEqual(
        store.builtins.string,
        store.lookupFunctionSignature(string_signature).?.return_type,
    );
}

test "Goal 136 qualified nominal identities isolate equal local declaration ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const a = model.SemanticDeclId.init(1, 42);
    const b = model.SemanticDeclId.init(2, 42);
    inline for (.{ .class, .interface, .enum_type }) |tag| {
        const a_kind: model.TypeKind = @unionInit(model.TypeKind, @tagName(tag), .{ .identity = a, .name = "Node" });
        const b_kind: model.TypeKind = @unionInit(model.TypeKind, @tagName(tag), .{ .identity = b, .name = "Node" });
        try std.testing.expect(kindsEqual(a_kind, a_kind));
        try std.testing.expect(!kindsEqual(a_kind, b_kind));
        const a_id = try store.intern(a_kind);
        const cloned = store.lookup(a_id).?;
        const cloned_identity = switch (cloned.kind) {
            .class => |value| value.identity,
            .interface => |value| value.identity,
            .enum_type => |value| value.identity,
            else => unreachable,
        };
        try std.testing.expectEqual(a, cloned_identity);
    }

    _ = try store.createClassSemanticType(a, "A");
    _ = try store.createClassSemanticType(b, "B");
    try std.testing.expectEqualStrings("A", store.class_types.get(a).?.name);
    try std.testing.expectEqualStrings("B", store.class_types.get(b).?.name);

    const a_interface = model.SemanticDeclId.init(1, 43);
    const b_interface = model.SemanticDeclId.init(2, 43);
    _ = try store.createInterfaceSemanticType(a_interface, "IA", .{});
    _ = try store.createInterfaceSemanticType(b_interface, "IB", .{});
    try std.testing.expectEqualStrings("IA", store.interface_types.get(a_interface).?.name);
    try std.testing.expectEqualStrings("IB", store.interface_types.get(b_interface).?.name);

    const debug_id = try store.intern(.{ .class = .{ .identity = a, .name = "Node" } });
    const debug = try store.formatDebugAlloc(arena.allocator(), debug_id);
    try std.testing.expect(std.mem.indexOf(u8, debug, "class Node") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "module=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, debug, "declaration=42") != null);
}

test "Goal 141 class and interface semantic foundations preserve identity and shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const class_identity = model.SemanticDeclId.init(7, 11);
    const class_type = try store.createClassSemanticType(class_identity, "Service");
    try std.testing.expect(class_type.constructor_type != class_type.instance_type);
    try std.testing.expectEqual(class_identity, store.lookup(class_type.instance_type).?.kind.class.identity);
    const constructor = store.lookup(class_type.constructor_type).?.kind.class_constructor;
    try std.testing.expectEqual(class_identity, constructor.identity);
    try std.testing.expectEqual(class_type.instance_type, constructor.instance_type);
    try std.testing.expectEqual(@as(usize, 0), class_type.static_members.members.len);
    try std.testing.expectEqual(@as(usize, 0), class_type.instance_members.members.len);
    try std.testing.expect(class_type.constructor_signature == null);
    try std.testing.expect(class_type.inheritance.extends == null);

    const interface_identity = model.SemanticDeclId.init(7, 12);
    const interface_type = try store.createInterfaceSemanticType(interface_identity, "Named", .{ .members = &.{
        .{ .name = "name", .type_id = store.builtins.string, .visibility = .public, .readonly = true },
        .{ .name = "secret", .type_id = store.builtins.string, .visibility = .protected, .optional = true },
        .{ .name = "hidden", .type_id = store.builtins.boolean, .visibility = .private },
        .{ .name = "plain", .type_id = store.builtins.number, .visibility = .none },
    } });
    const shape = store.lookup(interface_type.type_id).?.kind.interface;
    try std.testing.expectEqual(interface_identity, shape.identity);
    try std.testing.expectEqual(@as(usize, 4), shape.members.members.len);
    try std.testing.expectEqual(model.Visibility.public, shape.members.members[0].visibility);
    try std.testing.expectEqual(model.Visibility.protected, shape.members.members[1].visibility);
    try std.testing.expectEqual(model.Visibility.private, shape.members.members[2].visibility);
    try std.testing.expectEqual(model.Visibility.none, shape.members.members[3].visibility);

    const other_module = try store.createClassSemanticType(model.SemanticDeclId.init(8, 11), "Service");
    try std.testing.expect(other_module.instance_type != class_type.instance_type);
    try std.testing.expect(other_module.constructor_type != class_type.constructor_type);
}

test "TypeStore normalization and propagation rules are deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());
    const b = &store.builtins;

    try std.testing.expectEqual(b.never, try store.unionOf(&.{b.never}));
    try std.testing.expectEqual(b.unknown, try store.unionOf(&.{ b.number, b.unknown }));
    try std.testing.expectEqual(b.any, try store.unionOf(&.{ b.number, b.any }));
    try std.testing.expectEqual(b.unknown, try store.unionOf(&.{model.invalid_type}));
    try std.testing.expectEqual(b.never, try store.intersectionOf(&.{ b.number, b.never }));
    try std.testing.expectEqual(b.number, try store.intersectionOf(&.{ b.unknown, b.number, b.number }));
}

test "TypeStore recursive references use reserve then define without loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const recursive = try store.reserve();
    try std.testing.expect(store.lookup(recursive) == null);
    try store.defineReserved(recursive, .{ .object = &.{.{ .name = "next", .type_id = recursive, .optional = true }} });
    const found = store.lookup(recursive).?;
    try std.testing.expectEqual(recursive, found.kind.object[0].type_id);
    try std.testing.expect(store.structurallyEqual(recursive, recursive));

    const rendered = try store.formatDebugAlloc(arena.allocator(), recursive);
    try std.testing.expect(std.mem.startsWith(u8, rendered, "object#"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "first=next") != null);
}
