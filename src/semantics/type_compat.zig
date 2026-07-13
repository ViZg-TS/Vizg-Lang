const std = @import("std");
const types = @import("../types/root.zig");
const builtin = @import("../types/builtin.zig");

// Central source-to-target compatibility relation. The checker is heap-free,
// cycle-safe, and preserves the first deterministic failure path.

pub const FailureReason = enum {
    invalid_type,
    incompatible_kind,
    primitive_mismatch,
    literal_mismatch,
    union_member,
    readonly_mismatch,
    tuple_length,
    optional_mismatch,
    missing_property,
    function_flags,
    parameter_count,
    recursion_limit,
};

pub const PathSegment = union(enum) {
    source_union_member: usize,
    target_union_member: usize,
    array_element: void,
    tuple_element: usize,
    property: []const u8,
    parameter: usize,
    return_type: void,
    promise_value: void,
    generator_yield: void,
    generator_return: void,
};

pub const max_path_segments = 32;

pub const Failure = struct {
    reason: FailureReason,
    source: types.TypeId,
    target: types.TypeId,
    path: [max_path_segments]PathSegment = undefined,
    path_len: usize = 0,

    pub fn pathSlice(self: *const Failure) []const PathSegment {
        return self.path[0..self.path_len];
    }
};

pub const CompatibilityResult = union(enum) {
    compatible,
    incompatible: Failure,

    pub fn isCompatible(self: CompatibilityResult) bool {
        return self == .compatible;
    }
};

/// Returns true when `from` can be assigned to a location whose declared type
/// is `to`. Implements the v1 compatibility table:
///
///   any         → assignable to/from everything
///   unknown     → assignable only to unknown or any
///   number      → assignable to number   or any
///   string      → assignable to string   or any
///   boolean     → assignable to boolean  or any
///   null        → assignable to null, undefined, unknown, or any (per Goal 24 spec)
///   undefined   → assignable to undefined, void, unknown, or any (per Goal 24 spec)
///   void        → assignable to void     or any
///   function    → assignable only to function or any for now
pub fn isAssignable(
    from: types.TypeId,
    to: types.TypeId,
    builtins: *const types.Builtins,
) bool {
    if (from == types.invalid_type or to == types.invalid_type) return true;
    const from_kind = builtins.kindFor(from);
    if (from_kind != null and from_kind.? == .never) return true;
    if (from_kind != null and from_kind.? == .any) return true;

    const to_kind = builtins.kindFor(to);
    if (to_kind != null and to_kind.? == .any) return true;

    if (to_kind == null) return false;

    switch (from_kind orelse return false) {
        .number, .bigint, .string, .boolean, .symbol, .object => |kind| return to_kind.? == kind,
        .null_ => return to_kind.? == .null_ or to_kind.? == .undefined or to_kind.? == .unknown,
        .undefined => return to_kind.? == .undefined or to_kind.? == .void or to_kind.? == .unknown,
        .void => return to_kind.? == .void,
        .unknown => {
            // 'unknown' only flows into sinks that also accept it: same kind or any.
            const t = to_kind.?;
            if (t == .any) return true;
            if (t == .unknown) return true;
            return false;
        },
        .never, .any => unreachable,
    }
}

/// Full store-aware result used by assignments, calls, returns, and satisfies.
pub fn check(source: types.TypeId, target: types.TypeId, store: *const types.TypeStore) CompatibilityResult {
    var checker = Checker{ .store = store };
    return checker.compare(source, target);
}

pub fn isAssignableInStore(source: types.TypeId, target: types.TypeId, store: *const types.TypeStore) bool {
    return check(source, target, store).isCompatible();
}

const Pair = struct { source: types.TypeId, target: types.TypeId };
const max_pairs = 256;

const Checker = struct {
    store: *const types.TypeStore,
    active: [max_pairs]Pair = undefined,
    active_len: usize = 0,
    successful: [max_pairs]Pair = undefined,
    successful_len: usize = 0,
    path: [max_path_segments]PathSegment = undefined,
    path_len: usize = 0,
    path_overflow: usize = 0,

    fn compare(self: *Checker, source: types.TypeId, target: types.TypeId) CompatibilityResult {
        if (source == types.invalid_type or target == types.invalid_type) return .compatible;
        if (source == target) return .compatible;
        const pair = Pair{ .source = source, .target = target };
        if (containsPair(self.successful[0..self.successful_len], pair)) return .compatible;
        // Coinductive recursion rule: a pair already being compared is assumed
        // compatible until another finite part of its shape disproves it.
        if (containsPair(self.active[0..self.active_len], pair)) return .compatible;
        if (self.active_len == self.active.len) return self.fail(.recursion_limit, source, target);
        self.active[self.active_len] = pair;
        self.active_len += 1;
        defer self.active_len -= 1;

        const result = self.compareInner(source, target);
        if (result == .compatible and self.successful_len < self.successful.len) {
            self.successful[self.successful_len] = pair;
            self.successful_len += 1;
        }
        return result;
    }

    fn compareInner(self: *Checker, source: types.TypeId, target: types.TypeId) CompatibilityResult {
        const b = &self.store.builtins;
        const source_builtin = b.kindFor(source);
        const target_builtin = b.kindFor(target);
        if (source_builtin == .never or source_builtin == .any or target_builtin == .any or target_builtin == .unknown) return .compatible;
        if (source_builtin == .unknown) return self.fail(.primitive_mismatch, source, target);
        if (source_builtin != null and target_builtin != null) {
            return if (isAssignable(source, target, b)) .compatible else self.fail(.primitive_mismatch, source, target);
        }

        const source_type = self.store.lookup(source) orelse return self.fail(.invalid_type, source, target);
        const target_type = self.store.lookup(target) orelse return self.fail(.invalid_type, source, target);

        if (source_type.kind == .union_type) {
            for (source_type.kind.union_type, 0..) |member, index| {
                self.push(.{ .source_union_member = index });
                const result = self.compare(member, target);
                self.pop();
                if (result != .compatible) return result;
            }
            return .compatible;
        }
        if (target_type.kind == .union_type) {
            var first: ?CompatibilityResult = null;
            for (target_type.kind.union_type, 0..) |member, index| {
                self.push(.{ .target_union_member = index });
                const result = self.compare(source, member);
                self.pop();
                if (result == .compatible) return .compatible;
                if (first == null) first = result;
            }
            return first orelse self.fail(.union_member, source, target);
        }
        if (target_type.kind == .intersection) {
            for (target_type.kind.intersection, 0..) |member, index| {
                self.push(.{ .target_union_member = index });
                const result = self.compare(source, member);
                self.pop();
                if (result != .compatible) return result;
            }
            return .compatible;
        }
        if (source_type.kind == .intersection) {
            for (source_type.kind.intersection, 0..) |member, index| {
                self.push(.{ .source_union_member = index });
                const result = self.compare(member, target);
                self.pop();
                if (result == .compatible) return .compatible;
            }
            return self.fail(.union_member, source, target);
        }

        if (source_type.kind == .literal) {
            if (target_type.kind == .literal) {
                return if (literalEqual(source_type.kind.literal, target_type.kind.literal)) .compatible else self.fail(.literal_mismatch, source, target);
            }
            return if (literalPrimitive(source_type.kind.literal, b) == target) .compatible else self.fail(.literal_mismatch, source, target);
        }
        if (target_builtin == .object and isObjectLike(source_type.kind)) return .compatible;

        // Interfaces are structural sinks. Anonymous object shapes, other
        // interfaces, and class instances may satisfy their required members.
        if (target_type.kind == .interface and isStructuralSource(source_type.kind))
            return self.compareInterfaceTarget(source, target, target_type.kind.interface, 0);
        // Anonymous object annotations are also structural when the source is
        // a declared interface or class instance.
        if (target_type.kind == .object and (source_type.kind == .interface or source_type.kind == .class))
            return self.compareTargetProperties(source, target, target_type.kind.object);

        if (std.meta.activeTag(source_type.kind) != std.meta.activeTag(target_type.kind)) {
            if (source_type.kind == .tuple and target_type.kind == .array) return self.compareTupleToArray(source, target, source_type.kind.tuple, target_type.kind.array);
            return self.fail(.incompatible_kind, source, target);
        }

        return switch (source_type.kind) {
            .primitive => if (source_type.kind.primitive == target_type.kind.primitive) .compatible else self.fail(.primitive_mismatch, source, target),
            .literal => unreachable,
            .array => self.compareArrays(source, target, source_type.kind.array, target_type.kind.array),
            .tuple => self.compareTuples(source, target, source_type.kind.tuple, target_type.kind.tuple),
            .object => self.compareObjects(source, target, source_type.kind.object, target_type.kind.object),
            .function => self.compareFunctions(source, target),
            .promise => self.compareChild(source_type.kind.promise.value_type, target_type.kind.promise.value_type, .{ .promise_value = {} }),
            .generator => blk: {
                const yielded = self.compareChild(source_type.kind.generator.yield_type, target_type.kind.generator.yield_type, .{ .generator_yield = {} });
                if (yielded != .compatible) break :blk yielded;
                break :blk self.compareChild(source_type.kind.generator.return_type, target_type.kind.generator.return_type, .{ .generator_return = {} });
            },
            .class, .class_constructor, .enum_type, .type_parameter => if (self.store.structurallyEqual(source, target)) .compatible else self.fail(.incompatible_kind, source, target),
            .interface => unreachable,
            .union_type, .intersection => unreachable,
        };
    }

    fn compareArrays(self: *Checker, source: types.TypeId, target: types.TypeId, from: types.ArrayType, to: types.ArrayType) CompatibilityResult {
        if (from.readonly and !to.readonly) return self.fail(.readonly_mismatch, source, target);
        return self.compareChild(from.element_type, to.element_type, .{ .array_element = {} });
    }

    fn compareTupleToArray(self: *Checker, source: types.TypeId, target: types.TypeId, from: types.TupleType, to: types.ArrayType) CompatibilityResult {
        if (from.readonly and !to.readonly) return self.fail(.readonly_mismatch, source, target);
        for (from.elements, 0..) |element, index| {
            if (element.hole or element.optional) return self.fail(.optional_mismatch, source, target);
            const result = self.compareChild(element.type_id, to.element_type, .{ .tuple_element = index });
            if (result != .compatible) return result;
        }
        return .compatible;
    }

    fn compareTuples(self: *Checker, source: types.TypeId, target: types.TypeId, from: types.TupleType, to: types.TupleType) CompatibilityResult {
        if (from.readonly and !to.readonly) return self.fail(.readonly_mismatch, source, target);
        if (from.elements.len != to.elements.len) return self.fail(.tuple_length, source, target);
        for (from.elements, to.elements, 0..) |from_element, to_element, index| {
            if ((from_element.optional or from_element.hole) and !(to_element.optional or to_element.hole)) {
                self.push(.{ .tuple_element = index });
                const result = self.fail(.optional_mismatch, source, target);
                self.pop();
                return result;
            }
            const result = self.compareChild(from_element.type_id, to_element.type_id, .{ .tuple_element = index });
            if (result != .compatible) return result;
        }
        return .compatible;
    }

    fn compareObjects(self: *Checker, source: types.TypeId, target: types.TypeId, from: []const types.ObjectProperty, to: []const types.ObjectProperty) CompatibilityResult {
        _ = from;
        return self.compareTargetProperties(source, target, to);
    }

    fn compareTargetProperties(self: *Checker, source: types.TypeId, target: types.TypeId, to: []const types.ObjectProperty) CompatibilityResult {
        for (to) |target_property| {
            const source_property = self.findStructuralMember(source, target_property.name, 0) orelse {
                if (target_property.optional) continue;
                self.push(.{ .property = target_property.name });
                const result = self.fail(.missing_property, source, target);
                self.pop();
                return result;
            };
            self.push(.{ .property = target_property.name });
            if (source_property.optional and !target_property.optional) {
                const result = self.fail(.optional_mismatch, source_property.type_id, target_property.type_id);
                self.pop();
                return result;
            }
            if (source_property.readonly and !target_property.readonly) {
                const result = self.fail(.readonly_mismatch, source_property.type_id, target_property.type_id);
                self.pop();
                return result;
            }
            const result = self.compare(source_property.type_id, target_property.type_id);
            self.pop();
            if (result != .compatible) return result;
        }
        return .compatible;
    }

    fn compareInterfaceTarget(
        self: *Checker,
        source: types.TypeId,
        target: types.TypeId,
        interface: types.InterfaceType,
        depth: usize,
    ) CompatibilityResult {
        if (depth == max_path_segments) return self.fail(.recursion_limit, source, target);
        const semantic = self.store.lookupInterfaceSemanticType(interface.identity);
        const members = if (semantic) |value| value.members.members else interface.members.members;
        for (members) |target_member| {
            const source_member = self.findStructuralMember(source, target_member.name, 0) orelse {
                if (target_member.optional) continue;
                self.push(.{ .property = target_member.name });
                const result = self.fail(.missing_property, source, target);
                self.pop();
                return result;
            };
            self.push(.{ .property = target_member.name });
            if (source_member.optional and !target_member.optional) {
                const result = self.fail(.optional_mismatch, source_member.type_id, target_member.type_id);
                self.pop();
                return result;
            }
            if (source_member.readonly and !target_member.readonly) {
                const result = self.fail(.readonly_mismatch, source_member.type_id, target_member.type_id);
                self.pop();
                return result;
            }
            const result = self.compare(source_member.type_id, target_member.type_id);
            self.pop();
            if (result != .compatible) return result;
        }
        if (semantic) |value| for (value.inheritance.extends) |base| {
            const base_type = self.store.lookup(base) orelse return self.fail(.invalid_type, source, target);
            if (base_type.kind != .interface) return self.fail(.incompatible_kind, source, target);
            const result = self.compareInterfaceTarget(source, base, base_type.kind.interface, depth + 1);
            if (result != .compatible) return result;
        };
        return .compatible;
    }

    fn findStructuralMember(self: *Checker, source: types.TypeId, name: []const u8, depth: usize) ?types.SemanticMember {
        if (depth == max_path_segments) return null;
        const source_type = self.store.lookup(source) orelse return null;
        return switch (source_type.kind) {
            .object => |properties| if (findProperty(properties, name)) |property| .{
                .name = property.name,
                .type_id = property.type_id,
                .readonly = property.readonly,
                .optional = property.optional,
            } else null,
            .interface => |interface| blk: {
                const semantic = self.store.lookupInterfaceSemanticType(interface.identity);
                const members = if (semantic) |value| value.members.members else interface.members.members;
                for (members) |member| if (std.mem.eql(u8, member.name, name)) break :blk member;
                if (semantic) |value| for (value.inheritance.extends) |base|
                    if (self.findStructuralMember(base, name, depth + 1)) |member| break :blk member;
                break :blk null;
            },
            .class => |instance| blk: {
                const semantic = self.store.lookupClassSemanticType(instance.identity) orelse break :blk null;
                for (semantic.instance_members.members) |member| if (std.mem.eql(u8, member.name, name)) break :blk member;
                if (semantic.inheritance.extends) |base|
                    if (self.findStructuralMember(base, name, depth + 1)) |member| break :blk member;
                break :blk null;
            },
            else => null,
        };
    }

    fn compareFunctions(self: *Checker, source: types.TypeId, target: types.TypeId) CompatibilityResult {
        const from = self.store.lookupFunction(source) orelse return self.fail(.invalid_type, source, target);
        const to = self.store.lookupFunction(target) orelse return self.fail(.invalid_type, source, target);
        if (from.flags != to.flags or from.type_parameter_count != to.type_parameter_count) return self.fail(.function_flags, source, target);
        // Strict-function v1: parameters are contravariant, returns covariant.
        if (from.requiredParameterCount() > to.requiredParameterCount()) return self.fail(.parameter_count, source, target);
        const common = @min(from.parameters.len, to.parameters.len);
        for (0..common) |index| {
            const from_parameter = from.parameters[index];
            const to_parameter = to.parameters[index];
            if (!(from_parameter.optional or from_parameter.has_default or from_parameter.rest) and
                (to_parameter.optional or to_parameter.has_default or to_parameter.rest))
            {
                self.push(.{ .parameter = index });
                const result = self.fail(.optional_mismatch, from_parameter.type_id, to_parameter.type_id);
                self.pop();
                return result;
            }
            // Target parameter flows into source parameter: contravariance.
            const result = self.compareChild(to_parameter.type_id, from_parameter.type_id, .{ .parameter = index });
            if (result != .compatible) return result;
        }
        return self.compareChild(from.return_type, to.return_type, .{ .return_type = {} });
    }

    fn compareChild(self: *Checker, source: types.TypeId, target: types.TypeId, segment: PathSegment) CompatibilityResult {
        self.push(segment);
        const result = self.compare(source, target);
        self.pop();
        return result;
    }

    fn fail(self: *Checker, reason: FailureReason, source: types.TypeId, target: types.TypeId) CompatibilityResult {
        var failure = Failure{ .reason = reason, .source = source, .target = target };
        failure.path_len = self.path_len;
        @memcpy(failure.path[0..self.path_len], self.path[0..self.path_len]);
        return .{ .incompatible = failure };
    }

    fn push(self: *Checker, segment: PathSegment) void {
        if (self.path_len == self.path.len) {
            self.path_overflow += 1;
            return;
        }
        self.path[self.path_len] = segment;
        self.path_len += 1;
    }

    fn pop(self: *Checker) void {
        if (self.path_overflow != 0) {
            self.path_overflow -= 1;
            return;
        }
        if (self.path_len != 0) self.path_len -= 1;
    }
};

fn containsPair(pairs: []const Pair, wanted: Pair) bool {
    for (pairs) |pair| if (pair.source == wanted.source and pair.target == wanted.target) return true;
    return false;
}

fn findProperty(properties: []const types.ObjectProperty, name: []const u8) ?types.ObjectProperty {
    for (properties) |property| if (std.mem.eql(u8, property.name, name)) return property;
    return null;
}

fn literalPrimitive(literal: types.LiteralValue, builtins: *const types.Builtins) types.TypeId {
    return switch (literal) {
        .boolean => builtins.boolean,
        .number => builtins.number,
        .bigint => builtins.bigint,
        .string => builtins.string,
    };
}

fn literalEqual(left: types.LiteralValue, right: types.LiteralValue) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .boolean => |value| value == right.boolean,
        .number => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number)),
        .bigint => |value| std.mem.eql(u8, value, right.bigint),
        .string => |value| std.mem.eql(u8, value, right.string),
    };
}

fn isObjectLike(kind: types.TypeKind) bool {
    return switch (kind) {
        .function, .array, .tuple, .object, .class, .class_constructor, .interface => true,
        else => false,
    };
}

fn isStructuralSource(kind: types.TypeKind) bool {
    return switch (kind) {
        .object, .interface, .class => true,
        else => false,
    };
}

test "Goal 147 compatibility keeps classes and enums nominal but interfaces structural" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const a = types.SemanticDeclId.init(1, 42);
    const b = types.SemanticDeclId.init(2, 42);

    const a_class = try store.intern(.{ .class = .{ .identity = a, .name = "Shared" } });
    const b_class = try store.intern(.{ .class = .{ .identity = b, .name = "Shared" } });
    const a_interface = try store.intern(.{ .interface = .{ .identity = a, .name = "Shape" } });
    const b_interface = try store.intern(.{ .interface = .{ .identity = b, .name = "Shape" } });
    const a_enum = try store.intern(.{ .enum_type = .{ .identity = a, .name = "Choice" } });
    const b_enum = try store.intern(.{ .enum_type = .{ .identity = b, .name = "Choice" } });

    try std.testing.expect(!check(a_class, b_class, &store).isCompatible());
    try std.testing.expect(check(a_interface, b_interface, &store).isCompatible());
    try std.testing.expect(!check(a_enum, b_enum, &store).isCompatible());
}

/// Pretty-name for diagnostics and debug output. Returns the canonical builtin
/// name (e.g. "number"). For function signatures or unknown ids returns "function"
/// / "unknown" — matching `Type.displayName` contract in types/model.zig.
pub fn typeName(type_id: types.TypeId, builtins: *const types.Builtins) []const u8 {
    const kind = builtins.kindFor(type_id);
    if (kind != null) return builtin.builtinKindName(kind.?);

    // Builtin ids live in [100, 200), so anything below is unknown. User-defined
    // function ids start at next_user_type_id (1000). Anything else we label
    // generically to keep tests assertions simple and predictable.
    if (type_id < @as(types.TypeId, 100)) return "unknown";
    return "function";
}

// ---------------------------------------------------------------------------
// Tests — every row of the v1 compatibility table, per Goal 24 spec.
// ---------------------------------------------------------------------------
const testing = std.testing;
const test_builtins = types.Builtins.init();

test "isAssignable: number -> number (true)" {
    try testing.expect(isAssignable(
        test_builtins.number,
        test_builtins.number,
        &test_builtins,
    ));
}

test "isAssignable: number -> string (false)" {
    try testing.expect(!isAssignable(
        test_builtins.number,
        test_builtins.string,
        &test_builtins,
    ));
}

test "isAssignable: string -> string (true)" {
    try testing.expect(isAssignable(
        test_builtins.string,
        test_builtins.string,
        &test_builtins,
    ));
}

test "isAssignable: boolean -> number (false)" {
    try testing.expect(!isAssignable(
        test_builtins.boolean,
        test_builtins.number,
        &test_builtins,
    ));
}

test "isAssignable: any -> number (true)" {
    try testing.expect(isAssignable(
        test_builtins.any,
        test_builtins.number,
        &test_builtins,
    ));
}

test "isAssignable: number -> any (true)" {
    try testing.expect(isAssignable(
        test_builtins.number,
        test_builtins.any,
        &test_builtins,
    ));
}

test "isAssignable: unknown -> number (false)" {
    try testing.expect(!isAssignable(
        test_builtins.unknown,
        test_builtins.number,
        &test_builtins,
    ));
}

test "isAssignable: unknown -> any (true)" {
    try testing.expect(isAssignable(
        test_builtins.unknown,
        test_builtins.any,
        &test_builtins,
    ));
}

test "isAssignable: undefined -> void (true)" {
    try testing.expect(isAssignable(
        test_builtins.undefined,
        test_builtins.void,
        &test_builtins,
    ));
}

test "isAssignable: null -> number (false)" {
    try testing.expect(!isAssignable(
        test_builtins.null_,
        test_builtins.number,
        &test_builtins,
    ));
}

// Goal 24 spec — these rows are explicit in the required rule table.
test "isAssignable: null -> unknown (true)" {
    try testing.expect(isAssignable(
        test_builtins.null_,
        test_builtins.unknown,
        &test_builtins,
    ));
}

test "isAssignable: undefined -> unknown (true)" {
    try testing.expect(isAssignable(
        test_builtins.undefined,
        test_builtins.unknown,
        &test_builtins,
    ));
}

// Extra coverage for the full table.
test "isAssignable: unknown -> unknown (true)" {
    try testing.expect(isAssignable(
        test_builtins.unknown,
        test_builtins.unknown,
        &test_builtins,
    ));
}

test "isAssignable: null -> undefined (true)" {
    try testing.expect(isAssignable(
        test_builtins.null_,
        test_builtins.undefined,
        &test_builtins,
    ));
}

test "isAssignable: undefined -> undefined (true)" {
    try testing.expect(isAssignable(
        test_builtins.undefined,
        test_builtins.undefined,
        &test_builtins,
    ));
}

test "isAssignable: void -> void (true)" {
    try testing.expect(isAssignable(
        test_builtins.void,
        test_builtins.void,
        &test_builtins,
    ));
}

test "typeName: canonical names for primitives" {
    const b = &test_builtins;
    try testing.expectEqualStrings("number", typeName(test_builtins.number, b));
    try testing.expectEqualStrings("string", typeName(test_builtins.string, b));
    try testing.expectEqualStrings("boolean", typeName(test_builtins.boolean, b));
    try testing.expectEqualStrings("null", typeName(test_builtins.null_, b));
    try testing.expectEqualStrings("undefined", typeName(test_builtins.undefined, b));
    try testing.expectEqualStrings("void", typeName(test_builtins.void, b));
}

test "typeName: function signatures return 'function'" {
    // next_user_type_id is 1000 — reserved range for user-defined types.
    const fn_id = @as(types.TypeId, @import("../types/root.zig").next_user_type_id);
    try testing.expectEqualStrings("function", typeName(fn_id, &test_builtins));
}

test "typeName: unknown id returns 'unknown'" {
    const b = &test_builtins;
    // Any id below the builtin range (100) is treated as unknown.
    try testing.expectEqualStrings("unknown", typeName(50, b));
}

test "Goal 122 object compatibility reports first property path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const source = try store.intern(.{ .object = &.{
        .{ .name = "id", .type_id = store.builtins.number },
        .{ .name = "name", .type_id = store.builtins.string },
    } });
    const target = try store.intern(.{ .object = &.{
        .{ .name = "id", .type_id = store.builtins.string },
    } });

    const failure = check(source, target, &store).incompatible;
    try testing.expectEqual(FailureReason.primitive_mismatch, failure.reason);
    try testing.expectEqual(@as(usize, 1), failure.path_len);
    try testing.expectEqualStrings("id", failure.path[0].property);
}

test "Goal 122 required optional and readonly object properties are explicit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const b = &store.builtins;
    const empty = try store.intern(.{ .object = &.{} });
    const required = try store.intern(.{ .object = &.{.{ .name = "x", .type_id = b.number }} });
    const optional = try store.intern(.{ .object = &.{.{ .name = "x", .type_id = b.number, .optional = true }} });
    const readonly = try store.intern(.{ .object = &.{.{ .name = "x", .type_id = b.number, .readonly = true }} });

    try testing.expectEqual(FailureReason.missing_property, check(empty, required, &store).incompatible.reason);
    try testing.expect(check(empty, optional, &store).isCompatible());
    try testing.expectEqual(FailureReason.optional_mismatch, check(optional, required, &store).incompatible.reason);
    try testing.expectEqual(FailureReason.readonly_mismatch, check(readonly, required, &store).incompatible.reason);
    try testing.expect(check(required, readonly, &store).isCompatible());
}

test "Goal 122 recursive structural comparisons terminate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const left = try store.reserve();
    const right = try store.reserve();
    try store.defineReserved(left, .{ .object = &.{.{ .name = "next", .type_id = left, .optional = true }} });
    try store.defineReserved(right, .{ .object = &.{.{ .name = "next", .type_id = right, .optional = true }} });
    try testing.expect(check(left, right, &store).isCompatible());

    const wrong = try store.reserve();
    try store.defineReserved(wrong, .{ .object = &.{
        .{ .name = "next", .type_id = wrong, .optional = true },
        .{ .name = "value", .type_id = store.builtins.string },
    } });
    try testing.expectEqual(FailureReason.missing_property, check(left, wrong, &store).incompatible.reason);
}

test "Goal 122 union checks and failure paths are deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const b = &store.builtins;
    const source = try store.unionOf(&.{ b.number, b.string });
    const target = try store.unionOf(&.{ b.boolean, b.number });
    const failure = check(source, target, &store).incompatible;
    try testing.expectEqual(@as(usize, 2), failure.path_len);
    try testing.expectEqual(@as(usize, 1), failure.path[0].source_union_member);
    try testing.expectEqual(@as(usize, 0), failure.path[1].target_union_member);
    try testing.expect(check(b.number, target, &store).isCompatible());
}

test "Goal 122 tuple and array readonly policy is covariant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const b = &store.builtins;
    const mutable_numbers = try store.intern(.{ .array = .{ .element_type = b.number } });
    const readonly_numbers = try store.intern(.{ .array = .{ .element_type = b.number, .readonly = true } });
    const tuple = try store.intern(.{ .tuple = .{ .elements = &.{.{ .type_id = b.number }} } });
    try testing.expect(check(mutable_numbers, readonly_numbers, &store).isCompatible());
    try testing.expectEqual(FailureReason.readonly_mismatch, check(readonly_numbers, mutable_numbers, &store).incompatible.reason);
    try testing.expect(check(tuple, mutable_numbers, &store).isCompatible());
}

test "Goal 122 function parameters are contravariant and returns covariant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    const b = &store.builtins;
    const literal = try store.intern(.{ .literal = .{ .number = 1 } });
    const broad_parameter = try store.addFunction(&.{.{ .name = "x", .type_id = b.unknown }}, literal);
    const narrow_parameter = try store.addFunction(&.{.{ .name = "x", .type_id = b.number }}, b.number);

    try testing.expect(check(broad_parameter, narrow_parameter, &store).isCompatible());
    const failure = check(narrow_parameter, broad_parameter, &store).incompatible;
    try testing.expectEqual(FailureReason.primitive_mismatch, failure.reason);
    try testing.expectEqual(@as(usize, 1), failure.path_len);
    try testing.expectEqual(@as(usize, 0), failure.path[0].parameter);
}

test "Goal 122 invalid error type suppresses cascades" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var store = types.TypeStore.init(arena.allocator());
    try testing.expect(check(types.invalid_type, store.builtins.number, &store).isCompatible());
    try testing.expect(check(store.builtins.number, types.invalid_type, &store).isCompatible());
}
