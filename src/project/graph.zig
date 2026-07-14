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
    stale,
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
    kind: contracts.RequestKind,
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

pub const Graph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(ModuleMetadata) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    diagnostics: std.ArrayList(GraphDiagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Graph) void {
        self.modules.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn recordModule(self: *Graph, metadata: ModuleMetadata) !void {
        for (self.modules.items) |*item| {
            if (item.id == metadata.id) {
                item.* = metadata;
                return;
            }
        }
        try self.modules.append(self.allocator, metadata);
    }

    pub fn appendEdge(self: *Graph, edge: Edge) !void {
        try self.edges.append(self.allocator, edge);
    }

    pub fn resolve(self: *Graph, request_id: contracts.RequestId, state: EdgeState, target: ?contracts.ModuleId) !void {
        for (self.edges.items) |*edge| {
            if (edge.request_id != request_id or edge.state == .stale) continue;
            edge.state = state;
            edge.target = target;
            edge.external_target = null;
            const code: ?DiagnosticCode = switch (state) {
                .not_found => .module_not_found,
                .denied => .module_denied,
                .failed => .module_failed,
                else => null,
            };
            if (code) |value| try self.diagnostics.append(self.allocator, .{
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
            if (edge.request_id != request_id or edge.state == .stale) continue;
            edge.state = .external;
            edge.target = null;
            edge.external_target = target;
        }
    }

    pub fn recordMissingExternalExport(self: *Graph, edge: Edge) !void {
        for (self.diagnostics.items) |item| {
            if (item.code == .external_missing_export and item.request_id == edge.request_id and item.span.start == edge.span.start) return;
        }
        try self.diagnostics.append(self.allocator, .{
            .code = .external_missing_export,
            .importer = edge.importer,
            .request_id = edge.request_id,
            .raw_specifier = edge.raw_specifier,
            .span = edge.span,
        });
    }

    pub fn invalidateImporter(self: *Graph, importer: contracts.ModuleId) void {
        for (self.edges.items) |*edge| {
            if (edge.importer == importer) edge.state = .stale;
        }
        var index: usize = 0;
        while (index < self.modules.items.len) {
            if (self.modules.items[index].id == importer) {
                _ = self.modules.orderedRemove(index);
            } else {
                index += 1;
            }
        }
    }
};
