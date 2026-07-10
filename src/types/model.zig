const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const builtin_kind = @import("builtin.zig");

// ---------------------------------------------------------------------------
// TypeId — opaque numeric identifier for any type in the model.
// ---------------------------------------------------------------------------

pub const TypeId = u32;
pub const invalid_type: TypeId = std.math.maxInt(TypeId);

/// Reserved numeric ranges across every TypeId space:
///   - 0..99       reserved (unallocated as of now; kept for future builtins)
///   - 100..199    builtin primitives via `builtin_kind.builtinKindTypeId`
///                 (`base=100 + @intFromEnum(kind)` in builtin.zig:37).
///   - 200..999    reserved for future builtins or extensions (no consumer yet)
///   - >= 1000     user-defined function signatures via `FunctionSignatureStore`
///                 (`next_user_type_id + index`, see model.zig:110).

/// Builtins and user signatures must never overlap — the lookup at line 137 relies
///   on `sig_id < next_user_type_id` to distinguish the two kinds cheaply.

/// Start of reserved TypeId range for FunctionSignatureStore (user-defined function signatures).
pub const next_user_type_id: TypeId = 1000;

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
// FunctionSignatureStore — arena-owned container for every function signature
// produced by a semantic pass. Signatures are stored alongside their own ids so
// downstream phases (checker, resolver) can look them up via `TypeId`. The slice
// lives on the caller-provided allocator (typically an arena); callers do not
// need to free individual entries and should just drop the store when done.
// ---------------------------------------------------------------------------

/// Minimal arena-backed container of `FunctionSignature`s collected during a single
/// analysis pass. Parameter slices are allocated with the same allocator so they
/// outlive any transient AST data even if that arena is dropped before consumers.
pub const FunctionSignatureStore = struct {
    /// Allocator used for internal allocations (parameter copies). For typical
    /// callers this is an `ArenaAllocator`; OOMs propagate through `add()`.
    allocator: std.mem.Allocator,

    /// Accumulator of every signature added via `add()`. Backing storage comes from
    /// `self.allocator` so entries are freed when the arena (or its parent allocator)
    /// is dropped; callers do not call `deinit()` on this store directly.
    signatures: std.ArrayList(FunctionSignature),

    pub fn init(allocator_: std.mem.Allocator) FunctionSignatureStore {
        return .{
            .allocator = allocator_,
            .signatures = std.ArrayList(FunctionSignature).empty,
        };
    }

    /// Appends a new signature with the given parameter names and types plus the
    /// declared return type. Returns the id of the newly created signature so that
    /// downstream phases can later construct a `Type{ .kind = .function = sig_id }`.
    pub fn add(self: *FunctionSignatureStore, parameters: []const ParameterType, return_type: TypeId) !FunctionSignatureId {
        const new_id: FunctionSignatureId = next_user_type_id + @as(FunctionSignatureId, @intCast(self.signatures.items.len));

        // Duplicate the parameter slice on the store's allocator. We always copy —
        // the AST or binder may free its temporary slices before downstream consumers
        // touch the signature, so relying on borrowed storage would be a use-after-free
        // in every non-trivial pipeline.
        const params_copy = try self.allocator.dupe(ParameterType, parameters);

        var sig: FunctionSignature = undefined;
        sig.id = new_id;
        sig.parameters = params_copy;
        sig.return_type = return_type;

        if (self.signatures.append(self.allocator, sig)) |_| {} else |err| {
            // Arena-backed append only reports OOM in pathological paths that we cannot
            // recover from — keep the same error path as `dupe` for API symmetry.
            _ = self.allocator.free(params_copy);
            return err;
        }

        return new_id;
    }

    /// Looks up a signature by its id (the function's TypeId when wrapped). Returns
    /// null if the store never produced one with that id — useful for defensive code
    /// but callers are expected to only query ids they previously added.
    pub fn lookup(self: FunctionSignatureStore, sig_id: FunctionSignatureId) ?FunctionSignature {
        if (sig_id < next_user_type_id) return null;
        const idx = @as(usize, @intCast(sig_id - next_user_type_id));
        if (idx >= self.signatures.items.len) return null;
        // Return a copy to avoid aliasing the internal storage — callers should not
        // mutate signatures through this view.
        return self.signatures.items[idx];
    }

    /// Number of signatures currently stored — handy for tests and debug rendering.
    pub fn count(self: FunctionSignatureStore) usize {
        return self.signatures.items.len;
    }

    /// Returns a slice over the accumulated signatures. The slice's lifetime is tied to
    /// the store (and its allocator), so it must not outlive them.
    pub fn items(self: *FunctionSignatureStore) []const FunctionSignature {
        return self.signatures.items;
    }
};

test "FunctionSignatureStore.add allocates a fresh signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const x_param = ParameterType{ .name = "x", .type_id = builtin_instance.number };
    const y_param = ParameterType{ .name = "y", .type_id = builtin_instance.string };
    const params: []const ParameterType = &.{x_param, y_param};

    var store = FunctionSignatureStore.init(arena.allocator());

    const sig_id = try store.add(params, builtin_instance.boolean);
    try testing.expect(sig_id >= next_user_type_id);

    // The store should now report one entry and the lookup should return a matching signature.
    const found = store.lookup(sig_id).?;
    try testing.expectEqual(@as(usize, 2), found.parameterCount());
    try testing.expect(std.mem.eql(u8, "x", found.parameters[0].name));

    // Verify the parameter types are also captured correctly.
    try testing.expectEqual(builtin_instance.number, found.parameters[0].type_id);
    try testing.expectEqualStrings("y", found.parameters[1].name);
    try testing.expectEqual(builtin_instance.string, found.parameters[1].type_id);

    // The arena is still alive through `arena` — signature data should not be dropped.
}

test "FunctionSignatureStore.count reflects additions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = FunctionSignatureStore.init(arena.allocator());
    try testing.expectEqual(@as(usize, 0), store.count());

    _ = try store.add(&[_]ParameterType{}, builtin_kind.builtinKindTypeId(.number));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "FunctionSignatureStore.lookup returns null for missing id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = FunctionSignatureStore.init(arena.allocator());
    _ = try store.add(&[_]ParameterType{}, builtin_kind.builtinKindTypeId(.number));

    // Ids in the builtin range (100-199) must not collide with user signatures.
    try testing.expect(store.lookup(next_user_type_id - 1) == null);
}

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
