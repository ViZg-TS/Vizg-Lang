//! Environment-neutral host/core project descriptors.
//!
//! Every slice in this file is borrowed. The caller must keep its storage alive
//! for the duration of the API call receiving the descriptor. APIs that retain
//! a descriptor must copy all slices into core-owned storage.

const std = @import("std");
const tokens = @import("../frontend/tokens.zig");

/// Opaque module identity assigned by the host. Its integer representation is
/// stable for future C ABI transport; the value has no path or URL semantics.
pub const ModuleId = enum(u64) {
    _,

    pub fn init(value_: u64) ModuleId {
        return @enumFromInt(value_);
    }

    pub fn value(self: ModuleId) u64 {
        return @intFromEnum(self);
    }
};

/// Opaque host identity for a source-less runtime module. This is deliberately
/// a different Zig type from `ModuleId`; equal integers never imply equal
/// source and external identities.
pub const ExternalModuleId = enum(u64) {
    _,

    pub fn init(value_: u64) ExternalModuleId {
        return @enumFromInt(value_);
    }

    pub fn value(self: ExternalModuleId) u64 {
        return @intFromEnum(self);
    }
};

/// Stable host-assigned identity for one declaration in a source-less module.
/// Its domain is distinct from both source declarations and module identities.
pub const ExternalSymbolId = enum(u64) {
    _,

    pub fn init(value_: u64) ExternalSymbolId {
        return @enumFromInt(value_);
    }

    pub fn value(self: ExternalSymbolId) u64 {
        return @intFromEnum(self);
    }
};

/// Opaque identity assigned by the core to one unresolved module request.
pub const RequestId = enum(u64) {
    _,

    pub fn init(value_: u64) RequestId {
        return @enumFromInt(value_);
    }

    pub fn value(self: RequestId) u64 {
        return @intFromEnum(self);
    }
};

/// Parser interpretation of supplied bytes. Explicit width is reserved for the
/// future C ABI representation.
pub const SourceKind = enum(u32) {
    script,
    module,
};

/// Host-supplied source. `logical_name` is only a diagnostic label. It never
/// participates in identity, equality, hashing, caching, or graph linkage.
pub const ModuleSource = struct {
    id: ModuleId,
    logical_name: []const u8,
    bytes: []const u8,
    kind: SourceKind = .module,
};

/// Syntactic operation that requested another module. Runtime/type-only is an
/// orthogonal namespace flag because a re-export can also be type-only.
pub const RequestOperation = enum(u32) {
    static_import,
    re_export,
    dynamic_import,
};

pub const SourceSpan = tokens.Span;

/// One normalized import attribute. Both slices are borrowed exact byte spans.
pub const RequestAttribute = struct {
    key: []const u8,
    value: []const u8,
    span: SourceSpan,
};

/// Core-derived unresolved request. `raw_specifier`, attribute slices, and
/// their nested key/value slices are borrowed. The importer is always an opaque
/// host-assigned identity; the specifier is never resolved by the core.
pub const ModuleRequest = struct {
    id: RequestId,
    importer: ModuleId,
    raw_specifier: []const u8,
    operation: RequestOperation,
    type_only: bool = false,
    attributes: []const RequestAttribute = &.{},
    span: SourceSpan,
};

/// Core input used before a project-local RequestId is assigned. Every slice
/// follows the same borrowed-for-the-call rule as ModuleRequest.
pub const ModuleRequestInput = struct {
    importer: ModuleId,
    raw_specifier: []const u8,
    operation: RequestOperation,
    type_only: bool = false,
    attributes: []const RequestAttribute = &.{},
    span: SourceSpan,
};

/// Export spelling category supplied for a source-less module.
pub const ExternalExportKind = enum(u32) {
    named,
    default,
    namespace,
};

/// Portable type metadata accepted for external exports. Omitted metadata is
/// always `unknown`; `any` is used only when the host explicitly selects it.
pub const ExternalType = enum(u32) {
    unknown,
    any,
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

/// Namespaces in which a source-less export may be referenced. The zero value
/// is deliberately invalid at descriptor-validation boundaries.
pub const ExternalNamespace = packed struct(u8) {
    value: bool = false,
    type: bool = false,
    _reserved: u6 = 0,

    pub fn supports(self: ExternalNamespace, type_only: bool) bool {
        return if (type_only) self.type else self.value;
    }

    pub fn isValid(self: ExternalNamespace) bool {
        return self._reserved == 0 and (self.value or self.type);
    }
};

pub const ExternalDeclarationKind = enum(u32) {
    function,
    global,
    constant,
    type,
};

pub const ExternalParameterDescriptor = struct {
    name: []const u8 = "",
    type_metadata: ExternalType,
    optional: bool = false,
    has_default: bool = false,
    rest: bool = false,
};

pub const ExternalFunctionDescriptor = struct {
    parameters: []const ExternalParameterDescriptor = &.{},
    return_type: ExternalType,
    type_parameter_count: u32 = 0,
    is_async: bool = false,
    is_generator: bool = false,
    is_constructor: bool = false,
};

/// Conservative effect declaration. `unknown` dominates every other bit.
pub const ExternalEffectSet = packed struct(u16) {
    reads_memory: bool = false,
    writes_memory: bool = false,
    may_throw: bool = false,
    may_suspend: bool = false,
    allocates: bool = false,
    calls_unknown: bool = false,
    unknown: bool = true,
    reserved: u9 = 0,
};

/// One external export. Default exports must use name `default`. Namespace
/// exports are named namespace-valued members; `import *` is synthesized from
/// every member available in the namespace requested by the import.
pub const ExternalExportDescriptor = struct {
    name: []const u8,
    kind: ExternalExportKind = .named,
    namespace: ExternalNamespace = .{ .value = true },
    type_metadata: ?ExternalType = null,
    symbol_id: ?ExternalSymbolId = null,
    declaration_kind: ?ExternalDeclarationKind = null,
    function: ?ExternalFunctionDescriptor = null,
    effects: ?ExternalEffectSet = null,
};

/// Borrowed source-less module metadata. Retaining APIs copy every slice.
pub const ExternalModuleDescriptor = struct {
    id: ExternalModuleId,
    logical_name: []const u8,
    exports: []const ExternalExportDescriptor = &.{},
};

/// One borrowed structural member of an ambient global type. A self-reference
/// reuses the enclosing ambient type identity; otherwise `type_metadata`
/// supplies the member type.
pub const AmbientMember = struct {
    name: []const u8,
    type_metadata: ?ExternalType = null,
    optional: bool = false,
    readonly: bool = false,
    self_reference: bool = false,
};

/// Borrowed ambient global descriptor. The host registers ambient globals
/// before analysis so ViZg can resolve them without synthetic source files.
/// Retaining APIs copy `name`, `members`, and every member name.
pub const AmbientGlobal = struct {
    name: []const u8,
    namespace: ExternalNamespace,
    type_metadata: ?ExternalType = null,
    host_binding_id: u64 = 0,
    members: []const AmbientMember = &.{},
};

/// Borrowed mapping from a top-level source value declaration to a stable
/// host identity. The declaration and its type remain source-defined.
pub const SourceHostBinding = struct {
    name: []const u8,
    host_binding_id: u64,
};

comptime {
    if (@sizeOf(ModuleId) != @sizeOf(u64)) @compileError("ModuleId must remain C-representable as u64");
    if (@sizeOf(ExternalModuleId) != @sizeOf(u64)) @compileError("ExternalModuleId must remain C-representable as u64");
    if (@sizeOf(ExternalSymbolId) != @sizeOf(u64)) @compileError("ExternalSymbolId must remain C-representable as u64");
    if (@sizeOf(RequestId) != @sizeOf(u64)) @compileError("RequestId must remain C-representable as u64");
    if (@sizeOf(SourceKind) != @sizeOf(u32)) @compileError("SourceKind must remain C-representable as u32");
    if (@sizeOf(RequestOperation) != @sizeOf(u32)) @compileError("RequestOperation must remain C-representable as u32");
    if (@sizeOf(ExternalExportKind) != @sizeOf(u32)) @compileError("ExternalExportKind must remain C-representable as u32");
    if (@sizeOf(ExternalType) != @sizeOf(u32)) @compileError("ExternalType must remain C-representable as u32");
    if (@sizeOf(ExternalNamespace) != @sizeOf(u8)) @compileError("ExternalNamespace must remain C-representable as u8");
    if (@sizeOf(ExternalDeclarationKind) != @sizeOf(u32)) @compileError("ExternalDeclarationKind must remain C-representable as u32");
}

test "module identity is host assigned and independent of logical names" {
    const shared_id = ModuleId.init(41);
    const first = ModuleSource{ .id = shared_id, .logical_name = "/one/a.ts", .bytes = "export {};" };
    const alias = ModuleSource{ .id = shared_id, .logical_name = "mem://alias", .bytes = "export {};" };
    try std.testing.expectEqual(first.id, alias.id);

    const same_label_a = ModuleSource{ .id = ModuleId.init(1), .logical_name = "/same/path.ts", .bytes = "" };
    const same_label_b = ModuleSource{ .id = ModuleId.init(2), .logical_name = "/same/path.ts", .bytes = "" };
    try std.testing.expect(same_label_a.id != same_label_b.id);

    var identities = std.AutoHashMap(ModuleId, void).init(std.testing.allocator);
    defer identities.deinit();
    try identities.put(same_label_a.id, {});
    try identities.put(same_label_b.id, {});
    try identities.put(alias.id, {});
    try identities.put(first.id, {});
    try std.testing.expectEqual(@as(usize, 3), identities.count());
}

test "request contract keeps operation and type-only orthogonal" {
    const operations = [_]RequestOperation{ .static_import, .re_export, .dynamic_import };
    const attributes = [_]RequestAttribute{.{
        .key = "type",
        .value = "json",
        .span = .{ .start = 20, .end = 32, .line = 1, .column = 20 },
    }};

    for (operations, 0..) |operation, index| {
        const request = ModuleRequest{
            .id = RequestId.init(@intCast(index + 1)),
            .importer = ModuleId.init(9),
            .raw_specifier = "./data.json",
            .operation = operation,
            .type_only = operation == .re_export,
            .attributes = &attributes,
            .span = .{ .start = 7, .end = 18, .line = 1, .column = 7 },
        };
        try std.testing.expectEqual(operation, request.operation);
        try std.testing.expectEqual(operation == .re_export, request.type_only);
        try std.testing.expectEqualStrings("./data.json", request.raw_specifier);
    }
}

test "external namespace flags distinguish value type and both" {
    const value: ExternalNamespace = .{ .value = true };
    const type_only: ExternalNamespace = .{ .type = true };
    const both: ExternalNamespace = .{ .value = true, .type = true };
    const invalid: ExternalNamespace = .{};

    try std.testing.expect(value.isValid());
    try std.testing.expect(value.supports(false));
    try std.testing.expect(!value.supports(true));
    try std.testing.expect(type_only.isValid());
    try std.testing.expect(!type_only.supports(false));
    try std.testing.expect(type_only.supports(true));
    try std.testing.expect(both.isValid());
    try std.testing.expect(both.supports(false));
    try std.testing.expect(both.supports(true));
    try std.testing.expect(!invalid.isValid());
}

test "source and external identities are distinct types with stable widths" {
    const source = ModuleId.init(9);
    const external = ExternalModuleId.init(9);
    try std.testing.expectEqual(source.value(), external.value());
    try std.testing.expect(@TypeOf(source) != @TypeOf(external));
}
