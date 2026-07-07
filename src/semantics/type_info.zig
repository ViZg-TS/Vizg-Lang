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

    /// Returns the preferred type for this symbol: declared if present,
    /// otherwise inferred; `null` only when neither is known.
    pub fn effective(self: @This()) ?types.TypeId {
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
    type_id: types.TypeId,

    test "nodeTypeInfo stores id and type" {
        const n = NodeTypeInfo{ .node_id = 42, .type_id = 7 };
        try std.testing.expectEqual(@as(usize, 42), @as(usize, n.node_id));
        try std.testing.expectEqual(@as(types.TypeId, 7), n.type_id);
    }
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
            if (entry.node_id == node_id) return entry.type_id;
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
        try self.symbols.append(entry);
    }

    pub fn addNode(self: *Builder, node: NodeTypeInfo) void {
        _ = self.nodes.append(node); // size_t fits in NodeId by construction; error ignored intentionally for ergonomics.
    }

    pub fn addDiagnostic(self: *Builder, d: diagnostics_mod.Diagnostic) void {
        _ = self.diagnostics.append(d);
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
