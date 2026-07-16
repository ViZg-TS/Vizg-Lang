const std = @import("std");
const hir = @import("root.zig");
const project_mod = @import("../project/root.zig");

fn finishSource(id: u64, name: []const u8, source: []const u8) !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{ .id = .init(id), .logical_name = name, .bytes = source });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn stressSource(allocator: std.mem.Allocator, depth: usize, width: usize) ![]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, "export function stress(input: any, items: any[]): any { let value = ");
    for (0..depth) |_| try source.append(allocator, '(');
    try source.appendSlice(allocator, "input ?? 0");
    for (0..depth) |_| try source.append(allocator, ')');
    try source.appendSlice(allocator, "; input.value ||= input?.fallback ?? 0;");
    for (0..width) |index| {
        const statement = try std.fmt.allocPrint(allocator, " value = value + {d};", .{index});
        defer allocator.free(statement);
        try source.appendSlice(allocator, statement);
    }
    try source.appendSlice(allocator, " switch (value) {");
    for (0..width) |index| {
        const clause = try std.fmt.allocPrint(allocator, " case {d}: value += {d}; break;", .{ index, index + 1 });
        defer allocator.free(clause);
        try source.appendSlice(allocator, clause);
    }
    try source.appendSlice(allocator, " default: value = 0; }");
    for (0..depth) |_| try source.appendSlice(allocator, " try {");
    try source.appendSlice(allocator, " value += 1;");
    for (0..depth) |_| try source.appendSlice(allocator, " } finally { value += 1; }");
    try source.appendSlice(allocator, " outer: for (const item of items) { inner: while (item) { if (value) break outer; continue inner; } break; }" ++
        " for (const item of items) { if (item) break; continue; } return value; }");
    return source.toOwnedSlice(allocator);
}

test "all HIR budgets reject pre-growth without mutation and map to VZG7010" {
    inline for (@typeInfo(hir.LimitKind).@"enum".fields) |field| {
        const kind: hir.LimitKind = @enumFromInt(field.value);
        var configured: hir.Limits = .{};
        @field(configured, field.name) = 2;
        var budget = hir.Budget.init(configured);
        try std.testing.expect(budget.reserve(kind, 2) == null);
        const before = budget.usage.value(kind);
        const violation = budget.reserve(kind, 1).?;
        try std.testing.expectEqual(before, budget.usage.value(kind));
        try std.testing.expectEqual(@as(usize, 3), violation.attempted);
        const diagnostic = hir.Diagnostic.fromLimit(violation);
        try std.testing.expectEqualStrings("VZG7010", hir.diagnostics.codeId(diagnostic.code));
        _ = budget.reserve(kind, std.math.maxInt(usize)).?;
        try std.testing.expectEqual(before, budget.usage.value(kind));
    }
}

test "deep wide HIR lowering is bounded reproducible and traceable" {
    const source = try stressSource(std.testing.allocator, 24, 96);
    defer std.testing.allocator.free(source);
    var project = try finishSource(2300, "goal230-stress.ts", source);
    defer project.deinit();

    var outcome = try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .full);
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    try std.testing.expect(result.project.functions.len != 0);
    try std.testing.expect(result.project.origins.records.len > 100);
    try std.testing.expect(result.project.lowering_trace.?.events.len > 100);

    const first = try hir.printAlloc(std.testing.allocator, &result.project, result.identity_domain, .with_full_trace);
    defer std.testing.allocator.free(first);
    const second = try hir.printAlloc(std.testing.allocator, &result.project, result.identity_domain, .with_full_trace);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "nested cleanup depth fails as VZG7010 before HIR escapes" {
    const source = try stressSource(std.testing.allocator, 8, 2);
    defer std.testing.allocator.free(source);
    var project = try finishSource(2301, "goal230-region-limit.ts", source);
    defer project.deinit();
    var configured: hir.Limits = .{};
    configured.region_nesting = 4;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, configured);
    defer outcome.deinit();
    const report = switch (outcome) {
        .result => return error.UnexpectedLoweringSuccess,
        .diagnostics => |*value| value,
    };
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(hir.LimitKind.region_nesting, report.diagnostics[0].limit.?.kind);
    try std.testing.expectEqualStrings("VZG7010", hir.diagnostics.codeId(report.diagnostics[0].code));
}

test "wide module cycle closes and lowers once per module" {
    const module_count = 16;
    const root_source = try std.fmt.allocPrint(std.testing.allocator, "import './m1'; export const value0 = 0;", .{});
    defer std.testing.allocator.free(root_source);
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{ .id = .init(8000), .logical_name = "m0.ts", .bytes = root_source });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            const index = try std.fmt.parseInt(usize, request.raw_specifier[3..], 10);
            if (index == 0) {
                try project.respondSource(request.id, .{ .id = .init(8000), .logical_name = "m0.ts", .bytes = root_source });
                continue;
            }
            const next = (index + 1) % module_count;
            const name = try std.fmt.allocPrint(std.testing.allocator, "m{d}.ts", .{index});
            defer std.testing.allocator.free(name);
            const bytes = try std.fmt.allocPrint(std.testing.allocator, "import './m{d}'; export const value{d} = {d};", .{ next, index, index });
            defer std.testing.allocator.free(bytes);
            try project.respondSource(request.id, .{ .id = .init(8000 + index), .logical_name = name, .bytes = bytes });
        },
    };
    try std.testing.expect(!(try project.finish()).has_failures);
    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    try std.testing.expectEqual(@as(usize, module_count), result.project.modules.len);
}

test "deterministic expression mutation corpus always produces verified canonical HIR" {
    const expressions = [_][]const u8{
        "a + b * 2",               "a ? b : 3", "a && b || 4", "a ?? b",  "[a, , b]",
        "({ a, b, ...{ c: 3 } })", "a?.value",  "typeof a",    "a === b", "(a, b, 5)",
    };
    for (expressions, 0..) |expression, seed| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "export function property{d}(a: any, b: any): any {{ let x = {s}; x += {d}; return x; }}",
            .{ seed, expression, seed },
        );
        defer std.testing.allocator.free(source);
        var project = try finishSource(9000 + seed, "goal230-property.ts", source);
        defer project.deinit();
        var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
        defer outcome.deinit();
        const result = switch (outcome) {
            .result => |*value| value,
            .diagnostics => return error.UnexpectedLoweringFailure,
        };
        const first = try hir.printAlloc(std.testing.allocator, &result.project, result.identity_domain, .canonical);
        defer std.testing.allocator.free(first);
        const second = try hir.printAlloc(std.testing.allocator, &result.project, result.identity_domain, .canonical);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    }
}
