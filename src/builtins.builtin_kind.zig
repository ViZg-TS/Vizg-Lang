const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

// ---------------------------------------------------------------------------
// BuiltinKind — every primitive type supported by the frontend's type model.
// ---------------------------------------------------------------------------

pub const BuiltinKind = enum(u8) {
    number,
    string,
    boolean,
    null_,
    undefined,
    void,
    unknown,
    any,
};

/// Returns the canonical name of a builtin kind (e.g. "number", "string").
pub fn builtinKindName(kind: BuiltinKind) []const u8 {
    return switch (kind) {
        .number => "number",
        .string => "string",
        .boolean => "boolean",
        .null_ => "null",
        .undefined => "undefined",
        .void => "void",
        .unknown => "unknown",
        .any => "any",
    };
}

/// Stable numeric identifier for a builtin kind. These ids are invariant across
/// the lifetime of a program, which lets other layers refer to primitive types
/// without holding slice pointers or strings.
pub fn builtinKindTypeId(kind: BuiltinKind) u32 {
    // Base offset so builtins do not collide with user-defined function signatures.
    const base: u32 = 100;
    return base + @as(u32, @intFromEnum(kind));
}

/// Returns all builtin kinds in declaration order — useful for iteration and
/// validation tests.
pub fn allBuiltinKinds(allocator: std.mem.Allocator) AllocatorOwnedBuiltinKind {
    // Use the arena-allocated form when called from outside; this keeps a simple
    // "no allocator needed" path available via the static inline slice below.
    _ = allocator;
    return .{ .static_slice = builtinKinds_static };
}

/// All builtin kinds — static, read-only storage is fine because the list is tiny
/// and never mutated. Callers who need heap-allocated views can iterate through
/// `allBuiltinKindIds` instead.
pub const builtinKinds_static: []const BuiltinKind = &.{
    .number,
    .string,
    .boolean,
    .null_,
    .undefined,
    .void,
    .unknown,
    .any,
};

/// Type-safe way to iterate over all builtins without allocating.
pub const AllBuiltins = enum {
    number, string, boolean, null_, undefined, void, unknown, any,
};

fn builtinKindFromBuiltin(b: AllBuiltins) BuiltinKind {
    return switch (b) {
        .number => .number,
        .string => .string,
        .boolean => .boolean,
        .null_ => .null_,
        .undefined => .undefined,
        .void => .void,
        .unknown => .unknown,
        .any => .any,
    };
}

const AllocatorOwnedBuiltinKind = struct {
    static_slice: []const BuiltinKind,
};

test "builtinKindName returns canonical names" {
    try testing.expectEqualStrings("number", builtinKindName(.number));
    try testing.expectEqualStrings("string", builtinKindName(.string));
    try testing.expectEqualStrings("boolean", builtinKindName(.boolean));
    try testing.expectEqualStrings("null", builtinKindName(.null_));
    try testing.expectEqualStrings("undefined", builtinKindName(.undefined));
    try testing.expectEqualStrings("void", builtinKindName(.void));
    try testing.expectEqualStrings("unknown", builtinKindName(.unknown));
    try testing.expectEqualStrings("any", builtinKindName(.any));
}

test "builtinKindTypeId returns stable ids" {
    const a = builtinKindTypeId(.number);
    const b = builtinKindTypeId(.number);
    try testing.expectEqual(a, b); // stable across calls

    try testing.expect(a != 0);
    for (builtinKinds_static) |kind| {
        try testing.expect(@as(u8, @intCast(builtinKindTypeId(kind) % 256)) > 0);
    }
}

test "builtins slice is complete" {
    // Ensure no builtin kind is missing from the static list.
    for (builtinKinds_static) |kind| {
        _ = builtinKindName(kind);
        _ = builtinKindTypeId(kind);
    }
    try testing.expectEqual(8, builtinKinds_static.len);
}
