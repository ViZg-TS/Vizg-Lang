const std = @import("std");
const testing = std.testing;

/// Every builtin type supported by the semantic type model. Declaration order
/// is part of the per-context registry layout; consumers must obtain ids from
/// `types.Builtins` instead of deriving them from this enum.
pub const BuiltinKind = enum(u8) {
    any,
    unknown,
    never,
    void,
    undefined,
    null_,
    boolean,
    number,
    bigint,
    string,
    symbol,
    object,
};

pub fn builtinKindName(kind: BuiltinKind) []const u8 {
    return switch (kind) {
        .any => "any",
        .unknown => "unknown",
        .never => "never",
        .void => "void",
        .undefined => "undefined",
        .null_ => "null",
        .boolean => "boolean",
        .number => "number",
        .bigint => "bigint",
        .string => "string",
        .symbol => "symbol",
        .object => "object",
    };
}

pub const builtinKinds: []const BuiltinKind = &.{
    .any,
    .unknown,
    .never,
    .void,
    .undefined,
    .null_,
    .boolean,
    .number,
    .bigint,
    .string,
    .symbol,
    .object,
};

test "builtin names and list are complete" {
    try testing.expectEqual(@typeInfo(BuiltinKind).@"enum".fields.len, builtinKinds.len);
    for (builtinKinds) |kind| try testing.expect(builtinKindName(kind).len != 0);
    try testing.expectEqualStrings("null", builtinKindName(.null_));
}
