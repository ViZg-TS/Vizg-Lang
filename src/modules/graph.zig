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
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ModuleGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
