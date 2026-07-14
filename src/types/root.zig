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

pub const ParameterType = model.ParameterType;
pub const LiteralValue = model.LiteralValue;
pub const ObjectProperty = model.ObjectProperty;
pub const ArrayType = model.ArrayType;
pub const TupleElement = model.TupleElement;
pub const TupleType = model.TupleType;
pub const SemanticDeclId = model.SemanticDeclId;
pub const NominalType = model.NominalType;
pub const Visibility = model.Visibility;
pub const SemanticMember = model.SemanticMember;
pub const MemberTable = model.MemberTable;
pub const ClassInstanceType = model.ClassInstanceType;
pub const ClassConstructorType = model.ClassConstructorType;
pub const InterfaceType = model.InterfaceType;
pub const ClassInheritance = model.ClassInheritance;
pub const InterfaceInheritance = model.InterfaceInheritance;
pub const ClassSemanticType = model.ClassSemanticType;
pub const InterfaceSemanticType = model.InterfaceSemanticType;
pub const TypeParameterType = model.TypeParameterType;
pub const GenericParameter = model.GenericParameter;
pub const GenericDeclaration = model.GenericDeclaration;
pub const AppliedGenericType = model.AppliedGenericType;
pub const FunctionSignature = model.FunctionSignature;

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
