// By convention, root.zig is the package entry point for `types/`.
const std = @import("std");
const builtin = @import("builtin.zig");
const model = @import("model.zig");
const type_store = @import("type_store.zig");

pub const BuiltinKind = builtin.BuiltinKind;
pub const builtinKindName = builtin.builtinKindName;
pub const builtinKinds = builtin.builtinKinds;

pub const TypeId = model.TypeId;
pub const invalid_type = model.invalid_type;
pub const next_user_type_id = model.next_user_type_id;

pub const TypeKind = model.TypeKind;
pub const Type = model.Type;

pub const FunctionSignatureId = model.FunctionSignatureId;
pub const ParameterType = model.ParameterType;
pub const LiteralValue = model.LiteralValue;
pub const ObjectProperty = model.ObjectProperty;
pub const ArrayType = model.ArrayType;
pub const TupleElement = model.TupleElement;
pub const TupleType = model.TupleType;
pub const NominalType = model.NominalType;
pub const TypeParameterType = model.TypeParameterType;
pub const FunctionSignature = model.FunctionSignature;
/// Alias for the store of function signatures. Re-exported from `model.zig` so that
/// downstream consumers (e.g., type_collector) can address it as `types.FunctionSignatureStore`.
pub const FunctionSignatureStore = model.FunctionSignatureStore;

pub const Builtins = model.Builtins;
pub const TypeStore = type_store.TypeStore;

test {
    _ = builtin;
    _ = model;
    _ = type_store;
    _ = builtinKindName(.number);
    const _t: TypeId = 0;
    _ = _t;
}
