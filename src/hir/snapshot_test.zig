const std = @import("std");
const hir = @import("root.zig");
const project_mod = @import("../project/root.zig");

fn snapshotProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(228),
        .logical_name = "not-an-identity.ts",
        .bytes =
        \\interface Erased { value: number }
        \\const x = 1;
        \\const y = x && 2;
        \\function f(a: number = 3): number { return a ? y : x; }
        \\const z = { value: f(), ...{ other: 4 } };
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

test "canonical printer is deterministic and modes are independent" {
    var project = try snapshotProject();
    defer project.deinit();
    var lowered = switch (try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .full)) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    const first = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .canonical);
    defer std.testing.allocator.free(first);
    const second = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .canonical);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "0x") == null);

    const typed = try hir.printAllocOptions(std.testing.allocator, &lowered.project, lowered.identity_domain, .{ .types = true });
    defer std.testing.allocator.free(typed);
    const originated = try hir.printAllocOptions(std.testing.allocator, &lowered.project, lowered.identity_domain, .{ .origins = true });
    defer std.testing.allocator.free(originated);
    try std.testing.expect(std.mem.indexOf(u8, typed, " type=") != null);
    try std.testing.expect(std.mem.indexOf(u8, typed, "origin=") == null);
    try std.testing.expect(std.mem.indexOf(u8, originated, "origin=") != null);
    try std.testing.expect(std.mem.indexOf(u8, originated, "trace ") == null);

    const traced = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .with_full_trace);
    defer std.testing.allocator.free(traced);
    try std.testing.expect(std.mem.indexOf(u8, traced, "trace interface_erased") != null);
}

test "printer controls invalid and foreign IDs without dereferencing them" {
    var first = try snapshotProject();
    defer first.deinit();
    var second = try snapshotProject();
    defer second.deinit();
    var left = switch (try hir.lowerProject(std.testing.allocator, &first, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer left.deinit();
    var right = switch (try hir.lowerProject(std.testing.allocator, &second, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer right.deinit();

    const saved = left.project.functions[0].entry;
    @constCast(&left.project.functions[0]).entry = .invalid;
    var text = try hir.printAlloc(std.testing.allocator, &left.project, left.identity_domain, .canonical);
    try std.testing.expect(std.mem.indexOf(u8, text, "entry=<invalid>") != null);
    std.testing.allocator.free(text);

    @constCast(&left.project.functions[0]).entry = right.project.functions[0].entry;
    text = try hir.printAlloc(std.testing.allocator, &left.project, left.identity_domain, .canonical);
    try std.testing.expect(std.mem.indexOf(u8, text, "entry=<foreign:") != null);
    std.testing.allocator.free(text);
    @constCast(&left.project.functions[0]).entry = saved;
}
