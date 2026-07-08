const std = @import("std");
const types = @import("../types/root.zig");
const builtin = @import("../types/builtin.zig");

// ---------------------------------------------------------------------------
// Type compatibility for the v1 type checker.
//
// See Goal 24 spec for the full rule table. The implementation is small,
// side-effect-free, and heap-free — callable from both future checker traversal
// and unit tests without extra allocations.
// ---------------------------------------------------------------------------

/// Maps a TypeId to its BuiltinKind if one exists. Function signatures occupy
/// ids ≥ next_user_type_id (1000) and never collide with builtin id space.
fn builtinKindFor(type_id: types.TypeId) ?types.BuiltinKind {
    if (type_id == builtin.builtinKindTypeId(.number))   return .number;
    if (type_id == builtin.builtinKindTypeId(.string))    return .string;
    if (type_id == builtin.builtinKindTypeId(.boolean))   return .boolean;
    if (type_id == builtin.builtinKindTypeId(.null_))     return .null_;
    if (type_id == builtin.builtinKindTypeId(.undefined)) return .undefined;
    if (type_id == builtin.builtinKindTypeId(.void))      return .void;
    if (type_id == builtin.builtinKindTypeId(.unknown))   return .unknown;
    if (type_id == builtin.builtinKindTypeId(.any))       return .any;
    return null;
}

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
    builtins: types.Builtins,
) bool {
    _ = builtins; // reserved for per-built-in customization (v2+)

    const from_kind = builtinKindFor(from);
    if (from_kind != null and from_kind.? == .any) return true;

    const to_kind = builtinKindFor(to);
    if (to_kind != null and to_kind.? == .any) return true;

    if (to_kind == null) return false;

    switch (from_kind orelse return false) {
        .number   => return to_kind.? == .number,
        .string   => return to_kind.? == .string,
        .boolean  => return to_kind.? == .boolean,
        .null_    => return to_kind.? == .null_ or to_kind.? == .undefined or to_kind.? == .unknown,
        .undefined => return to_kind.? == .undefined or to_kind.? == .void or to_kind.? == .unknown,
        .void     => return to_kind.? == .void,
        .unknown  => {
            // 'unknown' only flows into sinks that also accept it: same kind or any.
            const t = to_kind.?;
            if (t == .any) return true;
            if (t == .unknown) return true;
            return false;
        },
        .any      => unreachable,   // short-circuited at top of isAssignable()
    }
}

/// Pretty-name for diagnostics and debug output. Returns the canonical builtin
/// name (e.g. "number"). For function signatures or unknown ids returns "function"
/// / "unknown" — matching `Type.displayName` contract in types/model.zig.
pub fn typeName(type_id: types.TypeId, builtins: types.Builtins) []const u8 {
    _ = builtins; // reserved for future customization

    const kind = builtinKindFor(type_id);
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

test "isAssignable: number -> number (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.number),
        builtin.builtinKindTypeId(.number),
        types.builtin_instance,
    ));
}

test "isAssignable: number -> string (false)" {
    try testing.expect(!isAssignable(
        builtin.builtinKindTypeId(.number),
        builtin.builtinKindTypeId(.string),
        types.builtin_instance,
    ));
}

test "isAssignable: string -> string (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.string),
        builtin.builtinKindTypeId(.string),
        types.builtin_instance,
    ));
}

test "isAssignable: boolean -> number (false)" {
    try testing.expect(!isAssignable(
        builtin.builtinKindTypeId(.boolean),
        builtin.builtinKindTypeId(.number),
        types.builtin_instance,
    ));
}

test "isAssignable: any -> number (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.any),
        builtin.builtinKindTypeId(.number),
        types.builtin_instance,
    ));
}

test "isAssignable: number -> any (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.number),
        builtin.builtinKindTypeId(.any),
        types.builtin_instance,
    ));
}

test "isAssignable: unknown -> number (false)" {
    try testing.expect(!isAssignable(
        builtin.builtinKindTypeId(.unknown),
        builtin.builtinKindTypeId(.number),
        types.builtin_instance,
    ));
}

test "isAssignable: unknown -> any (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.unknown),
        builtin.builtinKindTypeId(.any),
        types.builtin_instance,
    ));
}

test "isAssignable: undefined -> void (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.undefined),
        builtin.builtinKindTypeId(.void),
        types.builtin_instance,
    ));
}

test "isAssignable: null -> number (false)" {
    try testing.expect(!isAssignable(
        builtin.builtinKindTypeId(.null_),
        builtin.builtinKindTypeId(.number),
        types.builtin_instance,
    ));
}

// Goal 24 spec — these rows are explicit in the required rule table.
test "isAssignable: null -> unknown (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.null_),
        builtin.builtinKindTypeId(.unknown),
        types.builtin_instance,
    ));
}

test "isAssignable: undefined -> unknown (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.undefined),
        builtin.builtinKindTypeId(.unknown),
        types.builtin_instance,
    ));
}

// Extra coverage for the full table.
test "isAssignable: unknown -> unknown (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.unknown),
        builtin.builtinKindTypeId(.unknown),
        types.builtin_instance,
    ));
}

test "isAssignable: null -> undefined (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.null_),
        builtin.builtinKindTypeId(.undefined),
        types.builtin_instance,
    ));
}

test "isAssignable: undefined -> undefined (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.undefined),
        builtin.builtinKindTypeId(.undefined),
        types.builtin_instance,
    ));
}

test "isAssignable: void -> void (true)" {
    try testing.expect(isAssignable(
        builtin.builtinKindTypeId(.void),
        builtin.builtinKindTypeId(.void),
        types.builtin_instance,
    ));
}

test "typeName: canonical names for primitives" {
    const b = types.builtin_instance;
    try testing.expectEqualStrings("number",   typeName(builtin.builtinKindTypeId(.number),   b));
    try testing.expectEqualStrings("string",   typeName(builtin.builtinKindTypeId(.string),   b));
    try testing.expectEqualStrings("boolean",  typeName(builtin.builtinKindTypeId(.boolean),  b));
    try testing.expectEqualStrings("null",     typeName(builtin.builtinKindTypeId(.null_),    b));
    try testing.expectEqualStrings("undefined",typeName(builtin.builtinKindTypeId(.undefined),b));
    try testing.expectEqualStrings("void",     typeName(builtin.builtinKindTypeId(.void),     b));
}

test "typeName: function signatures return 'function'" {
    // next_user_type_id is 1000 — reserved range for user-defined types.
    const fn_id = @as(types.TypeId, @import("../types/root.zig").next_user_type_id);
    try testing.expectEqualStrings("function", typeName(fn_id, types.builtin_instance));
}

test "typeName: unknown id returns 'unknown'" {
    const b = types.builtin_instance;
    // Any id below the builtin range (100) is treated as unknown.
    try testing.expectEqualStrings("unknown", typeName(50, b));
}
