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

// ---------------------------------------------------------------------------
// Goal 012 — Preserve global source identity in HIR.
//
// Binding contract: Goal 010 §10.1–10.9 and §10.7.  A standard global exported
// from a global source module must lower as an ordinary source-backed import
// binding: it carries the source ModuleId, export name, declaration identity,
// TypeId, and a module-initialization dependency edge, and it never receives a
// `host_binding_id` merely because it is globally visible.  `console.log(...)`
// lowers as an ordinary `call_method` with no standard operation identity.
// ---------------------------------------------------------------------------

fn goal012Project() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addGlobalRoot(.{
        .id = .init(0),
        .logical_name = "std.ts",
        .bytes =
        \\export const console = {
        \\    log: (value: number) => { /* native bridge */ },
        \\};
        ,
    });
    try project.addRoot(.{
        .id = .init(1),
        .logical_name = "main.ts",
        .bytes = "console.log(42);",
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

test "goal012: source global lowers as ordinary import without host_binding_id" {
    var project = try goal012Project();
    defer project.deinit();
    var lowered = switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    // Locate the application module (ModuleId 1) and its console import.
    var app_module: ?@TypeOf(lowered.project.modules[0]) = null;
    for (lowered.project.modules) |module| {
        if (module.module_id.value() == 1) app_module = module;
    }
    try std.testing.expect(app_module != null);

    var console_import: ?@TypeOf(app_module.?.imports[0]) = null;
    for (app_module.?.imports) |import_binding| {
        if (std.mem.eql(u8, import_binding.exported_name, "console")) console_import = import_binding;
    }
    try std.testing.expect(console_import != null);
    const ci = console_import.?;

    // §10.7: source ModuleId — the import source is the global source module.
    try std.testing.expect(ci.source == .source);
    try std.testing.expectEqual(@as(u64, 0), ci.source.source.value());

    // §10.7: declaration identity — target declaration points at the source module.
    try std.testing.expectEqual(@as(u64, 0), ci.target.declaration.module_id);

    // §10.7: TypeId — the semantic type is preserved (not unknown).
    const builtin_unknown = lowered.type_store.?.builtins.unknown;
    try std.testing.expect(ci.target.type_id != builtin_unknown);

    // §10.7: no host_binding_id merely because globally visible.
    try std.testing.expectEqual(@as(?u64, null), ci.target.host_binding_id);

    // The local HIR binding for the import is live at entry and host-id-free.
    try std.testing.expect(ci.local != null);
    var local_binding: ?@TypeOf(lowered.project.functions[0].bindings[0]) = null;
    for (lowered.project.functions) |function| {
        for (function.bindings) |binding| {
            if (hir.ids.BindingId.eql(binding.id, ci.local.?)) local_binding = binding;
        }
    }
    try std.testing.expect(local_binding != null);
    const lb = local_binding.?;
    try std.testing.expectEqualStrings("console", lb.name);
    try std.testing.expect(lb.kind == .import);
    try std.testing.expect(lb.initial_state == .live_import);
    try std.testing.expectEqual(@as(?u64, null), lb.host_binding_id);
}

test "goal012: referencing module depends on global source module initialization" {
    var project = try goal012Project();
    defer project.deinit();
    var lowered = switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    var app_module: ?@TypeOf(lowered.project.modules[0]) = null;
    for (lowered.project.modules) |module| {
        if (module.module_id.value() == 1) app_module = module;
    }
    try std.testing.expect(app_module != null);

    // §10.7: module-initialization dependency — the app module must depend on
    // the global source module (ModuleId 0) with initialization_required.
    var found_dependency = false;
    for (app_module.?.dependencies) |dependency| {
        if (dependency.module_id.value() == 0) {
            try std.testing.expect(dependency.initialization_required);
            // This edge records source-backed provider provenance. It is not
            // an unconditional ESM module-evaluation edge.
            try std.testing.expect(!dependency.module_evaluation);
            found_dependency = true;
        }
    }
    try std.testing.expect(found_dependency);
}

test "goal012: unused global source modules do not become initialization dependencies" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.registerSourceLanguageItems(&.{.{
        .id = .init(1),
        .module_id = .init(2),
        .exported_name = "Object",
        .namespace = .value,
    }});
    try project.addGlobalRoot(.{
        .id = .init(0),
        .logical_name = "console.ts",
        .bytes = "export const console = 1;",
    });
    try project.addGlobalRoot(.{
        .id = .init(2),
        .logical_name = "object.ts",
        .bytes = "export const Object = 2;",
    });
    try project.addRoot(.{
        .id = .init(1),
        .logical_name = "main.ts",
        .bytes = "console;",
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var lowered = switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    const app_module = for (lowered.project.modules) |module| {
        if (module.module_id.value() == 1) break module;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), lowered.project.modules.len);
    for (lowered.project.modules) |module|
        try std.testing.expect(module.module_id.value() != 2);
    try std.testing.expectEqual(@as(usize, 1), lowered.project.language_items.len);
    try std.testing.expectEqual(@as(u64, 2), lowered.project.language_items[0].target.declaration.module_id);
    try std.testing.expectEqual(@as(usize, 1), app_module.dependencies.len);
    try std.testing.expectEqual(@as(u64, 0), app_module.dependencies[0].module_id.value());
    try std.testing.expectEqual(@as(usize, 1), app_module.imports.len);
    try std.testing.expectEqualStrings("console", app_module.imports[0].exported_name);
}

test "goal012: console.log lowers as ordinary call_method without standard operation" {
    var project = try goal012Project();
    defer project.deinit();
    var lowered = switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();
    const text = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .canonical);
    defer std.testing.allocator.free(text);

    // Normal call/property semantics: console.log(...) lowers as call_method.
    try std.testing.expect(std.mem.indexOf(u8, text, "call_method") != null);

    // No standard operation identity exists in the HIR model.
    try std.testing.expect(std.mem.indexOf(u8, text, "standard_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "standard_operation") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "host_call") == null);
}

test "goal012: console.log reference carries source origin and span" {
    var project = try goal012Project();
    defer project.deinit();
    // Origin/span provenance is attached by the post-lowering provenance pass,
    // which runs for non-`.none` debug levels.  Use `.minimal` so the pass
    // records source spans without forcing full trace events.
    var lowered = switch (try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .minimal)) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    var app_module: ?@TypeOf(lowered.project.modules[0]) = null;
    for (lowered.project.modules) |module| {
        if (module.module_id.value() == 1) app_module = module;
    }
    try std.testing.expect(app_module != null);

    // The app module's initialization function holds the lowered `console.log(42)`.
    var init_fn: ?@TypeOf(lowered.project.functions[0]) = null;
    for (lowered.project.functions) |function| {
        if (hir.ids.FunctionId.eql(function.id, app_module.?.initialization)) init_fn = function;
    }
    try std.testing.expect(init_fn != null);

    // §10.7: origin/span — the `call_method` referencing the source global must
    // carry a real source provenance record tied to the referencing module.
    var call_instruction: ?@TypeOf(init_fn.?.blocks[0].instructions[0]) = null;
    for (init_fn.?.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.operation == .call_method) call_instruction = instruction;
        }
    }
    try std.testing.expect(call_instruction != null);
    const call = call_instruction.?;
    try std.testing.expect(call.origin.isValidFor(lowered.identity_domain));
    const origin_record = lowered.project.origins.lookup(call.origin) orelse
        return error.MissingOriginRecord;
    try std.testing.expectEqual(@as(u64, 1), origin_record.module_id.value());
    try std.testing.expect(origin_record.primary_span.end > origin_record.primary_span.start);
}
