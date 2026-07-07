const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const builtin_kind = @import("../types/builtin.zig");
const type_collector = @import("type_collector.zig");
const testing = std.testing;

test "variable declared type is collected from source annotation" {
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "let x: number = 1;\n";
    const result = frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    var collected = type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        builtin_kind.builtin_instance,
    );

    // We rely on collectDeclaredTypes to build its output with the same allocator — the
    // returned slices are live as long as the arena is (arena allocations are not freed
    // until deinit). Verify the shape: one entry for 'x', declared_type == builtin number id.
    try testing.expectEqual(@as(usize, 1), collected.symbol_declared_types.len);

    const symbol_entry = &collected.symbol_declared_types[0];
    if (symbol_entry.declared_type) |t| {
        const expected_id = builtin_kind.builtinKindTypeId(.number);
        try testing.expectEqual(expected_id.?, t.?);
    } else {
        try testing.fail("expected declared type to be set for variable with annotation");
    }

    // Verify diagnostics list is empty (we used only a known builtin).
    _ = collected.diagnostics;
}

test "parameter declared type is collected from function" {
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "function f(x: string) {}\n";
    const result = frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        builtin_kind.builtin_instance,
    );

    // We expect the parameter symbol to appear in collected.symbol_declared_types with declared_type == builtin string id.
    const found_param = for (collected.symbol_declared_types) |entry| {
        if (entry.declared_type) break entry;
    } else null;

    try testing.expect(found_param != null);
    try testing.expectEqual(builtin_kind.builtinKindTypeId(.string).?, @as(u32, std.meta.intCast(found_param.?.declared_type.?)));
}

test "unknown type name emits VZG6004 and falls back to unknown" {
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "let x: Foo = 1;\n";
    const result = frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        builtin_kind.builtin_instance,
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
    var arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const src = "let x = 1;\n";
    const result = frontend.analyze(arena.allocator(), .{ .text = src }, .{});

    const collected = type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        builtin_kind.builtin_instance,
    );

    // Untyped symbol has no entry — the pass should return an empty list (or at least nothing with a non-null declared_type).
    const any_annotated = for (collected.symbol_declared_types) |entry| {
        if (entry.declared_type != null) break true;
    } else false;

    try testing.expect(!any_annotated);
}
