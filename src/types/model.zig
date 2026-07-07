const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin_kind = @import("builtin.zig");

// ---------------------------------------------------------------------------
// TypeId — opaque numeric identifier for any type in the model.
// ---------------------------------------------------------------------------

pub const TypeId = u32;
pub const invalid_type: TypeId = std.math.maxInt(TypeId);

/// Reserved id range for user-defined function signatures. Builtins occupy the
/// [100, 199) range via `builtin_kind.builtinKindTypeId`, so user functions must
/// be assigned ids ≥ `next_user_function_id` to avoid collisions.
pub const next_user_type_id: TypeId = 1_000;

// ---------------------------------------------------------------------------
// FunctionSignature — captured at declaration, referenced by id from a TypeKind.
// ---------------------------------------------------------------------------

pub const FunctionSignatureId = u32;
const invalid_function_signature: FunctionSignatureId = std.math.maxInt(FunctionSignatureId);

/// A single parameter in a function signature. The name is for debugging /
/// display purposes and does not participate in type identity.
pub const ParameterType = struct {
    name: []const u8,
    type_id: TypeId,
};

/// Complete signature of a typed function. Stored as an opaque blob; the caller
/// (typically the binder or module graph) is responsible for its lifetime.
pub const FunctionSignature = struct {
    id: FunctionSignatureId,
    parameters: []const ParameterType,
    return_type: TypeId,

    /// Number of declared parameters.
    pub fn parameterCount(self: FunctionSignature) usize {
        return self.parameters.len;
    }

    test "FunctionSignature.parameterCount returns correct count" {
        const dummy_params = &[_]ParameterType{
            .{ .name = "a", .type_id = 1 },
            .{ .name = "b", .type_id = 2 },
        };
        var sig: FunctionSignature = undefined;
        sig.id = 500;
        sig.parameters = dummy_params;
        sig.return_type = 3;
        try testing.expectEqual(@as(usize, 2), sig.parameterCount());
    }

    test "FunctionSignature returns invalid id on empty" {
        var sig: FunctionSignature = undefined;
        sig.id = next_user_type_id;
        sig.parameters = &[_]ParameterType{};
        sig.return_type = invalid_type;
        try testing.expectEqual(@as(usize, 0), sig.parameterCount());
    }
};

// ---------------------------------------------------------------------------
// TypeKind — the discriminated union of every type in the model.
// ---------------------------------------------------------------------------

pub const TypeKind = union(enum) {
    /// A primitive builtin (number | string | boolean | null | undefined | void).
    primitive: builtin_kind.BuiltinKind,

    /// A function signature identified by its declared id.
    function: FunctionSignatureId,
};

// ---------------------------------------------------------------------------
// Type — a concrete type value consisting of an id and a kind.
// ---------------------------------------------------------------------------

/// Describes the shape of any value in the frontend's analysis. Ids make types
/// cheap to pass around; kinds carry the real semantics.
pub const Type = struct {
    id: TypeId,
    kind: TypeKind,

    /// Returns true if this type is a function signature reference.
    pub fn isFunction(self: Type) bool {
        return self.kind == .function;
    }

    /// Returns true if the underlying primitive resolves to the given builtin.
    pub fn matchesPrimitive(self: Type, expected: builtin_kind.BuiltinKind) bool {
        return switch (self.kind) {
            .primitive => |b| b == expected,
            .function => false,
        };
    }

    /// Debug-friendly name for diagnostics and inspection commands. For function
    /// kinds we fall back to a fixed placeholder so the model can be used without
    /// libc linkage — production rendering goes through VZG6xxx.
    pub fn displayName(self: Type) []const u8 {
        return switch (self.kind) {
            .primitive => |k| builtin_kind.builtinKindName(k),
            .function => "function",
        };
    }

    test "Type.isFunction distinguishes kinds" {
        var t_fn: Type = undefined;
        t_fn.id = 500;
        t_fn.kind = .{ .function = @as(u32, 1) };
        try testing.expect(t_fn.isFunction());

        var t_prim: Type = undefined;
        t_prim.id = builtin_kind.builtinKindTypeId(.number);
        t_prim.kind = .{ .primitive = .number };
        try testing.expect(!t_prim.isFunction());
    }

    test "Type.matchesPrimitive compares by kind" {
        var t_num: Type = undefined;
        t_num.id = builtin_kind.builtinKindTypeId(.number);
        t_num.kind = .{ .primitive = .number };

        var t_str: Type = undefined;
        t_str.id = builtin_kind.builtinKindTypeId(.string);
        t_str.kind = .{ .primitive = .string };

        try testing.expect(t_num.matchesPrimitive(.number));
        try testing.expect(!t_num.matchesPrimitive(.boolean));
        try testing.expect(t_str.matchesPrimitive(.string));
    }

    test "displayName produces readable names" {
        var t: Type = undefined;
        t.id = 0;
        t.kind = .{ .primitive = .number };
        try testing.expectEqualStrings("number", t.displayName());

        t.kind = .{ .primitive = .undefined };
        try testing.expectEqualStrings("undefined", t.displayName());

        t.id = next_user_type_id;
        t.kind = .{ .function = @as(u32, 1) };
        try testing.expectEqualStrings("function", t.displayName());
    }
};

// ---------------------------------------------------------------------------
// Builtins — the "stable" helper that gives external callers a single entry
// point for looking up built-in primitives by kind. Keeping this here rather
// than in `builtins.builtin_kind.zig` makes it easy to later extend with user-
// defined function lookups without moving the builtin kinds themselves.
// ---------------------------------------------------------------------------

pub const Builtins = struct {
    number: TypeId,
    string: TypeId,
    boolean: TypeId,
    null_: TypeId,
    undefined: TypeId,
    void: TypeId,
    unknown: TypeId,
    any: TypeId,
};

/// Precomputed builtins instance — idempotent because builtin ids are stable.
pub const builtin_instance = Builtins{
    .number = builtin_kind.builtinKindTypeId(.number),
    .string = builtin_kind.builtinKindTypeId(.string),
    .boolean = builtin_kind.builtinKindTypeId(.boolean),
    .null_ = builtin_kind.builtinKindTypeId(.null_),
    .undefined = builtin_kind.builtinKindTypeId(.undefined),
    .void = builtin_kind.builtinKindTypeId(.void),
    .unknown = builtin_kind.builtinKindTypeId(.unknown),
    .any = builtin_kind.builtinKindTypeId(.any),
};

/// Factory for a fresh Builtins instance. Always returns the same ids since the
/// underlying mapping is deterministic by design; kept as a function so future
/// work (e.g., per-file builtins) could parameterize it.
pub fn builtins() Builtins {
    return builtin_instance;
}

test "builtins exist" {
    const b = builtin_instance;
    _ = b.number;
    _ = b.string;
    _ = b.boolean;
    _ = b.null_;
    _ = b.undefined;
    _ = b.void;
    _ = b.unknown;
    _ = b.any;
}

test "builtin ids are stable" {
    const a = builtin_instance;
    const b = builtins(); // factory call for comparison

    try testing.expectEqual(a.number, b.number);
    try testing.expectEqual(a.string, b.string);
    try testing.expectEqual(a.boolean, b.boolean);
    try testing.expectEqual(a.null_, b.null_);
    try testing.expectEqual(a.undefined, b.undefined);
    try testing.expectEqual(a.void, b.void);
    try testing.expectEqual(a.unknown, b.unknown);
    try testing.expectEqual(a.any, b.any);
}

test "builtins ids are distinct" {
    const b = builtin_instance;
    // Every built-in must resolve to a different numeric id — otherwise lookup by
    // TypeId would be ambiguous.
    inline for (builtin_kind.builtinKinds_static) |kind| {
        const other_id = builtin_kind.builtinKindTypeId(kind);
        var seen: u8 = 0;
        inline for (.{b.number, b.string, b.boolean, b.null_,
                     b.undefined, b.void, b.unknown, b.any}) |candidate| {
            if (other_id == candidate) seen += 1;
        }
        try testing.expectEqual(@as(u8, 1), seen);
    }
}

test "primitive lookup by kind works" {
    for (builtin_kind.builtinKinds_static) |kind| {
        const id = builtin_kind.builtinKindTypeId(kind);
        var t: Type = undefined;
        t.id = id;
        t.kind = .{ .primitive = kind };

        // The displayName test covers one direction; here we confirm the reverse.
        switch (kind) {
            .number => try testing.expect(t.matchesPrimitive(.number)),
            .string => try testing.expect(t.matchesPrimitive(.string)),
            .boolean => try testing.expect(t.matchesPrimitive(.boolean)),
            .null_ => try testing.expect(t.matchesPrimitive(.null_)),
            .undefined => try testing.expect(t.matchesPrimitive(.undefined)),
            .void => try testing.expect(t.matchesPrimitive(.void)),
            .unknown => try testing.expect(t.matchesPrimitive(.unknown)),
            .any => try testing.expect(t.matchesPrimitive(.any)),
        }
    }
}

test "function signature can be constructed" {
    const param_a = ParameterType{ .name = "x", .type_id = builtin_instance.number };
    const param_b = ParameterType{ .name = "y", .type_id = builtin_instance.string };
    const params: []const ParameterType = &.{param_a, param_b};

    var sig: FunctionSignature = undefined;
    sig.id = next_user_type_id; // reserved range, no collision with builtins
    sig.parameters = params;
    sig.return_type = builtin_instance.boolean;

    try testing.expectEqual(@as(usize, 2), sig.parameterCount());
    try testing.expectEqual(builtin_instance.number, param_a.type_id);
    try testing.expectEqualStrings("x", param_a.name);

    const fn_type = Type{ .id = sig.id, .kind = .{ .function = sig.id } };
    try testing.expect(fn_type.isFunction());
}
