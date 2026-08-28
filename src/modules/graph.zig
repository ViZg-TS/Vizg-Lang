const std = @import("std");

const ast = @import("../frontend/ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const frontend = @import("../frontend/frontend.zig");
const linker = @import("linker.zig");
const tokens = @import("../frontend/tokens.zig");

pub const ModuleId = u64;
pub const ImportEdgeId = u32;

pub const ImportStatus = enum {
    local,
    external,
    missing,
};

pub const ExternalExportKind = enum {
    named,
    default,
    namespace,
};

pub const ExternalType = enum {
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

pub const ExternalTypeReference = union(enum) {
    builtin: ExternalType,
    declared: u64,
};

pub const ExternalTypeMember = struct {
    name: []const u8,
    type_reference: ExternalTypeReference,
    optional: bool = false,
    readonly: bool = false,
};

pub const ExternalTypeDescriptor = struct {
    id: u64,
    name: []const u8,
    members: []const ExternalTypeMember,
};

pub const ExternalParameter = struct {
    name: []const u8,
    type_reference: ExternalTypeReference,
    optional: bool = false,
    has_default: bool = false,
    rest: bool = false,
};

pub const ExternalFunction = struct {
    parameters: []const ExternalParameter,
    return_type: ExternalTypeReference,
    type_parameter_count: u32 = 0,
    is_async: bool = false,
    is_generator: bool = false,
    is_constructor: bool = false,
};

pub const ExternalNamespace = packed struct(u8) {
    value: bool = false,
    type: bool = false,
    _reserved: u6 = 0,

    pub fn supports(self: ExternalNamespace, type_only: bool) bool {
        return if (type_only) self.type else self.value;
    }
};

pub const ExternalExport = struct {
    name: []const u8,
    kind: ExternalExportKind,
    namespace: ExternalNamespace,
    type_metadata: ?ExternalType,
    type_reference: ?ExternalTypeReference = null,
    function: ?ExternalFunction = null,
};

pub const ExternalModule = struct {
    id: u64,
    logical_name: []const u8,
    exports: []const ExternalExport,
    types: []const ExternalTypeDescriptor = &.{},
};

/// Portable, owned module data. Hosts choose how source bytes and paths are obtained.
pub const Module = struct {
    id: ModuleId,
    path: []const u8,
    display_path: []const u8,
    source_path: []const u8,
    result: frontend.FrontendResult,
    text: []const u8,
};

/// Source language-item locators are authorized by the embedding project
/// before semantic analysis. They carry no source-name meaning on their own:
/// consumers select behavior exclusively by the stable numeric identity.
pub const SourceLanguageItem = struct {
    id: u64,
    module: ModuleId,
    exported_name: []const u8,
    type_only: bool,
};

pub const ImportEdge = struct {
    id: ImportEdgeId,
    project_edge_index: usize,
    from: ModuleId,
    to: ?ModuleId,
    external_to: ?u64 = null,
    specifier: []const u8,
    kind: ast.ImportKind,
    type_only: bool,
    re_export: bool = false,
    attributes: ?ast.ImportAttributes = null,
    status: ImportStatus,
    span: tokens.Span,
};

pub const ModuleGraph = struct {
    arena: std.heap.ArenaAllocator,
    entry: ModuleId,
    modules: []const Module,
    imports: []const ImportEdge,
    linked_imports: []const linker.LinkedImport,
    external_modules: []const ExternalModule = &.{},
    source_language_items: []const SourceLanguageItem = &.{},
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ModuleGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
