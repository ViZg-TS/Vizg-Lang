//! Source-derived, host-resolved project graph.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const contracts = @import("contracts.zig");

pub const EdgeState = enum(u32) {
    unresolved,
    resolved,
    external,
    not_found,
    denied,
    failed,
};

pub const DiagnosticCode = enum(u32) {
    module_not_found,
    module_denied,
    module_failed,
    external_missing_export,
};

pub const Edge = struct {
    request_id: contracts.RequestId,
    importer: contracts.ModuleId,
    target: ?contracts.ModuleId = null,
    external_target: ?contracts.ExternalModuleId = null,
    raw_specifier: []const u8,
    operation: contracts.RequestOperation,
    type_only: bool,
    import_kind: ast.ImportKind,
    state: EdgeState = .unresolved,
    span: contracts.SourceSpan,
};

pub const ModuleMetadata = struct {
    id: contracts.ModuleId,
    imports: []const binder.ImportRecord,
    exports: []const binder.ExportRecord,
};

pub const GraphDiagnostic = struct {
    code: DiagnosticCode,
    importer: contracts.ModuleId,
    request_id: contracts.RequestId,
    raw_specifier: []const u8,
    span: contracts.SourceSpan,
};

pub const Checkpoint = struct {
    module_count: usize,
    edge_count: usize,
    diagnostic_count: usize,
};

pub const Limits = struct {
    max_modules: usize = std.math.maxInt(usize),
    max_edges: usize = std.math.maxInt(usize),
    max_diagnostics: usize = std.math.maxInt(usize),
};

pub const DepthMap = std.AutoHashMap(u64, usize);

pub const Graph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(ModuleMetadata) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    diagnostics: std.ArrayList(GraphDiagnostic) = .empty,
    limits: Limits,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Graph {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Graph) void {
        self.modules.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn checkpoint(self: *const Graph) Checkpoint {
        return .{
            .module_count = self.modules.items.len,
            .edge_count = self.edges.items.len,
            .diagnostic_count = self.diagnostics.items.len,
        };
    }

    pub fn rollback(self: *Graph, checkpoint_value: Checkpoint) void {
        self.modules.shrinkRetainingCapacity(checkpoint_value.module_count);
        self.edges.shrinkRetainingCapacity(checkpoint_value.edge_count);
        self.diagnostics.shrinkRetainingCapacity(checkpoint_value.diagnostic_count);
    }

    pub fn recordModule(self: *Graph, metadata: ModuleMetadata) !void {
        for (self.modules.items) |*item| {
            if (item.id == metadata.id) {
                item.* = metadata;
                return;
            }
        }
        if (self.modules.items.len >= self.limits.max_modules) return error.ModuleLimitExceeded;
        try self.modules.append(self.allocator, metadata);
    }

    pub fn ensureEdgeAvailable(self: *const Graph) !void {
        if (self.edges.items.len >= self.limits.max_edges) return error.EdgeLimitExceeded;
    }

    pub fn appendEdge(self: *Graph, edge: Edge) !void {
        try self.ensureEdgeAvailable();
        try self.edges.append(self.allocator, edge);
    }

    pub fn resolve(self: *Graph, request_id: contracts.RequestId, state: EdgeState, target: ?contracts.ModuleId) !void {
        const diagnostic_code: ?DiagnosticCode = switch (state) {
            .not_found => .module_not_found,
            .denied => .module_denied,
            .failed => .module_failed,
            else => null,
        };
        if (diagnostic_code != null) {
            var additions: usize = 0;
            for (self.edges.items) |edge| if (edge.request_id == request_id) {
                additions = std.math.add(usize, additions, 1) catch return error.DiagnosticLimitExceeded;
            };
            if (additions > self.limits.max_diagnostics -| self.diagnostics.items.len)
                return error.DiagnosticLimitExceeded;
        }
        for (self.edges.items) |*edge| {
            if (edge.request_id != request_id) continue;
            edge.state = state;
            edge.target = target;
            edge.external_target = null;
            if (diagnostic_code) |value| try self.diagnostics.append(self.allocator, .{
                .code = value,
                .importer = edge.importer,
                .request_id = request_id,
                .raw_specifier = edge.raw_specifier,
                .span = edge.span,
            });
        }
        // Manually queued host requests do not necessarily have a source edge.
    }

    pub fn resolveExternal(self: *Graph, request_id: contracts.RequestId, target: contracts.ExternalModuleId) void {
        for (self.edges.items) |*edge| {
            if (edge.request_id != request_id) continue;
            edge.state = .external;
            edge.target = null;
            edge.external_target = target;
        }
    }

    pub fn recordMissingExternalExport(self: *Graph, edge: Edge) !void {
        for (self.diagnostics.items) |item| {
            if (item.code == .external_missing_export and item.request_id == edge.request_id and item.span.start == edge.span.start) return;
        }
        if (self.diagnostics.items.len >= self.limits.max_diagnostics) return error.DiagnosticLimitExceeded;
        try self.diagnostics.append(self.allocator, .{
            .code = .external_missing_export,
            .importer = edge.importer,
            .request_id = edge.request_id,
            .raw_specifier = edge.raw_specifier,
            .span = edge.span,
        });
    }

    /// Canonical shortest resolved-edge distance from any root. Relaxation is
    /// explicit so the result remains correct for cycles and any edge order.
    pub fn shortestDepths(self: *const Graph, allocator: std.mem.Allocator, roots: []const contracts.ModuleId) !DepthMap {
        return self.shortestDepthsWithResolution(allocator, roots, null, null);
    }

    /// Compute shortest depths while treating every edge for `request_id` as
    /// resolved to `target`. This permits a response to be rejected before it
    /// mutates either the source set, request state, or graph.
    pub fn shortestDepthsWithResolution(
        self: *const Graph,
        allocator: std.mem.Allocator,
        roots: []const contracts.ModuleId,
        request_id: ?contracts.RequestId,
        target: ?contracts.ModuleId,
    ) !DepthMap {
        var depths = DepthMap.init(allocator);
        errdefer depths.deinit();
        var pending: std.ArrayList(contracts.ModuleId) = .empty;
        defer pending.deinit(allocator);

        for (roots) |root| {
            const result = try depths.getOrPut(root.value());
            if (!result.found_existing) {
                result.value_ptr.* = 0;
                try pending.append(allocator, root);
            }
        }

        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const importer = pending.items[index];
            const importer_depth = depths.get(importer.value()).?;
            const candidate = std.math.add(usize, importer_depth, 1) catch return error.GraphDepthLimitExceeded;
            for (self.edges.items) |edge| {
                if (edge.importer != importer) continue;
                const edge_target = if (request_id != null and edge.request_id == request_id.?)
                    target
                else if (edge.state == .resolved)
                    edge.target
                else
                    null;
                const resolved_target = edge_target orelse continue;
                const result = try depths.getOrPut(resolved_target.value());
                if (result.found_existing and result.value_ptr.* <= candidate) continue;
                result.value_ptr.* = candidate;
                try pending.append(allocator, resolved_target);
            }
        }
        return depths;
    }
};

fn testEdge(request_id: u64, importer: u64, target: ?u64) Edge {
    return .{
        .request_id = .init(request_id),
        .importer = .init(importer),
        .target = if (target) |value| .init(value) else null,
        .raw_specifier = "./dependency",
        .operation = .static_import,
        .type_only = false,
        .import_kind = .side_effect,
        .state = if (target == null) .unresolved else .resolved,
        .span = .{ .start = 0, .end = 1, .line = 1, .column = 0 },
    };
}

test "module edge and diagnostic limits hold their N boundaries" {
    var graph = Graph.initWithLimits(std.testing.allocator, .{
        .max_modules = 1,
        .max_edges = 2,
        .max_diagnostics = 1,
    });
    defer graph.deinit();

    try graph.recordModule(.{ .id = .init(1), .imports = &.{}, .exports = &.{} });
    try std.testing.expectError(error.ModuleLimitExceeded, graph.recordModule(.{
        .id = .init(2),
        .imports = &.{},
        .exports = &.{},
    }));
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);

    try graph.appendEdge(testEdge(1, 1, null));
    try graph.appendEdge(testEdge(2, 1, null));
    try std.testing.expectError(error.EdgeLimitExceeded, graph.appendEdge(testEdge(3, 1, null)));
    try std.testing.expectEqual(@as(usize, 2), graph.edges.items.len);

    try graph.resolve(.init(1), .not_found, null);
    try std.testing.expectError(error.DiagnosticLimitExceeded, graph.resolve(.init(2), .failed, null));
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.len);
    try std.testing.expectEqual(EdgeState.unresolved, graph.edges.items[1].state);
}

test "shortest graph depth is independent of edge order and converges through cycles" {
    const roots = [_]contracts.ModuleId{ .init(1), .init(5) };
    const ordered = [_]Edge{
        testEdge(1, 1, 2),
        testEdge(2, 2, 3),
        testEdge(3, 3, 4),
        testEdge(4, 4, 2),
        testEdge(5, 5, 4),
    };
    const reversed = [_]Edge{
        ordered[4],
        ordered[3],
        ordered[2],
        ordered[1],
        ordered[0],
    };

    var first = Graph.init(std.testing.allocator);
    defer first.deinit();
    for (ordered) |edge| try first.appendEdge(edge);
    var first_depths = try first.shortestDepths(std.testing.allocator, &roots);
    defer first_depths.deinit();

    var second = Graph.init(std.testing.allocator);
    defer second.deinit();
    for (reversed) |edge| try second.appendEdge(edge);
    var second_depths = try second.shortestDepths(std.testing.allocator, &roots);
    defer second_depths.deinit();

    try std.testing.expectEqual(@as(?usize, 0), first_depths.get(1));
    try std.testing.expectEqual(@as(?usize, 1), first_depths.get(2));
    try std.testing.expectEqual(@as(?usize, 2), first_depths.get(3));
    try std.testing.expectEqual(@as(?usize, 1), first_depths.get(4));
    try std.testing.expectEqual(@as(?usize, 0), first_depths.get(5));
    for ([_]u64{ 1, 2, 3, 4, 5 }) |id| {
        try std.testing.expectEqual(first_depths.get(id), second_depths.get(id));
    }
}
