const std = @import("std");
const ast_mod = @import("ast.zig");

const NodeId = ast_mod.NodeId;

pub const BasicBlockId = u32;

pub const BasicBlockKind = enum {
    entry,
    exit,
    normal,
    condition,
    @"unreachable",
};

pub const BasicBlock = struct {
    id: BasicBlockId,
    kind: BasicBlockKind = .normal,
    statements: []const NodeId,
    successors: []const BasicBlockId,
    predecessors: []const BasicBlockId,
};

pub const ControlFlowGraph = struct {
    entry: BasicBlockId,
    exit: BasicBlockId,
    blocks: []const BasicBlock,
};

pub const FunctionCfg = struct {
    function: NodeId,
    name: []const u8,
    graph: ControlFlowGraph,
};

pub fn build(allocator: std.mem.Allocator, tree: ast_mod.Ast) ![]const FunctionCfg {
    var functions: std.ArrayList(FunctionCfg) = .empty;
    errdefer functions.deinit(allocator);

    try collectFunctions(allocator, tree, tree.root, &functions);
    return functions.toOwnedSlice(allocator);
}

fn collectFunctions(allocator: std.mem.Allocator, tree: ast_mod.Ast, node_id: NodeId, functions: *std.ArrayList(FunctionCfg)) anyerror!void {
    if (node_id == ast_mod.invalid_node) return;
    const node = tree.node(node_id);
    switch (node.data) {
        .Program => |program| {
            for (program.statements) |statement| try collectFunctions(allocator, tree, statement, functions);
        },
        .ExportDeclaration => |export_decl| {
            if (export_decl.declaration != ast_mod.invalid_node) {
                const declaration = export_decl.declaration;
                try collectFunctions(allocator, tree, declaration, functions);
            }
            if (export_decl.expression != ast_mod.invalid_node) try collectFunctions(allocator, tree, export_decl.expression, functions);
        },
        .FunctionDeclaration => |function_decl| {
            try functions.append(allocator, .{
                .function = node_id,
                .name = function_decl.name,
                .graph = try buildFunctionGraph(allocator, tree, function_decl.body),
            });
        },
        .FunctionExpression => |function_expr| {
            try functions.append(allocator, .{
                .function = node_id,
                .name = function_expr.name orelse "<anonymous>",
                .graph = try buildFunctionGraph(allocator, tree, function_expr.body),
            });
        },
        .ArrowFunctionExpression => |arrow| {
            if (!arrow.expression_body) try functions.append(allocator, .{
                .function = node_id,
                .name = "<arrow>",
                .graph = try buildFunctionGraph(allocator, tree, arrow.body),
            });
        },
        .ClassDeclaration => |class_decl| for (class_decl.members) |member| try collectFunctions(allocator, tree, member, functions),
        .ClassExpression => |class_expr| for (class_expr.members) |member| try collectFunctions(allocator, tree, member, functions),
        .ClassMethod => |method| {
            try functions.append(allocator, .{
                .function = node_id,
                .name = method.name,
                .graph = try buildFunctionGraph(allocator, tree, method.body),
            });
        },
        .VariableDeclaration => |declaration| for (declaration.declarations) |item| try collectFunctions(allocator, tree, item, functions),
        .VariableDeclarator => |declarator| if (declarator.init) |init| try collectFunctions(allocator, tree, init, functions),
        .BlockStatement => |block| {
            for (block.statements) |statement| try collectFunctions(allocator, tree, statement, functions);
        },
        .TryStatement => |try_stmt| {
            try collectFunctions(allocator, tree, try_stmt.block, functions);
            if (try_stmt.handler) |handler| try collectFunctions(allocator, tree, handler, functions);
            if (try_stmt.finalizer) |finalizer| try collectFunctions(allocator, tree, finalizer, functions);
        },
        .CatchClause => |catch_clause| try collectFunctions(allocator, tree, catch_clause.body, functions),
        .FinallyClause => |finally_clause| try collectFunctions(allocator, tree, finally_clause.body, functions),
        .LabeledStatement => |labeled| try collectFunctions(allocator, tree, labeled.body, functions),
        .SwitchStatement => |switch_stmt| {
            for (switch_stmt.cases) |case| try collectFunctions(allocator, tree, case, functions);
        },
        .SwitchCase => |switch_case| {
            for (switch_case.consequent) |statement| try collectFunctions(allocator, tree, statement, functions);
        },
        else => {},
    }
}

fn buildFunctionGraph(allocator: std.mem.Allocator, tree: ast_mod.Ast, body_id: NodeId) !ControlFlowGraph {
    var builder = GraphBuilder.init(allocator, tree);
    const entry = try builder.createBlock(.entry);
    builder.exit = try builder.createBlock(.exit);

    const first = try builder.createBlock(.normal);
    try builder.addEdge(entry, first);

    const fallthrough = try builder.buildStatementList(first, blockStatements(tree, body_id));
    if (fallthrough) |block| try builder.addEdge(block, builder.exit);

    return .{
        .entry = entry,
        .exit = builder.exit,
        .blocks = try builder.finish(),
    };
}

const BlockBuilder = struct {
    id: BasicBlockId,
    kind: BasicBlockKind,
    statements: std.ArrayList(NodeId) = .empty,
    successors: std.ArrayList(BasicBlockId) = .empty,
    predecessors: std.ArrayList(BasicBlockId) = .empty,
};

const GraphBuilder = struct {
    const LoopContext = struct {
        continue_target: BasicBlockId,
    };
    const LabelContext = struct { name: []const u8, break_target: BasicBlockId, continue_target: ?BasicBlockId, iteration: bool };

    allocator: std.mem.Allocator,
    tree: ast_mod.Ast,
    blocks: std.ArrayList(BlockBuilder) = .empty,
    loops: std.ArrayList(LoopContext) = .empty,
    break_targets: std.ArrayList(BasicBlockId) = .empty,
    labels: std.ArrayList(LabelContext) = .empty,
    exit: BasicBlockId = 0,

    fn init(allocator: std.mem.Allocator, tree: ast_mod.Ast) GraphBuilder {
        return .{ .allocator = allocator, .tree = tree };
    }

    fn createBlock(self: *GraphBuilder, kind: BasicBlockKind) !BasicBlockId {
        const id: BasicBlockId = @intCast(self.blocks.items.len);
        try self.blocks.append(self.allocator, .{ .id = id, .kind = kind });
        return id;
    }

    fn addEdge(self: *GraphBuilder, from: BasicBlockId, to: BasicBlockId) !void {
        if (!containsBlockId(self.blocks.items[@intCast(from)].successors.items, to)) {
            try self.blocks.items[@intCast(from)].successors.append(self.allocator, to);
        }
        if (!containsBlockId(self.blocks.items[@intCast(to)].predecessors.items, from)) {
            try self.blocks.items[@intCast(to)].predecessors.append(self.allocator, from);
        }
    }

    fn addStatement(self: *GraphBuilder, block: BasicBlockId, statement: NodeId) !void {
        try self.blocks.items[@intCast(block)].statements.append(self.allocator, statement);
    }

    fn buildStatementList(self: *GraphBuilder, start: BasicBlockId, statements: []const NodeId) anyerror!?BasicBlockId {
        var current: ?BasicBlockId = start;
        for (statements) |statement| {
            if (current == null) current = try self.createBlock(.@"unreachable");
            current = try self.buildStatement(current.?, statement);
        }
        return current;
    }

    fn buildStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId) anyerror!?BasicBlockId {
        if (statement == ast_mod.invalid_node) return current;
        const node = self.tree.node(statement);
        switch (node.data) {
            .BlockStatement => |block| return self.buildStatementList(current, block.statements),
            .ReturnStatement, .ThrowStatement => {
                try self.addStatement(current, statement);
                try self.addEdge(current, self.exit);
                return null;
            },
            .LabeledStatement => |labeled| return self.buildLabeledStatement(current, labeled),
            .DebuggerStatement => {
                try self.addStatement(current, statement);
                return current;
            },
            .BreakStatement => |break_statement| {
                try self.addStatement(current, statement);
                const target = if (break_statement.label) |label|
                    if (self.findLabel(label)) |context| context.break_target else null
                else
                    self.currentBreakTarget();
                if (target) |destination| try self.addEdge(current, destination);
                return null;
            },
            .ContinueStatement => |continue_statement| {
                try self.addStatement(current, statement);
                const target = if (continue_statement.label) |label|
                    if (self.findLabel(label)) |context| context.continue_target else null
                else if (self.currentLoop()) |loop|
                    loop.continue_target
                else
                    null;
                if (target) |destination| try self.addEdge(current, destination);
                return null;
            },
            .IfStatement => |if_statement| return self.buildIfStatement(current, statement, if_statement),
            .TryStatement => |try_statement| return self.buildTryStatement(current, statement, try_statement),
            .CatchClause => |catch_clause| {
                try self.addStatement(current, statement);
                return self.buildStatement(current, catch_clause.body);
            },
            .FinallyClause => |finally_clause| {
                try self.addStatement(current, statement);
                return self.buildStatement(current, finally_clause.body);
            },
            .WhileStatement => |while_statement| return self.buildWhileStatement(current, statement, while_statement),
            .DoWhileStatement => |do_while_statement| return self.buildDoWhileStatement(current, statement, do_while_statement),
            .ForStatement => |for_statement| return self.buildForStatement(current, statement, for_statement),
            .SwitchStatement => |switch_statement| return self.buildSwitchStatement(current, statement, switch_statement),
            else => {
                try self.addStatement(current, statement);
                return current;
            },
        }
    }

    fn buildLabeledStatement(self: *GraphBuilder, current: BasicBlockId, labeled: ast_mod.LabeledStatement) anyerror!?BasicBlockId {
        const after = try self.createBlock(.normal);
        const body_node = self.tree.node(labeled.body);
        const fallthrough = switch (body_node.data) {
            .WhileStatement => |value| try self.buildWhileStatementLabeled(current, labeled.body, value, labeled.label, after),
            .DoWhileStatement => |value| try self.buildDoWhileStatementLabeled(current, labeled.body, value, labeled.label, after),
            .ForStatement => |value| try self.buildForStatementLabeled(current, labeled.body, value, labeled.label, after),
            else => blk: {
                try self.labels.append(self.allocator, .{ .name = labeled.label, .break_target = after, .continue_target = null, .iteration = self.isIterationLabelBody(labeled.body) });
                defer _ = self.labels.pop();
                break :blk try self.buildStatement(current, labeled.body);
            },
        };
        if (fallthrough) |block| if (block != after) try self.addEdge(block, after);
        return after;
    }

    fn isIterationLabelBody(self: *GraphBuilder, node_id: NodeId) bool {
        return switch (self.tree.node(node_id).data) {
            .WhileStatement, .DoWhileStatement, .ForStatement => true,
            .LabeledStatement => |nested| self.isIterationLabelBody(nested.body),
            else => false,
        };
    }

    fn activatePendingIterationLabels(self: *GraphBuilder, target: BasicBlockId) void {
        for (self.labels.items) |*label| if (label.iteration and label.continue_target == null) {
            label.continue_target = target;
        };
    }

    fn buildTryStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, try_statement: ast_mod.TryStatement) anyerror!?BasicBlockId {
        const dispatch = try self.beginConditionBlock(current);
        try self.addStatement(dispatch, statement);

        const try_entry = try self.createBlock(.normal);
        try self.addEdge(dispatch, try_entry);
        const try_fallthrough = try self.buildStatement(try_entry, try_statement.block);

        var catch_fallthrough: ?BasicBlockId = null;
        if (try_statement.handler) |handler| {
            const catch_entry = try self.createBlock(.normal);
            try self.addEdge(dispatch, catch_entry);
            catch_fallthrough = try self.buildStatement(catch_entry, handler);
        }

        if (try_statement.finalizer) |finalizer| {
            const finally_entry = try self.createBlock(.normal);
            if (try_fallthrough) |block| try self.addEdge(block, finally_entry);
            if (catch_fallthrough) |block| try self.addEdge(block, finally_entry);
            if (try_statement.handler == null) try self.addEdge(dispatch, finally_entry);
            return self.buildStatement(finally_entry, finalizer);
        }

        if (try_fallthrough == null and catch_fallthrough == null) return null;
        const after = try self.createBlock(.normal);
        if (try_fallthrough) |block| try self.addEdge(block, after);
        if (catch_fallthrough) |block| try self.addEdge(block, after);
        return after;
    }

    fn buildIfStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, if_statement: ast_mod.IfStatement) anyerror!?BasicBlockId {
        const condition = try self.beginConditionBlock(current);
        try self.addStatement(condition, statement);

        const then_block = try self.createBlock(.normal);
        try self.addEdge(condition, then_block);
        const then_fallthrough = try self.buildStatement(then_block, if_statement.consequent);

        var else_fallthrough: ?BasicBlockId = null;
        if (if_statement.alternate) |alternate| {
            const else_block = try self.createBlock(.normal);
            try self.addEdge(condition, else_block);
            else_fallthrough = try self.buildStatement(else_block, alternate);
        }

        const needs_merge = then_fallthrough != null or if_statement.alternate == null or else_fallthrough != null;
        if (!needs_merge) return null;

        const merge = try self.createBlock(.normal);
        if (then_fallthrough) |block| try self.addEdge(block, merge);
        if (if_statement.alternate) |_| {
            if (else_fallthrough) |block| try self.addEdge(block, merge);
        } else {
            try self.addEdge(condition, merge);
        }
        return merge;
    }

    fn buildWhileStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, while_statement: ast_mod.WhileStatement) anyerror!?BasicBlockId {
        return self.buildWhileStatementWithLabel(current, statement, while_statement, null, null);
    }

    fn buildWhileStatementLabeled(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, while_statement: ast_mod.WhileStatement, label: []const u8, after: BasicBlockId) anyerror!?BasicBlockId {
        return self.buildWhileStatementWithLabel(current, statement, while_statement, label, after);
    }

    fn buildWhileStatementWithLabel(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, while_statement: ast_mod.WhileStatement, label: ?[]const u8, forced_after: ?BasicBlockId) anyerror!?BasicBlockId {
        const condition = try self.beginConditionBlock(current);
        try self.addStatement(condition, statement);

        const body = try self.createBlock(.normal);
        const after = forced_after orelse try self.createBlock(.normal);
        try self.addEdge(condition, body);
        try self.addEdge(condition, after);

        try self.loops.append(self.allocator, .{ .continue_target = condition });
        defer _ = self.loops.pop();
        try self.break_targets.append(self.allocator, after);
        defer _ = self.break_targets.pop();
        self.activatePendingIterationLabels(condition);
        if (label) |name| try self.labels.append(self.allocator, .{ .name = name, .break_target = after, .continue_target = condition, .iteration = true });
        defer if (label != null) {
            _ = self.labels.pop();
        };
        const body_fallthrough = try self.buildStatement(body, while_statement.body);
        if (body_fallthrough) |block| try self.addEdge(block, condition);
        return after;
    }

    fn buildDoWhileStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, do_while_statement: ast_mod.DoWhileStatement) anyerror!?BasicBlockId {
        return self.buildDoWhileStatementWithLabel(current, statement, do_while_statement, null, null);
    }

    fn buildDoWhileStatementLabeled(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, do_while_statement: ast_mod.DoWhileStatement, label: []const u8, after: BasicBlockId) anyerror!?BasicBlockId {
        return self.buildDoWhileStatementWithLabel(current, statement, do_while_statement, label, after);
    }

    fn buildDoWhileStatementWithLabel(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, do_while_statement: ast_mod.DoWhileStatement, label: ?[]const u8, forced_after: ?BasicBlockId) anyerror!?BasicBlockId {
        const body = try self.createBlock(.normal);
        const condition = try self.createBlock(.condition);
        const after = forced_after orelse try self.createBlock(.normal);
        try self.addEdge(current, body);
        try self.addStatement(condition, statement);

        try self.loops.append(self.allocator, .{ .continue_target = condition });
        defer _ = self.loops.pop();
        try self.break_targets.append(self.allocator, after);
        defer _ = self.break_targets.pop();
        self.activatePendingIterationLabels(condition);
        if (label) |name| try self.labels.append(self.allocator, .{ .name = name, .break_target = after, .continue_target = condition, .iteration = true });
        defer if (label != null) {
            _ = self.labels.pop();
        };
        const body_fallthrough = try self.buildStatement(body, do_while_statement.body);
        if (body_fallthrough) |block| try self.addEdge(block, condition);

        try self.addEdge(condition, body);
        try self.addEdge(condition, after);
        return after;
    }

    fn beginConditionBlock(self: *GraphBuilder, current: BasicBlockId) !BasicBlockId {
        const current_block = &self.blocks.items[@intCast(current)];
        const kind: BasicBlockKind = if (current_block.kind == .@"unreachable") .@"unreachable" else .condition;
        if (current_block.statements.items.len == 0) {
            current_block.kind = kind;
            return current;
        }

        const condition = try self.createBlock(kind);
        try self.addEdge(current, condition);
        return condition;
    }

    fn buildForStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, for_statement: ast_mod.ForStatement) anyerror!?BasicBlockId {
        return self.buildForStatementWithLabel(current, statement, for_statement, null, null);
    }

    fn buildForStatementLabeled(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, for_statement: ast_mod.ForStatement, label: []const u8, after: BasicBlockId) anyerror!?BasicBlockId {
        return self.buildForStatementWithLabel(current, statement, for_statement, label, after);
    }

    fn buildForStatementWithLabel(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, for_statement: ast_mod.ForStatement, label: ?[]const u8, forced_after: ?BasicBlockId) anyerror!?BasicBlockId {
        const before_condition = current;
        if (for_statement.init) |init_node| try self.addStatement(before_condition, init_node);

        const condition = try self.createBlock(.condition);
        try self.addEdge(before_condition, condition);
        try self.addStatement(condition, statement);

        const body = try self.createBlock(.normal);
        try self.addEdge(condition, body);

        const after = forced_after orelse try self.createBlock(.normal);
        if (for_statement.kind != .classic or for_statement.condition != null) try self.addEdge(condition, after);

        const update_block = if (for_statement.update != null) try self.createBlock(.normal) else null;
        const continue_target = update_block orelse condition;
        try self.loops.append(self.allocator, .{ .continue_target = continue_target });
        defer _ = self.loops.pop();
        try self.break_targets.append(self.allocator, after);
        defer _ = self.break_targets.pop();
        self.activatePendingIterationLabels(continue_target);
        if (label) |name| try self.labels.append(self.allocator, .{ .name = name, .break_target = after, .continue_target = continue_target, .iteration = true });
        defer if (label != null) {
            _ = self.labels.pop();
        };

        const body_fallthrough = try self.buildStatement(body, for_statement.body);
        if (body_fallthrough) |block| {
            if (for_statement.update != null) {
                try self.addEdge(block, update_block.?);
            } else {
                try self.addEdge(block, condition);
            }
        }

        if (for_statement.update) |update| {
            try self.addStatement(update_block.?, update);
            try self.addEdge(update_block.?, condition);
        }

        return after;
    }

    fn buildSwitchStatement(self: *GraphBuilder, current: BasicBlockId, statement: NodeId, switch_statement: ast_mod.SwitchStatement) anyerror!?BasicBlockId {
        const condition = try self.beginConditionBlock(current);
        try self.addStatement(condition, statement);
        const after = try self.createBlock(.normal);

        const case_blocks = try self.allocator.alloc(BasicBlockId, switch_statement.cases.len);
        for (case_blocks) |*case_block| case_block.* = try self.createBlock(.normal);

        var has_default = false;
        for (switch_statement.cases, case_blocks) |case_node, case_block| {
            try self.addEdge(condition, case_block);
            const switch_case = self.tree.node(case_node).data.SwitchCase;
            if (switch_case.condition == null) has_default = true;
        }
        if (!has_default or switch_statement.cases.len == 0) try self.addEdge(condition, after);

        try self.break_targets.append(self.allocator, after);
        defer _ = self.break_targets.pop();
        for (switch_statement.cases, case_blocks, 0..) |case_node, case_block, index| {
            const switch_case = self.tree.node(case_node).data.SwitchCase;
            const fallthrough = try self.buildStatementList(case_block, switch_case.consequent);
            if (fallthrough) |block| {
                const target = if (index + 1 < case_blocks.len) case_blocks[index + 1] else after;
                try self.addEdge(block, target);
            }
        }
        return after;
    }

    fn currentLoop(self: *GraphBuilder) ?LoopContext {
        if (self.loops.items.len == 0) return null;
        return self.loops.items[self.loops.items.len - 1];
    }

    fn currentBreakTarget(self: *GraphBuilder) ?BasicBlockId {
        if (self.break_targets.items.len == 0) return null;
        return self.break_targets.items[self.break_targets.items.len - 1];
    }

    fn findLabel(self: *GraphBuilder, name: []const u8) ?LabelContext {
        var index = self.labels.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.labels.items[index].name, name)) return self.labels.items[index];
        }
        return null;
    }

    fn finish(self: *GraphBuilder) ![]const BasicBlock {
        const result = try self.allocator.alloc(BasicBlock, self.blocks.items.len);
        for (self.blocks.items, 0..) |*block, index| {
            result[index] = .{
                .id = block.id,
                .kind = block.kind,
                .statements = try block.statements.toOwnedSlice(self.allocator),
                .successors = try block.successors.toOwnedSlice(self.allocator),
                .predecessors = try block.predecessors.toOwnedSlice(self.allocator),
            };
        }
        return result;
    }
};

fn blockStatements(tree: ast_mod.Ast, body_id: NodeId) []const NodeId {
    if (body_id == ast_mod.invalid_node) return &.{};
    return switch (tree.node(body_id).data) {
        .BlockStatement => |block| block.statements,
        else => &.{},
    };
}

fn containsBlockId(ids: []const BasicBlockId, target: BasicBlockId) bool {
    for (ids) |id| {
        if (id == target) return true;
    }
    return false;
}

test "cfg creates a graph for exported function" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    return message;
        \\}
    ;

    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const cfgs = try build(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 1), cfgs.len);
    try std.testing.expectEqual(@as(usize, 3), cfgs[0].graph.blocks.len);
    try std.testing.expectEqual(@as(BasicBlockId, 0), cfgs[0].graph.entry);
    try std.testing.expectEqual(@as(BasicBlockId, 1), cfgs[0].graph.exit);
    try std.testing.expectEqual(@as(usize, 2), cfgs[0].graph.blocks[2].statements.len);
    try std.testing.expectEqual(@as(usize, 1), cfgs[0].graph.blocks[2].successors.len);
    try std.testing.expectEqual(cfgs[0].graph.exit, cfgs[0].graph.blocks[2].successors[0]);
}

test "cfg enters do while body before condition" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\function f(x: number) {
        \\    do { x = x - 1; } while (x > 0);
        \\    return x;
        \\}
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const graph = (try build(allocator, parsed.ast))[0].graph;

    try std.testing.expectEqual(@as(usize, 6), graph.blocks.len);
    try std.testing.expect(containsBlockId(graph.blocks[graph.entry].successors, 2));
    try std.testing.expect(containsBlockId(graph.blocks[2].successors, 3));
    try std.testing.expect(!containsBlockId(graph.blocks[2].successors, 4));
    try std.testing.expectEqual(BasicBlockKind.normal, graph.blocks[3].kind);
    try std.testing.expect(containsBlockId(graph.blocks[3].successors, 4));
    try std.testing.expectEqual(BasicBlockKind.condition, graph.blocks[4].kind);
    try std.testing.expect(containsBlockId(graph.blocks[4].successors, 3));
    try std.testing.expect(containsBlockId(graph.blocks[4].successors, 5));
    try std.testing.expect(containsBlockId(graph.blocks[5].successors, graph.exit));
}

test "cfg gives for of loops body exit and back edges" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\function visit(iterable) {
        \\    for (const value of iterable) { value; }
        \\    return iterable;
        \\}
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const graph = (try build(allocator, parsed.ast))[0].graph;

    var condition_id: ?BasicBlockId = null;
    for (graph.blocks) |block| {
        if (block.kind == .condition) condition_id = block.id;
    }
    const condition = graph.blocks[@intCast(condition_id.?)];
    try std.testing.expectEqual(@as(usize, 2), condition.successors.len);
    const body = condition.successors[0];
    const after = condition.successors[1];
    try std.testing.expect(containsBlockId(graph.blocks[@intCast(body)].successors, condition.id));
    try std.testing.expect(containsBlockId(graph.blocks[@intCast(after)].successors, graph.exit));
}

test "cfg preserves switch fallthrough and break exits" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\function classify(value) {
        \\    switch (value) {
        \\        case 1: first();
        \\        case 2: second(); break;
        \\        default: fallback();
        \\    }
        \\    return value;
        \\}
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const graph = (try build(allocator, parsed.ast))[0].graph;

    var dispatch: ?BasicBlock = null;
    for (graph.blocks) |block| {
        if (block.kind == .condition) dispatch = block;
    }
    try std.testing.expect(dispatch != null);
    try std.testing.expectEqual(@as(usize, 3), dispatch.?.successors.len);
    const first_case = dispatch.?.successors[0];
    const second_case = dispatch.?.successors[1];
    const default_case = dispatch.?.successors[2];
    try std.testing.expect(containsBlockId(graph.blocks[@intCast(first_case)].successors, second_case));
    const second_target = graph.blocks[@intCast(second_case)].successors[0];
    try std.testing.expect(containsBlockId(graph.blocks[@intCast(default_case)].successors, second_target));
    try std.testing.expect(!containsBlockId(graph.blocks[@intCast(second_case)].successors, default_case));
}

test "cfg routes try and catch fallthrough through finally" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\function f(value) {
        \\    try { value; } catch (error) { error; } finally { value; }
        \\    return value;
        \\}
    , true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const graph = (try build(allocator, parsed.ast))[0].graph;

    var dispatch: ?BasicBlock = null;
    var catch_block: ?BasicBlock = null;
    var finally_block: ?BasicBlock = null;
    for (graph.blocks) |block| {
        for (block.statements) |statement| switch (parsed.ast.node(statement).data) {
            .TryStatement => dispatch = block,
            .CatchClause => catch_block = block,
            .FinallyClause => finally_block = block,
            else => {},
        };
    }
    try std.testing.expect(dispatch != null);
    try std.testing.expect(catch_block != null);
    try std.testing.expect(finally_block != null);
    try std.testing.expectEqual(@as(usize, 2), dispatch.?.successors.len);
    try std.testing.expect(containsBlockId(dispatch.?.successors, catch_block.?.id));
    const try_body = if (dispatch.?.successors[0] == catch_block.?.id)
        dispatch.?.successors[1]
    else
        dispatch.?.successors[0];
    try std.testing.expect(containsBlockId(graph.blocks[@intCast(try_body)].successors, finally_block.?.id));
    try std.testing.expect(containsBlockId(catch_block.?.successors, finally_block.?.id));
}

test "cfg routes labeled break and continue to explicit targets" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\function run(stop) {
        \\    first: second: for (;;) {
        \\        if (stop) break second;
        \\        continue first;
        \\    }
        \\    return 1;
        \\}
    , true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const graph = (try build(allocator, parsed.ast))[0].graph;

    var condition_id: ?BasicBlockId = null;
    var break_block: ?BasicBlock = null;
    var continue_block: ?BasicBlock = null;
    for (graph.blocks) |block| {
        if (block.kind == .condition) {
            for (block.statements) |statement| switch (parsed.ast.node(statement).data) {
                .ForStatement => condition_id = block.id,
                else => {},
            };
        }
        for (block.statements) |statement| switch (parsed.ast.node(statement).data) {
            .BreakStatement => break_block = block,
            .ContinueStatement => continue_block = block,
            else => {},
        };
    }
    try std.testing.expect(condition_id != null);
    try std.testing.expect(break_block != null);
    try std.testing.expect(continue_block != null);
    try std.testing.expect(containsBlockId(continue_block.?.successors, condition_id.?));
    try std.testing.expectEqual(@as(usize, 1), break_block.?.successors.len);
    try std.testing.expect(break_block.?.successors[0] != condition_id.?);
}
