const std = @import("std");
const hir = @import("root.zig");
const project_mod = @import("../project/root.zig");
const types = @import("../types/root.zig");

const TestReachability = struct {
    module_bits: [16]u64 = [_]u64{0} ** 16,
    function_bits: [16]u64 = [_]u64{0} ** 16,
    block_bits: [32]u64 = [_]u64{0} ** 32,
    instruction_bits: [64]u64 = [_]u64{0} ** 64,
    binding_bits: [32]u64 = [_]u64{0} ** 32,
    module_ordinals: [1024]u32 = [_]u32{0} ** 1024,
    function_ordinals: [1024]u32 = [_]u32{0} ** 1024,
    block_ordinals: [2048]u32 = [_]u32{0} ** 2048,
    instruction_ordinals: [4096]u32 = [_]u32{0} ** 4096,
    binding_ordinals: [2048]u32 = [_]u32{0} ** 2048,
    external_ids: [32]u64 = [_]u64{0} ** 32,
    module_count: usize = 0,
    function_count: usize = 0,
    block_count: usize = 0,
    instruction_count: usize = 0,
    binding_count: usize = 0,
    external_count: usize = 0,
};

fn bitSet(words: []const u64, ordinal: usize) bool {
    const word = ordinal / 64;
    if (word >= words.len) return false;
    const bit: u6 = @intCast(ordinal % 64);
    return (words[word] & (@as(u64, 1) << bit)) != 0;
}

fn analyzeForTest(
    result: *const hir.HirResult,
    public_modules: []const u64,
    application_modules: []const u64,
    triggers: []const hir.reachability.LanguageItemTrigger,
) !TestReachability {
    var scratch: [64 * 1024]u8 align(@alignOf(u64)) = undefined;
    const required = try result.artifactReachabilityScratchSize();
    if (required > scratch.len) return error.TestReachabilityScratchTooSmall;

    var output: TestReachability = .{};
    const summary = try result.analyzeArtifactReachability(
        @alignCast(scratch[0..required]),
        .{
            .public_modules = public_modules,
            .application_modules = application_modules,
            .language_item_triggers = triggers,
        },
        .{
            .module_bits = output.module_bits[0..],
            .function_bits = output.function_bits[0..],
            .block_bits = output.block_bits[0..],
            .instruction_bits = output.instruction_bits[0..],
            .binding_bits = output.binding_bits[0..],
            .module_ordinals = output.module_ordinals[0..],
            .function_ordinals = output.function_ordinals[0..],
            .block_ordinals = output.block_ordinals[0..],
            .instruction_ordinals = output.instruction_ordinals[0..],
            .binding_ordinals = output.binding_ordinals[0..],
            .external_module_ids = output.external_ids[0..],
        },
    );
    output.module_count = summary.module_count;
    output.function_count = summary.function_count;
    output.block_count = summary.block_count;
    output.instruction_count = summary.instruction_count;
    output.binding_count = summary.binding_count;
    output.external_count = summary.external_module_count;
    return output;
}

fn expectCanonicalOrdinals(bits: []const u64, ordinals: []const u32) !void {
    var previous: ?u32 = null;
    for (ordinals) |ordinal| {
        if (previous) |value| try std.testing.expect(value < ordinal);
        const ordinal_index: usize = @intCast(ordinal);
        try std.testing.expect(bitSet(bits, ordinal_index));
        previous = ordinal;
    }
}

fn loweredRoot(id: u64, source: []const u8) !hir.HirResult {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(id),
        .logical_name = "reachability-root.ts",
        .bytes = source,
    });
    while (switch (try project.step()) {
        .complete => false,
        .request => return error.UnexpectedModuleRequest,
    }) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;
    return switch (try hir.lowerProject(std.testing.allocator, &project, .{})) {
        .result => |result| result,
        .diagnostics => error.UnexpectedLoweringDiagnostics,
    };
}

fn functionOrdinalByName(result: *const hir.HirResult, name: []const u8) ?usize {
    for (result.consumerIndex().function_names, 0..) |candidate, ordinal|
        if (std.mem.eql(u8, candidate, name)) return ordinal;
    return null;
}

fn bindingOrdinalByName(result: *const hir.HirResult, name: []const u8) ?usize {
    const index = result.consumerIndex();
    for (index.bindings, 0..) |_, ordinal| {
        const binding = index.binding(result.project, ordinal) orelse continue;
        if (std.mem.eql(u8, binding.name, name)) return ordinal;
    }
    return null;
}

fn expectFunctionReachability(result: *const hir.HirResult, reached: TestReachability, name: []const u8, expected: bool) !usize {
    const ordinal = functionOrdinalByName(result, name) orelse return error.TestExpectedFunction;
    try std.testing.expectEqual(expected, bitSet(reached.function_bits[0..], ordinal));
    return ordinal;
}

test "HIR reachability operation trigger ordinals remain ABI stable" {
    const Tag = std.meta.Tag(hir.HirOperation);
    const expected = [_]Tag{
        .constant, .copy, .load_binding, .initialize_binding, .store_binding,
        .load_this, .load_super, .load_meta,
        .make_binding_place, .make_property_place, .make_element_place, .make_super_place,
        .load_place, .store_place, .delete_place,
        .to_boolean, .is_nullish, .typeof_value, .void_value, .unary, .binary, .add,
        .call, .call_method, .call_super_method, .call_super_constructor, .construct,
        .tagged_template_call, .dynamic_import,
        .create_object, .create_array, .create_closure, .create_class, .create_enum_object,
        .create_regexp, .create_template_site, .define_property, .define_method,
        .copy_object_properties, .array_append, .array_append_hole, .array_append_iterable,
        .build_string, .to_string, .get_iterator, .get_async_iterator, .iterator_next,
        .iterator_done, .iterator_value, .iterator_close, .enumerate_properties,
        .enumerator_next, .enumerator_done, .enumerator_value, .collect_rest_arguments,
        .read_argument, .create_arguments_object, .await_, .yield_, .yield_delegate,
        .debugger_trap, .apply_pattern, .intrinsic_call,
    };
    const fields = @typeInfo(Tag).@"enum".fields;
    try std.testing.expectEqual(@as(usize, expected.len), fields.len);
    for (expected, 0..) |tag, ordinal|
        try std.testing.expectEqual(@as(u32, @intCast(ordinal)), @as(u32, @intFromEnum(tag)));
}

test "HIR consumer index maps sparse raw IDs to dense canonical ordinals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var domain: hir.ids.IdentityDomain = .{};
    var foreign_domain: hir.ids.IdentityDomain = .{};
    const function_id = try hir.FunctionId.init(&domain, 41);
    const block_id = try hir.BlockId.init(&domain, 97);
    const instruction_id = try hir.InstructionId.init(&domain, 211);
    const value_id = try hir.ValueId.init(&domain, 509);
    const binding_id = try hir.BindingId.init(&domain, 701);
    const place_id = try hir.PlaceId.init(&domain, 907);

    const instruction = try hir.HirInstruction.init(
        instruction_id,
        value_id,
        123,
        .{ .constant = .{ .number = 1 } },
        .invalid,
    );
    const binding: hir.HirBinding = .{
        .id = binding_id,
        .name = "sparse",
        .kind = .let_,
        .type_id = 123,
        .declaration = null,
        .mutable = true,
        .initial_state = .initialized,
        .origin = .invalid,
    };
    const place: hir.HirPlace = .{
        .id = place_id,
        .kind = .{ .binding = binding_id },
        .origin = .invalid,
    };
    const block: hir.HirBlock = .{
        .id = block_id,
        .instructions = &.{instruction},
        .terminator = .{ .return_ = value_id },
        .origin = .invalid,
    };
    const function: hir.HirFunction = .{
        .id = function_id,
        .module_id = .init(5),
        .symbol = null,
        .kind = .module_initialization,
        .flags = .{},
        .signature_type = 123,
        .bindings = &.{binding},
        .places = &.{place},
        .blocks = &.{block},
        .entry = block_id,
        .origin = .invalid,
    };
    const module: hir.HirModule = .{
        .module_id = .init(5),
        .logical_name = "sparse.ts",
        .initialization = function_id,
        .origin = .invalid,
    };
    const project: hir.HirProject = .{
        .modules = &.{module},
        .functions = &.{function},
    };

    var index = try hir.consumer_index.Index.build(arena.allocator(), &domain, project);
    defer index.deinit();

    try std.testing.expectEqual(@as(?u32, 0), index.functionOrdinal(function_id));
    try std.testing.expectEqual(@as(?u32, 0), index.blockOrdinal(block_id));
    try std.testing.expectEqual(@as(?u32, 0), index.instructionOrdinal(instruction_id));
    try std.testing.expectEqual(@as(?u32, 0), index.valueOrdinal(value_id));
    try std.testing.expectEqual(@as(?u32, 0), index.bindingOrdinal(binding_id));
    try std.testing.expect(index.bindingForPlace(place_id).?.eql(binding_id));
    try std.testing.expect(index.instruction(project, 0).?.id.eql(instruction_id));

    const foreign_instruction = try hir.InstructionId.init(&foreign_domain, instruction_id.index().?);
    const foreign_binding = try hir.BindingId.init(&foreign_domain, binding_id.index().?);
    const foreign_place = try hir.PlaceId.init(&foreign_domain, place_id.index().?);
    try std.testing.expect(index.instructionOrdinal(foreign_instruction) == null);
    try std.testing.expect(index.bindingOrdinal(foreign_binding) == null);
    try std.testing.expect(index.bindingForPlace(foreign_place) == null);
}

test "artifact reachability does not retain unconsumed pure place definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var domain: hir.ids.IdentityDomain = .{};
    const init_function_id = try hir.FunctionId.init(&domain, 10);
    const dead_function_id = try hir.FunctionId.init(&domain, 20);
    const init_block_id = try hir.BlockId.init(&domain, 30);
    const dead_block_id = try hir.BlockId.init(&domain, 40);
    const closure_instruction_id = try hir.InstructionId.init(&domain, 50);
    const place_instruction_id = try hir.InstructionId.init(&domain, 60);
    const closure_value_id = try hir.ValueId.init(&domain, 70);
    const place_id = try hir.PlaceId.init(&domain, 80);

    const closure_instruction = try hir.HirInstruction.init(
        closure_instruction_id,
        closure_value_id,
        1,
        .{ .create_closure = dead_function_id },
        .invalid,
    );
    const place_instruction = try hir.HirInstruction.init(
        place_instruction_id,
        null,
        null,
        .{ .make_property_place = .{
            .result = place_id,
            .base = closure_value_id,
            .key = .{ .static = "unused" },
        } },
        .invalid,
    );
    const place: hir.HirPlace = .{
        .id = place_id,
        .kind = .{ .property = .{
            .base = closure_value_id,
            .key = .{ .static = "unused" },
        } },
        .origin = .invalid,
    };
    const init_block: hir.HirBlock = .{
        .id = init_block_id,
        .instructions = &.{ closure_instruction, place_instruction },
        .terminator = .{ .return_ = null },
        .origin = .invalid,
    };
    const dead_block: hir.HirBlock = .{
        .id = dead_block_id,
        .instructions = &.{},
        .terminator = .{ .return_ = null },
        .origin = .invalid,
    };
    const init_function: hir.HirFunction = .{
        .id = init_function_id,
        .module_id = .init(5),
        .symbol = null,
        .kind = .module_initialization,
        .flags = .{},
        .signature_type = 1,
        .places = &.{place},
        .blocks = &.{init_block},
        .entry = init_block_id,
        .origin = .invalid,
    };
    const dead_function: hir.HirFunction = .{
        .id = dead_function_id,
        .module_id = .init(5),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = 1,
        .blocks = &.{dead_block},
        .entry = dead_block_id,
        .origin = .invalid,
    };
    const module: hir.HirModule = .{
        .module_id = .init(5),
        .logical_name = "places.ts",
        .initialization = init_function_id,
        .origin = .invalid,
    };
    const project: hir.HirProject = .{
        .modules = &.{module},
        .functions = &.{ init_function, dead_function },
    };

    var index = try hir.consumer_index.Index.build(arena.allocator(), &domain, project);
    defer index.deinit();
    try std.testing.expect(!index.placeIsConsumed(place_id));

    var type_store = types.TypeStore.init(arena.allocator());
    const required = try hir.reachability.scratchSize(project, &index);
    var scratch: [4096]u8 align(@alignOf(u64)) = undefined;
    try std.testing.expect(required <= scratch.len);

    var output: TestReachability = .{};
    const summary = try hir.reachability.analyze(
        @alignCast(scratch[0..required]),
        project,
        &type_store,
        &index,
        .{ .application_modules = &.{5} },
        .{
            .module_bits = output.module_bits[0..],
            .function_bits = output.function_bits[0..],
            .block_bits = output.block_bits[0..],
            .instruction_bits = output.instruction_bits[0..],
            .binding_bits = output.binding_bits[0..],
            .module_ordinals = output.module_ordinals[0..],
            .function_ordinals = output.function_ordinals[0..],
            .block_ordinals = output.block_ordinals[0..],
            .instruction_ordinals = output.instruction_ordinals[0..],
            .binding_ordinals = output.binding_ordinals[0..],
            .external_module_ids = output.external_ids[0..],
        },
    );
    try std.testing.expectEqual(@as(usize, 1), summary.function_count);
    try std.testing.expect(bitSet(output.function_bits[0..], 0));
    try std.testing.expect(!bitSet(output.function_bits[0..], 1));
    try std.testing.expect(!bitSet(output.instruction_bits[0..], index.instructionOrdinal(closure_instruction_id).?));
    try std.testing.expect(!bitSet(output.instruction_bits[0..], index.instructionOrdinal(place_instruction_id).?));
}

test "artifact reachability treats pattern place targets as real place consumers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var domain: hir.ids.IdentityDomain = .{};
    const init_function_id = try hir.FunctionId.init(&domain, 110);
    const property_function_id = try hir.FunctionId.init(&domain, 120);
    const init_block_id = try hir.BlockId.init(&domain, 130);
    const property_block_id = try hir.BlockId.init(&domain, 140);
    const closure_instruction_id = try hir.InstructionId.init(&domain, 150);
    const source_instruction_id = try hir.InstructionId.init(&domain, 160);
    const place_instruction_id = try hir.InstructionId.init(&domain, 170);
    const pattern_instruction_id = try hir.InstructionId.init(&domain, 180);
    const closure_value_id = try hir.ValueId.init(&domain, 190);
    const source_value_id = try hir.ValueId.init(&domain, 200);
    const binding_id = try hir.BindingId.init(&domain, 210);
    const place_id = try hir.PlaceId.init(&domain, 220);

    const closure_instruction = try hir.HirInstruction.init(
        closure_instruction_id,
        closure_value_id,
        1,
        .{ .create_closure = property_function_id },
        .invalid,
    );
    const source_instruction = try hir.HirInstruction.init(
        source_instruction_id,
        source_value_id,
        1,
        .{ .constant = .{ .number = 1 } },
        .invalid,
    );
    const place_instruction = try hir.HirInstruction.init(
        place_instruction_id,
        null,
        null,
        .{ .make_property_place = .{
            .result = place_id,
            .base = closure_value_id,
            .key = .{ .static = "value" },
        } },
        .invalid,
    );
    const pattern_items = [_]hir.PatternItem{
        .array_begin,
        .{ .place_target = place_id },
        .{ .binding_target = binding_id },
        .array_end,
    };
    const pattern_instruction = try hir.HirInstruction.init(
        pattern_instruction_id,
        null,
        null,
        .{ .apply_pattern = .{
            .position = .assignment,
            .source = source_value_id,
            .items = &pattern_items,
        } },
        .invalid,
    );
    const binding: hir.HirBinding = .{
        .id = binding_id,
        .name = "patternTarget",
        .kind = .let_,
        .type_id = 1,
        .declaration = null,
        .mutable = true,
        .initial_state = .initialized,
        .origin = .invalid,
    };
    const place: hir.HirPlace = .{
        .id = place_id,
        .kind = .{ .property = .{
            .base = closure_value_id,
            .key = .{ .static = "value" },
        } },
        .origin = .invalid,
    };
    const init_block: hir.HirBlock = .{
        .id = init_block_id,
        .instructions = &.{ closure_instruction, source_instruction, place_instruction, pattern_instruction },
        .terminator = .{ .return_ = null },
        .origin = .invalid,
    };
    const property_block: hir.HirBlock = .{
        .id = property_block_id,
        .instructions = &.{},
        .terminator = .{ .return_ = null },
        .origin = .invalid,
    };
    const init_function: hir.HirFunction = .{
        .id = init_function_id,
        .module_id = .init(6),
        .symbol = null,
        .kind = .module_initialization,
        .flags = .{},
        .signature_type = 1,
        .bindings = &.{binding},
        .places = &.{place},
        .blocks = &.{init_block},
        .entry = init_block_id,
        .origin = .invalid,
    };
    const property_function: hir.HirFunction = .{
        .id = property_function_id,
        .module_id = .init(6),
        .symbol = null,
        .kind = .ordinary,
        .flags = .{},
        .signature_type = 1,
        .blocks = &.{property_block},
        .entry = property_block_id,
        .origin = .invalid,
    };
    const module: hir.HirModule = .{
        .module_id = .init(6),
        .logical_name = "pattern-place.ts",
        .initialization = init_function_id,
        .origin = .invalid,
    };
    const project: hir.HirProject = .{
        .modules = &.{module},
        .functions = &.{ init_function, property_function },
    };

    var index = try hir.consumer_index.Index.build(arena.allocator(), &domain, project);
    defer index.deinit();
    try std.testing.expect(index.placeIsConsumed(place_id));
    const writers = index.writersForBinding(binding_id);
    try std.testing.expectEqual(@as(usize, 1), writers.len);
    try std.testing.expectEqual(index.instructionOrdinal(pattern_instruction_id).?, writers[0]);

    var type_store = types.TypeStore.init(arena.allocator());
    const required = try hir.reachability.scratchSize(project, &index);
    var scratch: [4096]u8 align(@alignOf(u64)) = undefined;
    try std.testing.expect(required <= scratch.len);
    var output: TestReachability = .{};
    const summary = try hir.reachability.analyze(
        @alignCast(scratch[0..required]),
        project,
        &type_store,
        &index,
        .{ .application_modules = &.{6} },
        .{
            .module_bits = output.module_bits[0..],
            .function_bits = output.function_bits[0..],
            .block_bits = output.block_bits[0..],
            .instruction_bits = output.instruction_bits[0..],
            .binding_bits = output.binding_bits[0..],
            .module_ordinals = output.module_ordinals[0..],
            .function_ordinals = output.function_ordinals[0..],
            .block_ordinals = output.block_ordinals[0..],
            .instruction_ordinals = output.instruction_ordinals[0..],
            .binding_ordinals = output.binding_ordinals[0..],
            .external_module_ids = output.external_ids[0..],
        },
    );
    try std.testing.expectEqual(@as(usize, 2), summary.function_count);
    try std.testing.expect(bitSet(output.function_bits[0..], index.functionOrdinal(property_function_id).?));
    try std.testing.expect(bitSet(output.instruction_bits[0..], index.instructionOrdinal(closure_instruction_id).?));
    try std.testing.expect(bitSet(output.instruction_bits[0..], index.instructionOrdinal(place_instruction_id).?));
    try std.testing.expect(bitSet(output.instruction_bits[0..], index.instructionOrdinal(pattern_instruction_id).?));
    try std.testing.expect(!bitSet(output.binding_bits[0..], index.bindingOrdinal(binding_id).?));
}

test "artifact reachability excludes unused function declarations before MIR" {
    var result = try loweredRoot(
        1001,
        \\function unused(): number { return 123; }
        \\function used(): number { return 456; }
        \\used();
    );
    defer result.deinit();

    const reached = try analyzeForTest(&result, &.{}, &.{1001}, &.{});
    try expectCanonicalOrdinals(reached.module_bits[0..], reached.module_ordinals[0..reached.module_count]);
    try expectCanonicalOrdinals(reached.function_bits[0..], reached.function_ordinals[0..reached.function_count]);
    try expectCanonicalOrdinals(reached.block_bits[0..], reached.block_ordinals[0..reached.block_count]);
    try expectCanonicalOrdinals(reached.instruction_bits[0..], reached.instruction_ordinals[0..reached.instruction_count]);
    try expectCanonicalOrdinals(reached.binding_bits[0..], reached.binding_ordinals[0..reached.binding_count]);
    _ = try expectFunctionReachability(&result, reached, "used", true);
    const unused_ordinal = try expectFunctionReachability(&result, reached, "unused", false);
    const unused = result.project.functions[unused_ordinal];
    for (unused.blocks) |block| {
        const block_ordinal = result.consumerIndex().blockOrdinal(block.id) orelse return error.TestExpectedBlock;
        try std.testing.expect(!bitSet(reached.block_bits[0..], block_ordinal));
        for (block.instructions) |instruction| {
            const instruction_ordinal = result.consumerIndex().instructionOrdinal(instruction.id) orelse return error.TestExpectedInstruction;
            try std.testing.expect(!bitSet(reached.instruction_bits[0..], instruction_ordinal));
        }
    }

    var saw_unused_closure = false;
    for (result.project.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .create_closure => |target| if (target.eql(unused.id)) {
            const ordinal = result.consumerIndex().instructionOrdinal(instruction.id) orelse return error.TestExpectedInstruction;
            try std.testing.expect(!bitSet(reached.instruction_bits[0..], ordinal));
            saw_unused_closure = true;
        },
        else => {},
    };
    try std.testing.expect(saw_unused_closure);
}

test "artifact reachability preserves source side-effect module evaluation but excludes type-only modules" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1100),
        .logical_name = "main.ts",
        .bytes =
        \\import "./side";
        \\import type { Shape } from "./types";
        \\42;
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "./side")) {
                try project.respondSource(request.id, .{
                    .id = .init(1101),
                    .logical_name = "side.ts",
                    .bytes = "let side = 0; side = side + 1;",
                });
            } else if (std.mem.eql(u8, request.raw_specifier, "./types")) {
                try project.respondSource(request.id, .{
                    .id = .init(1102),
                    .logical_name = "types.ts",
                    .bytes = "export interface Shape { value: number; }",
                });
            } else return error.UnexpectedModuleRequest;
        },
    };
    const finished = try project.finish();
    if (finished.has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const reached = try analyzeForTest(result, &.{}, &.{1100}, &.{});
    const index = result.consumerIndex();
    const main_module_ordinal = index.module_ordinals.get(1100).?;
    try std.testing.expect(bitSet(reached.module_bits[0..], main_module_ordinal));
    try std.testing.expect(bitSet(reached.module_bits[0..], index.module_ordinals.get(1101).?));
    const main_module = result.project.modules[main_module_ordinal];
    var saw_side_effect_evaluation = false;
    for (main_module.dependencies) |dependency| if (dependency.module_id.value() == 1101) {
        try std.testing.expect(dependency.initialization_required);
        try std.testing.expect(dependency.module_evaluation);
        saw_side_effect_evaluation = true;
    };
    try std.testing.expect(saw_side_effect_evaluation);
    if (index.module_ordinals.get(1102)) |ordinal|
        try std.testing.expect(!bitSet(reached.module_bits[0..], ordinal));
}

test "artifact reachability follows only live resolved dynamic source imports" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1160),
        .logical_name = "dynamic-main.ts",
        .bytes =
        \\function dead(): void { import("./dead"); }
        \\import("./live");
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "\"./dead\"")) {
                try project.respondSource(request.id, .{
                    .id = .init(1161),
                    .logical_name = "dynamic-dead.ts",
                    .bytes = "export const deadValue = 1;",
                });
            } else if (std.mem.eql(u8, request.raw_specifier, "\"./live\"")) {
                try project.respondSource(request.id, .{
                    .id = .init(1162),
                    .logical_name = "dynamic-live.ts",
                    .bytes = "export const liveValue = 2;",
                });
            } else return error.UnexpectedModuleRequest;
        },
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const index = result.consumerIndex();
    const dead_module = index.module_ordinals.get(1161) orelse return error.TestExpectedDynamicModule;
    const live_module = index.module_ordinals.get(1162) orelse return error.TestExpectedDynamicModule;

    var saw_dead_resolution = false;
    var saw_live_resolution = false;
    for (result.project.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
        .dynamic_import => |payload| if (payload.resolved) |resolved| switch (resolved) {
            .source => |module_id| {
                if (module_id.value() == 1161) saw_dead_resolution = true;
                if (module_id.value() == 1162) saw_live_resolution = true;
            },
            .external => {},
        },
        else => {},
    };
    try std.testing.expect(saw_dead_resolution);
    try std.testing.expect(saw_live_resolution);

    const reached = try analyzeForTest(result, &.{}, &.{1160}, &.{});
    try std.testing.expect(!bitSet(reached.module_bits[0..], dead_module));
    try std.testing.expect(bitSet(reached.module_bits[0..], live_module));
    _ = try expectFunctionReachability(result, reached, "dead", false);
}

test "artifact reachability retains dynamic source namespace exports only when the result escapes" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1165),
        .logical_name = "dynamic-public.ts",
        .bytes =
        \\export const lazy = import("./dep");
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            try std.testing.expectEqualStrings("\"./dep\"", request.raw_specifier);
            try project.respondSource(request.id, .{
                .id = .init(1166),
                .logical_name = "dynamic-public-dep.ts",
                .bytes =
                \\export function first(): number { return 1; }
                \\export function second(): number { return 2; }
                ,
            });
        },
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    // A public export of the dynamic-import value makes the eventual module
    // namespace observable, so every runtime export remains reachable.
    const reached = try analyzeForTest(result, &.{1165}, &.{}, &.{});
    _ = try expectFunctionReachability(result, reached, "first", true);
    _ = try expectFunctionReachability(result, reached, "second", true);
}

test "artifact reachability preserves external identity for live resolved dynamic imports" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1170),
        .logical_name = "dynamic-external.ts",
        .bytes =
        \\function dead(): void { import("native:dead"); }
        \\import("native:live");
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            if (std.mem.eql(u8, request.raw_specifier, "\"native:dead\"")) {
                try project.respondExternalModule(request.id, .{
                    .id = .init(9971),
                    .logical_name = "opaque-dead-external",
                    .exports = &.{},
                });
            } else if (std.mem.eql(u8, request.raw_specifier, "\"native:live\"")) {
                try project.respondExternalModule(request.id, .{
                    .id = .init(9972),
                    .logical_name = "opaque-live-external",
                    .exports = &.{},
                });
            } else return error.UnexpectedModuleRequest;
        },
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const index = result.consumerIndex();
    try std.testing.expect(index.external_module_ordinals.contains(9971));
    try std.testing.expect(index.external_module_ordinals.contains(9972));

    const reached = try analyzeForTest(result, &.{}, &.{1170}, &.{});
    try std.testing.expectEqual(@as(usize, 1), reached.external_count);
    try std.testing.expectEqual(@as(u64, 9972), reached.external_ids[0]);
    _ = try expectFunctionReachability(result, reached, "dead", false);
}

test "artifact reachability preserves namespace semantics without source spelling dispatch" {
    const Case = struct {
        fn lower(root_id: u64, dep_id: u64, source: []const u8) !hir.HirResult {
            var project = project_mod.Project.init(std.testing.allocator);
            defer project.deinit();
            try project.addRoot(.{
                .id = .init(root_id),
                .logical_name = "namespace-main.ts",
                .bytes = source,
            });
            while (true) switch (try project.step()) {
                .complete => break,
                .request => |request| {
                    try std.testing.expectEqualStrings("./dep", request.raw_specifier);
                    try project.respondSource(request.id, .{
                        .id = .init(dep_id),
                        .logical_name = "namespace-dep.ts",
                        .bytes =
                        \\export function first(): number { return 1; }
                        \\export function second(): number { return 2; }
                        ,
                    });
                },
            };
            if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;
            var lowered = try hir.lowerProject(std.testing.allocator, &project, .{});
            return switch (lowered) {
                .result => |result| result,
                .diagnostics => |*report| {
                    report.deinit();
                    return error.UnexpectedLoweringDiagnostics;
                },
            };
        }
    };

    var unused_result = try Case.lower(
        1120,
        1121,
        \\import * as deliberatelyRenamed from "./dep";
        \\42;
        ,
    );
    defer unused_result.deinit();
    var saw_namespace_metadata = false;
    for (unused_result.project.modules) |module| {
        if (module.module_id.value() != 1120) continue;
        for (module.imports) |import_binding| {
            if (import_binding.local == null) continue;
            try std.testing.expect(import_binding.namespace);
            saw_namespace_metadata = true;
        }
    }
    try std.testing.expect(saw_namespace_metadata);
    const dep_module = unused_result.consumerIndex().module_ordinals.get(1121) orelse return error.TestExpectedDependencyModule;
    const unused = try analyzeForTest(&unused_result, &.{}, &.{1120}, &.{});
    try std.testing.expect(bitSet(unused.module_bits[0..], dep_module));
    _ = try expectFunctionReachability(&unused_result, unused, "first", false);
    _ = try expectFunctionReachability(&unused_result, unused, "second", false);

    var live_result = try Case.lower(
        1130,
        1131,
        \\import * as arbitraryLocalName from "./dep";
        \\arbitraryLocalName.first();
        ,
    );
    defer live_result.deinit();
    const live = try analyzeForTest(&live_result, &.{}, &.{1130}, &.{});
    _ = try expectFunctionReachability(&live_result, live, "first", true);
    // Namespace objects expose the complete runtime export surface. With the
    // current property-based HIR, a dynamic member read may observe any export.
    _ = try expectFunctionReachability(&live_result, live, "second", true);
}

test "artifact reachability reaches source-backed globals only through live semantic use" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addGlobalRoot(.{
        .id = .init(1150),
        .logical_name = "global.ts",
        .bytes = "export function sourceGlobal(): number { return 9; }",
    });
    try project.addRoot(.{
        .id = .init(1151),
        .logical_name = "app.ts",
        .bytes =
        \\function dead(): number { return sourceGlobal(); }
        \\42;
        ,
    });
    while (try project.step() != .complete) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const index = result.consumerIndex();
    const global_module = index.module_ordinals.get(1150) orelse return error.TestExpectedSourceGlobalModule;
    const app_module = index.module_ordinals.get(1151) orelse return error.TestExpectedApplicationModule;
    const provider_function = functionOrdinalByName(result, "sourceGlobal") orelse return error.TestExpectedFunction;
    var saw_conditional_provider_dependency = false;
    for (result.project.modules[app_module].dependencies) |dependency| if (dependency.module_id.value() == 1150) {
        try std.testing.expect(dependency.initialization_required);
        try std.testing.expect(!dependency.module_evaluation);
        saw_conditional_provider_dependency = true;
    };
    try std.testing.expect(saw_conditional_provider_dependency);

    const dead_only = try analyzeForTest(result, &.{}, &.{1151}, &.{});
    try std.testing.expect(!bitSet(dead_only.module_bits[0..], global_module));
    try std.testing.expect(!bitSet(dead_only.function_bits[0..], provider_function));
    _ = try expectFunctionReachability(result, dead_only, "dead", false);

    // The same semantic provider must become reachable when the application
    // actually references it. Rebuild because artifact reachability is
    // intentionally stateless and HIR itself is immutable.
    var live_project = project_mod.Project.init(std.testing.allocator);
    defer live_project.deinit();
    try live_project.addGlobalRoot(.{
        .id = .init(1150),
        .logical_name = "global.ts",
        .bytes = "export function sourceGlobal(): number { return 9; }",
    });
    try live_project.addRoot(.{
        .id = .init(1151),
        .logical_name = "app.ts",
        .bytes = "sourceGlobal();",
    });
    while (try live_project.step() != .complete) {}
    if ((try live_project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var live_outcome = try hir.lowerProject(std.testing.allocator, &live_project, .{});
    defer live_outcome.deinit();
    const live_result = switch (live_outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const live_index = live_result.consumerIndex();
    const live_global_module = live_index.module_ordinals.get(1150) orelse return error.TestExpectedSourceGlobalModule;
    const live_provider = functionOrdinalByName(live_result, "sourceGlobal") orelse return error.TestExpectedFunction;
    const live = try analyzeForTest(live_result, &.{}, &.{1151}, &.{});
    try std.testing.expect(bitSet(live.module_bits[0..], live_global_module));
    try std.testing.expect(bitSet(live.function_bits[0..], live_provider));
}

test "artifact reachability does not pull external modules from dead bodies" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1200),
        .logical_name = "dead-native.ts",
        .bytes =
        \\import { nativeCall } from "native:api";
        \\function dead(): void { nativeCall(); }
        \\42;
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9900),
            .logical_name = "native:api",
            .exports = &.{.{
                .name = "nativeCall",
                .symbol_id = .init(1),
                .declaration_kind = .function,
                .function = .{ .return_type = .void },
                .effects = .{ .calls_unknown = true, .unknown = false },
            }},
        }),
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const reached = try analyzeForTest(result, &.{}, &.{1200}, &.{});
    _ = try expectFunctionReachability(result, reached, "dead", false);
    try std.testing.expectEqual(@as(usize, 0), reached.external_count);
}

test "artifact reachability returns external module identity for live native use" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1210),
        .logical_name = "live-native.ts",
        .bytes =
        \\import { nativeCall } from "native:api";
        \\nativeCall();
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| try project.respondExternalModule(request.id, .{
            .id = .init(9910),
            .logical_name = "native:api",
            .exports = &.{.{
                .name = "nativeCall",
                .symbol_id = .init(1),
                .declaration_kind = .function,
                .function = .{ .return_type = .void },
                .effects = .{ .calls_unknown = true, .unknown = false },
            }},
        }),
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const reached = try analyzeForTest(result, &.{}, &.{1210}, &.{});
    try std.testing.expectEqual(@as(usize, 1), reached.external_count);
    try std.testing.expectEqual(@as(u64, 9910), reached.external_ids[0]);
}

test "artifact reachability roots static-library exports and re-export targets only" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    try project.addRoot(.{
        .id = .init(1300),
        .logical_name = "library.ts",
        .bytes =
        \\export { publicThing } from "./dep";
        \\function localDead(): number { return 1; }
        ,
    });
    while (true) switch (try project.step()) {
        .complete => break,
        .request => |request| {
            try std.testing.expectEqualStrings("./dep", request.raw_specifier);
            try project.respondSource(request.id, .{
                .id = .init(1301),
                .logical_name = "dep.ts",
                .bytes =
                \\export function publicThing(): number { return 7; }
                \\function hiddenThing(): number { return 8; }
                ,
            });
        },
    };
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };
    const reached = try analyzeForTest(result, &.{1300}, &.{}, &.{});
    _ = try expectFunctionReachability(result, reached, "publicThing", true);
    _ = try expectFunctionReachability(result, reached, "hiddenThing", false);
    _ = try expectFunctionReachability(result, reached, "localDead", false);
}

test "consumer index resolves source import aliases to exact provider bindings" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
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
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    const index = result.consumerIndex();
    var saw_alias = false;
    for (result.project.modules) |module| {
        if (module.module_id.value() != 40) continue;
        for (module.imports) |import_binding| {
            const local = import_binding.local orelse continue;
            const source = index.bindingSource(result.project, local) orelse
                return error.TestExpectedProviderBinding;
            try std.testing.expect(source.index().? != local.index().?);
            const source_ordinal = index.bindingOrdinal(source) orelse
                return error.TestExpectedProviderBinding;
            _ = index.binding(result.project, source_ordinal) orelse
                return error.TestExpectedProviderBinding;
            const provider_function = index.bindingFunction(result.project, source_ordinal) orelse
                return error.TestExpectedProviderBinding;
            try std.testing.expectEqual(@as(u64, 7), provider_function.module_id.value());
            saw_alias = true;
        }
    }
    try std.testing.expect(saw_alias);
}

test "artifact reachability retains effectful binding reads even when their value is unused" {
    var result = try loweredRoot(
        1390,
        \\const observed = 1;
        \\observed;
    );
    defer result.deinit();

    const reached = try analyzeForTest(&result, &.{}, &.{1390}, &.{});
    const binding_ordinal = bindingOrdinalByName(&result, "observed") orelse return error.TestExpectedBinding;
    try std.testing.expect(bitSet(reached.binding_bits[0..], binding_ordinal));

    var saw_reached_load = false;
    for (result.project.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        switch (instruction.operation) {
            .load_binding => |binding| {
                const ordinal = result.consumerIndex().bindingOrdinal(binding) orelse continue;
                if (ordinal != binding_ordinal) continue;
                const instruction_ordinal = result.consumerIndex().instructionOrdinal(instruction.id) orelse return error.TestExpectedInstruction;
                if (bitSet(reached.instruction_bits[0..], instruction_ordinal)) saw_reached_load = true;
            },
            else => {},
        }
    };
    try std.testing.expect(saw_reached_load);
}

test "artifact reachability preserves observable RHS while omitting dead binding storage" {
    var result = try loweredRoot(
        1400,
        \\function effect(): number { return 1; }
        \\const unused = effect();
    );
    defer result.deinit();

    const reached = try analyzeForTest(&result, &.{}, &.{1400}, &.{});
    _ = try expectFunctionReachability(&result, reached, "effect", true);
    const unused_binding = bindingOrdinalByName(&result, "unused") orelse return error.TestExpectedBinding;
    try std.testing.expect(!bitSet(reached.binding_bits[0..], unused_binding));

    var saw_reached_call = false;
    var saw_omitted_storage = false;
    for (result.project.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        const ordinal = result.consumerIndex().instructionOrdinal(instruction.id) orelse return error.TestExpectedInstruction;
        switch (instruction.operation) {
            .call => {
                if (bitSet(reached.instruction_bits[0..], ordinal)) saw_reached_call = true;
            },
            .initialize_binding => |payload| {
                const binding_ordinal = result.consumerIndex().bindingOrdinal(payload.binding) orelse continue;
                if (binding_ordinal == unused_binding and !bitSet(reached.instruction_bits[0..], ordinal))
                    saw_omitted_storage = true;
            },
            else => {},
        }
    };
    try std.testing.expect(saw_reached_call);
    try std.testing.expect(saw_omitted_storage);
}

test "artifact reachability traces capture binding sources" {
    var result = try loweredRoot(
        1500,
        \\const captured = 7;
        \\function used(): number { return captured; }
        \\used();
    );
    defer result.deinit();

    const reached = try analyzeForTest(&result, &.{}, &.{1500}, &.{});
    _ = try expectFunctionReachability(&result, reached, "used", true);
    const captured = bindingOrdinalByName(&result, "captured") orelse return error.TestExpectedBinding;
    try std.testing.expect(bitSet(reached.binding_bits[0..], captured));
}

test "artifact reachability traces callable aliases without a global fixed point" {
    var result = try loweredRoot(
        1550,
        \\function dead(): number { return 0; }
        \\function used(): number { return 1; }
        \\const first = used;
        \\const second = first;
        \\second();
    );
    defer result.deinit();

    const reached = try analyzeForTest(&result, &.{}, &.{1550}, &.{});
    _ = try expectFunctionReachability(&result, reached, "used", true);
    _ = try expectFunctionReachability(&result, reached, "dead", false);
    const first = bindingOrdinalByName(&result, "first") orelse return error.TestExpectedBinding;
    const second = bindingOrdinalByName(&result, "second") orelse return error.TestExpectedBinding;
    try std.testing.expect(bitSet(reached.binding_bits[0..], first));
    try std.testing.expect(bitSet(reached.binding_bits[0..], second));
}

test "language-item operation triggers use stable identity and only reached operations" {
    var project = project_mod.Project.init(std.testing.allocator);
    defer project.deinit();
    const language_item_id: u64 = 0xA55A;
    try project.registerSourceLanguageItems(&.{.{
        .id = .init(language_item_id),
        .module_id = .init(1601),
        .exported_name = "renamedArrayProtocol",
        .namespace = .value,
    }});
    try project.addRoot(.{
        .id = .init(1600),
        .logical_name = "main.ts",
        .bytes =
        \\function dead(): void { const values = [1, 2, 3]; values; }
        \\const live = [4, 5];
        \\live;
        ,
    });
    try project.supplySource(.{
        .id = .init(1601),
        .logical_name = "protocol.ts",
        .bytes = "export function renamedArrayProtocol(value: unknown): unknown { return value; }",
    });
    while (try project.step() != .complete) {}
    if ((try project.finish()).has_failures) return error.UnexpectedSemanticDiagnostics;

    var outcome = try hir.lowerProject(std.testing.allocator, &project, .{});
    defer outcome.deinit();
    const result = switch (outcome) {
        .result => |*value| value,
        .diagnostics => return error.UnexpectedLoweringDiagnostics,
    };

    const protocol_ordinal = functionOrdinalByName(result, "renamedArrayProtocol") orelse return error.TestExpectedFunction;
    const without_trigger = try analyzeForTest(result, &.{}, &.{1600}, &.{});
    try std.testing.expect(!bitSet(without_trigger.function_bits[0..], protocol_ordinal));

    const create_array_tag: u32 = @intFromEnum(std.meta.Tag(hir.HirOperation).create_array);
    const with_trigger = try analyzeForTest(result, &.{}, &.{1600}, &.{.{
        .operation_tag = create_array_tag,
        .flags = 0,
        .language_item_id = language_item_id,
    }});
    try std.testing.expect(bitSet(with_trigger.function_bits[0..], protocol_ordinal));
    _ = try expectFunctionReachability(result, with_trigger, "dead", false);
}
