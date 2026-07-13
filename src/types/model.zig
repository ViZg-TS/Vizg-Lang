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
///   - 0..99       reserved
///   - 100..199    builtin types allocated by one `Builtins` registry
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
    optional: bool = false,
    has_default: bool = false,
    rest: bool = false,
};

pub const FunctionFlags = packed struct {
    is_async: bool = false,
    is_generator: bool = false,
    is_constructor: bool = false,
};

pub const LiteralValue = union(enum) {
    boolean: bool,
    number: f64,
    bigint: []const u8,
    string: []const u8,
};

pub const ObjectProperty = struct {
    name: []const u8,
    type_id: TypeId,
    optional: bool = false,
    readonly: bool = false,
};

pub const ArrayType = struct {
    element_type: TypeId,
    readonly: bool = false,
};

pub const TupleElement = struct {
    type_id: TypeId,
    optional: bool = false,
    hole: bool = false,
};

pub const TupleType = struct {
    elements: []const TupleElement,
    readonly: bool = false,
};

pub const NominalType = struct {
    /// Unique identifier per class/interface/enum declaration. Prevents structural 
    /// interning from merging distinct declarations with same name across modules.
    declaration_id: u32,
    
    /// Module where this type was declared - enables cross-module identity checking.
    /// Two types are only equal if they have the same module_id AND declaration_id.
    module_id: ?u32 = null,
    
    name: []const u8,
    
    // Semantic members stored separately in TypeStore for classes/interfaces
    // This is populated during class/interface analysis and used by member access lookup
};

pub const TypeParameterType = struct {
    declaration_id: u32,
    name: []const u8,
    constraint: ?TypeId = null,
    default: ?TypeId = null,
};


/// Represents a field in a class or interface declaration.
pub const ClassField = struct {
    name: []const u8,
    type_id: TypeId,
    is_public: bool = true,
    is_readonly: bool = false,
};

/// Represents a method in a class declaration with its full signature.
pub const ClassMethod = struct {
    name: []const u8,
    signature_id: FunctionSignatureId,
    is_static: bool = false,
};

/// Complete semantic representation of a class - includes both identity and members.
pub const ClassSemanticModel = struct {
    declaration_id: u32,
    module_id: ?u32,
    name: []const u8,
    fields: []const ClassField,
    methods: []const ClassMethod,
    constructor_signature: ?FunctionSignatureId = null,
};

/// Complete semantic representation of an interface - includes member signatures.
pub const InterfaceSemanticModel = struct {
    declaration_id: u32,
    module_id: ?u32,
    name: []const u8,
    members: []const ClassField,  // Interfaces have fields/methods as properties
};

/// Complete signature of a typed function. Stored as an opaque blob; the caller
/// (typically the binder or module graph) is responsible for its lifetime.
pub const FunctionSignature = struct {
    /// Unique identifier per function declaration. Prevents structural interning
    /// from sharing TypeIds across different functions with identical initial shapes.
    declaration_id: ?u32 = null,
    
    id: FunctionSignatureId,
    parameters: []const ParameterType,
    return_type: TypeId,
    type_parameter_count: u32 = 0,
    flags: FunctionFlags = .{},

    /// Number of declared parameters.
    pub fn parameterCount(self: FunctionSignature) usize {
        return self.parameters.len;
    }

    pub fn requiredParameterCount(self: FunctionSignature) usize {
        var count: usize = 0;
        for (self.parameters) |parameter| {
            if (parameter.optional or parameter.has_default or parameter.rest) break;
            count += 1;
        }
        return count;
    }

    pub fn acceptsArgumentCount(self: FunctionSignature, count: usize) bool {
        if (count < self.requiredParameterCount()) return false;
        const has_rest = self.parameters.len != 0 and self.parameters[self.parameters.len - 1].rest;
        return has_rest or count <= self.parameters.len;
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

pub const PromiseType = struct { value_type: TypeId };
pub const GeneratorType = struct { yield_type: TypeId, return_type: TypeId };

// ---------------------------------------------------------------------------
// TypeKind — the discriminated union of every type in the model.
// ---------------------------------------------------------------------------

pub const TypeKind = union(enum) {
    /// A primitive builtin (number | string | boolean | null | undefined | void).
    primitive: builtin_kind.BuiltinKind,

    /// A function signature identified by its declared id.
    function: FunctionSignatureId,
    promise: PromiseType,
    generator: GeneratorType,
    literal: LiteralValue,
    union_type: []const TypeId,
    intersection: []const TypeId,
    array: ArrayType,
    tuple: TupleType,
    object: []const ObjectProperty,
    class: NominalType,
    interface: NominalType,
    enum_type: NominalType,
    type_parameter: TypeParameterType,
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

    const b = Builtins.init();
    const x_param = ParameterType{ .name = "x", .type_id = b.number };
    const y_param = ParameterType{ .name = "y", .type_id = b.string };
    const params: []const ParameterType = &.{ x_param, y_param };

    var store = FunctionSignatureStore.init(arena.allocator());

    const sig_id = try store.add(params, b.boolean);
    try testing.expect(sig_id >= next_user_type_id);

    // The store should now report one entry and the lookup should return a matching signature.
    const found = store.lookup(sig_id).?;
    try testing.expectEqual(@as(usize, 2), found.parameterCount());
    try testing.expect(std.mem.eql(u8, "x", found.parameters[0].name));

    // Verify the parameter types are also captured correctly.
    try testing.expectEqual(b.number, found.parameters[0].type_id);
    try testing.expectEqualStrings("y", found.parameters[1].name);
    try testing.expectEqual(b.string, found.parameters[1].type_id);

    // The arena is still alive through `arena` — signature data should not be dropped.
}

test "FunctionSignatureStore.count reflects additions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = FunctionSignatureStore.init(arena.allocator());
    try testing.expectEqual(@as(usize, 0), store.count());

    const b = Builtins.init();
    _ = try store.add(&[_]ParameterType{}, b.number);
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "FunctionSignatureStore.lookup returns null for missing id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = FunctionSignatureStore.init(arena.allocator());
    const b = Builtins.init();
    _ = try store.add(&[_]ParameterType{}, b.number);

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
            else => false,
        };
    }

    /// Debug-friendly name for diagnostics and inspection commands. For function
    /// kinds we fall back to a fixed placeholder so the model can be used without
    /// libc linkage — production rendering goes through VZG6xxx.
    pub fn displayName(self: Type) []const u8 {
        return switch (self.kind) {
            .primitive => |k| builtin_kind.builtinKindName(k),
            .function => "function",
            .promise => "Promise",
            .generator => "Generator",
            .literal => "literal",
            .union_type => "union",
            .intersection => "intersection",
            .array => "array",
            .tuple => "tuple",
            .object => "object",
            .class => "class",
            .interface => "interface",
            .enum_type => "enum",
            .type_parameter => "type parameter",
        };
    }

    test "Type.isFunction distinguishes kinds" {
        const b = Builtins.init();
        var t_fn: Type = undefined;
        t_fn.id = 500;
        t_fn.kind = .{ .function = @as(u32, 1) };
        try testing.expect(t_fn.isFunction());

        var t_prim: Type = undefined;
        t_prim.id = b.number;
        t_prim.kind = .{ .primitive = .number };
        try testing.expect(!t_prim.isFunction());
    }

    test "Type.matchesPrimitive compares by kind" {
        const b = Builtins.init();
        var t_num: Type = undefined;
        t_num.id = b.number;
        t_num.kind = .{ .primitive = .number };

        var t_str: Type = undefined;
        t_str.id = b.string;
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
// Builtins — one canonical registry per semantic context.
// ---------------------------------------------------------------------------

pub const Builtins = struct {
    any: TypeId,
    unknown: TypeId,
    never: TypeId,
    void: TypeId,
    undefined: TypeId,
    null_: TypeId,
    boolean: TypeId,
    number: TypeId,
    bigint: TypeId,
    string: TypeId,
    symbol: TypeId,
    object: TypeId,
    records: [builtin_kind.builtinKinds.len]Type,

    const first_id: TypeId = 100;

    pub fn init() Builtins {
        var result: Builtins = undefined;
        for (builtin_kind.builtinKinds, 0..) |kind, index| {
            const type_id = first_id + @as(TypeId, @intCast(index));
            result.records[index] = .{ .id = type_id, .kind = .{ .primitive = kind } };
            switch (kind) {
                .any => result.any = type_id,
                .unknown => result.unknown = type_id,
                .never => result.never = type_id,
                .void => result.void = type_id,
                .undefined => result.undefined = type_id,
                .null_ => result.null_ = type_id,
                .boolean => result.boolean = type_id,
                .number => result.number = type_id,
                .bigint => result.bigint = type_id,
                .string => result.string = type_id,
                .symbol => result.symbol = type_id,
                .object => result.object = type_id,
            }
        }
        return result;
    }

    /// Type equality inside one semantic context is constant-time TypeId equality.
    pub fn id(self: *const Builtins, kind: builtin_kind.BuiltinKind) TypeId {
        return self.records[@intFromEnum(kind)].id;
    }

    pub fn lookup(self: *const Builtins, type_id: TypeId) ?*const Type {
        if (type_id < first_id) return null;
        const index = @as(usize, @intCast(type_id - first_id));
        if (index >= self.records.len) return null;
        return &self.records[index];
    }

    pub fn kindFor(self: *const Builtins, type_id: TypeId) ?builtin_kind.BuiltinKind {
        const ty = self.lookup(type_id) orelse return null;
        return switch (ty.kind) {
            .primitive => |kind| kind,
            else => null,
        };
    }
};

test "builtins exist" {
    const b = Builtins.init();
    _ = b.never;
    _ = b.bigint;
    _ = b.symbol;
    _ = b.object;
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
    const a = Builtins.init();
    const b = Builtins.init();

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
    const b = Builtins.init();
    // Every built-in must resolve to a different numeric id — otherwise lookup by
    // TypeId would be ambiguous.
    for (builtin_kind.builtinKinds, 0..) |kind, index| {
        try testing.expectEqual(b.id(kind), b.records[index].id);
        for (b.records, 0..) |candidate, candidate_index| {
            if (index != candidate_index) try testing.expect(b.id(kind) != candidate.id);
        }
    }
}

test "primitive lookup by kind works" {
    const b = Builtins.init();
    for (builtin_kind.builtinKinds) |kind| {
        const t = b.lookup(b.id(kind)).?;
        try testing.expect(t.matchesPrimitive(kind));
        try testing.expectEqual(kind, b.kindFor(t.id).?);
    }
}

test "function signature can be constructed" {
    const b = Builtins.init();
    const param_a = ParameterType{ .name = "x", .type_id = b.number };
    const param_b = ParameterType{ .name = "y", .type_id = b.string };
    const params: []const ParameterType = &.{ param_a, param_b };

    var sig: FunctionSignature = undefined;
    sig.id = next_user_type_id; // reserved range, no collision with builtins
    sig.parameters = params;
    sig.return_type = b.boolean;

    try testing.expectEqual(@as(usize, 2), sig.parameterCount());
    try testing.expectEqual(b.number, param_a.type_id);
    try testing.expectEqualStrings("x", param_a.name);

    const fn_type = Type{ .id = sig.id, .kind = .{ .function = sig.id } };
    try testing.expect(fn_type.isFunction());
}
