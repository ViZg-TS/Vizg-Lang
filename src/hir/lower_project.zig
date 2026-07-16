//! Project eligibility and deterministic HIR shell construction.

const std = @import("std");
const builder_mod = @import("builder.zig");
const canonicalize = @import("canonicalize.zig");
const diagnostics = @import("diagnostics.zig");
const eligibility = @import("eligibility.zig");
const limits_mod = @import("limits.zig");
const lower_module = @import("lower_module.zig");
const project_mod = @import("../project/root.zig");
const provenance = @import("provenance.zig");
const result_mod = @import("result.zig");
const origin = @import("origin.zig");
const verifier = @import("verifier.zig");

pub const Outcome = union(enum) {
    result: result_mod.HirResult,
    diagnostics: eligibility.Report,

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .result => |*result| result.deinit(),
            .diagnostics => |*report| report.deinit(),
        }
        self.* = undefined;
    }
};

pub fn lower(allocator: std.mem.Allocator, project: *const project_mod.Project, configured_limits: limits_mod.Limits) !Outcome {
    return lowerWithDebug(allocator, project, configured_limits, .none);
}

pub fn lowerWithDebug(allocator: std.mem.Allocator, project: *const project_mod.Project, configured_limits: limits_mod.Limits, debug_level: origin.DebugLevel) !Outcome {
    var report = try eligibility.check(allocator, project, configured_limits);
    if (!report.isEligible()) return .{ .diagnostics = report };
    report.deinit();

    var result = try result_mod.HirResult.initEmpty(allocator, project.semanticResult().?);
    errdefer result.deinit();
    var builder = builder_mod.Builder.initWithDebug(&result, configured_limits, debug_level);

    var reachable: std.ArrayList(project_mod.ModuleId) = .empty;
    defer reachable.deinit(allocator);
    for (project.modules.items) |module| if (module.is_root and module.source != null) try appendUnique(&reachable, allocator, module.id);
    var cursor: usize = 0;
    while (cursor < reachable.items.len) : (cursor += 1) {
        const current = reachable.items[cursor];
        for (project.edges()) |edge| {
            if (edge.importer != current or edge.state != .resolved) continue;
            if (edge.target) |target| try appendUnique(&reachable, allocator, target);
        }
    }
    std.mem.sort(project_mod.ModuleId, reachable.items, {}, lessModuleId);

    for (reachable.items) |module_id| {
        const module = project.lookup(module_id) orelse unreachable;
        lower_module.lower(&builder, project, module) catch |err| switch (err) {
            error.ResourceLimit => {
                const failure = try limitReport(allocator, builder.violation.?);
                result.deinit();
                return .{ .diagnostics = failure };
            },
            else => return err,
        };
    }
    provenance.attach(&builder, project) catch |err| switch (err) {
        error.ResourceLimit => {
            const failure = try limitReport(allocator, builder.violation.?);
            result.deinit();
            return .{ .diagnostics = failure };
        },
        else => return err,
    };
    if (try verifier.verifyBuilder(allocator, &builder, .raw)) |code| {
        const failure = try verifierReport(allocator, code);
        result.deinit();
        return .{ .diagnostics = failure };
    }
    canonicalize.run(&builder) catch |err| switch (err) {
        error.CanonicalizationBudget => {
            const failure = try canonicalizationReport(allocator);
            result.deinit();
            return .{ .diagnostics = failure };
        },
        error.ResourceLimit => {
            const failure = try limitReport(allocator, builder.violation.?);
            result.deinit();
            return .{ .diagnostics = failure };
        },
        else => return err,
    };
    if (try verifier.verifyBuilder(allocator, &builder, .canonical)) |code| {
        const failure = try verifierReport(allocator, code);
        result.deinit();
        return .{ .diagnostics = failure };
    }
    try builder.finish();
    return .{ .result = result };
}

fn verifierReport(allocator: std.mem.Allocator, code: diagnostics.Code) !eligibility.Report {
    const items = try allocator.alloc(diagnostics.Diagnostic, 1);
    items[0] = .{ .code = code };
    return .{ .allocator = allocator, .diagnostics = items };
}

fn canonicalizationReport(allocator: std.mem.Allocator) !eligibility.Report {
    const items = try allocator.alloc(diagnostics.Diagnostic, 1);
    items[0] = .{ .code = .canonicalization_budget };
    return .{ .allocator = allocator, .diagnostics = items };
}

fn limitReport(allocator: std.mem.Allocator, violation: limits_mod.Violation) !eligibility.Report {
    const items = try allocator.alloc(diagnostics.Diagnostic, 1);
    items[0] = diagnostics.Diagnostic.fromLimit(violation);
    return .{ .allocator = allocator, .diagnostics = items };
}

fn appendUnique(items: *std.ArrayList(project_mod.ModuleId), allocator: std.mem.Allocator, id: project_mod.ModuleId) !void {
    for (items.items) |existing| if (existing == id) return;
    try items.append(allocator, id);
}

fn lessModuleId(_: void, left: project_mod.ModuleId, right: project_mod.ModuleId) bool {
    return left.value() < right.value();
}
