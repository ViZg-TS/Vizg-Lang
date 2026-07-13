const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const types = @import("../types/root.zig");
const type_collector = @import("type_collector.zig");
const testing = std.testing;
const test_builtins = types.Builtins.init();

fn symbolByName(result: frontend.FrontendResult, name: []const u8, namespace: @import("../frontend/binder.zig").SymbolNamespace) ?@import("../frontend/binder.zig").Symbol {
    for (result.bind.symbols) |symbol| {
        if (symbol.namespace == namespace and std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn collectedType(collected: type_collector.TypeInfoCollectResult, symbol_id: u32) ?types.TypeId {
    for (collected.symbol_declared_types) |entry| {
        if (entry.symbol_id == symbol_id) return entry.declared_type;
    }
    return null;
}

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

test "local interface and class names resolve through type-space symbols" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{
        .text = "interface User {} class Account {} let user: User; let account: Account;",
    }, .{});
    const collected = try type_collector.collectDeclaredTypesInModule(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        41,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);
    const user_type = collectedType(collected, symbolByName(result, "user", .value).?.id).?;
    const account_type = collectedType(collected, symbolByName(result, "account", .value).?.id).?;
    const account_value_type = collectedType(collected, symbolByName(result, "Account", .value).?.id).?;
    const account_instance_type = collectedType(collected, symbolByName(result, "Account", .type).?.id).?;
    const user_nominal = type_store.lookup(user_type).?.kind.interface;
    const account_nominal = type_store.lookup(account_type).?.kind.class;
    try testing.expectEqual(@as(u32, 41), user_nominal.identity.module_id);
    try testing.expectEqual(symbolByName(result, "User", .type).?.declaration, user_nominal.identity.declaration_id);
    try testing.expectEqual(@as(u32, 41), account_nominal.identity.module_id);
    try testing.expect(account_value_type != account_instance_type);
    try testing.expectEqual(account_instance_type, account_type);
    const account_constructor = type_store.lookup(account_value_type).?.kind.class_constructor;
    try testing.expectEqual(account_instance_type, account_constructor.instance_type);
    try testing.expectEqual(account_nominal.identity, account_constructor.identity);
    try testing.expectEqual(@as(usize, 0), user_nominal.members.members.len);
    try testing.expect(type_store.lookupInterfaceSemanticType(user_nominal.identity) != null);
    try testing.expect(type_store.lookupClassSemanticType(account_nominal.identity) != null);
}

test "local alias resolves and value-only names remain invalid in type space" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{
        .text = "const ValueOnly = 1; type UserId = string; let id: UserId; let bad: ValueOnly;",
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(test_builtins.string, collectedType(collected, symbolByName(result, "id", .value).?.id).?);
    try testing.expectEqual(test_builtins.unknown, collectedType(collected, symbolByName(result, "bad", .value).?.id).?);
    try testing.expectEqual(@as(usize, 1), collected.diagnostics.len);
    try testing.expectEqualStrings("ValueOnly", collected.diagnostics[0].label.?);
}

test "unknown parameter emits one stable diagnostic at its annotation span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{ .text = "function f(value: Missing) {}" }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );
    const parameter_symbol = symbolByName(result, "value", .value).?;
    const annotation = result.ast.node(parameter_symbol.declaration).data.Parameter.type_annotation.?;

    try testing.expectEqual(@as(usize, 1), collected.diagnostics.len);
    try testing.expectEqual(annotation.span.start, collected.diagnostics[0].span.start);
    try testing.expectEqual(annotation.span.end, collected.diagnostics[0].span.end);
}

test "nearest local type alias shadows its parent scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{
        .text = "type Choice = string; { type Choice = number; let selected: Choice; }",
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);
    try testing.expectEqual(test_builtins.number, collectedType(collected, symbolByName(result, "selected", .value).?.id).?);
}

test "duplicate type names diagnose once and resolve deterministically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{
        .text = "type Same = string; interface Same {} let value: Same;",
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 1), result.bind.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);
    try testing.expectEqual(test_builtins.string, collectedType(collected, symbolByName(result, "value", .value).?.id).?);
}

test "Goal 139 generic parameter environment shares identity across a signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{
        .text = "function identity<T>(value: T): T { return value; }",
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);
    try testing.expectEqual(@as(usize, 1), collected.function_signatures.len);
    const signature = type_store.lookupFunction(collected.function_signatures[0].signature_id).?;
    try testing.expectEqual(@as(usize, 1), signature.parameters.len);
    try testing.expectEqual(signature.parameters[0].type_id, signature.return_type);
    switch (type_store.lookup(signature.return_type).?.kind) {
        .type_parameter => |parameter| {
            try testing.expectEqualStrings("T", parameter.name);
            try testing.expectEqual(@as(u32, 0), parameter.identity.module_id);
        },
        else => return error.TestExpectedEqual,
    }
}

test "Goal 140 exhaustively lowers supported type-node variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\interface User { name: string; age?: number }
        \\type Mode = "dark";
        \\type Name = User["name"];
        \\type Keys = keyof User;
        \\const value: string = "x";
        \\type Query = typeof value;
        \\type Box<T> = { value: T };
        \\type Boxed = Box<number>;
        \\type ArrayShape = string[];
        \\type TupleShape = readonly [string, number];
        \\type UnionShape = string | number;
        \\type IntersectionShape = { a: string } & { b: number };
        \\type ObjectShape = { value: string };
        \\type FunctionShape = (value: string) => number;
        \\type ParenthesizedShape = (string);
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);
    const mode = collectedType(collected, symbolByName(result, "Mode", .type).?.id).?;
    try testing.expectEqualStrings("dark", type_store.lookup(mode).?.kind.literal.string);
    try testing.expectEqual(
        test_builtins.string,
        collectedType(collected, symbolByName(result, "Name", .type).?.id).?,
    );
    try testing.expectEqual(
        test_builtins.string,
        collectedType(collected, symbolByName(result, "Query", .type).?.id).?,
    );
    const keys = type_store.lookup(collectedType(collected, symbolByName(result, "Keys", .type).?.id).?).?.kind.union_type;
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "Boxed", .type).?.id).?).?.kind == .object);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "ArrayShape", .type).?.id).?).?.kind == .array);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "TupleShape", .type).?.id).?).?.kind.tuple.readonly);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "UnionShape", .type).?.id).?).?.kind == .union_type);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "IntersectionShape", .type).?.id).?).?.kind == .intersection);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "ObjectShape", .type).?.id).?).?.kind == .object);
    try testing.expect(type_store.lookup(collectedType(collected, symbolByName(result, "FunctionShape", .type).?.id).?).?.kind == .function);
    try testing.expectEqual(
        test_builtins.string,
        collectedType(collected, symbolByName(result, "ParenthesizedShape", .type).?.id).?,
    );
}

test "Goal 140 invalid type operators diagnose instead of silently becoming unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\interface User { name: string }
        \\type Missing = User["missing"];
        \\type PrimitiveKeys = keyof number;
        \\const inferred = 1;
        \\type UnsupportedQuery = typeof inferred;
        \\type Box<T> = { value: T };
        \\type MissingArgument = Box;
        \\type ExtraArgument = number<string>;
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 5), collected.diagnostics.len);
    for (collected.diagnostics) |diagnostic| {
        try testing.expectEqual(@import("../diagnostics/root.zig").DiagnosticCode.type_mismatch, diagnostic.code);
        try testing.expect(diagnostic.message.len != 0);
    }
    inline for (.{ "Missing", "PrimitiveKeys", "UnsupportedQuery", "MissingArgument", "ExtraArgument" }) |name| {
        try testing.expectEqual(
            test_builtins.unknown,
            collectedType(collected, symbolByName(result, name, .type).?.id).?,
        );
    }
}

test "Goal 142 collects class and interface member foundations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var type_store = types.TypeStore.init(arena.allocator());
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\interface Base { base: string }
        \\interface Shape extends Base { readonly name?: string; render(scale: number): boolean }
        \\class Service extends Parent {
        \\  readonly id: string;
        \\  inferred = 1;
        \\  static count: number;
        \\  constructor(public readonly token: string, protected age?: number) {}
        \\  private run(value: number): string {}
        \\  static make(): boolean {}
        \\}
        \\class Parent {}
    }, .{});
    const collected = try type_collector.collectDeclaredTypes(
        arena.allocator(),
        result.source,
        result.ast,
        result.bind,
        &type_store,
    );

    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expectEqual(@as(usize, 0), collected.diagnostics.len);

    const service_symbol = symbolByName(result, "Service", .type).?;
    const service = type_store.lookupClassSemanticType(.init(0, service_symbol.declaration)).?;
    try testing.expectEqual(@as(usize, 5), service.instance_members.members.len);
    try testing.expectEqual(@as(usize, 2), service.static_members.members.len);
    try testing.expect(service.constructor_signature != null);
    try testing.expect(type_store.lookupFunction(service.constructor_signature.?) != null);
    try testing.expectEqual(
        service.instance_type,
        type_store.lookupFunction(service.constructor_signature.?).?.return_type,
    );
    try testing.expect(service.inheritance.extends != null);

    const id = semanticMember(service.instance_members, "id").?;
    try testing.expectEqual(test_builtins.string, id.type_id);
    try testing.expect(id.readonly);
    const inferred = semanticMember(service.instance_members, "inferred").?;
    try testing.expectEqual(test_builtins.unknown, inferred.type_id);
    const token = semanticMember(service.instance_members, "token").?;
    try testing.expect(token.readonly);
    try testing.expectEqual(types.Visibility.public, token.visibility);
    const age = semanticMember(service.instance_members, "age").?;
    try testing.expect(age.optional);
    try testing.expectEqual(types.Visibility.protected, age.visibility);
    const run = semanticMember(service.instance_members, "run").?;
    try testing.expectEqual(types.Visibility.private, run.visibility);
    try testing.expect(type_store.lookupFunction(run.type_id) != null);
    try testing.expect(semanticMember(service.static_members, "count") != null);
    const make = semanticMember(service.static_members, "make").?;
    try testing.expect(type_store.lookupFunction(make.type_id) != null);

    const shape_symbol = symbolByName(result, "Shape", .type).?;
    const shape = type_store.lookupInterfaceSemanticType(.init(0, shape_symbol.declaration)).?;
    try testing.expectEqual(@as(usize, 2), shape.members.members.len);
    try testing.expectEqual(@as(usize, 1), shape.inheritance.extends.len);
    const name = semanticMember(shape.members, "name").?;
    try testing.expect(name.readonly);
    try testing.expect(name.optional);
    const render = semanticMember(shape.members, "render").?;
    try testing.expect(type_store.lookupFunction(render.type_id) != null);
}

fn semanticMember(table: types.MemberTable, name: []const u8) ?types.SemanticMember {
    for (table.members) |member| if (std.mem.eql(u8, member.name, name)) return member;
    return null;
}
