//! One-shot project-owned HIR derivation for Zig hosts.

const std = @import("std");
const diagnostics = @import("eligibility.zig");
const limits = @import("limits.zig");
const lower_project = @import("lower_project.zig");
const origin = @import("origin.zig");
const project_mod = @import("../project/root.zig");
const result_mod = @import("result.zig");

pub const Outcome = union(enum) {
    result: *const result_mod.HirResult,
    diagnostics: diagnostics.Report,

    /// Only diagnostics remain caller-owned. Successful HIR belongs to Project.
    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .result => {},
            .diagnostics => |*report| report.deinit(),
        }
        self.* = undefined;
    }
};

pub fn derive(project: *project_mod.Project, configured_limits: limits.Limits) !Outcome {
    return deriveWithDebug(project, configured_limits, .none);
}

pub fn deriveWithDebug(project: *project_mod.Project, configured_limits: limits.Limits, debug_level: origin.DebugLevel) !Outcome {
    if (project.hirResult()) |existing| return .{ .result = existing };

    const finished = try project.finish();
    if (finished.has_failures) return error.ProjectHasFailures;

    var lowered = try lower_project.lowerWithDebug(project.allocator, project, configured_limits, debug_level);
    switch (lowered) {
        .diagnostics => |report| {
            lowered = undefined;
            return .{ .diagnostics = report };
        },
        .result => |result_value| {
            lowered = undefined;
            var result = result_value;
            const installed = project.installHirResult(result) catch |err| {
                result.deinit();
                return err;
            };
            return .{ .result = installed };
        },
    }
}

test "project derives exactly one owned canonical HIR result" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(229),
        .logical_name = "goal229.ts",
        .bytes = "export const answer: number = 42;",
        .kind = .module,
        .revision = 1,
    });
    while (switch (try project.step()) {
        .request => true,
        .complete => false,
    }) return error.UnexpectedModuleRequest;

    var first = try derive(&project, .{});
    defer first.deinit();
    const first_result = first.result;
    try std.testing.expectEqual(first_result, project.hirResult().?);

    var second = try derive(&project, .{});
    defer second.deinit();
    try std.testing.expectEqual(first_result, second.result);
    try std.testing.expectEqual(@as(usize, 1), second.result.project.modules.len);
}

test "project revision invalidates owned HIR before borrowed semantics" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();

    try project.addRoot(.{
        .id = .init(230),
        .logical_name = "goal230.ts",
        .bytes = "export const value = 1;",
        .kind = .module,
        .revision = 1,
    });
    while (try project.step() != .complete) {}

    var outcome = try derive(&project, .{});
    defer outcome.deinit();
    try std.testing.expect(project.hirResult() != null);
    try std.testing.expect(project.semanticResult() != null);

    try project.supplySource(.{
        .id = .init(230),
        .logical_name = "goal230.ts",
        .bytes = "export const value = 2;",
        .kind = .module,
        .revision = 2,
    });
    try std.testing.expect(project.hirResult() == null);
    try std.testing.expect(project.semanticResult() == null);
}
