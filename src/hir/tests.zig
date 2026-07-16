const std = @import("std");
const hir = @import("root.zig");
const project_mod = @import("../project/root.zig");

fn completedProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(1),
        .logical_name = "hir:test",
        .bytes = "export const answer: number = 42;",
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    _ = try project.finish();
    return project;
}

fn multiModuleProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(40),
        .logical_name = "descriptive/root.ts",
        .bytes = "import { value as depValue } from './dep'; export const answer: number = depValue;",
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            try std.testing.expectEqualStrings("./dep", request.raw_specifier);
            try project.respondSource(request.id, .{
                .id = .init(7),
                .logical_name = "unrelated-name.ts",
                .bytes = "export const value: number = 7;",
            });
        },
    };
    try std.testing.expect(!(try project.finish()).has_failures);
    return project;
}

fn cycleProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    const source_a: project_mod.ModuleSource = .{
        .id = .init(71),
        .logical_name = "cycle-a.ts",
        .bytes = "import './b'; export const a = 1;",
    };
    const source_b: project_mod.ModuleSource = .{
        .id = .init(72),
        .logical_name = "cycle-b.ts",
        .bytes = "import './a'; export const b = 2;",
    };
    try project.addRoot(source_a);
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "./a")) {
                try project.respondSource(request.id, source_a);
            } else {
                try std.testing.expectEqualStrings("./b", request.raw_specifier);
                try project.respondSource(request.id, source_b);
            }
        },
    };
    try std.testing.expect(!(try project.finish()).has_failures);
    return project;
}

fn declarationLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(213),
        .logical_name = "goal-213.ts",
        .bytes =
        \\type Named = number;
        \\type LiteralAlias = "x";
        \\type ArrayAlias = number[];
        \\type ReadonlyAlias = readonly number[];
        \\type IndexedAlias = { x: number }["x"];
        \\type KeyAlias = keyof { x: number };
        \\type UnionAlias = number | string;
        \\type IntersectionAlias = { x: number } & { y: string };
        \\type ObjectAlias = { x: number };
        \\type FunctionAlias = (value: number) => string;
        \\type TupleAlias = [number, string];
        \\type ParenthesizedAlias = (number);
        \\interface Box { value: number; }
        \\function make(): number { return 1; }
        \\var before = 0x2a;
        \\type QueryAlias = typeof before;
        \\let later;
        \\const asserted = before as number;
        \\const checked = before satisfies unknown;
        \\const nonnull = before!;
        \\const text = "line\n\x21\u003f";
        \\const big = 12n;
        \\const truth = true;
        \\const nil = null;
        \\let value = 1;
        \\{ let value = 2; const inner = value; }
        \\const outer = value;
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn anfLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(214),
        .logical_name = "goal-214.ts",
        .bytes =
        \\function a(): number { return 1; }
        \\function b(): number { return 2; }
        \\function foo(left: number, right: number): number { return left + right; }
        \\const condition = true;
        \\const nested = foo(a(), b());
        \\(a(), b());
        \\const selected = condition ? a() : b();
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn functionLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(219),
        .logical_name = "goal-219.ts",
        .bytes =
        \\const captured = 7;
        \\function declared(first: number = captured, ...rest: number[]): number {
        \\  const local = first;
        \\  const nested = (delta: number = local): number => delta;
        \\  return nested();
        \\}
        \\const expression = function(value?: number): number { return value ?? captured; };
        \\const lexical = () => this;
        \\const object = {
        \\  method(value: number): number { return value; },
        \\  get value(): number { return captured; },
        \\  set value(next: number) { next; }
        \\};
        \\async function asynchronous() {}
        \\function* generator() {}
        \\async function* asyncGenerator() {}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn classEnumLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(224),
        .logical_name = "goal-224.ts",
        .bytes =
        \\class Base {}
        \\class Derived extends Base {
        \\  first = 1;
        \\  second = 2;
        \\  static alpha = 3;
        \\  static omega = 4;
        \\  constructor(public property: number) { super(); }
        \\  get value(): number { return this.first; }
        \\  set value(next: number) { this.first = next; }
        \\  method(): number { return this.second; }
        \\}
        \\const Expression = class Named { field = 5; };
        \\enum Numeric { Zero, Five = 5, Six }
        \\enum Text { A = "a", B = "b" }
        \\function nestedDeclarations(): number {
        \\  class Local { field = 1; }
        \\  enum LocalEnum { One }
        \\  return 1;
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn exceptionLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(222),
        .logical_name = "goal-222.ts",
        .bytes =
        \\let moduleMarker = 0;
        \\try { moduleMarker = 1; } finally { moduleMarker = 2; }
        \\function caught(): number {
        \\  try { throw 7; } catch (caughtValue) { return caughtValue; }
        \\}
        \\function nested(flag: boolean): number {
        \\  try {
        \\    if (flag) throw 1;
        \\    return 2;
        \\  } catch (caughtValue) {
        \\    throw caughtValue;
        \\  } finally {
        \\    if (flag) return 3;
        \\  }
        \\}
        \\function transfers(values: number[]): number {
        \\  let result = 0;
        \\  outer: for (const value of values) {
        \\    try {
        \\      if (value === 0) continue outer;
        \\      if (value === 1) break outer;
        \\      result = value;
        \\    } finally {
        \\      result = result + 1;
        \\    }
        \\  }
        \\  return result;
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn suspensionLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(223),
        .logical_name = "goal-223.ts",
        .bytes =
        \\async function wait(value: any): any { return await value; }
        \\function* sequence(value: any): any {
        \\  const resumed = yield value;
        \\  yield* value;
        \\  return resumed;
        \\}
        \\async function* combined(value: any): any { yield await value; return value; }
        \\async function consume(iterable: any): any {
        \\  for await (const value of iterable) {
        \\    if (value) break;
        \\  }
        \\  return null;
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn placeLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(215),
        .logical_name = "goal-215.ts",
        .bytes =
        \\function base(): any { return null; }
        \\function key(): any { return "value"; }
        \\function rhs(): number { return 3; }
        \\let x = 0;
        \\base()[key()] += rhs();
        \\base().value = rhs();
        \\const post = x++;
        \\const pre = ++x;
        \\const removed = delete base()[key()];
        \\x -= 1;
        \\x *= 1;
        \\x /= 1;
        \\x %= 1;
        \\x **= 1;
        \\x &= 1;
        \\x |= 1;
        \\x ^= 1;
        \\x <<= 1;
        \\x >>= 1;
        \\x >>>= 1;
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn operatorLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(216),
        .logical_name = "goal-216.ts",
        .bytes =
        \\function side(): any { return 1; }
        \\function base(): any { return null; }
        \\function key(): any { return "method"; }
        \\function callable(value: any): any { return value; }
        \\let value: any = 1;
        \\let target: any = null;
        \\const unaryPlus = +value;
        \\const unaryMinus = -value;
        \\const logicalNot = !value;
        \\const bitNot = ~value;
        \\const typeName = typeof value;
        \\const nothing = void side();
        \\const add = value + value;
        \\const subtract = value - value;
        \\const multiply = value * value;
        \\const divide = value / value;
        \\const remainder = value % value;
        \\const power = value ** value;
        \\const bitAnd = value & value;
        \\const bitOr = value | value;
        \\const bitXor = value ^ value;
        \\const shiftLeft = value << value;
        \\const shiftRight = value >> value;
        \\const shiftUnsigned = value >>> value;
        \\const less = value < value;
        \\const lessEqual = value <= value;
        \\const greater = value > value;
        \\const greaterEqual = value >= value;
        \\const looseEqual = value == value;
        \\const strictEqual = value === value;
        \\const looseNotEqual = value != value;
        \\const strictNotEqual = value !== value;
        \\const contained = "x" in target;
        \\const matched = target instanceof callable;
        \\const selectedAnd = value && side();
        \\const selectedOr = value || side();
        \\const selectedNullish = value ?? side();
        \\base()[key()] &&= side();
        \\base()[key()] ||= side();
        \\base()[key()] ??= side();
        \\const optionalMember = base()?.method;
        \\const optionalElement = base()?.[key()];
        \\const optionalFunction = callable?.(side());
        \\const optionalMethod = base()?.method(side());
        \\const optionalMethodValue = base().method?.(side());
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn accessCallLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(217),
        .logical_name = "goal-217.ts",
        .bytes =
        \\function receiver(): any { return null; }
        \\function key(): any { return "method"; }
        \\function arg(): any { return 1; }
        \\function callable(value: any): any { return value; }
        \\let Constructor: any = callable;
        \\let source: any = "runtime";
        \\let options: any = null;
        \\const ordinary = callable(arg());
        \\const method = receiver().method(arg());
        \\const constructed = new Constructor(arg());
        \\const loaded = import(source, options);
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn aggregateLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(218),
        .logical_name = "goal-218.ts",
        .bytes =
        \\function key(): any { return "computed"; }
        \\function value(): any { return 1; }
        \\function spread(): any { return [2]; }
        \\function callable(...values: any[]): any { return values; }
        \\function tag(strings: any, substitution: any): any { return substitution; }
        \\const object = { first: value(), [key()]: value(), ...spread(), method() {}, get answer() { return 1; }, set answer(next: any) {} };
        \\const array = [, null, ...spread()];
        \\const called = callable(...spread());
        \\const text = `a${value()}b`;
        \\const tagged = tag`raw${value()}tail`;
        \\let receiver: any = object;
        \\const memberTagged = receiver.method`member`;
        \\const regexpA = /a+/gi;
        \\const regexpB = /a+/gi;
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn controlFlowLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(220),
        .logical_name = "goal-220.ts",
        .bytes =
        \\function effect() {}
        \\function choose(flag: boolean): number {
        \\  if (flag) effect(); else effect();
        \\  return flag ? 1 : 2;
        \\}
        \\function loops(flag: boolean, object: any) {
        \\  while (flag) { effect(); flag = false; }
        \\  do { effect(); } while (flag);
        \\  for (let index = 0; index < 1; index++) effect();
        \\  for (const key in object) effect();
        \\}
        \\function first(iterable: any): any {
        \\  for (const value of iterable) return value;
        \\  return null;
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn switchAndLabelLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(221),
        .logical_name = "goal-221.ts",
        .bytes =
        \\function effect(value: number): number { return value; }
        \\function choose(marker: number): number {
        \\  switch (effect(marker)) {
        \\    case effect(1): effect(10);
        \\    default: effect(20);
        \\    case effect(2): effect(30); break;
        \\    case effect(3): effect(40);
        \\  }
        \\  return 0;
        \\}
        \\function repeat(limit: number) {
        \\outer: for (let index = 0; index < limit; index++) {
        \\  continue outer;
        \\}
        \\}
        \\function close(iterable: any, stop: boolean) {
        \\outer: for (const item of iterable) {
        \\  if (stop) continue outer;
        \\  break outer;
        \\}
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn provenanceLoweringProject() !project_mod.Project {
    var project = project_mod.Project.init(std.testing.allocator);
    errdefer project.deinit();
    try project.addRoot(.{
        .id = .init(227),
        .logical_name = "path/must-not-be-identity.ts",
        .bytes =
        \\interface Erased { value: number; }
        \\const arrow = (value: number): number => value;
        \\function trace(flag: boolean, object: any): number {
        \\  let value = 0;
        \\  value += 1;
        \\  const both = flag && object;
        \\  const member = object?.value;
        \\  switch (value) { case 1: value = flag ? 2 : 3; break; default: value = 4; }
        \\  return value;
        \\}
        ,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    const result = try project.finish();
    if (result.has_failures) return error.UnexpectedSemanticDiagnostics;
    return project;
}

fn findBinding(function: hir.HirFunction, name: []const u8, ordinal: usize) !hir.HirBinding {
    var seen: usize = 0;
    for (function.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        if (seen == ordinal) return binding;
        seen += 1;
    }
    return error.MissingHirBinding;
}

fn hasBinding(function: hir.HirFunction, name: []const u8) bool {
    for (function.bindings) |binding| if (std.mem.eql(u8, binding.name, name)) return true;
    return false;
}

test "empty HirResult owns and releases its identity domain" {
    var project = try completedProject();
    defer project.deinit();

    const semantic_result = project.semanticResult().?;
    var result = try hir.HirResult.initEmpty(std.testing.allocator, semantic_result);
    defer result.deinit();

    try std.testing.expectEqual(semantic_result, result.semanticResult());
}

test "HIR IDs have one invalid value and reject foreign domains" {
    var project = try completedProject();
    defer project.deinit();
    const semantic_result = project.semanticResult().?;

    var first = try hir.HirResult.initEmpty(std.testing.allocator, semantic_result);
    defer first.deinit();
    var second = try hir.HirResult.initEmpty(std.testing.allocator, semantic_result);
    defer second.deinit();

    const id_types = .{
        hir.EntityId,
        hir.FunctionId,
        hir.BlockId,
        hir.InstructionId,
        hir.ValueId,
        hir.BindingId,
        hir.PlaceId,
        hir.RegionId,
        hir.OriginId,
    };
    inline for (id_types) |IdType| {
        try std.testing.expectEqual(@as(?u32, null), IdType.invalid.index());
        try std.testing.expectError(error.InvalidId, first.makeId(IdType, std.math.maxInt(u32)));

        const id = try first.makeId(IdType, 7);
        try first.requireOwnedId(id);
        try std.testing.expectError(error.ForeignId, second.requireOwnedId(id));
    }
}

test "HirResult borrows semantic storage and does not destroy it" {
    var project = try completedProject();
    defer project.deinit();
    const semantic_result = project.semanticResult().?;

    var result = try hir.HirResult.initEmpty(std.testing.allocator, semantic_result);
    result.deinit();

    try std.testing.expectEqual(semantic_result, project.semanticResult().?);
    try std.testing.expect(semantic_result.lookupModule(1) != null);
}

test "HIR instructions validate result shape and derive conservative effects" {
    const instruction = try hir.HirInstruction.init(
        hir.InstructionId.invalid,
        hir.ValueId.invalid,
        1,
        .{ .call = .{ .callee = hir.ValueId.invalid } },
        hir.OriginId.invalid,
    );
    try std.testing.expect(instruction.effects.may_throw);
    try std.testing.expect(instruction.effects.may_call_user_code);
    try std.testing.expect(instruction.effects.reads_state);
    try std.testing.expect(instruction.effects.writes_state);

    try std.testing.expectError(
        error.ResultTypeMismatch,
        hir.HirInstruction.init(
            hir.InstructionId.invalid,
            hir.ValueId.invalid,
            null,
            .{ .constant = .undefined },
            hir.OriginId.invalid,
        ),
    );
    try std.testing.expectError(
        error.ResultPresenceMismatch,
        hir.HirInstruction.init(
            hir.InstructionId.invalid,
            hir.ValueId.invalid,
            1,
            .{ .store_binding = .{
                .binding = hir.BindingId.invalid,
                .value = hir.ValueId.invalid,
            } },
            hir.OriginId.invalid,
        ),
    );
}

test "variable-arity HIR operations reject malformed payloads" {
    const no_parts: []const hir.model.TemplatePart = &.{};
    try std.testing.expectError(
        error.EmptyStringBuild,
        (hir.HirOperation{ .build_string = no_parts }).checked(),
    );

    const cooked = [_]?[]const u8{"cooked"};
    const raw: []const []const u8 = &.{};
    try std.testing.expectError(
        error.TemplateArityMismatch,
        (hir.HirOperation{ .create_template_site = .{
            .source_site = hir.SourceSiteId.invalid,
            .cooked = &cooked,
            .raw = raw,
        } }).checked(),
    );
}

test "HIR represents branch merges with block parameters and semantic places" {
    const merge_parameter = hir.HirBlockParameter{
        .value = hir.ValueId.invalid,
        .type_id = 1,
        .origin = hir.OriginId.invalid,
    };
    const jump_arguments = [_]hir.ValueId{hir.ValueId.invalid};
    const blocks = [_]hir.HirBlock{
        .{
            .id = hir.BlockId.invalid,
            .terminator = .{ .branch = .{
                .condition = hir.ValueId.invalid,
                .true_target = hir.BlockId.invalid,
                .false_target = hir.BlockId.invalid,
            } },
            .origin = hir.OriginId.invalid,
        },
        .{
            .id = hir.BlockId.invalid,
            .terminator = .{ .jump = .{
                .target = hir.BlockId.invalid,
                .arguments = &jump_arguments,
            } },
            .origin = hir.OriginId.invalid,
        },
        .{
            .id = hir.BlockId.invalid,
            .parameters = &.{merge_parameter},
            .terminator = .{ .return_ = hir.ValueId.invalid },
            .origin = hir.OriginId.invalid,
        },
    };
    const place = hir.HirPlace{
        .id = hir.PlaceId.invalid,
        .kind = .{ .property = .{
            .base = hir.ValueId.invalid,
            .key = .{ .static = "answer" },
        } },
        .origin = hir.OriginId.invalid,
    };
    const function = hir.HirFunction{
        .id = hir.FunctionId.invalid,
        .module_id = .init(1),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = 1,
        .places = &.{place},
        .blocks = &blocks,
        .entry = hir.BlockId.invalid,
        .origin = hir.OriginId.invalid,
    };

    try std.testing.expectEqual(@as(usize, 3), function.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), function.blocks[2].parameters.len);
    try std.testing.expectEqual(@as(usize, 1), function.places.len);
}

test "HIR operation set excludes structured and backend-only fallbacks" {
    const forbidden_operations = .{
        "if",
        "switch",
        "loop",
        "arrow",
        "assignment",
        "update",
        "optional_chain",
        "phi",
        "ast_node",
        "machine_type",
        "memory_order",
    };
    inline for (forbidden_operations) |name| {
        try std.testing.expect(!@hasField(hir.HirOperation, name));
    }
}

test "HIR exports require exactly one runtime target" {
    try std.testing.expectError(
        error.InvalidExportTarget,
        hir.model.HirExportBinding.init("answer", null, null, undefined, false),
    );
    try std.testing.expectError(
        error.InvalidExportTarget,
        hir.model.HirExportBinding.init(
            "answer",
            hir.BindingId.invalid,
            hir.EntityId.invalid,
            undefined,
            false,
        ),
    );
    _ = try hir.model.HirExportBinding.init("TypeOnly", null, null, undefined, true);
}

test "HIR eligibility accepts complete semantic input" {
    var project = try completedProject();
    defer project.deinit();

    var report = try hir.eligibility.check(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(report.isEligible());
}

test "HIR eligibility rejects recovered unsupported syntax without producing HIR" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(11),
        .logical_name = "unsupported.ts",
        .bytes = "namespace Models { export const value = 1; } const after = 1;",
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => return error.UnexpectedModuleRequest,
    };
    _ = try project.finish();

    var report = try hir.eligibility.check(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(!report.isEligible());
    var saw_unsupported = false;
    for (report.diagnostics) |diagnostic| {
        if (diagnostic.code == .unsupported_executable_syntax) saw_unsupported = true;
    }
    try std.testing.expect(saw_unsupported);
}

test "HIR eligibility accepts typed external bindings without source bodies" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(12),
        .logical_name = "external.ts",
        .bytes = "import { platform, version } from 'native:env'; export const value = platform + version;",
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9001),
            .logical_name = "native:env",
            // Descriptor order is deliberately opposite to stable symbol order.
            .exports = &.{
                .{
                    .name = "version",
                    .type_metadata = .number,
                    .symbol_id = .init(72),
                    .declaration_kind = .global,
                    .effects = .{ .unknown = false },
                },
                .{
                    .name = "platform",
                    .type_metadata = .string,
                    .symbol_id = .init(71),
                    .declaration_kind = .constant,
                    .effects = .{ .unknown = false },
                },
            },
        }),
    };
    _ = try project.finish();

    var report = try hir.eligibility.check(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(report.isEligible());
    try std.testing.expectEqual(@as(usize, 1), project.semanticResult().?.modules.len);
    try std.testing.expect(project.semanticResult().?.imports[0].target.?.external_module_id != null);

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    try std.testing.expectEqual(@as(usize, 1), result.project.modules.len);
    try std.testing.expectEqual(@as(usize, 2), result.project.external_declarations.len);
    try std.testing.expectEqual(@as(usize, 0), result.project.entities.len);
    try std.testing.expectEqual(@as(usize, 1), result.project.functions.len);
    try std.testing.expectEqual(@as(u64, 71), result.project.external_declarations[0].symbol_id.value());
    try std.testing.expectEqualStrings("platform", result.project.external_declarations[0].exported_name);
    try std.testing.expectEqual(@as(u64, 72), result.project.external_declarations[1].symbol_id.value());
    try std.testing.expectEqualStrings("version", result.project.external_declarations[1].exported_name);
    try std.testing.expectEqual(@as(u64, 9001), result.project.modules[0].imports[0].source.external.value());
    try std.testing.expectEqual(@as(u64, 9001), result.project.modules[0].imports[0].target.external_module_id.?.value());
    try std.testing.expectEqual(@as(u64, 71), result.project.modules[0].imports[0].target.external_symbol_id.?.value());
}

test "HIR eligibility rejects external bindings without explicit publication metadata" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(13),
        .logical_name = "legacy-external.ts",
        .bytes = "import { platform } from 'native:env'; export const value = platform;",
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9002),
            .logical_name = "native:env",
            .exports = &.{.{
                .name = "platform",
                .type_metadata = .string,
            }},
        }),
    };
    _ = try project.finish();

    var report = try hir.eligibility.check(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(!report.isEligible());
    var saw_invalid_identity = false;
    for (report.diagnostics) |diagnostic| {
        if (diagnostic.code == .invalid_semantic_reference) saw_invalid_identity = true;
    }
    try std.testing.expect(saw_invalid_identity);

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    switch (outcome) {
        .result => return error.UnexpectedPublishedHir,
        .diagnostics => |diagnostics| try std.testing.expect(!diagnostics.isEligible()),
    }
}

test "sealed HIR consumer survives project teardown with types intact" {
    var project = try completedProject();
    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    project.deinit();
    defer outcome.deinit();

    try std.testing.expect(result.semantic_result == null);
    const view = try hir.ConsumerView.open(result, hir.hir_api_version);
    try std.testing.expectEqual(hir.hir_api_version, view.version());
    try std.testing.expectEqual(@as(usize, 1), view.modules().len);
    try std.testing.expect(view.functions().len > 0);
    try std.testing.expect(view.typeCount() > 0);
    for (0..view.typeCount()) |index| {
        const item = try view.typeAt(index);
        try std.testing.expectEqual(item.id, (try view.typeRecord(item.id)).id);
    }
    try std.testing.expectError(error.InvalidId, view.typeAt(view.typeCount()));
    const function = view.functions()[0];
    _ = try view.function(function.id);
    _ = try view.typeRecord(function.signature_type);
}

test "HIR consumer rejects unsupported versions invalid IDs and foreign IDs" {
    var first_project = try completedProject();
    defer first_project.deinit();
    var second_project = try completedProject();
    defer second_project.deinit();
    var first = try hir.lowerProject(std.testing.allocator, &first_project, .{});
    defer first.deinit();
    var second = try hir.lowerProject(std.testing.allocator, &second_project, .{});
    defer second.deinit();

    const first_result = switch (first) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const second_result = switch (second) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    try std.testing.expectError(error.UnsupportedVersion, hir.ConsumerView.open(first_result, 0));
    try std.testing.expectError(error.UnsupportedVersion, hir.ConsumerView.open(first_result, hir.hir_api_version + 1));

    const view = try hir.ConsumerView.open(first_result, hir.hir_api_version);
    try std.testing.expectError(error.ForeignId, view.function(second_result.project.functions[0].id));
    const invalid = try first_result.makeId(hir.FunctionId, @intCast(first_result.project.functions.len));
    try std.testing.expectError(error.InvalidId, view.function(invalid));
}

test "HIR limit kind summary and diagnostic stay consistent" {
    var configured: hir.Limits = .{};
    configured.instructions = 0;
    var budget = hir.Budget.init(configured);
    const violation = budget.reserve(.instructions, 1).?;
    const diagnostic = hir.diagnostics.Diagnostic.fromLimit(violation);

    try std.testing.expectEqualStrings(hir.limits.summary(violation.kind), diagnostic.message());
    try std.testing.expectEqualStrings("VZG7010", hir.diagnostics.codeId(diagnostic.code));
    try std.testing.expectEqual(@as(usize, 0), budget.usage.instructions);
}

test "HIR project lowering builds deterministic linked multi-module shells" {
    var project = try multiModuleProject();
    defer project.deinit();

    var first = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer first.deinit();
    var second = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer second.deinit();
    const first_result = switch (first) {
        .result => |*result| result,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const second_result = switch (second) {
        .result => |*result| result,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    try std.testing.expectEqual(@as(usize, 2), first_result.project.modules.len);
    try std.testing.expectEqual(@as(u64, 7), first_result.project.modules[0].module_id.value());
    try std.testing.expectEqual(@as(u64, 40), first_result.project.modules[1].module_id.value());
    try std.testing.expectEqualStrings("unrelated-name.ts", first_result.project.modules[0].logical_name);
    try std.testing.expectEqualStrings("descriptive/root.ts", first_result.project.modules[1].logical_name);
    try std.testing.expectEqual(@as(usize, 0), first_result.project.modules[0].dependencies.len);
    try std.testing.expectEqual(@as(usize, 1), first_result.project.modules[1].dependencies.len);
    try std.testing.expectEqual(@as(u64, 7), first_result.project.modules[1].dependencies[0].module_id.value());
    try std.testing.expect(first_result.project.modules[1].dependencies[0].initialization_required);
    try std.testing.expectEqual(@as(usize, 2), first_result.project.functions.len);
    for (first_result.project.functions) |function| {
        try std.testing.expectEqual(hir.model.HirFunctionKind.module_initialization, function.kind);
        try std.testing.expectEqual(@as(usize, 1), function.blocks.len);
    }

    const root = first_result.project.modules[1];
    try std.testing.expectEqual(@as(usize, 1), root.imports.len);
    try std.testing.expectEqual(@as(u64, 7), root.imports[0].source.source.value());
    try std.testing.expectEqual(@as(u64, 7), root.imports[0].target.declaration.module_id);
    const semantic_import = project.semanticResult().?.imports[0];
    try std.testing.expectEqual(semantic_import.target.?.declaration, root.imports[0].target.declaration);
    try std.testing.expectEqual(semantic_import.target.?.type_id, root.imports[0].target.type_id);

    for (first_result.project.modules, second_result.project.modules) |left, right| {
        try std.testing.expectEqual(left.module_id, right.module_id);
        try std.testing.expectEqualStrings(left.logical_name, right.logical_name);
        try std.testing.expectEqual(left.initialization.index(), right.initialization.index());
        try std.testing.expectEqual(left.dependencies.len, right.dependencies.len);
        try std.testing.expectEqual(left.imports.len, right.imports.len);
        try std.testing.expectEqual(left.exports.len, right.exports.len);
    }
}

test "HIR project lowering closes module cycles without duplicate shells" {
    var project = try cycleProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var second_outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer second_outcome.deinit();
    const second = switch (second_outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    try std.testing.expectEqual(@as(usize, 2), result.project.modules.len);
    try std.testing.expectEqual(@as(usize, 2), result.project.functions.len);
    try std.testing.expectEqual(@as(usize, 1), result.project.modules[0].dependencies.len);
    try std.testing.expectEqual(@as(usize, 1), result.project.modules[1].dependencies.len);
    try std.testing.expectEqual(result.project.modules[1].module_id, result.project.modules[0].dependencies[0].module_id);
    try std.testing.expectEqual(result.project.modules[0].module_id, result.project.modules[1].dependencies[0].module_id);
    for (result.project.modules, second.project.modules) |left, right| {
        try std.testing.expectEqual(left.module_id, right.module_id);
        try std.testing.expectEqual(left.initialization.index(), right.initialization.index());
        try std.testing.expectEqual(@as(usize, 1), left.exports.len);
        try std.testing.expectEqual(left.exports.len, right.exports.len);
        try std.testing.expectEqualStrings(left.exports[0].exported_name, right.exports[0].exported_name);
        try std.testing.expect(left.exports[0].binding != null);
        try std.testing.expectEqual(left.exports[0].binding.?.index(), right.exports[0].binding.?.index());
        try std.testing.expectEqual(left.exports[0].target.declaration, right.exports[0].target.declaration);
    }
}

test "HIR declaration lowering preserves semantic bindings values and type erasure" {
    var project = try declarationLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    try std.testing.expectEqual(@as(usize, 1), result.project.modules.len);
    try std.testing.expectEqual(@as(usize, 1), result.project.entities.len);
    try std.testing.expectEqual(@as(usize, 2), result.project.functions.len);

    const ordinary = result.project.functions[0];
    const initialization = result.project.functions[1];
    try std.testing.expectEqual(hir.model.HirFunctionKind.ordinary, ordinary.kind);
    try std.testing.expectEqual(hir.model.HirFunctionKind.module_initialization, initialization.kind);
    try std.testing.expectEqual(@as(u64, 213), ordinary.symbol.?.module_id);
    try std.testing.expectEqual(ordinary.id, result.project.entities[0].kind.function.function);
    try std.testing.expectEqual(@as(usize, 1), ordinary.blocks[0].instructions.len);
    try std.testing.expect(ordinary.blocks[0].instructions[0].operation == .constant);

    const function_binding = try findBinding(initialization, "make", 0);
    const before = try findBinding(initialization, "before", 0);
    const later = try findBinding(initialization, "later", 0);
    const asserted = try findBinding(initialization, "asserted", 0);
    const outer_value = try findBinding(initialization, "value", 0);
    const inner_value = try findBinding(initialization, "value", 1);
    try std.testing.expectEqual(hir.model.HirBindingKind.function, function_binding.kind);
    try std.testing.expectEqual(hir.model.HirBindingInitialState.hoisted_function, function_binding.initial_state);
    try std.testing.expectEqual(hir.model.HirBindingKind.var_, before.kind);
    try std.testing.expectEqual(hir.model.HirBindingInitialState.hoisted_undefined, before.initial_state);
    try std.testing.expect(before.mutable);
    try std.testing.expectEqual(hir.model.HirBindingKind.let_, later.kind);
    try std.testing.expectEqual(hir.model.HirBindingInitialState.temporal_dead_zone, later.initial_state);
    try std.testing.expectEqual(hir.model.HirBindingKind.const_, asserted.kind);
    try std.testing.expectEqual(hir.model.HirBindingInitialState.temporal_dead_zone, asserted.initial_state);
    try std.testing.expect(!asserted.mutable);

    var saw_number = false;
    var saw_undefined = false;
    var saw_string = false;
    var saw_bigint = false;
    var saw_boolean = false;
    var saw_null = false;
    var asserted_value: ?hir.ValueId = null;
    var inner_read_binding: ?hir.BindingId = null;
    var outer_read_binding: ?hir.BindingId = null;
    for (initialization.blocks[0].instructions) |instruction| switch (instruction.operation) {
        .constant => |constant| switch (constant) {
            .number => |value| if (value == 42) {
                saw_number = true;
            },
            .undefined => saw_undefined = true,
            .string => |value| if (std.mem.eql(u8, value, "line\n!?")) {
                saw_string = true;
            },
            .bigint => |value| if (std.mem.eql(u8, value, "12")) {
                saw_bigint = true;
            },
            .boolean => |value| if (value) {
                saw_boolean = true;
            },
            .null_ => saw_null = true,
        },
        .load_binding => |binding| {
            if (binding.eql(before.id) and asserted_value == null) asserted_value = instruction.result.?;
            if (binding.eql(inner_value.id)) inner_read_binding = binding;
            if (binding.eql(outer_value.id)) outer_read_binding = binding;
        },
        .initialize_binding => |initialize| {
            if (initialize.binding.eql(asserted.id)) try std.testing.expect(asserted_value.?.eql(initialize.value));
        },
        else => {},
    };
    try std.testing.expect(saw_number);
    try std.testing.expect(saw_undefined);
    try std.testing.expect(saw_string);
    try std.testing.expect(saw_bigint);
    try std.testing.expect(saw_boolean);
    try std.testing.expect(saw_null);
    try std.testing.expectEqual(inner_value.id, inner_read_binding.?);
    try std.testing.expectEqual(outer_value.id, outer_read_binding.?);

    const semantic_module = project.semanticResult().?.lookupModule(213).?;
    const local = project.lookup(.init(213)).?.semantic_result.?;
    for (local.frontend.bind.symbols) |symbol| {
        if (symbol.namespace != .value) continue;
        if (!std.mem.eql(u8, symbol.name, "before")) continue;
        try std.testing.expectEqual(symbol.declaration, before.declaration.?.declaration_id);
        try std.testing.expectEqual(semantic_module.type_info.lookupSymbol(symbol.id).?.effective().?, before.type_id);
    }
}

test "HIR ANF lowering preserves call order sequence effects and branch merges" {
    var project = try anfLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const initialization = result.project.functions[result.project.functions.len - 1];
    try std.testing.expectEqual(hir.model.HirFunctionKind.module_initialization, initialization.kind);
    try std.testing.expectEqual(@as(usize, 4), initialization.blocks.len);

    var call_names: std.ArrayList([]const u8) = .empty;
    defer call_names.deinit(std.testing.allocator);
    for (initialization.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .call => |call| {
            const binding = findLoadedBinding(initialization, call.callee) orelse return error.MissingCallCallee;
            try call_names.append(std.testing.allocator, binding.name);
        },
        else => {},
    };
    const expected = [_][]const u8{ "a", "b", "foo", "a", "b", "a", "b" };
    try std.testing.expectEqual(expected.len, call_names.items.len);
    for (expected, call_names.items) |name, actual| try std.testing.expectEqualStrings(name, actual);

    var merge: ?hir.HirBlock = null;
    var jumps_to_merge: usize = 0;
    for (initialization.blocks) |block| if (block.parameters.len != 0) {
        try std.testing.expectEqual(@as(usize, 1), block.parameters.len);
        merge = block;
    };
    const merge_block = merge orelse return error.MissingMergeBlock;
    for (initialization.blocks) |block| switch (block.terminator) {
        .jump => |jump| if (jump.target.eql(merge_block.id)) {
            try std.testing.expectEqual(@as(usize, 1), jump.arguments.len);
            jumps_to_merge += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), jumps_to_merge);
    var used_merge_parameter = false;
    for (merge_block.instructions) |instruction| switch (instruction.operation) {
        .initialize_binding => |initialize| if (initialize.value.eql(merge_block.parameters[0].value)) {
            used_merge_parameter = true;
        },
        else => {},
    };
    try std.testing.expect(used_merge_parameter);
}

test "ANF builder rejects a value use before definition" {
    var project = try completedProject();
    defer project.deinit();
    var result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer result.deinit();
    var raw_builder = hir.builder.Builder.init(&result, .{});
    var anf = try hir.anf_builder.AnfBuilder.init(&raw_builder);
    const unknown = try result.makeId(hir.ValueId, 99);
    try std.testing.expectError(
        error.ValueUseBeforeDefinition,
        anf.emitValue(.{ .copy = unknown }, project.semanticResult().?.type_store.builtins.unknown),
    );
}

test "HIR place lowering evaluates targets once and preserves assignment results" {
    var project = try placeLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const initialization = result.project.functions[result.project.functions.len - 1];
    try std.testing.expectEqual(@as(usize, 16), initialization.places.len);

    var call_names: std.ArrayList([]const u8) = .empty;
    defer call_names.deinit(std.testing.allocator);
    var binary_operators: std.EnumSet(hir.model.BinaryOperator) = .initEmpty();
    var saw_add = false;
    for (initialization.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .call => |call| {
            const binding = findLoadedBinding(initialization, call.callee) orelse return error.MissingCallCallee;
            try call_names.append(std.testing.allocator, binding.name);
        },
        .add => saw_add = true,
        .binary => |binary| binary_operators.insert(binary.operator),
        else => {},
    };
    const expected_calls = [_][]const u8{ "base", "key", "rhs", "base", "rhs", "base", "key" };
    try std.testing.expectEqual(expected_calls.len, call_names.items.len);
    for (expected_calls, call_names.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(saw_add);
    const expected_binary = [_]hir.model.BinaryOperator{
        .subtract,             .multiply, .divide,  .remainder,  .exponentiate,
        .bit_and,              .bit_or,   .bit_xor, .shift_left, .shift_right,
        .shift_right_unsigned,
    };
    for (expected_binary) |operator| try std.testing.expect(binary_operators.contains(operator));

    const post = try findBinding(initialization, "post", 0);
    const pre = try findBinding(initialization, "pre", 0);
    const removed = try findBinding(initialization, "removed", 0);
    var post_value: ?hir.ValueId = null;
    var pre_value: ?hir.ValueId = null;
    var removed_value: ?hir.ValueId = null;
    for (initialization.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .initialize_binding => |initialize| {
            if (initialize.binding.eql(post.id)) post_value = initialize.value;
            if (initialize.binding.eql(pre.id)) pre_value = initialize.value;
            if (initialize.binding.eql(removed.id)) removed_value = initialize.value;
        },
        else => {},
    };
    try std.testing.expect(operationForValue(initialization, post_value orelse return error.MissingPostValue) == .load_place);
    try std.testing.expect(operationForValue(initialization, pre_value orelse return error.MissingPreValue) == .add);
    try std.testing.expect(operationForValue(initialization, removed_value orelse return error.MissingDeleteValue) == .delete_place);
}

test "ANF builder owns all semantic place forms and rejects unknown places" {
    var project = try completedProject();
    defer project.deinit();
    var result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer result.deinit();
    var raw_builder = hir.builder.Builder.init(&result, .{});
    var anf = try hir.anf_builder.AnfBuilder.init(&raw_builder);
    const unknown_type = project.semanticResult().?.type_store.builtins.unknown;
    const base = try anf.emitValue(.{ .constant = .null_ }, unknown_type);
    const key = try anf.emitValue(.{ .constant = .{ .string = "key" } }, unknown_type);
    const binding = try result.makeId(hir.BindingId, 0);
    _ = try anf.emitPlace(.{ .binding = binding });
    _ = try anf.emitPlace(.{ .property = .{ .base = base, .key = .{ .static = "field" } } });
    _ = try anf.emitPlace(.{ .element = .{ .base = base, .key = key } });
    const super_place = try anf.emitPlace(.{ .super_property = .{ .receiver = base, .key = .{ .computed = key } } });
    _ = try anf.emitValue(.{ .load_place = super_place }, unknown_type);
    const places = try anf.finishPlaces();
    try std.testing.expectEqual(@as(usize, 4), places.len);
    try std.testing.expect(places[0].kind == .binding);
    try std.testing.expect(places[1].kind == .property);
    try std.testing.expect(places[2].kind == .element);
    try std.testing.expect(places[3].kind == .super_property);

    const unknown = try result.makeId(hir.PlaceId, 99);
    try std.testing.expectError(error.PlaceUseBeforeDefinition, anf.emitValue(.{ .load_place = unknown }, unknown_type));
}

test "ANF builder preserves distinct super calls and new target" {
    var project = try completedProject();
    defer project.deinit();
    var result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer result.deinit();
    var raw_builder = hir.builder.Builder.init(&result, .{});
    var anf = try hir.anf_builder.AnfBuilder.init(&raw_builder);
    const unknown_type = project.semanticResult().?.type_store.builtins.unknown;
    _ = try anf.emitValue(.load_this, unknown_type);
    const receiver = try anf.emitValue(.load_super, unknown_type);
    _ = try anf.emitValue(.{ .load_meta = .import_meta }, unknown_type);
    const key = try anf.emitValue(.{ .constant = .{ .string = "key" } }, unknown_type);
    const argument = try anf.emitValue(.{ .constant = .null_ }, unknown_type);
    const arguments = try raw_builder.allocator.alloc(hir.model.CallArgument, 1);
    arguments[0] = .{ .value = argument };
    _ = try anf.emitValue(.{ .call_method = .{
        .receiver = receiver,
        .key = .{ .computed = key },
        .arguments = arguments,
    } }, unknown_type);
    _ = try anf.emitValue(.{ .call_super_method = .{
        .receiver = receiver,
        .key = .{ .computed = key },
        .arguments = arguments,
    } }, unknown_type);
    _ = try anf.emitValue(.{ .call_super_constructor = arguments }, unknown_type);
    _ = try anf.emitValue(.{ .load_meta = .new_target }, unknown_type);
    try anf.terminate(.{ .return_ = null });
    const blocks = try anf.finish();

    try std.testing.expectEqual(@as(usize, 9), blocks[0].instructions.len);
    try std.testing.expect(blocks[0].instructions[0].operation == .load_this);
    try std.testing.expectEqual(hir.model.MetaKind.import_meta, blocks[0].instructions[2].operation.load_meta);
    const method = blocks[0].instructions[5];
    switch (method.operation) {
        .call_method => |call| {
            try std.testing.expect(call.receiver.eql(receiver));
            try std.testing.expect(call.key.computed.eql(key));
            try std.testing.expectEqual(@as(usize, 1), call.arguments.len);
            try std.testing.expect(call.arguments[0].value.eql(argument));
        },
        else => return error.MissingMethodCall,
    }
    try std.testing.expect(blocks[0].instructions[6].operation == .call_super_method);
    try std.testing.expect(blocks[0].instructions[7].operation == .call_super_constructor);
    try std.testing.expect(blocks[0].instructions[8].operation == .load_meta);
    try std.testing.expectEqual(hir.model.MetaKind.new_target, blocks[0].instructions[8].operation.load_meta);
}

test "HIR operator lowering keeps semantic modes and selected evaluation explicit" {
    var project = try operatorLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const initialization = result.project.functions[result.project.functions.len - 1];
    var unary_operators: std.EnumSet(hir.model.UnaryOperator) = .initEmpty();
    var binary_operators: std.EnumSet(hir.model.BinaryOperator) = .initEmpty();
    var add_modes: std.EnumSet(hir.model.AddMode) = .initEmpty();
    var to_boolean_count: usize = 0;
    var is_nullish_count: usize = 0;
    var typeof_count: usize = 0;
    var void_count: usize = 0;
    var branch_count: usize = 0;
    var store_place_count: usize = 0;
    var undefined_count: usize = 0;
    var method_call_count: usize = 0;
    var preloaded_method_call_count: usize = 0;
    var selected_side_calls: usize = 0;

    for (initialization.blocks, 0..) |block, block_index| {
        switch (block.terminator) {
            .branch => branch_count += 1,
            else => {},
        }
        for (block.instructions) |instruction| switch (instruction.operation) {
            .unary => |unary| unary_operators.insert(unary.operator),
            .binary => |binary| binary_operators.insert(binary.operator),
            .add => |add| add_modes.insert(add.mode),
            .to_boolean => to_boolean_count += 1,
            .is_nullish => is_nullish_count += 1,
            .typeof_value => typeof_count += 1,
            .void_value => void_count += 1,
            .store_place => store_place_count += 1,
            .constant => |constant| switch (constant) {
                .undefined => undefined_count += 1,
                else => {},
            },
            .call_method => |call| {
                method_call_count += 1;
                if (call.callee != null) preloaded_method_call_count += 1;
            },
            .call => |call| if (block_index != 0) {
                const binding = findLoadedBinding(initialization, call.callee) orelse continue;
                if (std.mem.eql(u8, binding.name, "side")) selected_side_calls += 1;
            },
            else => {},
        };
    }

    for ([_]hir.model.UnaryOperator{ .plus, .negate, .logical_not, .bit_not }) |operator| try std.testing.expect(unary_operators.contains(operator));
    for ([_]hir.model.BinaryOperator{
        .subtract,     .multiply,        .divide,               .remainder,
        .exponentiate, .bit_and,         .bit_or,               .bit_xor,
        .shift_left,   .shift_right,     .shift_right_unsigned, .less,
        .less_equal,   .greater,         .greater_equal,        .equal_loose,
        .equal_strict, .not_equal_loose, .not_equal_strict,     .in,
        .instanceof,
    }) |operator| try std.testing.expect(binary_operators.contains(operator));
    try std.testing.expect(add_modes.contains(.dynamic));
    try std.testing.expectEqual(@as(usize, 5), to_boolean_count);
    try std.testing.expectEqual(@as(usize, 7), is_nullish_count);
    try std.testing.expectEqual(@as(usize, 1), typeof_count);
    // Mandatory canonicalization folds `void` to its literal `undefined` result.
    try std.testing.expectEqual(@as(usize, 0), void_count);
    try std.testing.expectEqual(@as(usize, 11), branch_count);
    try std.testing.expectEqual(@as(usize, 3), store_place_count);
    try std.testing.expectEqual(@as(usize, 6), undefined_count);
    try std.testing.expectEqual(@as(usize, 2), method_call_count);
    try std.testing.expectEqual(@as(usize, 1), preloaded_method_call_count);
    try std.testing.expectEqual(@as(usize, 9), selected_side_calls);
}

test "HIR access and call lowering preserves receivers order construction and runtime import" {
    var project = try accessCallLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const initialization = result.project.functions[result.project.functions.len - 1];
    var events: std.ArrayList([]const u8) = .empty;
    defer events.deinit(std.testing.allocator);
    var load_this_count: usize = 0;
    var load_super_count: usize = 0;
    var super_property_count: usize = 0;
    var import_meta_count: usize = 0;
    var new_target_count: usize = 0;
    var dynamic_import_count: usize = 0;

    for (initialization.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .call => |call| {
            const binding = findLoadedBinding(initialization, call.callee) orelse return error.MissingCallCallee;
            try events.append(std.testing.allocator, binding.name);
        },
        .call_method => try events.append(std.testing.allocator, "call_method"),
        .call_super_method => try events.append(std.testing.allocator, "call_super_method"),
        .call_super_constructor => try events.append(std.testing.allocator, "call_super_constructor"),
        .construct => try events.append(std.testing.allocator, "construct"),
        .load_this => load_this_count += 1,
        .load_super => load_super_count += 1,
        .make_super_place => super_property_count += 1,
        .load_meta => |kind| switch (kind) {
            .import_meta => import_meta_count += 1,
            .new_target => new_target_count += 1,
        },
        .dynamic_import => |import| {
            dynamic_import_count += 1;
            try std.testing.expectEqualStrings("source", (findLoadedBinding(initialization, import.source) orelse return error.MissingImportSource).name);
            try std.testing.expectEqualStrings("options", (findLoadedBinding(initialization, import.options orelse return error.MissingImportOptions) orelse return error.MissingImportOptions).name);
            try std.testing.expectEqual(@as(usize, 0), import.attributes.len);
        },
        else => {},
    };

    const expected = [_][]const u8{
        "arg",         "callable",
        "receiver",    "arg",
        "call_method", "arg",
        "construct",
    };
    try std.testing.expectEqual(expected.len, events.items.len);
    for (expected, events.items) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
    try std.testing.expectEqual(@as(usize, 0), load_this_count);
    try std.testing.expectEqual(@as(usize, 0), load_super_count);
    try std.testing.expectEqual(@as(usize, 0), super_property_count);
    try std.testing.expectEqual(@as(usize, 0), import_meta_count);
    try std.testing.expectEqual(@as(usize, 0), new_target_count);
    try std.testing.expectEqual(@as(usize, 1), dynamic_import_count);
}

test "HIR aggregate lowering preserves source order holes spread sites and regexp identity" {
    var project = try aggregateLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const initialization = result.project.functions[result.project.functions.len - 1];
    var call_events: std.ArrayList([]const u8) = .empty;
    defer call_events.deinit(std.testing.allocator);
    var sites: std.ArrayList(hir.SourceSiteId) = .empty;
    defer sites.deinit(std.testing.allocator);
    var define_property_count: usize = 0;
    var define_method_count: usize = 0;
    var copy_object_count: usize = 0;
    var append_count: usize = 0;
    var hole_count: usize = 0;
    var iterable_count: usize = 0;
    var spread_argument_count: usize = 0;
    var build_string_count: usize = 0;
    var to_string_count: usize = 0;
    var template_site_count: usize = 0;
    var tagged_call_count: usize = 0;
    var tagged_receiver_count: usize = 0;
    var regexp_count: usize = 0;
    var first_template_site_instruction: ?usize = null;
    var tagged_substitution_instruction: ?usize = null;
    var instruction_index: usize = 0;

    for (initialization.blocks) |block| for (block.instructions) |instruction| {
        defer instruction_index += 1;
        switch (instruction.operation) {
            .call => |call| {
                for (call.arguments) |argument| {
                    if (argument == .spread) spread_argument_count += 1;
                }
                const binding = findLoadedBinding(initialization, call.callee) orelse continue;
                try call_events.append(std.testing.allocator, binding.name);
                if (std.mem.eql(u8, binding.name, "value") and first_template_site_instruction != null and tagged_substitution_instruction == null)
                    tagged_substitution_instruction = instruction_index;
            },
            .define_property => define_property_count += 1,
            .define_method => |method| {
                define_method_count += 1;
                try std.testing.expect(method.kind == .method or method.kind == .getter or method.kind == .setter);
            },
            .copy_object_properties => copy_object_count += 1,
            .array_append => append_count += 1,
            .array_append_hole => hole_count += 1,
            .array_append_iterable => iterable_count += 1,
            .build_string => |parts| {
                build_string_count += 1;
                try std.testing.expectEqual(@as(usize, 3), parts.len);
            },
            .to_string => to_string_count += 1,
            .create_template_site => |site| {
                template_site_count += 1;
                if (first_template_site_instruction == null) first_template_site_instruction = instruction_index;
                try result.requireOwnedId(site.source_site);
                try sites.append(std.testing.allocator, site.source_site);
                try std.testing.expectEqual(site.raw.len, site.cooked.len);
                if (template_site_count == 1) {
                    try std.testing.expectEqualStrings("raw", site.raw[0]);
                    try std.testing.expectEqualStrings("tail", site.raw[1]);
                    try std.testing.expectEqualStrings("raw", site.cooked[0].?);
                    try std.testing.expectEqualStrings("tail", site.cooked[1].?);
                }
            },
            .tagged_template_call => |call| {
                tagged_call_count += 1;
                if (call.receiver != null) tagged_receiver_count += 1;
            },
            .create_regexp => |regexp| {
                regexp_count += 1;
                try std.testing.expectEqualStrings("a+", regexp.pattern);
                try std.testing.expectEqualStrings("gi", regexp.flags);
                try result.requireOwnedId(regexp.source_site);
                try sites.append(std.testing.allocator, regexp.source_site);
            },
            else => {},
        }
    };

    const object_call_prefix = [_][]const u8{ "value", "key", "value", "spread" };
    try std.testing.expect(call_events.items.len >= object_call_prefix.len);
    for (object_call_prefix, call_events.items[0..object_call_prefix.len]) |wanted, actual| try std.testing.expectEqualStrings(wanted, actual);
    try std.testing.expectEqual(@as(usize, 2), define_property_count);
    try std.testing.expectEqual(@as(usize, 3), define_method_count);
    try std.testing.expectEqual(@as(usize, 1), copy_object_count);
    try std.testing.expectEqual(@as(usize, 1), append_count);
    try std.testing.expectEqual(@as(usize, 1), hole_count);
    try std.testing.expectEqual(@as(usize, 1), iterable_count);
    try std.testing.expectEqual(@as(usize, 1), spread_argument_count);
    try std.testing.expectEqual(@as(usize, 1), build_string_count);
    try std.testing.expectEqual(@as(usize, 1), to_string_count);
    try std.testing.expectEqual(@as(usize, 2), template_site_count);
    try std.testing.expectEqual(@as(usize, 2), tagged_call_count);
    try std.testing.expectEqual(@as(usize, 1), tagged_receiver_count);
    try std.testing.expectEqual(@as(usize, 2), regexp_count);
    try std.testing.expect(first_template_site_instruction.? < tagged_substitution_instruction.?);
    try std.testing.expectEqual(@as(usize, 4), sites.items.len);
    for (sites.items, 0..) |site, left| for (sites.items[left + 1 ..]) |other| try std.testing.expect(!site.eql(other));
}

test "HIR function lowering unifies parameters flags bodies and explicit captures" {
    var project = try functionLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var saw_default_rest = false;
    var saw_lexical_this = false;
    var saw_live_capture = false;
    var method_count: usize = 0;
    var getter_count: usize = 0;
    var setter_count: usize = 0;
    var async_count: usize = 0;
    var generator_count: usize = 0;
    var async_generator_count: usize = 0;
    for (result.project.functions) |function| {
        try std.testing.expect(function.blocks.len != 0);
        try std.testing.expect(function.entry.index() != null);
        if (function.flags.async_) async_count += 1;
        if (function.flags.generator) generator_count += 1;
        if (function.flags.async_generator) async_generator_count += 1;
        switch (function.kind) {
            .method => method_count += 1,
            .getter => getter_count += 1,
            .setter => setter_count += 1,
            else => {},
        }
        if (function.parameters.len == 2 and function.parameters[0].has_default and function.parameters[1].rest) {
            saw_default_rest = true;
            try std.testing.expectEqual(@as(u32, 0), function.parameters[0].argument_index);
            try std.testing.expectEqual(@as(u32, 1), function.parameters[1].argument_index);
            var read_first = false;
            var collect_second = false;
            var branch_default = false;
            for (function.blocks) |block| {
                switch (block.terminator) {
                    .branch => branch_default = true,
                    else => {},
                }
                for (block.instructions) |instruction| switch (instruction.operation) {
                    .read_argument => |index| if (index == 0) {
                        read_first = true;
                    },
                    .collect_rest_arguments => |index| if (index == 1) {
                        collect_second = true;
                    },
                    else => {},
                };
            }
            try std.testing.expect(read_first and collect_second and branch_default);
        }
        if (function.flags.lexical_this) {
            try std.testing.expect(!function.flags.dynamic_this);
            for (function.captures) |capture| switch (capture.source) {
                .this => {
                    saw_lexical_this = true;
                    try std.testing.expectEqual(hir.model.CaptureMode.lexical_value, capture.mode);
                },
                else => {},
            };
        }
        for (function.captures) |capture| switch (capture.source) {
            .binding => {
                saw_live_capture = true;
                try std.testing.expectEqual(hir.model.CaptureMode.live_binding, capture.mode);
            },
            else => {},
        };
    }

    try std.testing.expect(saw_default_rest);
    try std.testing.expect(saw_lexical_this);
    try std.testing.expect(saw_live_capture);
    try std.testing.expectEqual(@as(usize, 1), method_count);
    try std.testing.expectEqual(@as(usize, 1), getter_count);
    try std.testing.expectEqual(@as(usize, 1), setter_count);
    try std.testing.expectEqual(@as(usize, 2), async_count);
    try std.testing.expectEqual(@as(usize, 1), generator_count);
    try std.testing.expectEqual(@as(usize, 1), async_generator_count);
}

test "HIR suspension lowering preserves async generator and async iterator semantics" {
    var project = try suspensionLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .minimal);
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var async_count: usize = 0;
    var generator_count: usize = 0;
    var async_generator_count: usize = 0;
    var await_count: usize = 0;
    var yield_count: usize = 0;
    var yield_delegate_count: usize = 0;
    var async_iterator_count: usize = 0;
    var iterator_close_count: usize = 0;
    var suspension_count: usize = 0;
    var async_iterator_state: ?hir.ValueId = null;
    var closed_iterator_state: ?hir.ValueId = null;
    var saw_async_iterator_region = false;

    for (result.project.functions) |function| {
        if (function.flags.async_) async_count += 1;
        if (function.flags.generator) generator_count += 1;
        if (function.flags.async_generator) async_generator_count += 1;
        const consumes_async_iterator = hasBinding(function, "iterable");
        for (function.regions) |region_id| {
            const region = result.project.regions[region_id.index().?];
            if (consumes_async_iterator and region.kind == .iterator_close) saw_async_iterator_region = true;
        }
        for (function.blocks) |block| for (block.instructions) |instruction| {
            switch (instruction.operation) {
                .await_ => await_count += 1,
                .yield_ => yield_count += 1,
                .yield_delegate => yield_delegate_count += 1,
                .get_async_iterator => {
                    async_iterator_count += 1;
                    async_iterator_state = instruction.result;
                },
                .iterator_close => |state| {
                    iterator_close_count += 1;
                    if (consumes_async_iterator) closed_iterator_state = state;
                },
                else => {},
            }
            if (instruction.effects.may_suspend) {
                suspension_count += 1;
                try std.testing.expect(instruction.result != null);
                try std.testing.expect(instruction.result_type != null);
                try result.requireOwnedId(instruction.origin);
            }
        };
    }

    try std.testing.expectEqual(@as(usize, 3), async_count);
    try std.testing.expectEqual(@as(usize, 1), generator_count);
    try std.testing.expectEqual(@as(usize, 1), async_generator_count);
    try std.testing.expectEqual(@as(usize, 3), await_count);
    try std.testing.expectEqual(@as(usize, 2), yield_count);
    try std.testing.expectEqual(@as(usize, 1), yield_delegate_count);
    try std.testing.expectEqual(@as(usize, 1), async_iterator_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_close_count);
    try std.testing.expectEqual(@as(usize, 7), suspension_count);
    try std.testing.expect(saw_async_iterator_region);
    try std.testing.expect((async_iterator_state orelse return error.MissingAsyncIterator).eql(closed_iterator_state orelse return error.MissingAsyncIteratorClose));
}

test "HIR class enum and module initialization lowering preserves ordered semantic plans" {
    var project = try classEnumLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var class_count: usize = 0;
    var enum_count: usize = 0;
    var saw_derived = false;
    var saw_expression = false;
    var saw_nested_class_binding = false;
    var saw_nested_enum_binding = false;
    for (result.project.functions) |function| for (function.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "Local")) {
            try std.testing.expectEqual(hir.model.HirBindingKind.class, binding.kind);
            try std.testing.expectEqual(hir.model.HirBindingInitialState.temporal_dead_zone, binding.initial_state);
            saw_nested_class_binding = true;
        }
        if (std.mem.eql(u8, binding.name, "LocalEnum")) {
            try std.testing.expectEqual(hir.model.HirBindingKind.enum_, binding.kind);
            try std.testing.expectEqual(hir.model.HirBindingInitialState.temporal_dead_zone, binding.initial_state);
            saw_nested_enum_binding = true;
        }
    };
    for (result.project.entities) |entity| switch (entity.kind) {
        .class => |class| {
            class_count += 1;
            if (class.methods.len == 3) {
                saw_derived = true;
                try std.testing.expect(class.instance_initializer != null);
                try std.testing.expect(class.static_initializer != null);
                const instance = result.project.functions[class.instance_initializer.?.index().?];
                const static = result.project.functions[class.static_initializer.?.index().?];
                var instance_names: std.ArrayList([]const u8) = .empty;
                defer instance_names.deinit(std.testing.allocator);
                var static_names: std.ArrayList([]const u8) = .empty;
                defer static_names.deinit(std.testing.allocator);
                for (instance.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                    .define_property => |define| switch (define.key) {
                        .static => |name| try instance_names.append(std.testing.allocator, name),
                        .computed => {},
                        .private => {},
                    },
                    else => {},
                };
                for (static.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                    .define_property => |define| switch (define.key) {
                        .static => |name| try static_names.append(std.testing.allocator, name),
                        .computed => {},
                        .private => {},
                    },
                    else => {},
                };
                try std.testing.expectEqual(@as(usize, 2), instance_names.items.len);
                try std.testing.expectEqualStrings("first", instance_names.items[0]);
                try std.testing.expectEqualStrings("second", instance_names.items[1]);
                try std.testing.expectEqual(@as(usize, 2), static_names.items.len);
                try std.testing.expectEqualStrings("alpha", static_names.items[0]);
                try std.testing.expectEqualStrings("omega", static_names.items[1]);

                const constructor = result.project.functions[class.constructor.index().?];
                try std.testing.expectEqual(@as(usize, 1), constructor.parameters.len);
                try std.testing.expect(constructor.parameters[0].parameter_property);
                var super_index: ?usize = null;
                var property_index: ?usize = null;
                var operation_index: usize = 0;
                for (constructor.blocks) |block| for (block.instructions) |instruction| {
                    switch (instruction.operation) {
                        .call_super_constructor => super_index = operation_index,
                        .define_property => |define| switch (define.key) {
                            .static => |name| if (std.mem.eql(u8, name, "property")) {
                                property_index = operation_index;
                            },
                            .computed => {},
                            .private => {},
                        },
                        else => {},
                    }
                    operation_index += 1;
                };
                try std.testing.expect((super_index orelse return error.MissingSuperCall) < (property_index orelse return error.MissingParameterProperty));
            } else if (class.instance_initializer != null) {
                const initializer = result.project.functions[class.instance_initializer.?.index().?];
                for (initializer.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                    .define_property => |define| switch (define.key) {
                        .static => |name| if (std.mem.eql(u8, name, "field")) {
                            saw_expression = true;
                        },
                        .computed => {},
                        .private => {},
                    },
                    else => {},
                };
            }
        },
        .enum_object => enum_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), class_count);
    try std.testing.expectEqual(@as(usize, 3), enum_count);
    try std.testing.expect(saw_derived);
    try std.testing.expect(saw_expression);
    try std.testing.expect(saw_nested_class_binding);
    try std.testing.expect(saw_nested_enum_binding);

    const initialization = result.project.functions[result.project.modules[0].initialization.index().?];
    var enum_definition_counts: [2]usize = .{ 0, 0 };
    var active_enum: ?usize = null;
    var enum_index: usize = 0;
    for (initialization.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .create_enum_object => {
            active_enum = enum_index;
            enum_index += 1;
        },
        .define_property => {
            if (active_enum) |index| enum_definition_counts[index] += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), enum_index);
    try std.testing.expectEqual(@as(usize, 6), enum_definition_counts[0]);
    try std.testing.expectEqual(@as(usize, 2), enum_definition_counts[1]);
}

test "HIR control lowering eliminates structured branches and loops with iterator cleanup" {
    var project = try controlFlowLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var branch_count: usize = 0;
    var jump_count: usize = 0;
    var enumerate_count: usize = 0;
    var enumerator_next_count: usize = 0;
    var enumerator_done_count: usize = 0;
    var enumerator_value_count: usize = 0;
    var iterator_count: usize = 0;
    var iterator_next_count: usize = 0;
    var iterator_done_count: usize = 0;
    var iterator_value_count: usize = 0;
    var iterator_close_count: usize = 0;
    var leave_return_count: usize = 0;
    var resume_count: usize = 0;
    var done_normal_exit_count: usize = 0;

    try std.testing.expectEqual(@as(usize, 1), result.project.regions.len);
    const region = result.project.regions[0];
    try std.testing.expectEqual(hir.model.HirRegionKind.iterator_close, region.kind);
    try std.testing.expect(region.continuation != null);
    try std.testing.expect(region.protected_blocks.len != 0);

    for (result.project.functions) |function| {
        var owns_region = false;
        for (function.regions) |region_id| {
            if (region_id.eql(region.id)) owns_region = true;
        }
        if (function.id.eql(region.function)) try std.testing.expect(owns_region);

        for (function.blocks) |block| {
            switch (block.terminator) {
                .branch => |branch| {
                    branch_count += 1;
                    if (operationForValue(function, branch.condition) == .iterator_done and branch.true_target.eql(region.continuation.?)) {
                        done_normal_exit_count += 1;
                    }
                },
                .jump => jump_count += 1,
                .leave_region => |leave| switch (leave.completion) {
                    .return_ => {
                        leave_return_count += 1;
                        try std.testing.expect(leave.region.eql(region.id));
                        try std.testing.expect(leave.cleanup.eql(region.handler));
                    },
                    else => {},
                },
                .resume_completion => {
                    resume_count += 1;
                    try std.testing.expect(block.id.eql(region.handler));
                },
                else => {},
            }
            for (block.instructions) |instruction| switch (instruction.operation) {
                .enumerate_properties => enumerate_count += 1,
                .enumerator_next => enumerator_next_count += 1,
                .enumerator_done => enumerator_done_count += 1,
                .enumerator_value => enumerator_value_count += 1,
                .get_iterator => iterator_count += 1,
                .iterator_next => iterator_next_count += 1,
                .iterator_done => iterator_done_count += 1,
                .iterator_value => iterator_value_count += 1,
                .iterator_close => {
                    iterator_close_count += 1;
                    try std.testing.expect(block.id.eql(region.handler));
                },
                else => {},
            };
        }
    }

    try std.testing.expectEqual(@as(usize, 7), branch_count);
    try std.testing.expect(jump_count >= 12);
    try std.testing.expectEqual(@as(usize, 1), enumerate_count);
    try std.testing.expectEqual(@as(usize, 1), enumerator_next_count);
    try std.testing.expectEqual(@as(usize, 1), enumerator_done_count);
    try std.testing.expectEqual(@as(usize, 1), enumerator_value_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_next_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_done_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_value_count);
    try std.testing.expectEqual(@as(usize, 1), iterator_close_count);
    try std.testing.expectEqual(@as(usize, 1), leave_return_count);
    try std.testing.expectEqual(@as(usize, 1), resume_count);
    try std.testing.expectEqual(@as(usize, 1), done_normal_exit_count);
}

test "HIR switch and label lowering preserves ordered tests and exact control targets" {
    var project = try switchAndLabelLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var saw_switch = false;
    var saw_classic_label = false;
    var saw_iterator_label = false;
    for (result.project.functions) |function| {
        if (hasBinding(function, "marker")) {
            saw_switch = true;
            var test_blocks: [3]hir.BlockId = undefined;
            var true_targets: [3]hir.BlockId = undefined;
            var false_targets: [3]hir.BlockId = undefined;
            var test_count: usize = 0;
            var discriminant: ?hir.ValueId = null;
            for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                .binary => |binary| if (binary.operator == .equal_strict) {
                    try std.testing.expect(test_count < test_blocks.len);
                    try std.testing.expectEqual(std.meta.Tag(hir.HirOperation).call, operationForValue(function, binary.right));
                    if (discriminant) |value|
                        try std.testing.expect(value.eql(binary.left))
                    else {
                        discriminant = binary.left;
                        try std.testing.expectEqual(std.meta.Tag(hir.HirOperation).call, operationForValue(function, binary.left));
                    }
                    const branch = switch (block.terminator) {
                        .branch => |value| value,
                        else => return error.ExpectedSwitchBranch,
                    };
                    test_blocks[test_count] = block.id;
                    true_targets[test_count] = branch.true_target;
                    false_targets[test_count] = branch.false_target;
                    test_count += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 3), test_count);
            try std.testing.expect(false_targets[0].eql(test_blocks[1]));
            try std.testing.expect(false_targets[1].eql(test_blocks[2]));
            const default_target = false_targets[2];
            const first_body = try findBlock(function, true_targets[0]);
            const default_body = try findBlock(function, default_target);
            const second_body = try findBlock(function, true_targets[1]);
            const third_body = try findBlock(function, true_targets[2]);
            const first_fallthrough = switch (first_body.terminator) {
                .jump => |jump| jump.target,
                else => return error.ExpectedCaseFallthrough,
            };
            const default_fallthrough = switch (default_body.terminator) {
                .jump => |jump| jump.target,
                else => return error.ExpectedCaseFallthrough,
            };
            const switch_exit = switch (second_body.terminator) {
                .jump => |jump| jump.target,
                else => return error.ExpectedSwitchBreak,
            };
            const final_fallthrough = switch (third_body.terminator) {
                .jump => |jump| jump.target,
                else => return error.ExpectedCaseFallthrough,
            };
            try std.testing.expect(first_fallthrough.eql(default_target));
            try std.testing.expect(default_fallthrough.eql(true_targets[1]));
            try std.testing.expect(final_fallthrough.eql(switch_exit));
        }

        if (hasBinding(function, "limit")) {
            saw_classic_label = true;
            const index_binding = try findBinding(function, "index", 0);
            var index_place: ?hir.PlaceId = null;
            for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                .make_binding_place => |place| {
                    if (place.binding.eql(index_binding.id)) index_place = place.result;
                },
                else => {},
            };
            var update_block: ?hir.BlockId = null;
            for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
                .store_place => |store| if (store.place.eql(index_place orelse return error.MissingIndexPlace)) {
                    try std.testing.expect(update_block == null);
                    update_block = block.id;
                },
                else => {},
            };
            // The update remains exactly once; canonicalization may legally
            // merge its jump-only predecessor into this block.
            _ = update_block orelse return error.MissingForUpdate;
        }

        if (hasBinding(function, "iterable")) {
            saw_iterator_label = true;
            try std.testing.expectEqual(@as(usize, 1), function.regions.len);
            const region = result.project.regions[function.regions[0].index().?];
            var next_block: ?hir.BlockId = null;
            var jumps_to_next: usize = 0;
            var break_target: ?hir.BlockId = null;
            var continue_completion_count: usize = 0;
            for (function.blocks) |block| {
                for (block.instructions) |instruction| switch (instruction.operation) {
                    .iterator_next => next_block = block.id,
                    else => {},
                };
                switch (block.terminator) {
                    .leave_region => |leave| switch (leave.completion) {
                        .break_ => |target| {
                            try std.testing.expect(leave.region.eql(region.id));
                            break_target = target;
                        },
                        .continue_ => continue_completion_count += 1,
                        else => {},
                    },
                    else => {},
                }
            }
            const iterator_next_block = next_block orelse return error.MissingIteratorNext;
            for (function.blocks) |block| switch (block.terminator) {
                .jump => |jump| if (jump.target.eql(iterator_next_block)) {
                    jumps_to_next += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 2), jumps_to_next);
            try std.testing.expectEqual(@as(usize, 0), continue_completion_count);
            try std.testing.expect(!(break_target orelse return error.MissingLabeledBreak).eql(region.continuation.?));
        }
    }

    try std.testing.expect(saw_switch);
    try std.testing.expect(saw_classic_label);
    try std.testing.expect(saw_iterator_label);
}

test "HIR exception lowering uses catch entry and resumable cleanup regions" {
    var project = try exceptionLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var saw_module_finally = false;
    var saw_catch_only = false;
    var saw_nested = false;
    var saw_transfers = false;
    for (result.project.functions) |function| {
        var catch_count: usize = 0;
        var finally_count: usize = 0;
        var iterator_count: usize = 0;
        var normal_count: usize = 0;
        var return_count: usize = 0;
        var throw_count: usize = 0;
        var break_count: usize = 0;
        var continue_count: usize = 0;
        var resume_count: usize = 0;
        for (function.regions) |region_id| {
            const region = result.project.regions[region_id.index().?];
            switch (region.kind) {
                .catch_ => {
                    catch_count += 1;
                    const handler = try findBlock(function, region.handler);
                    try std.testing.expectEqual(@as(usize, 1), handler.parameters.len);
                    var initialized_catch = false;
                    for (handler.instructions) |instruction| switch (instruction.operation) {
                        .initialize_binding => |initialize| for (function.bindings) |binding| {
                            if (binding.id.eql(initialize.binding) and binding.kind == .catch_) initialized_catch = true;
                        },
                        else => {},
                    };
                    try std.testing.expect(initialized_catch);
                },
                .finally => {
                    finally_count += 1;
                    const handler = try findBlock(function, region.handler);
                    switch (handler.terminator) {
                        .resume_completion, .return_, .branch, .jump => {},
                        else => return error.ExpectedFinallyCompletion,
                    }
                },
                .iterator_close => iterator_count += 1,
            }
        }
        for (function.blocks) |block| {
            switch (block.terminator) {
                .leave_region => |leave| switch (leave.completion) {
                    .normal => normal_count += 1,
                    .return_ => return_count += 1,
                    .throw => throw_count += 1,
                    .break_ => break_count += 1,
                    .continue_ => continue_count += 1,
                },
                .resume_completion => resume_count += 1,
                else => {},
            }
        }

        if (hasBinding(function, "moduleMarker")) {
            saw_module_finally = true;
            try std.testing.expectEqual(@as(usize, 1), finally_count);
            try std.testing.expectEqual(@as(usize, 1), normal_count);
            try std.testing.expectEqual(@as(usize, 1), resume_count);
        }
        if (hasBinding(function, "caughtValue") and finally_count == 0) {
            saw_catch_only = true;
            try std.testing.expectEqual(@as(usize, 1), catch_count);
            try std.testing.expectEqual(@as(usize, 0), return_count);
        } else if (hasBinding(function, "caughtValue")) {
            saw_nested = true;
            try std.testing.expectEqual(@as(usize, 1), catch_count);
            try std.testing.expectEqual(@as(usize, 1), finally_count);
            try std.testing.expect(return_count != 0);
            try std.testing.expect(throw_count != 0);
            try std.testing.expect(resume_count != 0);
            const catch_region = result.project.regions[function.regions[0].index().?];
            try std.testing.expect(catch_region.parent != null);
        }
        if (hasBinding(function, "values")) {
            saw_transfers = true;
            try std.testing.expectEqual(@as(usize, 1), finally_count);
            try std.testing.expectEqual(@as(usize, 1), iterator_count);
            try std.testing.expect(break_count != 0);
            try std.testing.expect(continue_count != 0);
        }
    }

    try std.testing.expect(saw_module_finally);
    try std.testing.expect(saw_catch_only);
    try std.testing.expect(saw_nested);
    try std.testing.expect(saw_transfers);
}

test "HIR region validation rejects illegal cleanup exit and protected entry" {
    var project = try exceptionLoweringProject();
    defer project.deinit();

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    var selected_function: ?hir.HirFunction = null;
    var selected_region: ?hir.RegionId = null;
    find_leave: for (result.project.functions) |candidate| for (candidate.blocks) |block| switch (block.terminator) {
        .leave_region => |leave| {
            selected_function = candidate;
            selected_region = leave.region;
            break :find_leave;
        },
        else => {},
    };
    const function = selected_function orelse return error.MissingExceptionRegion;
    const first_region = result.project.regions[(selected_region orelse return error.MissingExceptionRegion).index().?];

    const bad_exit_blocks = try std.testing.allocator.dupe(hir.HirBlock, function.blocks);
    defer std.testing.allocator.free(bad_exit_blocks);
    var changed_exit = false;
    for (bad_exit_blocks) |*block| switch (block.terminator) {
        .leave_region => |leave| {
            block.terminator = .{ .leave_region = .{
                .region = leave.region,
                .completion = leave.completion,
                .cleanup = first_region.continuation orelse return error.MissingRegionContinuation,
            } };
            changed_exit = true;
            break;
        },
        else => {},
    };
    try std.testing.expect(changed_exit);
    var bad_exit_function = function;
    bad_exit_function.blocks = bad_exit_blocks;
    try std.testing.expectError(
        error.InvalidRegion,
        hir.region_validation.validateFunction(std.testing.allocator, &bad_exit_function, result.project.regions),
    );

    if (first_region.protected_blocks.len < 2) return error.MissingNestedProtectedBlock;
    const bad_entry_blocks = try std.testing.allocator.dupe(hir.HirBlock, function.blocks);
    defer std.testing.allocator.free(bad_entry_blocks);
    const handler_index = for (bad_entry_blocks, 0..) |block, index| {
        if (block.id.eql(first_region.handler)) break index;
    } else return error.MissingRegionHandler;
    bad_entry_blocks[handler_index].terminator = .{ .jump = .{ .target = first_region.protected_blocks[1] } };
    var bad_entry_function = function;
    bad_entry_function.blocks = bad_entry_blocks;
    try std.testing.expectError(
        error.InvalidRegion,
        hir.region_validation.validateFunction(std.testing.allocator, &bad_entry_function, result.project.regions),
    );
}

fn findBlock(function: hir.HirFunction, id: hir.BlockId) !hir.HirBlock {
    for (function.blocks) |block| if (block.id.eql(id)) return block;
    return error.MissingHirBlock;
}

fn operationForValue(function: hir.HirFunction, value: hir.ValueId) std.meta.Tag(hir.HirOperation) {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result != null and instruction.result.?.eql(value)) return instruction.operation;
    };
    unreachable;
}

fn findLoadedBinding(function: hir.HirFunction, value: hir.ValueId) ?hir.HirBinding {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result == null or !instruction.result.?.eql(value)) continue;
        const binding_id = switch (instruction.operation) {
            .load_binding => |binding| binding,
            else => return null,
        };
        for (function.bindings) |binding| if (binding.id.eql(binding_id)) return binding;
    };
    return null;
}

test "HIR project lowering reports output limits without partial result" {
    var project = try completedProject();
    defer project.deinit();
    var configured: hir.Limits = .{};
    configured.functions = 0;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, configured);
    defer outcome.deinit();
    const report = switch (outcome) {
        .result => return error.UnexpectedLoweringSuccess,
        .diagnostics => |*value| value,
    };
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(hir.DiagnosticCode.resource_limit, report.diagnostics[0].code);
    try std.testing.expectEqual(hir.LimitKind.functions, report.diagnostics[0].limit.?.kind);
}

test "HIR canonicalization folds local values and preserves identity effects" {
    var project = try completedProject();
    defer project.deinit();
    var result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer result.deinit();
    var raw_builder = hir.builder.Builder.init(&result, .{});
    const unknown_type = project.semanticResult().?.type_store.builtins.unknown;

    var anf = try hir.anf_builder.AnfBuilder.init(&raw_builder);
    const live = try anf.createBlock();
    const dead = try anf.createBlock();
    const one = try anf.emitValue(.{ .constant = .{ .number = 1 } }, unknown_type);
    const two = try anf.emitValue(.{ .constant = .{ .number = 2 } }, unknown_type);
    const sum = try anf.emitValue(.{ .add = .{ .left = one, .right = two, .mode = .numeric } }, unknown_type);
    const copied = try anf.emitValue(.{ .copy = sum }, unknown_type);
    const condition = try anf.emitValue(.{ .constant = .{ .boolean = true } }, unknown_type);
    try anf.terminate(.{ .branch = .{ .condition = condition, .true_target = live, .false_target = dead } });
    try anf.beginBlock(live);
    _ = try anf.emitValue(.create_object, unknown_type);
    try anf.terminate(.{ .return_ = copied });
    try anf.beginBlock(dead);
    const unused = try anf.emitValue(.{ .constant = .{ .number = 99 } }, unknown_type);
    try anf.terminate(.{ .return_ = unused });
    const entry = anf.entry;
    try raw_builder.appendFunction(.{
        .id = try raw_builder.makeId(hir.FunctionId, 0),
        .module_id = .init(1),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = unknown_type,
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = entry,
        .origin = .invalid,
    });

    var empty_return = try hir.anf_builder.AnfBuilder.init(&raw_builder);
    const undefined_value = try empty_return.emitValue(.{ .constant = .undefined }, unknown_type);
    try empty_return.terminate(.{ .return_ = undefined_value });
    const empty_entry = empty_return.entry;
    try raw_builder.appendFunction(.{
        .id = try raw_builder.makeId(hir.FunctionId, 1),
        .module_id = .init(1),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = unknown_type,
        .places = try empty_return.finishPlaces(),
        .blocks = try empty_return.finish(),
        .entry = empty_entry,
        .origin = .invalid,
    });

    try hir.canonicalize.run(&raw_builder);
    const folded = raw_builder.functions.items[0];
    try std.testing.expectEqual(@as(usize, 2), folded.blocks.len);
    try std.testing.expect(folded.blocks[0].terminator == .jump);
    try std.testing.expect(folded.blocks[0].terminator.jump.target.eql(live));
    var saw_identity = false;
    var folded_sum: ?hir.ValueId = null;
    for (folded.blocks) |folded_block| for (folded_block.instructions) |instruction| switch (instruction.operation) {
        .create_object => {
            saw_identity = instruction.effects.creates_identity;
        },
        .constant => |constant| if (constant == .number and constant.number == 3) {
            folded_sum = instruction.result;
        },
        else => {},
    };
    try std.testing.expect(saw_identity);
    try std.testing.expect(folded_sum != null);
    try std.testing.expect(folded.blocks[1].terminator.return_.?.eql(folded_sum.?));

    const normalized = raw_builder.functions.items[1];
    try std.testing.expectEqual(@as(usize, 1), normalized.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), normalized.blocks[0].instructions.len);
    try std.testing.expect(normalized.blocks[0].terminator.return_ == null);
}

test "HIR canonicalization reports its dedicated rewrite budget" {
    var project = try operatorLoweringProject();
    defer project.deinit();
    var configured: hir.Limits = .{};
    configured.rewrites = 0;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, configured);
    defer outcome.deinit();
    const report = switch (outcome) {
        .result => return error.UnexpectedLoweringSuccess,
        .diagnostics => |*value| value,
    };
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(hir.DiagnosticCode.canonicalization_budget, report.diagnostics[0].code);
    try std.testing.expect(report.diagnostics[0].limit == null);
    try std.testing.expectEqualStrings("VZG7009", hir.diagnostics.codeId(report.diagnostics[0].code));
}

test "HIR verifier rejects corrupted ID and operation families deterministically" {
    var project = try completedProject();
    defer project.deinit();
    var result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer result.deinit();
    var builder = hir.builder.Builder.init(&result, .{});
    const unknown_type = project.semanticResult().?.type_store.builtins.unknown;

    try builder.reserve(.functions, 1);
    const function_id = try builder.makeId(hir.FunctionId, 0);
    const binding_id = try builder.makeId(hir.BindingId, 0);
    var bindings: std.ArrayList(hir.HirBinding) = .empty;
    try builder.appendBinding(&bindings, .{
        .id = binding_id,
        .name = "x",
        .kind = .let_,
        .type_id = unknown_type,
        .declaration = null,
        .mutable = true,
        .initial_state = .initialized,
        .origin = .invalid,
    });

    var anf = try hir.anf_builder.AnfBuilder.init(&builder);
    const original = try anf.emitValue(.{ .constant = .{ .number = 1 } }, unknown_type);
    const copied = try anf.emitValue(.{ .copy = original }, unknown_type);
    _ = try anf.emitPlace(.{ .binding = binding_id });
    try anf.terminate(.{ .return_ = copied });
    const entry = anf.entry;
    try builder.appendFunction(.{
        .id = function_id,
        .module_id = .init(1),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = unknown_type,
        .bindings = try bindings.toOwnedSlice(builder.allocator),
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = entry,
        .origin = try builder.nextOrigin(),
    });
    const entity_id = try builder.makeId(hir.EntityId, 0);
    try builder.appendEntity(.{
        .id = entity_id,
        .module_id = .init(1),
        .declaration = null,
        .origin = .invalid,
        .kind = .{ .function = .{ .function = function_id } },
    });
    try builder.appendModule(.{
        .module_id = .init(1),
        .logical_name = "hir:verifier",
        .initialization = function_id,
        .entities = try builder.allocator.dupe(hir.EntityId, &.{entity_id}),
        .origin = .invalid,
    });

    try std.testing.expect((try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)) == null);
    try std.testing.expectEqual(hir.DiagnosticCode.internal_invariant, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .canonical)).?);

    var function = &builder.functions.items[0];
    const blocks = @constCast(function.blocks);
    const instructions = @constCast(blocks[0].instructions);
    const places = @constCast(function.places);
    const function_bindings = @constCast(function.bindings);

    const saved_function_id = function.id;
    function.id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.internal_invariant, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    function.id = saved_function_id;

    const saved_entity_id = builder.entities.items[0].id;
    builder.entities.items[0].id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.internal_invariant, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    builder.entities.items[0].id = saved_entity_id;

    const saved_block_id = blocks[0].id;
    blocks[0].id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_cfg, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    blocks[0].id = saved_block_id;

    const saved_instruction_id = instructions[0].id;
    instructions[0].id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.internal_invariant, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].id = saved_instruction_id;

    const saved_value_id = instructions[0].result.?;
    instructions[0].result = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].result = saved_value_id;

    const saved_binding_id = function_bindings[0].id;
    function_bindings[0].id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    function_bindings[0].id = saved_binding_id;

    const saved_place_id = places[0].id;
    places[0].id = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    places[0].id = saved_place_id;

    const saved_regions = function.regions;
    function.regions = &.{hir.RegionId.invalid};
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_region, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    function.regions = saved_regions;

    var foreign_result = try hir.HirResult.initEmpty(std.testing.allocator, project.semanticResult().?);
    defer foreign_result.deinit();
    const saved_origin = function.origin;
    function.origin = try foreign_result.makeId(hir.OriginId, 0);
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_semantic_reference, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    function.origin = saved_origin;

    const saved_operation = instructions[0].operation;
    const saved_effects = instructions[0].effects;
    instructions[0].operation = .{ .create_regexp = .{ .pattern = "x", .flags = "", .source_site = .invalid } };
    instructions[0].effects = instructions[0].operation.effectSet();
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_semantic_reference, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].operation = saved_operation;
    instructions[0].effects = saved_effects;

    const saved_result_type = instructions[0].result_type.?;
    instructions[0].result_type = 0;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_semantic_reference, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].result_type = saved_result_type;

    instructions[0].effects.reads_state = true;
    try std.testing.expectEqual(hir.DiagnosticCode.illegal_operation, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].effects = saved_effects;

    const saved_copy_operation = instructions[1].operation;
    const saved_copy_effects = instructions[1].effects;
    instructions[1].operation = .{ .await_ = original };
    instructions[1].effects = instructions[1].operation.effectSet();
    try std.testing.expectEqual(hir.DiagnosticCode.illegal_operation, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[1].operation = saved_copy_operation;
    instructions[1].effects = saved_copy_effects;

    const saved_terminator = blocks[0].terminator;
    blocks[0].terminator = .{ .jump = .{ .target = .invalid, .arguments = &.{} } };
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_cfg, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    blocks[0].terminator = saved_terminator;

    instructions[1].operation = .{ .copy = .invalid };
    instructions[1].effects = instructions[1].operation.effectSet();
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[1].operation = saved_copy_operation;
    instructions[1].effects = saved_copy_effects;

    const make_place_operation = instructions[2].operation;
    instructions[2].operation.make_binding_place.binding = .invalid;
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[2].operation = make_place_operation;

    const saved_mutable = function_bindings[0].mutable;
    function_bindings[0].mutable = false;
    instructions[0].operation = .{ .store_place = .{ .place = places[0].id, .value = original } };
    instructions[0].result = null;
    instructions[0].result_type = null;
    instructions[0].effects = instructions[0].operation.effectSet();
    try std.testing.expectEqual(hir.DiagnosticCode.invalid_value_binding_or_place, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    function_bindings[0].mutable = saved_mutable;
    instructions[0].operation = saved_operation;
    instructions[0].result = saved_value_id;
    instructions[0].result_type = saved_result_type;
    instructions[0].effects = saved_effects;

    instructions[0].operation = .{ .create_closure = .invalid };
    instructions[0].effects = instructions[0].operation.effectSet();
    try std.testing.expectEqual(hir.DiagnosticCode.internal_invariant, (try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)).?);
    instructions[0].operation = saved_operation;
    instructions[0].effects = saved_effects;

    try std.testing.expect((try hir.verifier.verifyBuilder(std.testing.allocator, &builder, .raw)) == null);
}

test "HIR provenance levels preserve executable shape and full trace records erased syntax" {
    var project = try provenanceLoweringProject();
    defer project.deinit();

    var none_outcome = try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .none);
    defer none_outcome.deinit();
    var minimal_outcome = try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .minimal);
    defer minimal_outcome.deinit();
    var full_outcome = try hir.lowerProjectWithDebug(std.testing.allocator, &project, .{}, .full);
    defer full_outcome.deinit();
    const none = switch (none_outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const minimal = switch (minimal_outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const full = switch (full_outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    try std.testing.expectEqual(@as(usize, 0), none.project.origins.records.len);
    try std.testing.expect(none.project.lowering_trace == null);
    try std.testing.expect(minimal.project.origins.records.len != 0);
    try std.testing.expect(minimal.project.lowering_trace == null);
    try std.testing.expect(full.project.origins.records.len >= minimal.project.origins.records.len);
    const events = (full.project.lowering_trace orelse return error.MissingLoweringTrace).events;

    try expectSameExecutableShape(none, minimal);
    try expectSameExecutableShape(none, full);
    for (none.project.functions) |function| for (function.blocks) |block| {
        try std.testing.expect(block.origin.eql(.invalid));
        for (block.instructions) |instruction| try std.testing.expect(instruction.origin.eql(.invalid));
    };
    for (minimal.project.modules) |module| {
        try minimal.requireOwnedId(module.origin);
        const record = minimal.project.origins.lookup(module.origin) orelse return error.MissingOrigin;
        try std.testing.expectEqual(@as(u64, 227), record.module_id.value());
    }
    for (minimal.project.functions) |function| for (function.blocks) |block| {
        try minimal.requireOwnedId(block.origin); // The block origin is also its terminator origin.
        try std.testing.expect(minimal.project.origins.lookup(block.origin) != null);
        for (block.instructions) |instruction| {
            try minimal.requireOwnedId(instruction.origin);
            try std.testing.expect(minimal.project.origins.lookup(instruction.origin) != null);
        }
    };

    const expected = [_]hir.TraceEventKind{
        .interface_erased,
        .arrow_to_function,
        .compound_assignment_to_place_load_store,
        .logical_and_to_branch,
        .optional_chain_to_nullish_branch,
        .switch_to_dispatch,
        .conditional_to_branch,
    };
    for (expected) |kind| {
        var found = false;
        for (events) |event| if (event.kind == kind) {
            found = true;
            try std.testing.expect(event.inputs.len != 0);
            for (event.inputs) |input| try full.requireOwnedId(input);
            if (kind == .interface_erased) try std.testing.expect(event.output == null);
        };
        try std.testing.expect(found);
    }
}

fn expectSameExecutableShape(left: *const hir.HirResult, right: *const hir.HirResult) !void {
    try std.testing.expectEqual(left.project.modules.len, right.project.modules.len);
    try std.testing.expectEqual(left.project.entities.len, right.project.entities.len);
    try std.testing.expectEqual(left.project.functions.len, right.project.functions.len);
    try std.testing.expectEqual(left.project.regions.len, right.project.regions.len);
    for (left.project.functions, right.project.functions) |left_function, right_function| {
        try std.testing.expectEqual(left_function.module_id.value(), right_function.module_id.value());
        try std.testing.expectEqual(left_function.kind, right_function.kind);
        try std.testing.expectEqual(left_function.signature_type, right_function.signature_type);
        try std.testing.expectEqual(left_function.blocks.len, right_function.blocks.len);
        for (left_function.blocks, right_function.blocks) |left_block, right_block| {
            try std.testing.expectEqual(left_block.parameters.len, right_block.parameters.len);
            try std.testing.expectEqual(left_block.instructions.len, right_block.instructions.len);
            try std.testing.expectEqual(std.meta.activeTag(left_block.terminator), std.meta.activeTag(right_block.terminator));
            for (left_block.instructions, right_block.instructions) |left_instruction, right_instruction| {
                try std.testing.expectEqual(std.meta.activeTag(left_instruction.operation), std.meta.activeTag(right_instruction.operation));
                try std.testing.expectEqual(left_instruction.result_type, right_instruction.result_type);
                try std.testing.expectEqual(left_instruction.effects, right_instruction.effects);
            }
        }
    }
}

test "HIR canonical snapshots cover every supported lowering family" {
    try expectStableSnapshot(declarationLoweringProject);
    try expectStableSnapshot(anfLoweringProject);
    try expectStableSnapshot(placeLoweringProject);
    try expectStableSnapshot(operatorLoweringProject);
    try expectStableSnapshot(accessCallLoweringProject);
    try expectStableSnapshot(aggregateLoweringProject);
    try expectStableSnapshot(functionLoweringProject);
    try expectStableSnapshot(controlFlowLoweringProject);
    try expectStableSnapshot(switchAndLabelLoweringProject);
    try expectStableSnapshot(exceptionLoweringProject);
    try expectStableSnapshot(suspensionLoweringProject);
    try expectStableSnapshot(classEnumLoweringProject);
    try expectStableSnapshot(provenanceLoweringProject);
}

fn expectStableSnapshot(factory: anytype) !void {
    var project = try factory();
    defer project.deinit();
    var lowered = switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => return error.UnexpectedLoweringFailure,
    };
    defer lowered.deinit();

    const first = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .canonical);
    defer std.testing.allocator.free(first);
    const second = try hir.printAlloc(std.testing.allocator, &lowered.project, lowered.identity_domain, .canonical);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, "hir-v1 "));
}
