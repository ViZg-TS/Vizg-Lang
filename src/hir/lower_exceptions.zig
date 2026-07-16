//! Canonical exception, catch, and cleanup-region lowering.

const ast = @import("../frontend/ast.zig");
const ids = @import("ids.zig");
const lower_control = @import("lower_control.zig");
const model = @import("model.zig");

pub fn lowerTry(context: anytype, statement: ast.TryStatement) anyerror!void {
    const continuation = try context.anf.createBlock();
    const finally_clause = if (statement.finalizer) |node_id| context.astNode(node_id).data.FinallyClause else null;
    const finally_handler = if (finally_clause != null) try context.anf.createBlock() else ids.BlockId.invalid;
    const finally_region = if (finally_clause != null) try context.builder.reserveRegion(context.function_id, .finally, context.cleanups.items.len + 1) else ids.RegionId.invalid;
    const catch_clause = if (statement.handler) |node_id| context.astNode(node_id).data.CatchClause else null;
    const catch_handler = if (catch_clause != null) try context.anf.createBlock() else ids.BlockId.invalid;
    const catch_region = if (catch_clause != null) try context.builder.reserveRegion(context.function_id, .catch_, context.cleanups.items.len + @as(usize, if (finally_clause != null) 2 else 1)) else ids.RegionId.invalid;
    const try_entry = try context.anf.createBlock();

    try jump(context, try_entry);
    try context.anf.beginBlock(try_entry);

    if (finally_clause != null) try context.cleanups.append(context.builder.allocator, .{
        .region = finally_region,
        .cleanup = finally_handler,
        .continue_target = continuation,
        .protected_id_start = try_entry.index().?,
    });
    if (catch_clause != null) try context.catch_cleanup_depths.append(context.builder.allocator, context.cleanups.items.len);

    const try_start = context.anf.blockCount();
    try context.lowerStatement(statement.block);
    if (catch_clause != null) _ = context.catch_cleanup_depths.pop();
    if (!context.anf.currentTerminated()) try normalExit(context, finally_region, finally_handler, continuation);
    const try_nested = try context.anf.blockIdsSince(try_start);
    const try_blocks = try prependBlock(context, try_entry, try_nested);

    var catch_blocks: []const ids.BlockId = &.{};
    if (catch_clause) |clause| {
        try context.anf.beginBlock(catch_handler);
        if (clause.parameter) |parameter| {
            const exception = try context.anf.addParameter(catch_handler, context.unknownType());
            try context.emitVoid(.{ .initialize_binding = .{
                .binding = try context.catchBinding(parameter),
                .value = exception,
            } });
        }
        const catch_start = context.anf.blockCount();
        try context.lowerStatement(clause.body);
        if (!context.anf.currentTerminated()) try normalExit(context, finally_region, finally_handler, continuation);
        catch_blocks = try prependBlock(context, catch_handler, try context.anf.blockIdsSince(catch_start));
        try context.builder.replaceRegion(.{
            .id = catch_region,
            .function = context.function_id,
            .parent = if (finally_clause != null) finally_region else null,
            .kind = .catch_,
            .protected_blocks = try_blocks,
            .handler = catch_handler,
            .continuation = continuation,
            .origin = .invalid,
        });
        try context.regions.append(context.builder.allocator, catch_region);
    }

    if (finally_clause) |clause| {
        _ = context.cleanups.pop();
        try context.anf.beginBlock(finally_handler);
        try context.lowerStatement(clause.body);
        if (!context.anf.currentTerminated()) try context.anf.terminate(.resume_completion);
        const protected = try context.builder.allocator.alloc(ids.BlockId, try_blocks.len + catch_blocks.len);
        @memcpy(protected[0..try_blocks.len], try_blocks);
        @memcpy(protected[try_blocks.len..], catch_blocks);
        try context.builder.replaceRegion(.{
            .id = finally_region,
            .function = context.function_id,
            .parent = if (context.cleanups.items.len == 0) null else context.cleanups.items[context.cleanups.items.len - 1].region,
            .kind = .finally,
            .protected_blocks = protected,
            .handler = finally_handler,
            .continuation = continuation,
            .origin = .invalid,
        });
        try context.regions.append(context.builder.allocator, finally_region);
    }

    try context.anf.beginBlock(continuation);
}

pub fn lowerThrow(context: anytype, statement: ast.ThrowStatement) anyerror!void {
    const value = try context.lowerExpression(statement.argument);
    const caught_here = context.catch_cleanup_depths.items.len != 0 and
        context.cleanups.items.len <= context.catch_cleanup_depths.items[context.catch_cleanup_depths.items.len - 1];
    if (context.cleanups.items.len == 0 or caught_here) {
        try context.anf.terminate(.{ .throw = value });
        return;
    }
    const cleanup = context.cleanups.items[context.cleanups.items.len - 1];
    try context.anf.terminate(.{ .leave_region = .{
        .region = cleanup.region,
        .completion = .{ .throw = value },
        .cleanup = cleanup.cleanup,
    } });
}

fn normalExit(context: anytype, region: ids.RegionId, cleanup: ids.BlockId, continuation: ids.BlockId) !void {
    if (region.index() != null)
        try context.anf.terminate(.{ .leave_region = .{
            .region = region,
            .completion = .{ .normal = continuation },
            .cleanup = cleanup,
        } })
    else
        try jump(context, continuation);
}

fn prependBlock(context: anytype, first: ids.BlockId, rest: []const ids.BlockId) ![]const ids.BlockId {
    const result = try context.builder.allocator.alloc(ids.BlockId, rest.len + 1);
    result[0] = first;
    @memcpy(result[1..], rest);
    return result;
}

fn jump(context: anytype, target: ids.BlockId) !void {
    try context.anf.terminate(.{ .jump = .{ .target = target } });
}
