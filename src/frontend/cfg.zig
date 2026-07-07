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
        },
        .FunctionDeclaration => |function_decl| {
            try functions.append(allocator, .{
                .function = node_id,
                .name = function_decl.name,
                .graph = try buildFunctionGraph(allocator, tree, function_decl.body),
            });
        },
        .BlockStatement => |block| {
            for (block.statements) |statement| try collectFunctions(allocator, tree, statement, functions);
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
    allocator: std.mem.Allocator,
    tree: ast_mod.Ast,
    blocks: std.ArrayList(BlockBuilder) = .empty,
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
            .ReturnStatement => {
                try self.addStatement(current, statement);
                try self.addEdge(current, self.exit);
                return null;
            },
            .IfStatement => |if_statement| return self.buildIfStatement(current, statement, if_statement),
            .WhileStatement => |while_statement| return self.buildWhileStatement(current, statement, while_statement),
            .ForStatement => |for_statement| return self.buildForStatement(current, statement, for_statement),
            else => {
                try self.addStatement(current, statement);
                return current;
            },
        }
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
        const condition = try self.beginConditionBlock(current);
        try self.addStatement(condition, statement);

        const body = try self.createBlock(.normal);
        const after = try self.createBlock(.normal);
        try self.addEdge(condition, body);
        try self.addEdge(condition, after);

        const body_fallthrough = try self.buildStatement(body, while_statement.body);
        if (body_fallthrough) |block| try self.addEdge(block, condition);
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
        const before_condition = current;
        if (for_statement.init) |init_node| try self.addStatement(before_condition, init_node);

        const condition = try self.createBlock(.condition);
        try self.addEdge(before_condition, condition);
        try self.addStatement(condition, statement);

        const body = try self.createBlock(.normal);
        try self.addEdge(condition, body);

        const after = if (for_statement.condition != null) try self.createBlock(.normal) else null;
        if (after) |after_block| try self.addEdge(condition, after_block);

        const body_fallthrough = try self.buildStatement(body, for_statement.body);
        if (body_fallthrough) |block| {
            if (for_statement.update) |update| {
                const update_block = try self.createBlock(.normal);
                try self.addEdge(block, update_block);
                try self.addStatement(update_block, update);
                try self.addEdge(update_block, condition);
            } else {
                try self.addEdge(block, condition);
            }
        }

        return after;
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
    const parsed = try parser.parse(allocator, scan.tokens, true);
    const cfgs = try build(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 1), cfgs.len);
    try std.testing.expectEqual(@as(usize, 3), cfgs[0].graph.blocks.len);
    try std.testing.expectEqual(@as(BasicBlockId, 0), cfgs[0].graph.entry);
    try std.testing.expectEqual(@as(BasicBlockId, 1), cfgs[0].graph.exit);
    try std.testing.expectEqual(@as(usize, 2), cfgs[0].graph.blocks[2].statements.len);
    try std.testing.expectEqual(@as(usize, 1), cfgs[0].graph.blocks[2].successors.len);
    try std.testing.expectEqual(cfgs[0].graph.exit, cfgs[0].graph.blocks[2].successors[0]);
}
