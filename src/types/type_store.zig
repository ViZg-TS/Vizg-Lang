const std = @import("std");
const model = @import("model.zig");

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    builtins: model.Builtins,
    records: std.ArrayList(StoredType),
    signatures: std.ArrayList(model.FunctionSignature),

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

    /// Anonymous structural types are interned. Nominal types retain declaration
    /// identity. Recursive construction uses reserve/defineReserved instead.
    pub fn intern(self: *TypeStore, kind: model.TypeKind) !model.TypeId {
        if (!isNominal(kind)) {
            for (self.records.items) |record| {
                const existing = record.kind orelse continue;
                if (kindsEqual(existing, kind)) return record.id;
            }
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
        for (self.signatures.items) |signature| {
            if (signature.return_type == return_type and
                signature.type_parameter_count == type_parameter_count and
                signature.flags == flags and
                parametersEqual(signature.parameters, parameters))
            {
                return signature.id;
            }
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

    pub fn updateFunctionReturn(self: *TypeStore, id: model.TypeId, return_type: model.TypeId) bool {
        for (self.signatures.items) |*signature| {
            if (signature.id != id) continue;
            if (signature.return_type == return_type) return false;
            signature.return_type = return_type;
            return true;
        }
        return false;
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
        return std.fmt.allocPrint(allocator, "{s}#{d}", .{ ty.displayName(), id });
    }

    fn stored(self: *const TypeStore, id: model.TypeId) ?*const StoredType {
        if (id < model.next_user_type_id) return null;
        const index: usize = @intCast(id - model.next_user_type_id);
        if (index >= self.records.items.len) return null;
        return &self.records.items[index];
    }

    fn storedMut(self: *TypeStore, id: model.TypeId) ?*StoredType {
        if (id < model.next_user_type_id) return null;
        const index: usize = @intCast(id - model.next_user_type_id);
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
            .class => |nominal| .{ .class = try self.cloneNominal(nominal) },
            .interface => |nominal| .{ .interface = try self.cloneNominal(nominal) },
            .enum_type => |nominal| .{ .enum_type = try self.cloneNominal(nominal) },
            .type_parameter => |parameter| .{ .type_parameter = .{
                .declaration_id = parameter.declaration_id,
                .name = try self.allocator.dupe(u8, parameter.name),
                .constraint = parameter.constraint,
                .default = parameter.default,
            } },
        };
    }

    fn cloneNominal(self: *TypeStore, nominal: model.NominalType) !model.NominalType {
        return .{ .declaration_id = nominal.declaration_id, .name = try self.allocator.dupe(u8, nominal.name) };
    }
};

fn isNominal(kind: model.TypeKind) bool {
    return switch (kind) {
        .class, .interface, .enum_type, .type_parameter => true,
        else => false,
    };
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
        .class => |value| value.declaration_id == right.class.declaration_id,
        .interface => |value| value.declaration_id == right.interface.declaration_id,
        .enum_type => |value| value.declaration_id == right.enum_type.declaration_id,
        .type_parameter => |value| value.declaration_id == right.type_parameter.declaration_id,
    };
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
    const class = try store.intern(.{ .class = .{ .declaration_id = 1, .name = "C" } });
    const interface = try store.intern(.{ .interface = .{ .declaration_id = 2, .name = "I" } });
    const enum_type = try store.intern(.{ .enum_type = .{ .declaration_id = 3, .name = "E" } });
    const parameter = try store.intern(.{ .type_parameter = .{ .declaration_id = 4, .name = "T" } });
    const union_type = try store.unionOf(&.{ literal, b.never, literal, b.number });
    const intersection = try store.intersectionOf(&.{ object, b.unknown, object, interface });

    for ([_]model.TypeId{ literal, array, tuple, object, function, class, interface, enum_type, parameter, union_type, intersection }) |id| {
        try std.testing.expect(store.lookup(id) != null);
    }
    try std.testing.expectEqual(array, try store.intern(.{ .array = .{ .element_type = b.number } }));
    try std.testing.expect(store.lookupFunction(function) != null);
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
}
