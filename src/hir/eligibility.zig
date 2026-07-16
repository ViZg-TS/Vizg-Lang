//! Pre-lowering eligibility gate. It never constructs a partial HirResult.

const std = @import("std");
const frontend_diagnostics = @import("../diagnostics/root.zig");
const project_mod = @import("../project/root.zig");
const semantics = @import("../semantics/root.zig");
const types = @import("../types/root.zig");
const diagnostics = @import("diagnostics.zig");
const limits_mod = @import("limits.zig");

pub const Report = struct {
    allocator: std.mem.Allocator,
    diagnostics: []diagnostics.Diagnostic,

    pub fn deinit(self: *Report) void {
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn isEligible(self: Report) bool {
        return self.diagnostics.len == 0;
    }
};

/// Examines the completed active Project and its borrowed project semantics.
/// Callers may construct HirResult only when the returned report is eligible.
pub fn check(
    allocator: std.mem.Allocator,
    project: *const project_mod.Project,
    configured_limits: limits_mod.Limits,
) !Report {
    var output: std.ArrayList(diagnostics.Diagnostic) = .empty;
    errdefer output.deinit(allocator);
    var budget = limits_mod.Budget.init(configured_limits);

    if (budget.reserve(.input_modules, project.modules.items.len)) |violation| {
        try output.append(allocator, diagnostics.Diagnostic.fromLimit(violation));
        return .{ .allocator = allocator, .diagnostics = try output.toOwnedSlice(allocator) };
    }

    const project_semantics = project.semanticResult() orelse {
        try output.append(allocator, .{ .code = .not_eligible });
        return .{ .allocator = allocator, .diagnostics = try output.toOwnedSlice(allocator) };
    };

    for (project.modules.items) |module| {
        const source = module.source orelse continue;
        if (budget.reserve(.input_source_bytes, source.bytes.len)) |violation| {
            try output.append(allocator, diagnosticForModule(module, diagnostics.Diagnostic.fromLimit(violation)));
            continue;
        }
        const local = module.semantic_result orelse {
            try output.append(allocator, diagnosticForModule(module, .{ .code = .not_eligible }));
            continue;
        };
        if (budget.reserve(.input_ast_nodes, local.frontend.ast.nodes.len)) |violation| {
            try output.append(allocator, diagnosticForModule(module, diagnostics.Diagnostic.fromLimit(violation)));
        }
        if (module.state != .complete or local.metadata.is_partial) {
            try appendUnique(&output, allocator, diagnosticForModule(module, .{ .code = .not_eligible }));
        }
        for (local.diagnostics) |item| {
            if (item.severity != .@"error") continue;
            const code: diagnostics.Code = if (isUnsupported(item.code)) .unsupported_executable_syntax else .not_eligible;
            try appendUnique(&output, allocator, .{
                .code = code,
                .module_id = module.id.value(),
                .path = source.logical_name,
                .span = item.span,
            });
        }
        try validateLocalIdentities(&output, allocator, module, local, project_semantics);
    }

    for (project_semantics.diagnostics) |item| {
        if (item.severity != .@"error") continue;
        try appendUnique(&output, allocator, .{
            .code = if (isUnsupported(item.code)) .unsupported_executable_syntax else .not_eligible,
            .path = item.path,
            .span = item.span,
        });
    }
    if (project_semantics.is_partial) try appendUnique(&output, allocator, .{ .code = .not_eligible });

    try validateProjectIdentities(&output, allocator, project, project_semantics);
    return .{ .allocator = allocator, .diagnostics = try output.toOwnedSlice(allocator) };
}

fn validateLocalIdentities(
    output: *std.ArrayList(diagnostics.Diagnostic),
    allocator: std.mem.Allocator,
    module: project_mod.ProjectModule,
    local: *const semantics.SemanticResult,
    project_semantics: *const semantics.BorrowedProjectSemanticResult,
) !void {
    for (local.frontend.bind.symbols) |symbol| {
        if (@as(usize, @intCast(symbol.declaration)) >= local.frontend.ast.nodes.len or
            @as(usize, @intCast(symbol.scope)) >= local.frontend.bind.scopes.len)
        {
            try appendInvalid(output, allocator, module);
        }
    }
    const project_info = project_semantics.lookupModule(module.id.value()) orelse {
        try appendInvalid(output, allocator, module);
        return;
    };
    for (project_info.type_info.symbols) |entry| {
        if (!hasSymbol(local, entry.symbol_id) or !validOptionalType(project_semantics, entry.declared_type) or
            !validOptionalType(project_semantics, entry.inferred_type))
        {
            try appendInvalid(output, allocator, module);
        }
    }
    for (project_info.type_info.nodes) |entry| {
        if (@as(usize, @intCast(entry.node_id)) >= local.frontend.ast.nodes.len or
            !validType(project_semantics, entry.type_id) or
            !validOptionalType(project_semantics, entry.receiver_type) or
            !validOptionalType(project_semantics, entry.contextual_type))
        {
            try appendInvalid(output, allocator, module);
        }
    }
}

fn validateProjectIdentities(
    output: *std.ArrayList(diagnostics.Diagnostic),
    allocator: std.mem.Allocator,
    project: *const project_mod.Project,
    result: *const semantics.BorrowedProjectSemanticResult,
) !void {
    for (result.modules, 0..) |module, index| {
        if (project.lookup(.init(module.id)) == null) try appendUnique(output, allocator, .{ .code = .invalid_semantic_reference, .module_id = module.id, .path = module.path });
        for (result.modules[index + 1 ..]) |other| if (other.id == module.id) {
            try appendUnique(output, allocator, .{ .code = .invalid_semantic_reference, .module_id = module.id, .path = module.path });
        };
    }
    for (result.imports) |item| {
        if (item.state == .unresolved or item.state == .cyclic_partial) {
            try appendUnique(output, allocator, .{ .code = .not_eligible, .module_id = item.module_id, .span = item.span });
            continue;
        }
        const target = item.target orelse {
            try appendUnique(output, allocator, .{ .code = .missing_semantic_identity, .module_id = item.module_id, .span = item.span });
            continue;
        };
        if (!validIdentity(project, result, target, target.external_module_id != null)) {
            try appendUnique(output, allocator, .{ .code = .invalid_semantic_reference, .module_id = item.module_id, .span = item.span });
        }
    }
    for (result.exports) |item| if (!validIdentity(project, result, item.identity, false)) {
        try appendUnique(output, allocator, .{ .code = .invalid_semantic_reference, .module_id = item.module_id, .span = item.span });
    };
}

fn validIdentity(project: *const project_mod.Project, result: *const semantics.BorrowedProjectSemanticResult, identity: semantics.SemanticIdentity, external: bool) bool {
    if (!validType(result, identity.type_id)) return false;
    if (identity.external_module_id) |module_id| {
        const descriptor = project.lookupExternalModule(.init(module_id)) orelse return false;
        const symbol_id = identity.external_symbol_id orelse {
            return !external and identity.external_declaration_kind == null and
                identity.external_effects == null;
        };
        if (identity.external_declaration_kind == null or identity.external_effects == null) return false;
        for (descriptor.exports) |item| {
            if (item.symbol_id != null and item.symbol_id.?.value() == symbol_id and
                item.declaration_kind == identity.external_declaration_kind and item.effects == identity.external_effects) return true;
        }
        return false;
    }
    if (external) return false;
    if (identity.external_symbol_id != null or identity.external_declaration_kind != null or identity.external_effects != null) return false;
    if (result.lookupModule(identity.declaration.module_id) == null) return false;
    if (project.lookup(.init(identity.declaration.module_id))) |module| {
        const local = module.semantic_result orelse return false;
        if (identity.symbol_id) |symbol_id| return hasSymbol(local, symbol_id);
        return identity.namespace == .type;
    }
    return false;
}

fn validType(result: *const semantics.BorrowedProjectSemanticResult, type_id: types.TypeId) bool {
    return type_id != types.invalid_type and result.type_store.lookup(type_id) != null;
}

fn validOptionalType(result: *const semantics.BorrowedProjectSemanticResult, type_id: ?types.TypeId) bool {
    return if (type_id) |id| validType(result, id) else true;
}

fn hasSymbol(local: *const semantics.SemanticResult, id: u32) bool {
    for (local.frontend.bind.symbols) |symbol| if (symbol.id == id) return true;
    return false;
}

fn isUnsupported(code: frontend_diagnostics.DiagnosticCode) bool {
    return code == .unsupported_syntax or code == .unsupported_ts_syntax or code == .unsupported_jsx;
}

fn diagnosticForModule(module: project_mod.ProjectModule, diagnostic: diagnostics.Diagnostic) diagnostics.Diagnostic {
    var result = diagnostic;
    result.module_id = module.id.value();
    result.path = if (module.source) |source| source.logical_name else null;
    return result;
}

fn appendInvalid(output: *std.ArrayList(diagnostics.Diagnostic), allocator: std.mem.Allocator, module: project_mod.ProjectModule) !void {
    try appendUnique(output, allocator, diagnosticForModule(module, .{ .code = .invalid_semantic_reference }));
}

fn appendUnique(output: *std.ArrayList(diagnostics.Diagnostic), allocator: std.mem.Allocator, item: diagnostics.Diagnostic) !void {
    for (output.items) |existing| {
        if (existing.code == item.code and existing.module_id == item.module_id and existing.limit == null and item.limit == null) return;
    }
    try output.append(allocator, item);
}
