// By convention, root.zig is the package entry point for `types/`.
const std = @import("std");
const builtin = @import("builtin.zig");
const model = @import("model.zig");

pub const BuiltinKind = builtin.BuiltinKind;
pub const builtinKindName = builtin.builtinKindName;
pub const builtinKindTypeId = builtin.builtinKindTypeId;
// Keep the legacy slice name in sync so callers that already used
// `types.builtinKinds_static` continue to compile without changes.
pub const builtinKinds_static = builtin.builtinKinds_static;

pub const TypeId = model.TypeId;
pub const invalid_type = model.invalid_type;
pub const next_user_type_id = model.next_user_type_id;

pub const TypeKind = model.TypeKind;
pub const Type = model.Type;

pub const FunctionSignatureId = model.FunctionSignatureId;
pub const ParameterType = model.ParameterType;
pub const FunctionSignature = model.FunctionSignature;
/// Alias for the store of function signatures. Re-exported from `model.zig` so that
/// downstream consumers (e.g., type_collector) can address it as `types.FunctionSignatureStore`.
pub const FunctionSignatureStore = model.FunctionSignatureStore;

pub const Builtins = model.Builtins;
// Keep the precomputed instance available at the package level so callers that
// already used `types.builtin_instance` still compile.
pub const builtin_instance = model.builtin_instance;
pub fn builtins() model.Builtins {
    return model.builtins();
}

test {
    _ = builtin;
    _ = model;
    _ = builtinKindName(.number);
    const _t: TypeId = 0;
    _ = _t;
}
