//! Optional source provenance for HIR. Module identity is always the opaque
//! host-supplied ModuleId; diagnostic names and paths are never identities.

const ast = @import("../frontend/ast.zig");
const tokens = @import("../frontend/tokens.zig");
const ids = @import("ids.zig");
const project = @import("../project/contracts.zig");
const types = @import("../types/root.zig");

pub const DebugLevel = enum { none, minimal, full };
pub const SyntaxKind = std.meta.Tag(ast.NodeData);

const std = @import("std");

pub const LoweringRule = enum {
    direct,
    module_initialization,
    control_flow,
    expression,
    declaration,
    synthetic,
    canonicalized,
};

pub const SyntheticReason = enum {
    module_entry,
    control_flow,
    temporary,
    canonicalization,
    missing_source,
};

pub const OriginRecord = struct {
    module_id: project.ModuleId,
    primary_span: tokens.Span,
    ast_nodes: []const ast.NodeId,
    original_syntax: SyntaxKind,
    symbol: ?types.SemanticDeclId = null,
    type_id: ?types.TypeId = null,
    parent: ?ids.OriginId = null,
    lowering_rule: LoweringRule,
    synthetic_reason: ?SyntheticReason = null,
};

pub const OriginTable = struct {
    records: []const OriginRecord = &.{},

    pub fn lookup(self: OriginTable, id: ids.OriginId) ?*const OriginRecord {
        const index = id.index() orelse return null;
        if (index >= self.records.len) return null;
        return &self.records[index];
    }
};
