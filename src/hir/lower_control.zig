//! Canonical block lowering for conditional and loop statement families.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");
const model = @import("model.zig");

pub const CleanupFrame = struct {
    region: ids.RegionId,
    cleanup: ids.BlockId,
    continue_target: ids.BlockId,
    protected_id_start: usize,
};

pub const ControlTarget = struct {
    break_target: ids.BlockId,
    continue_target: ?ids.BlockId,
};

pub const LabelFrame = struct {
    name: []const u8,
    break_target: ids.BlockId,
    continue_target: ?ids.BlockId,
    iteration: bool,
};

pub fn lowerIf(context: anytype, statement: ast.IfStatement) anyerror!void {
    const then_block = try context.anf.createBlock();
    const else_block = try context.anf.createBlock();
    const merge_block = try context.anf.createBlock();
    const condition = try context.emitValue(.{ .to_boolean = try context.lowerExpression(statement.condition) }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = condition, .true_target = then_block, .false_target = else_block } });

    try context.anf.beginBlock(then_block);
    try context.lowerStatement(statement.consequent);
    if (!context.anf.currentTerminated()) try jump(context, merge_block);

    try context.anf.beginBlock(else_block);
    if (statement.alternate) |alternate| try context.lowerStatement(alternate);
    if (!context.anf.currentTerminated()) try jump(context, merge_block);

    try context.anf.beginBlock(merge_block);
}

pub fn lowerWhile(context: anytype, statement: ast.WhileStatement) anyerror!void {
    const condition_block = try context.anf.createBlock();
    const body_block = try context.anf.createBlock();
    const exit_block = try context.anf.createBlock();
    try jump(context, condition_block);
    try context.anf.beginBlock(condition_block);
    const condition = try context.emitValue(.{ .to_boolean = try context.lowerExpression(statement.condition) }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = condition, .true_target = body_block, .false_target = exit_block } });
    try context.anf.beginBlock(body_block);
    try pushControl(context, exit_block, condition_block);
    activateIterationLabels(context, condition_block);
    try context.lowerStatement(statement.body);
    _ = context.controls.pop();
    if (!context.anf.currentTerminated()) try jump(context, condition_block);
    try context.anf.beginBlock(exit_block);
}

pub fn lowerDoWhile(context: anytype, statement: ast.DoWhileStatement) anyerror!void {
    const body_block = try context.anf.createBlock();
    const condition_block = try context.anf.createBlock();
    const exit_block = try context.anf.createBlock();
    try jump(context, body_block);
    try context.anf.beginBlock(body_block);
    try pushControl(context, exit_block, condition_block);
    activateIterationLabels(context, condition_block);
    try context.lowerStatement(statement.body);
    _ = context.controls.pop();
    if (!context.anf.currentTerminated()) try jump(context, condition_block);
    try context.anf.beginBlock(condition_block);
    const condition = try context.emitValue(.{ .to_boolean = try context.lowerExpression(statement.condition) }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = condition, .true_target = body_block, .false_target = exit_block } });
    try context.anf.beginBlock(exit_block);
}

pub fn lowerFor(context: anytype, statement: ast.ForStatement) anyerror!void {
    switch (statement.kind) {
        .classic => try lowerClassicFor(context, statement),
        .in => try lowerIteratorLike(context, statement, false, false),
        .of => {
            if (statement.await and !context.allowsAwait()) return error.AwaitOutsideAsyncContext;
            if (statement.await) {
                try lowerIteratorLike(context, statement, true, true);
            } else {
                try lowerIteratorLike(context, statement, true, false);
            }
        },
    }
}

pub fn lowerSwitch(context: anytype, statement: ast.SwitchStatement) anyerror!void {
    const discriminant = try context.lowerExpression(statement.discriminant);
    const exit_block = try context.anf.createBlock();
    const body_blocks = try context.builder.allocator.alloc(ids.BlockId, statement.cases.len);
    var default_target: ?ids.BlockId = null;
    var test_count: usize = 0;
    for (statement.cases, body_blocks) |case_id, *body_block| {
        body_block.* = try context.anf.createBlock();
        const case = context.astNode(case_id).data.SwitchCase;
        if (case.condition == null) default_target = body_block.* else test_count += 1;
    }

    const test_blocks = try context.builder.allocator.alloc(ids.BlockId, test_count);
    for (test_blocks) |*test_block| test_block.* = try context.anf.createBlock();
    if (test_blocks.len == 0)
        try jump(context, default_target orelse exit_block)
    else
        try jump(context, test_blocks[0]);

    var test_index: usize = 0;
    for (statement.cases, body_blocks) |case_id, body_block| {
        const case = context.astNode(case_id).data.SwitchCase;
        const condition_id = case.condition orelse continue;
        try context.anf.beginBlock(test_blocks[test_index]);
        const case_value = try context.lowerExpression(condition_id);
        const matches = try context.emitValue(.{ .binary = .{
            .operator = .equal_strict,
            .left = discriminant,
            .right = case_value,
            .mode = .dynamic,
        } }, context.booleanType());
        test_index += 1;
        const miss = if (test_index < test_blocks.len) test_blocks[test_index] else default_target orelse exit_block;
        try context.anf.terminate(.{ .branch = .{ .condition = matches, .true_target = body_block, .false_target = miss } });
    }

    try pushControl(context, exit_block, null);
    for (statement.cases, body_blocks, 0..) |case_id, body_block, index| {
        try context.anf.beginBlock(body_block);
        const case = context.astNode(case_id).data.SwitchCase;
        for (case.consequent) |child| {
            if (context.anf.currentTerminated()) break;
            try context.lowerStatement(child);
        }
        if (!context.anf.currentTerminated()) {
            const next = if (index + 1 < body_blocks.len) body_blocks[index + 1] else exit_block;
            try jump(context, next);
        }
    }
    _ = context.controls.pop();
    try context.anf.beginBlock(exit_block);
}

pub fn lowerLabeled(context: anytype, statement: ast.LabeledStatement) anyerror!void {
    const exit_block = try context.anf.createBlock();
    try context.labels.append(context.builder.allocator, .{
        .name = statement.label,
        .break_target = exit_block,
        .continue_target = null,
        .iteration = context.labelBodyIsIteration(statement.body),
    });
    try context.lowerStatement(statement.body);
    _ = context.labels.pop();
    if (!context.anf.currentTerminated()) try jump(context, exit_block);
    try context.anf.beginBlock(exit_block);
}

pub fn lowerBreak(context: anytype, statement: ast.BreakStatement) anyerror!void {
    const target = if (statement.label) |name|
        (findLabel(context, name) orelse return error.UnknownControlTarget).break_target
    else blk: {
        if (context.controls.items.len == 0) return error.UnknownControlTarget;
        break :blk context.controls.items[context.controls.items.len - 1].break_target;
    };
    try transfer(context, target, false);
}

pub fn lowerContinue(context: anytype, statement: ast.ContinueStatement) anyerror!void {
    const target = if (statement.label) |name|
        (findLabel(context, name) orelse return error.UnknownControlTarget).continue_target orelse return error.UnknownControlTarget
    else blk: {
        var index = context.controls.items.len;
        while (index > 0) {
            index -= 1;
            if (context.controls.items[index].continue_target) |target| break :blk target;
        }
        return error.UnknownControlTarget;
    };
    try transfer(context, target, true);
}

fn findLabel(context: anytype, name: []const u8) ?LabelFrame {
    var index = context.labels.items.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, context.labels.items[index].name, name)) return context.labels.items[index];
    }
    return null;
}

fn transfer(context: anytype, target: ids.BlockId, comptime is_continue: bool) !void {
    if (context.cleanups.items.len != 0) {
        const cleanup = context.cleanups.items[context.cleanups.items.len - 1];
        const target_index = target.index() orelse return error.UnknownControlTarget;
        const remains_protected = target.eql(cleanup.continue_target) or @as(usize, target_index) >= cleanup.protected_id_start;
        if (!remains_protected) {
            const completion: model.Completion = if (is_continue) .{ .continue_ = target } else .{ .break_ = target };
            try context.anf.terminate(.{ .leave_region = .{
                .region = cleanup.region,
                .completion = completion,
                .cleanup = cleanup.cleanup,
            } });
            return;
        }
    }
    try jump(context, target);
}

fn lowerClassicFor(context: anytype, statement: ast.ForStatement) anyerror!void {
    if (statement.init) |initializer| try context.lowerForInitializer(initializer);
    const condition_block = try context.anf.createBlock();
    const body_block = try context.anf.createBlock();
    const update_block = try context.anf.createBlock();
    const exit_block = try context.anf.createBlock();
    try jump(context, condition_block);
    try context.anf.beginBlock(condition_block);
    const condition = if (statement.condition) |node|
        try context.emitValue(.{ .to_boolean = try context.lowerExpression(node) }, context.booleanType())
    else
        try context.emitValue(.{ .constant = .{ .boolean = true } }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = condition, .true_target = body_block, .false_target = exit_block } });
    try context.anf.beginBlock(body_block);
    try pushControl(context, exit_block, update_block);
    activateIterationLabels(context, update_block);
    try context.lowerStatement(statement.body);
    _ = context.controls.pop();
    if (!context.anf.currentTerminated()) try jump(context, update_block);
    try context.anf.beginBlock(update_block);
    if (statement.update) |update| _ = try context.lowerExpression(update);
    try jump(context, condition_block);
    try context.anf.beginBlock(exit_block);
}

fn lowerIteratorLike(context: anytype, statement: ast.ForStatement, comptime iterator: bool, comptime async_iterator: bool) anyerror!void {
    const initializer = statement.init orelse return error.InvalidForStatement;
    const right = statement.right orelse return error.InvalidForStatement;
    const source = try context.lowerExpression(right);
    const state = if (async_iterator)
        try context.emitSuspension(.{ .get_async_iterator = source }, context.unknownType())
    else if (iterator)
        try context.emitValue(.{ .get_iterator = source }, context.unknownType())
    else
        try context.emitValue(.{ .enumerate_properties = source }, context.unknownType());
    const next_block = try context.anf.createBlock();
    const body_block = try context.anf.createBlock();
    const exit_block = try context.anf.createBlock();
    const cleanup_block = if (iterator) try context.anf.createBlock() else ids.BlockId.invalid;
    const region = if (iterator) try context.builder.reserveRegion(context.function_id, .iterator_close, context.cleanups.items.len + 1) else ids.RegionId.invalid;
    const protected_start = context.anf.blockCount();
    const protected_id_start = if (iterator) @as(usize, cleanup_block.index().?) + 1 else 0;

    try jump(context, next_block);
    try context.anf.beginBlock(next_block);
    const next = if (iterator)
        try context.emitValue(.{ .iterator_next = state }, context.unknownType())
    else
        try context.emitValue(.{ .enumerator_next = state }, context.unknownType());
    const step = if (async_iterator)
        try context.emitSuspension(.{ .await_ = next }, context.unknownType())
    else
        next;
    const done = if (iterator)
        try context.emitValue(.{ .iterator_done = step }, context.booleanType())
    else
        try context.emitValue(.{ .enumerator_done = step }, context.booleanType());
    try context.anf.terminate(.{ .branch = .{ .condition = done, .true_target = exit_block, .false_target = body_block } });

    try context.anf.beginBlock(body_block);
    const value = if (iterator)
        try context.emitValue(.{ .iterator_value = step }, context.unknownType())
    else
        try context.emitValue(.{ .enumerator_value = step }, context.unknownType());
    try context.assignIterationTarget(initializer, value);
    try pushControl(context, exit_block, next_block);
    activateIterationLabels(context, next_block);
    if (iterator) try context.cleanups.append(context.builder.allocator, .{
        .region = region,
        .cleanup = cleanup_block,
        .continue_target = next_block,
        .protected_id_start = protected_id_start,
    });
    try context.lowerStatement(statement.body);
    if (iterator) _ = context.cleanups.pop();
    _ = context.controls.pop();
    if (!context.anf.currentTerminated()) try jump(context, next_block);

    if (iterator) {
        try context.anf.beginBlock(cleanup_block);
        try context.emitVoid(.{ .iterator_close = state });
        try context.anf.terminate(.resume_completion);
        const nested = try context.anf.blockIdsSince(protected_start);
        const protected = try context.builder.allocator.alloc(ids.BlockId, nested.len + 1);
        protected[0] = body_block;
        @memcpy(protected[1..], nested);
        const parent = if (context.cleanups.items.len == 0) null else context.cleanups.items[context.cleanups.items.len - 1].region;
        try context.builder.replaceRegion(.{
            .id = region,
            .function = context.function_id,
            .parent = parent,
            .kind = .iterator_close,
            .protected_blocks = protected,
            .handler = cleanup_block,
            .continuation = exit_block,
            .origin = .invalid,
        });
        try context.regions.append(context.builder.allocator, region);
    }
    try context.anf.beginBlock(exit_block);
}

fn jump(context: anytype, target: ids.BlockId) !void {
    try context.anf.terminate(.{ .jump = .{ .target = target } });
}

fn pushControl(context: anytype, break_target: ids.BlockId, continue_target: ?ids.BlockId) !void {
    try context.controls.append(context.builder.allocator, .{
        .break_target = break_target,
        .continue_target = continue_target,
    });
}

fn activateIterationLabels(context: anytype, target: ids.BlockId) void {
    for (context.labels.items) |*label| {
        if (label.iteration and label.continue_target == null) label.continue_target = target;
    }
}
