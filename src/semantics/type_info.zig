const std = @import("std");
const ast_mod = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const diagnostics_mod = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");

// ---------------------------------------------------------------------------
// SymbolTypeInfo — declared / inferred type for a single symbol.
//
// Either or both of `declared_type` and `inferred_type` may be null at any
// point during analysis; the two are intentionally kept distinct so callers can
// distinguish "annotated by the source" from "filled in by inference".
// ---------------------------------------------------------------------------

pub const SymbolTypeInfo = struct {
    symbol_id: binder.SymbolId,
    declared_type: ?types.TypeId = null,
    inferred_type: ?types.TypeId = null,
    state: TypeResolutionState = .resolved,

    /// Error state has no usable type. Otherwise declaration evidence wins over
    /// inference, with null reserved for a symbol that has neither.
    pub fn effective(self: @This()) ?types.TypeId {
        if (self.state == .@"error") return null;
        return self.declared_type orelse self.inferred_type;
    }

    test "effective returns declared over inferred" {
        const entry = SymbolTypeInfo{
            .symbol_id = 1,
            .declared_type = 42,
            .inferred_type = 7,
        };
        try std.testing.expectEqual(@as(types.TypeId, 42), entry.effective());
    }

    test "effective returns inferred when declared is null" {
        const entry = SymbolTypeInfo{
            .symbol_id = 2,
            .declared_type = null,
            .inferred_type = 9,
        };
        try std.testing.expectEqual(@as(types.TypeId, 9), entry.effective());
    }

    test "effective returns null when both are null" {
        const entry = SymbolTypeInfo{
            .symbol_id = 3,
            .declared_type = null,
            .inferred_type = null,
        };
        try std.testing.expect(entry.effective() == null);
    }

    test "effective returns null for an error state" {
        const entry = SymbolTypeInfo{
            .symbol_id = 4,
            .declared_type = 42,
            .inferred_type = 7,
            .state = .@"error",
        };
        try std.testing.expect(entry.effective() == null);
    }

    test "defaults declare and infer to null" {
        const entry = SymbolTypeInfo{ .symbol_id = 0 };
        try std.testing.expect(entry.declared_type == null);
        try std.testing.expect(entry.inferred_type == null);
    }
};

// ---------------------------------------------------------------------------
// NodeTypeInfo — type for a single AST node (e.g. an expression).
// ---------------------------------------------------------------------------

pub const NodeTypeInfo = struct {
    node_id: ast_mod.NodeId,
    /// Actual source-inferred type. Contextual expectations never replace it.
    type_id: types.TypeId,
    state: TypeResolutionState = .resolved,
    issue: TypeIssue = .none,
    /// Base object for a method-valued member access. Call inference uses this
    /// to preserve `this` without changing the canonical function identity.
    receiver_type: ?types.TypeId = null,
    /// Contextual (declared annotation) type used only as a structural hint.
    /// The actual inferred source expression type stays in `type_id`. The two
    /// are compared post-inference so incompatible initializers surface the
    /// real element-level mismatch rather than a generic "incompatible" hit.
    contextual_type: ?types.TypeId = null,

    /// Effective expression type is the actual inferred type when resolution
    /// succeeded. Context only guides inference; it is never the expression's
    /// result type.
    pub fn effective(self: @This()) ?types.TypeId {
        if (self.state != .resolved or self.type_id == types.invalid_type) return null;
        return self.type_id;
    }

    test "nodeTypeInfo stores id and type" {
        const n = NodeTypeInfo{ .node_id = 42, .type_id = 7 };
        try std.testing.expectEqual(@as(usize, 42), @as(usize, n.node_id));
        try std.testing.expectEqual(@as(types.TypeId, 7), n.type_id);
    }

    test "contextual_type defaults to null" {
        const n = NodeTypeInfo{ .node_id = 1, .type_id = 2 };
        try std.testing.expect(n.contextual_type == null);
    }

    test "effective uses inference and never substitutes context" {
        const n = NodeTypeInfo{ .node_id = 1, .type_id = 2, .contextual_type = 3 };
        try std.testing.expectEqual(@as(types.TypeId, 2), n.effective().?);
        const failed = NodeTypeInfo{ .node_id = 1, .type_id = 2, .contextual_type = 3, .state = .@"error" };
        try std.testing.expect(failed.effective() == null);
    }
};

/// Canonical inference outcome consumed by the checker. Keeping the issue on
/// the node table prevents the checker from re-running inference rules.
pub const TypeIssue = enum {
    none,
    invalid_operator,
    unknown_property,
    invalid_index,
    invalid_argument_count,
    invalid_argument_type,
    invalid_callee,
    invalid_constructor,
    satisfies,
};

/// Flow-sensitive type of one resolved reference in one CFG block.
pub const FlowTypeInfo = struct {
    function_node: ast_mod.NodeId,
    block_id: u32,
    program_point: u32 = 0,
    symbol_id: binder.SymbolId,
    reference_node: ast_mod.NodeId,
    type_id: types.TypeId,
};

/// Why a symbol or expression has the type currently recorded for it.
pub const TypeResolutionState = enum {
    resolved,
    uninitialized,
    unresolved,
    @"error",
};

// ---------------------------------------------------------------------------
// TypeInfo — per-file snapshot of declared/inferred types plus any captured
// diagnostics. Allocated as a heap object via the `Builder`; callers that need
// to keep the table around for the lifetime of an analysis pass can hand out
// slices, or use `TypeInfoArena` when they prefer arena-backed storage.
// ---------------------------------------------------------------------------

pub const TypeInfo = struct {
    symbols: []const SymbolTypeInfo,
    nodes: []const NodeTypeInfo,
    flow_types: []const FlowTypeInfo = &.{},
    diagnostics: []const diagnostics_mod.Diagnostic,

    /// Look up a symbol by id; returns null if not found.
    pub fn lookupSymbol(self: @This(), symbol_id: binder.SymbolId) ?SymbolTypeInfo {
        for (self.symbols) |entry| {
            if (entry.symbol_id == symbol_id) return entry;
        }
        return null;
    }

    /// Look up the type of an AST node by id; returns `types.invalid_type`
    /// when no entry is found.
    pub fn lookupNode(self: @This(), node_id: ast_mod.NodeId) ?types.TypeId {
        for (self.nodes) |entry| {
            if (entry.node_id == node_id) return entry.effective();
        }
        return null;
    }

    pub fn lookupNodeInfo(self: @This(), node_id: ast_mod.NodeId) ?NodeTypeInfo {
        for (self.nodes) |entry| {
            if (entry.node_id == node_id) return entry;
        }
        return null;
    }

    pub fn lookupFlowType(self: @This(), function_node: ast_mod.NodeId, block_id: u32, symbol_id: binder.SymbolId) ?types.TypeId {
        var found: ?types.TypeId = null;
        for (self.flow_types) |entry| {
            if (entry.function_node == function_node and entry.block_id == block_id and entry.symbol_id == symbol_id)
                found = entry.type_id;
        }
        return found;
    }

    pub fn lookupFlowTypeAtReference(self: @This(), reference_node: ast_mod.NodeId) ?types.TypeId {
        for (self.flow_types) |entry| if (entry.reference_node == reference_node) return entry.type_id;
        return null;
    }

    pub fn lookupFlowTypeAtPoint(self: @This(), function_node: ast_mod.NodeId, block_id: u32, program_point: u32, symbol_id: binder.SymbolId) ?types.TypeId {
        for (self.flow_types) |entry| {
            if (entry.function_node == function_node and entry.block_id == block_id and entry.program_point == program_point and entry.symbol_id == symbol_id)
                return entry.type_id;
        }
        return null;
    }

    test "lookupSymbol returns declared/inferred data" {
        const symbols = [_]SymbolTypeInfo{
            SymbolTypeInfo{ .symbol_id = 1, .declared_type = 10, .inferred_type = null },
            SymbolTypeInfo{ .symbol_id = 2, .declared_type = null, .inferred_type = 20 },
        };
        const empty_nodes: [0]NodeTypeInfo = .{};
        const diagnostics: [0]diagnostics_mod.Diagnostic = .{};

        const info = TypeInfo{
            .symbols = &symbols,
            .nodes = &empty_nodes,
            .diagnostics = &diagnostics,
        };

        var found = info.lookupSymbol(1) orelse unreachable;
        try std.testing.expectEqual(@as(types.TypeId, 10), @as(types.TypeId, std.math.cast(types.TypeId, found.declared_type.?) orelse unreachable));

        found = info.lookupSymbol(2) orelse unreachable;
        try std.testing.expectEqual(@as(types.TypeId, 20), @as(types.TypeId, found.inferred_type.?));

        try std.testing.expect(info.lookupSymbol(99) == null);
    }

    test "lookupNode returns type id" {
        const empty_syms: [0]SymbolTypeInfo = .{};
        const nodes = [_]NodeTypeInfo{
            NodeTypeInfo{ .node_id = 5, .type_id = 31 },
            NodeTypeInfo{ .node_id = 6, .type_id = 32 },
        };
        const diagnostics: [0]diagnostics_mod.Diagnostic = .{};

        const info = TypeInfo{
            .symbols = &empty_syms,
            .nodes = &nodes,
            .diagnostics = &diagnostics,
        };

        try std.testing.expectEqual(@as(types.TypeId, 31), info.lookupNode(5).?);
        try std.testing.expectEqual(@as(types.TypeId, 32), info.lookupNode(6).?);
        try std.testing.expect(info.lookupNode(99) == null);
    }

    test "flow lookups distinguish references and program points in one block" {
        const empty_symbols: [0]SymbolTypeInfo = .{};
        const empty_nodes: [0]NodeTypeInfo = .{};
        const flow = [_]FlowTypeInfo{
            .{ .function_node = 10, .block_id = 2, .program_point = 0, .symbol_id = 7, .reference_node = 20, .type_id = 30 },
            .{ .function_node = 10, .block_id = 2, .program_point = 1, .symbol_id = 7, .reference_node = 21, .type_id = 31 },
        };
        const empty_diagnostics: [0]diagnostics_mod.Diagnostic = .{};
        const info: TypeInfo = .{
            .symbols = &empty_symbols,
            .nodes = &empty_nodes,
            .flow_types = &flow,
            .diagnostics = &empty_diagnostics,
        };

        try std.testing.expectEqual(@as(types.TypeId, 30), info.lookupFlowTypeAtReference(20).?);
        try std.testing.expectEqual(@as(types.TypeId, 31), info.lookupFlowTypeAtReference(21).?);
        try std.testing.expectEqual(@as(types.TypeId, 30), info.lookupFlowTypeAtPoint(10, 2, 0, 7).?);
        try std.testing.expectEqual(@as(types.TypeId, 31), info.lookupFlowType(10, 2, 7).?);
    }

    test "empty table lookup returns null" {
        const empty_syms: [0]SymbolTypeInfo = .{};
        const empty_nodes: [0]NodeTypeInfo = .{};
        const diagnostics: [0]diagnostics_mod.Diagnostic = .{};

        const info = TypeInfo{
            .symbols = &empty_syms,
            .nodes = &empty_nodes,
            .diagnostics = &diagnostics,
        };

        try std.testing.expect(info.lookupSymbol(1) == null);
        try std.testing.expect(info.lookupNode(1) == null);
    }

    test "lookup returns first match only" {
        const symbols = [_]SymbolTypeInfo{
            SymbolTypeInfo{ .symbol_id = 1, .declared_type = 10, .inferred_type = null },
        };
        const empty_nodes: [0]NodeTypeInfo = .{};
        const diagnostics: [0]diagnostics_mod.Diagnostic = .{};

        const info = TypeInfo{
            .symbols = &symbols,
            .nodes = &empty_nodes,
            .diagnostics = &diagnostics,
        };

        const found = info.lookupSymbol(1) orelse unreachable;
        try std.testing.expectEqual(@as(types.TypeId, 10), @as(types.TypeId, std.math.cast(types.TypeId, found.declared_type.?) orelse unreachable));
    }
};

// ---------------------------------------------------------------------------
// Builder — append-only builder for TypeInfo that uses the supplied allocator.
// Keeps the API friendly while respecting arena-compatible usage: pass an Arena
// to keep allocations short-lived or a persistent allocator otherwise.
// ---------------------------------------------------------------------------

pub const Builder = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(SymbolTypeInfo) = .empty,
    nodes: std.ArrayList(NodeTypeInfo) = .empty,
    diagnostics: std.ArrayList(diagnostics_mod.Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn addSymbol(self: *Builder, entry: SymbolTypeInfo) !void {
        try self.symbols.append(self.allocator, entry);
    }

    pub fn addNode(self: *Builder, node: NodeTypeInfo) void {
        _ = self.nodes.append(self.allocator, node); // size_t fits in NodeId by construction; error ignored intentionally for ergonomics.
    }

    pub fn addDiagnostic(self: *Builder, d: diagnostics_mod.Diagnostic) void {
        _ = self.diagnostics.append(self.allocator, d);
    }

    /// Consumes the builder and returns a TypeInfo whose slices point into the
    /// ArrayLists kept alive by `self`. Callers who need to free or detach
    /// storage should drain it first or use their own allocator pattern. The
    /// lifetime of the returned slices matches the Builder's lifetime; this is
    /// the convention used throughout the frontend.
    pub fn build(self: *Builder) TypeInfo {
        return TypeInfo{
            .symbols = self.symbols.items,
            .nodes = self.nodes.items,
            .diagnostics = self.diagnostics.items,
        };
    }

    test "build returns populated table" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var builder = (Builder{ .allocator = allocator }).init(allocator);
        errdefer _ = builder.destroy();

        try builder.addSymbol(SymbolTypeInfo{ .symbol_id = 1, .declared_type = 5 });
        builder.addNode(NodeTypeInfo{ .node_id = 3, .type_id = 7 });

        const info = builder.build();

        const sym = info.lookupSymbol(1) orelse unreachable;
        try std.testing.expectEqual(@as(types.TypeId, 5), @as(types.TypeId, sym.declared_type.?));

        _ = info.lookupNode(3); // non-null — just verifying no panic.
    }

    test "build returns empty table when nothing added" {
        const allocator = std.testing.allocator;
        var builder = (Builder{ .allocator = allocator }).init(allocator);

        const info = builder.build();

        try std.testing.expect(info.lookupSymbol(1) == null);
        try std.testing.expect(info.lookupNode(1) == null);
    }

    fn destroy(self: *Builder) void {
        // Deinitializes the ArrayLists owned by the caller's allocator. For
        // tests that pass an Arena this clears all allocations at once, which
        // is what callers using `build()` expect.
        self.symbols.deinit();
        self.nodes.deinit();
        self.diagnostics.deinit();
    }
};

test "type_info" {
    _ = SymbolTypeInfo;
    _ = NodeTypeInfo;
    _ = TypeInfo;
}
