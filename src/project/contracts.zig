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
    /// Host-defined revision token. Zero means no revision was supplied.
    revision: u64 = 0,
};

/// Why source syntax requested another module. Explicit width is reserved for
/// the future C ABI representation.
pub const RequestKind = enum(u32) {
    static,
    type_only,
    dynamic,
    re_export,
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
    kind: RequestKind,
    attributes: []const RequestAttribute = &.{},
    span: SourceSpan,
};

/// Core input used before a project-local RequestId is assigned. Every slice
/// follows the same borrowed-for-the-call rule as ModuleRequest.
pub const ModuleRequestInput = struct {
    importer: ModuleId,
    raw_specifier: []const u8,
    kind: RequestKind,
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

/// One external export. Default exports must use name `default`. Namespace
/// exports are named namespace-valued members; `import *` is synthesized from
/// every non-type-only member in the module descriptor.
pub const ExternalExportDescriptor = struct {
    name: []const u8,
    kind: ExternalExportKind = .named,
    type_only: bool = false,
    type_metadata: ?ExternalType = null,
};

/// Borrowed source-less module metadata. Retaining APIs copy every slice.
pub const ExternalModuleDescriptor = struct {
    id: ExternalModuleId,
    logical_name: []const u8,
    exports: []const ExternalExportDescriptor = &.{},
};

comptime {
    if (@sizeOf(ModuleId) != @sizeOf(u64)) @compileError("ModuleId must remain C-representable as u64");
    if (@sizeOf(ExternalModuleId) != @sizeOf(u64)) @compileError("ExternalModuleId must remain C-representable as u64");
    if (@sizeOf(RequestId) != @sizeOf(u64)) @compileError("RequestId must remain C-representable as u64");
    if (@sizeOf(SourceKind) != @sizeOf(u32)) @compileError("SourceKind must remain C-representable as u32");
    if (@sizeOf(RequestKind) != @sizeOf(u32)) @compileError("RequestKind must remain C-representable as u32");
    if (@sizeOf(ExternalExportKind) != @sizeOf(u32)) @compileError("ExternalExportKind must remain C-representable as u32");
    if (@sizeOf(ExternalType) != @sizeOf(u32)) @compileError("ExternalType must remain C-representable as u32");
}

test "module identity is host assigned and independent of logical names" {
    const shared_id = ModuleId.init(41);
    const first = ModuleSource{ .id = shared_id, .logical_name = "/one/a.ts", .bytes = "export {};" };
    const alias = ModuleSource{ .id = shared_id, .logical_name = "mem://alias", .bytes = "export {};", .revision = 2 };
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

test "request contract represents every request kind and borrowed metadata" {
    const kinds = [_]RequestKind{ .static, .type_only, .dynamic, .re_export };
    const attributes = [_]RequestAttribute{.{
        .key = "type",
        .value = "json",
        .span = .{ .start = 20, .end = 32, .line = 1, .column = 20 },
    }};

    for (kinds, 0..) |kind, index| {
        const request = ModuleRequest{
            .id = RequestId.init(@intCast(index + 1)),
            .importer = ModuleId.init(9),
            .raw_specifier = "./data.json",
            .kind = kind,
            .attributes = &attributes,
            .span = .{ .start = 7, .end = 18, .line = 1, .column = 7 },
        };
        try std.testing.expectEqual(kind, request.kind);
        try std.testing.expectEqualStrings("./data.json", request.raw_specifier);
        try std.testing.expectEqual(@as(usize, 1), request.attributes.len);
    }
}

test "source and external identities are distinct types with stable widths" {
    const source = ModuleId.init(9);
    const external = ExternalModuleId.init(9);
    try std.testing.expectEqual(source.value(), external.value());
    try std.testing.expect(@TypeOf(source) != @TypeOf(external));
}
