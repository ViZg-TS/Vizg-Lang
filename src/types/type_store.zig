const std = @import("std");
const model = @import("model.zig");

pub const TypeStore = struct {
    /// Hard limits keep adversarial type shapes from causing unbounded work or
    /// native-stack exhaustion. Callers receive error.TypeComplexityLimit.
    pub const max_composite_members: usize = 1024;
    pub const max_generic_arguments: usize = 256;
    pub const max_substitution_depth: usize = 256;

    allocator: std.mem.Allocator,
    builtins: model.Builtins,
    records: std.ArrayList(StoredType),
    signatures: std.ArrayList(model.FunctionSignature),

    /// Qualified keys prevent equal local AST NodeIds in different modules from
    /// colliding. Classes and interfaces have different semantic contracts.
    class_types: std.AutoHashMap(model.SemanticDeclId, model.ClassSemanticType),
    interface_types: std.AutoHashMap(model.SemanticDeclId, model.InterfaceSemanticType),
    generic_declarations: std.AutoHashMap(model.SemanticDeclId, model.GenericDeclaration),

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
            .generic_declarations = std.AutoHashMap(model.SemanticDeclId, model.GenericDeclaration).init(allocator),
        };
    }

    /// Deep immutable snapshot preserving every TypeId and signature identity.
    /// Semantic-only mutation indexes are intentionally omitted.
    pub fn cloneReadOnly(self: *const TypeStore, allocator: std.mem.Allocator) !TypeStore {
        var copy = TypeStore.init(allocator);
        errdefer {
            copy.records.deinit(allocator);
            copy.signatures.deinit(allocator);
            copy.class_types.deinit();
            copy.interface_types.deinit();
            copy.generic_declarations.deinit();
        }
        for (self.records.items) |record| {
            try copy.records.append(allocator, .{
                .id = record.id,
                .kind = if (record.kind) |kind| try copy.cloneKind(kind) else null,
            });
        }
        for (self.signatures.items) |signature| {
            try copy.signatures.append(allocator, .{
                .declaration_id = signature.declaration_id,
                .id = signature.id,
                .parameters = try copy.cloneParameters(signature.parameters),
                .return_type = signature.return_type,
                .type_parameter_count = signature.type_parameter_count,
                .flags = signature.flags,
            });
        }
        return copy;
    }

    pub fn registerGenericDeclaration(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        template_type: model.TypeId,
        parameters: []const model.GenericParameter,
    ) !void {
        if (parameters.len > max_generic_arguments) return error.TypeComplexityLimit;
        const owned = try self.allocator.dupe(model.GenericParameter, parameters);
        try self.generic_declarations.put(identity, .{
            .identity = identity,
            .template_type = template_type,
            .parameters = owned,
        });
    }

    pub fn lookupGenericDeclaration(self: *const TypeStore, identity: model.SemanticDeclId) ?model.GenericDeclaration {
        return self.generic_declarations.get(identity);
    }

    pub fn updateGenericDeclaration(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        template_type: model.TypeId,
        parameters: []const model.GenericParameter,
    ) !void {
        if (parameters.len > max_generic_arguments) return error.TypeComplexityLimit;
        const declaration = self.generic_declarations.getPtr(identity) orelse return error.UnknownGenericDeclaration;
        declaration.template_type = template_type;
        declaration.parameters = try self.allocator.dupe(model.GenericParameter, parameters);
    }

    pub fn updateTypeParameter(
        self: *TypeStore,
        type_id: model.TypeId,
        constraint: ?model.TypeId,
        default: ?model.TypeId,
    ) !void {
        const record = self.storedMut(type_id) orelse return error.InvalidTypeId;
        if (record.kind) |*kind| switch (kind.*) {
            .type_parameter => |*parameter| {
                parameter.constraint = constraint;
                parameter.default = default;
            },
            else => return error.InvalidTypeParameter,
        } else return error.InvalidTypeParameter;
    }

    pub fn instantiateGeneric(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        arguments: []const model.TypeId,
    ) !model.TypeId {
        if (arguments.len > max_generic_arguments) return error.TypeComplexityLimit;
        const declaration = self.lookupGenericDeclaration(identity) orelse return error.UnknownGenericDeclaration;
        if (arguments.len != declaration.parameters.len) return error.InvalidGenericArity;
        return self.intern(.{ .applied_generic = .{
            .declaration = identity,
            .base_type = declaration.template_type,
            .arguments = arguments,
        } });
    }

    /// Substitute type parameters throughout a stored shape. Active ids are
    /// returned unchanged, which makes recursive aliases and objects terminate.
    pub fn substitute(
        self: *TypeStore,
        type_id: model.TypeId,
        parameters: []const model.GenericParameter,
        arguments: []const model.TypeId,
    ) !model.TypeId {
        if (parameters.len != arguments.len) return error.InvalidGenericArity;
        if (parameters.len > max_generic_arguments) return error.TypeComplexityLimit;
        var active: std.AutoHashMap(model.TypeId, void) = .init(self.allocator);
        defer active.deinit();
        return self.substituteInner(type_id, parameters, arguments, &active, 0);
    }

    pub fn resolveAppliedTarget(self: *TypeStore, type_id: model.TypeId) !model.TypeId {
        const ty = self.lookup(type_id) orelse return type_id;
        if (ty.kind != .applied_generic) return type_id;
        const applied = ty.kind.applied_generic;
        const declaration = self.lookupGenericDeclaration(applied.declaration) orelse return applied.base_type;
        return self.substitute(declaration.template_type, declaration.parameters, applied.arguments);
    }

    fn substituteInner(
        self: *TypeStore,
        type_id: model.TypeId,
        parameters: []const model.GenericParameter,
        arguments: []const model.TypeId,
        active: *std.AutoHashMap(model.TypeId, void),
        depth: usize,
    ) anyerror!model.TypeId {
        if (depth >= max_substitution_depth) return error.TypeComplexityLimit;
        for (parameters, arguments) |parameter, argument| {
            if (type_id == parameter.type_id) return argument;
        }
        if (active.contains(type_id)) return type_id;
        const ty = self.lookup(type_id) orelse return type_id;
        try active.put(type_id, {});
        defer _ = active.remove(type_id);
        return switch (ty.kind) {
            .primitive, .literal, .class, .class_constructor, .interface, .enum_type, .type_parameter => type_id,
            .function => |signature_id| blk: {
                const signature = self.lookupFunctionSignature(signature_id) orelse break :blk type_id;
                const converted = try self.allocator.alloc(model.ParameterType, signature.parameters.len);
                for (signature.parameters, 0..) |parameter, index| {
                    converted[index] = parameter;
                    converted[index].type_id = try self.substituteInner(parameter.type_id, parameters, arguments, active, depth + 1);
                }
                break :blk try self.addFunctionDetailed(
                    converted,
                    try self.substituteInner(signature.return_type, parameters, arguments, active, depth + 1),
                    0,
                    signature.flags,
                );
            },
            .promise => |value| self.intern(.{ .promise = .{
                .value_type = try self.substituteInner(value.value_type, parameters, arguments, active, depth + 1),
            } }),
            .generator => |value| self.intern(.{ .generator = .{
                .yield_type = try self.substituteInner(value.yield_type, parameters, arguments, active, depth + 1),
                .return_type = try self.substituteInner(value.return_type, parameters, arguments, active, depth + 1),
            } }),
            .union_type => |members| blk: {
                const converted = try self.allocator.alloc(model.TypeId, members.len);
                for (members, 0..) |member, index| converted[index] = try self.substituteInner(member, parameters, arguments, active, depth + 1);
                break :blk try self.unionOf(converted);
            },
            .intersection => |members| blk: {
                const converted = try self.allocator.alloc(model.TypeId, members.len);
                for (members, 0..) |member, index| converted[index] = try self.substituteInner(member, parameters, arguments, active, depth + 1);
                break :blk try self.intersectionOf(converted);
            },
            .array => |value| self.intern(.{ .array = .{
                .element_type = try self.substituteInner(value.element_type, parameters, arguments, active, depth + 1),
                .readonly = value.readonly,
            } }),
            .tuple => |value| blk: {
                const elements = try self.allocator.alloc(model.TupleElement, value.elements.len);
                for (value.elements, 0..) |element, index| {
                    elements[index] = element;
                    elements[index].type_id = try self.substituteInner(element.type_id, parameters, arguments, active, depth + 1);
                }
                break :blk try self.intern(.{ .tuple = .{ .elements = elements, .readonly = value.readonly } });
            },
            .object => |properties| blk: {
                const converted = try self.allocator.alloc(model.ObjectProperty, properties.len);
                for (properties, 0..) |property, index| {
                    converted[index] = property;
                    converted[index].type_id = try self.substituteInner(property.type_id, parameters, arguments, active, depth + 1);
                }
                break :blk try self.intern(.{ .object = converted });
            },
            .applied_generic => |applied| blk: {
                const converted = try self.allocator.alloc(model.TypeId, applied.arguments.len);
                for (applied.arguments, 0..) |argument, index| converted[index] = try self.substituteInner(argument, parameters, arguments, active, depth + 1);
                break :blk try self.intern(.{ .applied_generic = .{
                    .declaration = applied.declaration,
                    .base_type = applied.base_type,
                    .arguments = converted,
                } });
            },
        };
    }

    pub fn count(self: *const TypeStore) usize {
        return self.builtins.records.len + self.records.items.len;
    }

    /// Number of fully defined types available to immutable consumers.
    pub fn definedCount(self: *const TypeStore) usize {
        var total = self.builtins.records.len;
        for (self.records.items) |record| {
            if (record.kind != null) total += 1;
        }
        return total;
    }

    /// Deterministic ordinal traversal independent of sparse/stable TypeId values.
    pub fn typeAt(self: *const TypeStore, ordinal: usize) ?model.Type {
        if (ordinal < self.builtins.records.len) return self.builtins.records[ordinal];
        var current = ordinal - self.builtins.records.len;
        for (self.records.items) |record| {
            const kind = record.kind orelse continue;
            if (current == 0) return .{ .id = record.id, .kind = kind };
            current -= 1;
        }
        return null;
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
    ) !model.InterfaceSemanticType {
        if (self.interface_types.get(identity)) |existing| return existing;
        const type_id = try self.intern(.{ .interface = .{
            .identity = identity,
            .name = name,
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
        if (semantic.completed) return error.SemanticTypeAlreadyCompleted;
        semantic.static_members = try self.cloneMemberTable(static_members);
        semantic.instance_members = try self.cloneMemberTable(instance_members);
        semantic.constructor_signature = constructor_signature;
        semantic.inheritance = .{
            .extends = inheritance.extends,
            .implements = try self.allocator.dupe(model.TypeId, inheritance.implements),
        };
        semantic.completed = true;
    }

    /// Refresh one callable class member after body inference while preserving
    /// the class's nominal identity and stable member-table allocation.
    pub fn updateClassCallableType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        name: []const u8,
        is_static: bool,
        constructor: bool,
        type_id: model.TypeId,
    ) !void {
        const semantic = self.class_types.getPtr(identity) orelse return error.UnknownClassIdentity;
        if (constructor) {
            semantic.constructor_signature = type_id;
            return;
        }
        const members = @constCast(if (is_static) semantic.static_members.members else semantic.instance_members.members);
        for (members) |*member| {
            if (!std.mem.eql(u8, member.name, name)) continue;
            member.type_id = type_id;
            return;
        }
    }

    /// Complete a predeclared interface while preserving its stable TypeId.
    pub fn completeInterfaceSemanticType(
        self: *TypeStore,
        identity: model.SemanticDeclId,
        members: model.MemberTable,
        inheritance: model.InterfaceInheritance,
    ) !void {
        const semantic = self.interface_types.getPtr(identity) orelse return error.UnknownInterfaceIdentity;
        if (semantic.completed) return error.SemanticTypeAlreadyCompleted;
        const owned_members = try self.cloneMemberTable(members);
        const record = self.storedMut(semantic.type_id) orelse return error.InvalidTypeId;
        if (record.kind) |*kind| switch (kind.*) {
            .interface => |*interface| interface.members = owned_members,
            else => return error.InvalidInterfaceType,
        } else return error.InvalidInterfaceType;
        semantic.members = owned_members;
        semantic.inheritance = .{ .extends = try self.allocator.dupe(model.TypeId, inheritance.extends) };
        semantic.completed = true;
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
                for (ty.kind.union_type) |nested| {
                    try appendSortedUnique(self.allocator, &normalized, nested);
                    if (normalized.items.len > max_composite_members) return error.TypeComplexityLimit;
                }
            } else {
                try appendSortedUnique(self.allocator, &normalized, member);
                if (normalized.items.len > max_composite_members) return error.TypeComplexityLimit;
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
                for (ty.kind.intersection) |nested| {
                    try appendSortedUnique(self.allocator, &normalized, nested);
                    if (normalized.items.len > max_composite_members) return error.TypeComplexityLimit;
                }
            } else {
                try appendSortedUnique(self.allocator, &normalized, member);
                if (normalized.items.len > max_composite_members) return error.TypeComplexityLimit;
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

    /// Inspection rendering is cycle-safe and descriptive, but must never drive
    /// type decisions. TypeIds remain visible so output can be correlated with
    /// the semantic lookup APIs.
    pub fn formatDebugAlloc(self: *const TypeStore, allocator: std.mem.Allocator, id: model.TypeId) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        var stack: [32]model.TypeId = undefined;
        try self.writeTypeDebug(&output.writer, id, &stack, 0);
        var bytes = output.toArrayList();
        return bytes.toOwnedSlice(allocator);
    }

    fn writeTypeDebug(
        self: *const TypeStore,
        writer: *std.Io.Writer,
        id: model.TypeId,
        stack: *[32]model.TypeId,
        depth: usize,
    ) anyerror!void {
        if (depth == stack.len) return writer.print("<depth-limit#{d}>", .{id});
        for (stack[0..depth]) |ancestor| if (ancestor == id)
            return writer.print("<recursive#{d}>", .{id});
        stack[depth] = id;

        const ty = self.lookup(id) orelse return writer.print("<invalid:{d}>", .{id});
        switch (ty.kind) {
            .primitive => try writer.print("{s}#{d}", .{ ty.displayName(), id }),
            .literal => |literal| {
                switch (literal) {
                    .boolean => |value| try writer.print("{}", .{value}),
                    .number => |value| try writer.print("{d}", .{value}),
                    .bigint => |value| try writer.print("{s}n", .{value}),
                    .string => |value| try writer.print("\"{s}\"", .{value}),
                }
                try writer.print("#{d}", .{id});
            },
            .function => |signature_id| {
                try writer.print("function#{d}(", .{id});
                if (self.lookupFunctionSignature(signature_id)) |signature| {
                    for (signature.parameters, 0..) |parameter, index| {
                        if (index != 0) try writer.writeAll(", ");
                        if (parameter.rest) try writer.writeAll("...");
                        try writer.print("{s}{s}: ", .{ parameter.name, if (parameter.optional or parameter.has_default) "?" else "" });
                        try self.writeTypeDebug(writer, parameter.type_id, stack, depth + 1);
                    }
                    try writer.writeAll(") -> ");
                    try self.writeTypeDebug(writer, signature.return_type, stack, depth + 1);
                    if (signature.type_parameter_count != 0)
                        try writer.print(" [type-parameters={d}]", .{signature.type_parameter_count});
                } else try writer.print("<missing-signature:{d}>)", .{signature_id});
            },
            .promise => |value| {
                try writer.print("Promise#{d}<", .{id});
                try self.writeTypeDebug(writer, value.value_type, stack, depth + 1);
                try writer.writeAll(">");
            },
            .generator => |value| {
                try writer.print("Generator#{d}<yield=", .{id});
                try self.writeTypeDebug(writer, value.yield_type, stack, depth + 1);
                try writer.writeAll(", return=");
                try self.writeTypeDebug(writer, value.return_type, stack, depth + 1);
                try writer.writeAll(">");
            },
            .union_type => |members| try self.writeTypeList(writer, "union", " | ", id, members, stack, depth),
            .intersection => |members| try self.writeTypeList(writer, "intersection", " & ", id, members, stack, depth),
            .array => |value| {
                if (value.readonly) try writer.writeAll("readonly ");
                try writer.print("array#{d}<", .{id});
                try self.writeTypeDebug(writer, value.element_type, stack, depth + 1);
                try writer.writeAll(">");
            },
            .tuple => |value| {
                if (value.readonly) try writer.writeAll("readonly ");
                try writer.print("tuple#{d}<[", .{id});
                for (value.elements, 0..) |element, index| {
                    if (index != 0) try writer.writeAll(", ");
                    if (element.hole) {
                        try writer.writeAll("<hole>");
                        continue;
                    }
                    try self.writeTypeDebug(writer, element.type_id, stack, depth + 1);
                    if (element.optional) try writer.writeAll("?");
                }
                try writer.writeAll("]>");
            },
            .object => |properties| {
                try writer.print("object#{d}{{", .{id});
                for (properties, 0..) |property, index| {
                    if (index != 0) try writer.writeAll("; ");
                    if (property.readonly) try writer.writeAll("readonly ");
                    try writer.print("{s}{s}: ", .{ property.name, if (property.optional) "?" else "" });
                    try self.writeTypeDebug(writer, property.type_id, stack, depth + 1);
                }
                try writer.writeAll("}");
            },
            .class => |value| try writeNominalDebug(writer, "class", value.name, id, value.identity),
            .class_constructor => |value| {
                try writeNominalDebug(writer, "class-constructor", value.name, id, value.identity);
                try writer.writeAll(" instance=");
                try self.writeTypeDebug(writer, value.instance_type, stack, depth + 1);
            },
            .interface => |value| {
                try writeNominalDebug(writer, "interface", value.name, id, value.identity);
                try writer.writeAll(" {");
                for (value.members.members, 0..) |member, index| {
                    if (index != 0) try writer.writeAll("; ");
                    if (member.readonly) try writer.writeAll("readonly ");
                    try writer.print("{s}{s}: ", .{ member.name, if (member.optional) "?" else "" });
                    try self.writeTypeDebug(writer, member.type_id, stack, depth + 1);
                }
                try writer.writeAll("}");
            },
            .enum_type => |value| try writeNominalDebug(writer, "enum", value.name, id, value.identity),
            .type_parameter => |value| {
                try writeNominalDebug(writer, "type-parameter", value.name, id, value.identity);
                try writer.print(" parameter={d}", .{value.parameter_id});
                if (value.constraint) |constraint| {
                    try writer.writeAll(" extends ");
                    try self.writeTypeDebug(writer, constraint, stack, depth + 1);
                }
                if (value.default) |default| {
                    try writer.writeAll(" default ");
                    try self.writeTypeDebug(writer, default, stack, depth + 1);
                }
            },
            .applied_generic => |value| {
                try writer.print("generic#{d}[module={d},declaration={d}]<", .{ id, value.declaration.module_id, value.declaration.declaration_id });
                for (value.arguments, 0..) |argument, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try self.writeTypeDebug(writer, argument, stack, depth + 1);
                }
                try writer.writeAll("> base=");
                try self.writeTypeDebug(writer, value.base_type, stack, depth + 1);
            },
        }
    }

    fn writeTypeList(
        self: *const TypeStore,
        writer: *std.Io.Writer,
        name: []const u8,
        separator: []const u8,
        id: model.TypeId,
        members: []const model.TypeId,
        stack: *[32]model.TypeId,
        depth: usize,
    ) anyerror!void {
        try writer.print("{s}#{d}<", .{ name, id });
        for (members, 0..) |member, index| {
            if (index != 0) try writer.writeAll(separator);
            try self.writeTypeDebug(writer, member, stack, depth + 1);
        }
        try writer.writeAll(">");
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
            .applied_generic => |applied| .{ .applied_generic = .{
                .declaration = applied.declaration,
                .base_type = applied.base_type,
                .arguments = try self.allocator.dupe(model.TypeId, applied.arguments),
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

fn writeNominalDebug(
    writer: *std.Io.Writer,
    kind_name: []const u8,
    name: []const u8,
    id: model.TypeId,
    identity: model.SemanticDeclId,
) !void {
    return writer.print(
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
        .interface => |value| value.identity.eql(right.interface.identity),
        .enum_type => |value| value.identity.eql(right.enum_type.identity),
        .type_parameter => |value| value.identity.eql(right.type_parameter.identity) and
            value.parameter_id == right.type_parameter.parameter_id,
        .applied_generic => |value| value.declaration.eql(right.applied_generic.declaration) and
            std.mem.eql(model.TypeId, value.arguments, right.applied_generic.arguments),
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
    for (left) |a| {
        const b = for (right) |candidate| {
            if (std.mem.eql(u8, a.name, candidate.name)) break candidate;
        } else return false;
        if (a.type_id != b.type_id or a.optional != b.optional or a.readonly != b.readonly) return false;
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
    _ = try store.createInterfaceSemanticType(a_interface, "IA");
    _ = try store.createInterfaceSemanticType(b_interface, "IB");
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
    const interface_type = try store.createInterfaceSemanticType(interface_identity, "Named");
    try store.completeInterfaceSemanticType(interface_identity, .{ .members = &.{
        .{ .name = "name", .type_id = store.builtins.string, .visibility = .public, .readonly = true },
        .{ .name = "secret", .type_id = store.builtins.string, .visibility = .protected, .optional = true },
        .{ .name = "hidden", .type_id = store.builtins.boolean, .visibility = .private },
        .{ .name = "plain", .type_id = store.builtins.number, .visibility = .none },
    } }, .{});
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

test "Goal 155 nominal completion is one-shot and preserves stable identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const class_identity = model.SemanticDeclId.init(9, 1);
    const class_before = try store.createClassSemanticType(class_identity, "Box");
    const class_again = try store.createClassSemanticType(class_identity, "Ignored");
    try std.testing.expectEqual(class_before.instance_type, class_again.instance_type);
    try store.completeClassSemanticType(class_identity, .{}, .{}, null, .{});
    try std.testing.expectError(error.SemanticTypeAlreadyCompleted, store.completeClassSemanticType(class_identity, .{}, .{}, null, .{}));
    try std.testing.expectEqual(class_before.instance_type, store.lookupClassSemanticType(class_identity).?.instance_type);

    const interface_identity = model.SemanticDeclId.init(9, 2);
    const interface_before = try store.createInterfaceSemanticType(interface_identity, "Pair");
    const interface_again = try store.createInterfaceSemanticType(interface_identity, "Ignored");
    try std.testing.expectEqual(interface_before.type_id, interface_again.type_id);
    try store.completeInterfaceSemanticType(interface_identity, .{ .members = &.{
        .{ .name = "left", .type_id = store.builtins.number },
    } }, .{});
    try std.testing.expectError(error.SemanticTypeAlreadyCompleted, store.completeInterfaceSemanticType(interface_identity, .{}, .{}));
    const completed = store.lookupInterfaceSemanticType(interface_identity).?;
    try std.testing.expectEqual(interface_before.type_id, completed.type_id);
    try std.testing.expectEqual(interface_before.type_id, try store.intern(.{ .interface = .{
        .identity = interface_identity,
        .name = "Pair",
        .members = .{},
    } }));
}

test "Goal 155 object shape keys ignore source property order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const first = try store.intern(.{ .object = &.{
        .{ .name = "left", .type_id = store.builtins.number },
        .{ .name = "right", .type_id = store.builtins.string, .readonly = true },
    } });
    const reordered = try store.intern(.{ .object = &.{
        .{ .name = "right", .type_id = store.builtins.string, .readonly = true },
        .{ .name = "left", .type_id = store.builtins.number },
    } });
    try std.testing.expectEqual(first, reordered);
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

test "Goal 158 TypeStore rejects adversarial composite and generic growth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const members = try arena.allocator().alloc(model.TypeId, TypeStore.max_composite_members + 1);
    for (members, 0..) |*member, index| {
        member.* = try store.intern(.{ .literal = .{ .number = @floatFromInt(index) } });
    }
    try std.testing.expectError(error.TypeComplexityLimit, store.unionOf(members));
    try std.testing.expectError(error.TypeComplexityLimit, store.intersectionOf(members));

    const arguments = try arena.allocator().alloc(model.TypeId, TypeStore.max_generic_arguments + 1);
    @memset(arguments, store.builtins.number);
    const parameters = try arena.allocator().alloc(model.GenericParameter, TypeStore.max_generic_arguments + 1);
    for (parameters) |*parameter| parameter.* = .{ .type_id = store.builtins.number };
    try std.testing.expectError(
        error.TypeComplexityLimit,
        store.registerGenericDeclaration(model.SemanticDeclId.init(0, 998), store.builtins.number, parameters),
    );
    try std.testing.expectError(
        error.TypeComplexityLimit,
        store.instantiateGeneric(model.SemanticDeclId.init(0, 999), arguments),
    );
    try std.testing.expectError(
        error.InvalidGenericArity,
        store.substitute(store.builtins.number, &.{.{ .type_id = store.builtins.number }}, &.{}),
    );

    var nested = store.builtins.number;
    for (0..TypeStore.max_substitution_depth + 1) |_| {
        nested = try store.intern(.{ .array = .{ .element_type = nested } });
    }
    try std.testing.expectError(error.TypeComplexityLimit, store.substitute(nested, &.{}, &.{}));
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
    try std.testing.expect(std.mem.indexOf(u8, rendered, "next?: <recursive#") != null);
}

test "Goal 152 generic applications substitute nested shapes canonically and terminate recursively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = TypeStore.init(arena.allocator());

    const identity = model.SemanticDeclId.init(4, 20);
    const parameter = try store.intern(.{ .type_parameter = .{
        .identity = identity,
        .parameter_id = 0,
        .name = "T",
    } });
    const function = try store.addFunction(&.{.{ .name = "value", .type_id = parameter }}, parameter);
    const array = try store.intern(.{ .array = .{ .element_type = parameter } });
    const tuple = try store.intern(.{ .tuple = .{ .elements = &.{.{ .type_id = parameter }} } });
    const union_type = try store.unionOf(&.{ parameter, store.builtins.string });
    const marker = try store.intern(.{ .object = &.{.{ .name = "marker", .type_id = store.builtins.boolean }} });
    const intersection = try store.intern(.{ .intersection = &.{ parameter, marker } });
    const template = try store.intern(.{ .object = &.{
        .{ .name = "call", .type_id = function },
        .{ .name = "array", .type_id = array },
        .{ .name = "tuple", .type_id = tuple },
        .{ .name = "union", .type_id = union_type },
        .{ .name = "intersection", .type_id = intersection },
    } });
    try store.registerGenericDeclaration(identity, template, &.{.{ .type_id = parameter }});

    const first = try store.instantiateGeneric(identity, &.{store.builtins.number});
    const repeated = try store.instantiateGeneric(identity, &.{store.builtins.number});
    const other = try store.instantiateGeneric(identity, &.{store.builtins.string});
    try std.testing.expectEqual(first, repeated);
    try std.testing.expect(first != other);

    const rendered = try store.formatDebugAlloc(arena.allocator(), first);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "generic#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "module=4,declaration=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "number#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "base=object#") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "call: function#") != null);

    const resolved = store.lookup(try store.resolveAppliedTarget(first)).?.kind.object;
    const signature = store.lookupFunction(resolved[0].type_id).?;
    try std.testing.expectEqual(store.builtins.number, signature.parameters[0].type_id);
    try std.testing.expectEqual(store.builtins.number, signature.return_type);
    try std.testing.expectEqual(store.builtins.number, store.lookup(resolved[1].type_id).?.kind.array.element_type);
    try std.testing.expectEqual(store.builtins.number, store.lookup(resolved[2].type_id).?.kind.tuple.elements[0].type_id);
    try std.testing.expect(store.lookup(resolved[3].type_id).?.kind == .union_type);
    try std.testing.expectEqual(store.builtins.number, store.lookup(resolved[4].type_id).?.kind.intersection[0]);

    const recursive_identity = model.SemanticDeclId.init(4, 21);
    const recursive_parameter = try store.intern(.{ .type_parameter = .{
        .identity = recursive_identity,
        .parameter_id = 0,
        .name = "T",
    } });
    const shell = try store.reserve();
    try store.registerGenericDeclaration(recursive_identity, shell, &.{.{ .type_id = recursive_parameter }});
    const nested = try store.instantiateGeneric(recursive_identity, &.{recursive_parameter});
    try store.defineReserved(shell, .{ .object = &.{
        .{ .name = "value", .type_id = recursive_parameter },
        .{ .name = "next", .type_id = nested, .optional = true },
    } });
    const recursive_number = try store.instantiateGeneric(recursive_identity, &.{store.builtins.number});
    const recursive_target = store.lookup(try store.resolveAppliedTarget(recursive_number)).?.kind.object;
    try std.testing.expectEqual(store.builtins.number, recursive_target[0].type_id);
    try std.testing.expectEqual(recursive_number, recursive_target[1].type_id);
}
