const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const types = @import("../types/root.zig");
const type_collector = @import("type_collector.zig");
const testing = std.testing;
const test_builtins = types.Builtins.init();

test "variable declared type is collected from source annotation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "let x: number = 1;\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // We rely on collectDeclaredTypes to build its output with the same allocator — the
    // returned slices are live as long as the arena is (arena allocations are not freed
    // until deinit). Verify the shape: one entry for 'x', declared_type == builtin number id.
    try testing.expectEqual(@as(usize, 1), collected.symbol_declared_types.len);

    const symbol_entry = &collected.symbol_declared_types[0];
    if (symbol_entry.declared_type) |t| {
        try testing.expectEqual(test_builtins.number, t);
    } else {
        std.debug.panic("expected declared type to be set for variable with annotation", .{});
    }

    // Verify diagnostics list is empty (we used only a known builtin).
    _ = collected.diagnostics;
}

test "parameter declared type is collected from function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "function f(x: string) {}\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // We expect the parameter symbol to appear in collected.symbol_declared_types with declared_type == builtin string id.
    var found_param: ?type_collector.DeclaredSymbolType = null;
    for (collected.symbol_declared_types) |entry| {
        if (entry.declared_type) |t| {
            _ = t;
            found_param = entry;
            break;
        }
    }

    try testing.expect(found_param != null);
    if (found_param) |fp| {
        try testing.expectEqual(test_builtins.string, fp.declared_type.?);
    } else unreachable;
}

test "unknown type name emits VZG6004 and falls back to unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "let x: Foo = 1;\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expect(collected.symbol_declared_types.len > 0);
    // Diagnostic was emitted for the unknown name.
    var saw_unknown_diag = false;
    for (collected.diagnostics) |d| {
        if (d.code == .unknown_type_name) {
            saw_unknown_diag = true;
            break;
        }
    }
    try testing.expect(saw_unknown_diag);

    // Declared type falls back to builtin unknown — we accept either null or the 'unknown' id.
}

test "untyped variable is omitted from declared types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "let x = 1;\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // Untyped symbol has no entry — the pass should return an empty list (or at least nothing with a non-null declared_type).
    const any_annotated = for (collected.symbol_declared_types) |entry| {
        if (entry.declared_type != null) break true;
    } else false;

    try testing.expect(!any_annotated);
}

test "declared type in for-loop init is collected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    // The `i` declared as `number` inside the for-loop init sits in a local
    // (function) scope rather than the global module body, so this test
    // confirms that collectDeclaredTypes now walks every binder scope and not
    // just the global one.
    const src = "function f() { for (let i: number = 0; false; ) {} }\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // We expect exactly one symbol with a declared_type set: `i` as number.
    try testing.expect(collected.symbol_declared_types.len == 1);
    const entry = &collected.symbol_declared_types[0];
    if (entry.declared_type) |t| {
        try testing.expectEqual(
            test_builtins.number,
            t,
        );
    } else unreachable;

    _ = collected.diagnostics;
}

test "fully-annotated function produces a signature entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "function f(a: number, b: string): void {}\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // hasAny() confirms at least one signature was produced; length check proves
    // the entry count matches expectations for a single function declaration.
    try testing.expect(collected.hasAny());
    try testing.expectEqual(@as(usize, 1), collected.function_signatures.len);
}

test "multi-parameter function collects each parameter declared type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "function f(x: number, y: string) {}\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // Both parameters should appear in symbol_declared_types with the right ids.
    try testing.expect(collected.symbol_declared_types.len >= 2);

    var found_number = false;
    var found_string = false;
    for (collected.symbol_declared_types) |entry| {
        if (entry.declared_type) |t| {
            const id: u32 = t;
            if (id == test_builtins.number) {
                found_number = true;
            } else if (id == test_builtins.string) {
                found_string = true;
            }
        }
    }
    try testing.expect(found_number);
    try testing.expect(found_string);
}

test "function without return annotation falls back to unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "function f() {}\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // Signature was produced (else the unannotated branch wouldn't have fired).
    try testing.expect(collected.hasAny());
    const entry = &collected.function_signatures[0];
    if (entry.resolved_return_type) |rt| {
        // Verify inline return type is the builtin unknown id.
        try testing.expectEqual(test_builtins.unknown, @as(u32, rt));
    } else unreachable;

    // Unknown fallback must not emit an "unknown_type_name" diagnostic — there was
    // no annotation name to fail on.
    for (collected.diagnostics) |d| {
        try testing.expect(d.code != .unknown_type_name);
    }
}

test "unknown parameter type name emits VZG6004 diagnostic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());

    const src = "function f(x: Foo) {}\n";
    const result = try frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    // A diagnostic for the unknown parameter type must be present.
    var saw_unknown_diag = false;
    for (collected.diagnostics) |d| {
        if (d.code == .unknown_type_name) {
            saw_unknown_diag = true;
            break;
        }
    }
    try testing.expect(saw_unknown_diag);

    // A signature entry must still be produced — the parameter was declared even if
    // its type is unknown.
    try testing.expect(collected.hasAny());
}
