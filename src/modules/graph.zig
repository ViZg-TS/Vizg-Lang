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
};

pub const ExternalModule = struct {
    id: u64,
    logical_name: []const u8,
    exports: []const ExternalExport,
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
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ModuleGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
