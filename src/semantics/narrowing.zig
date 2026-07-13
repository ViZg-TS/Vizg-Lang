const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const cfg = @import("../frontend/cfg.zig");
const frontend = @import("../frontend/frontend.zig");
const tokens = @import("../frontend/tokens.zig");
const types = @import("../types/root.zig");
const type_info = @import("type_info.zig");

const Fact = struct { symbol: binder.SymbolId, type_id: types.TypeId };

pub const Result = struct { flow_types: []const type_info.FlowTypeInfo };

const Analyzer = struct {
    allocator: std.mem.Allocator,
    frontend_result: frontend.FrontendResult,
    store: *types.TypeStore,
    symbols: []const type_info.SymbolTypeInfo,
    nodes: *std.ArrayList(type_info.NodeTypeInfo),
    flow: std.ArrayList(type_info.FlowTypeInfo) = .empty,
    function_node: ast.NodeId = ast.invalid_node,
    function_cfg: ?cfg.FunctionCfg = null,

    fn run(self: *Analyzer) !Result {
        for (self.frontend_result.cfgs) |function_cfg| {
            self.function_node = function_cfg.function;
            self.function_cfg = function_cfg;
            var facts: std.ArrayList(Fact) = .empty;
            try self.processFunction(function_cfg.function, &facts);
        }
        return .{ .flow_types = try self.flow.toOwnedSlice(self.allocator) };
    }

    fn processFunction(self: *Analyzer, node_id: ast.NodeId, facts: *std.ArrayList(Fact)) !void {
        switch (self.frontend_result.ast.node(node_id).data) {
            .FunctionDeclaration => |value| try self.processStatement(value.body, facts),
            .FunctionExpression => |value| try self.processStatement(value.body, facts),
            .ArrowFunctionExpression => |value| if (value.expression_body)
                try self.processExpr(value.body, facts, self.blockFor(value.body))
            else
                try self.processStatement(value.body, facts),
            .ClassMethod => |value| try self.processStatement(value.body, facts),
            else => {},
        }
    }

    fn processStatement(self: *Analyzer, node_id: ast.NodeId, facts: *std.ArrayList(Fact)) anyerror!void {
        if (!self.valid(node_id)) return;
        const block_id = self.blockFor(node_id);
        switch (self.frontend_result.ast.node(node_id).data) {
            .BlockStatement => |value| for (value.statements) |statement| try self.processStatement(statement, facts),
            .ExpressionStatement => |value| try self.processExpr(value.expression, facts, block_id),
            .VariableDeclaration => |value| for (value.declarations) |declaration| try self.processStatement(declaration, facts),
            .VariableDeclarator => |value| {
                if (value.init) |initializer| try self.processExpr(initializer, facts, block_id);
                self.invalidateDeclaration(node_id, facts);
            },
            .ReturnStatement => |value| if (value.argument) |argument| try self.processExpr(argument, facts, block_id),
            .ThrowStatement => |value| try self.processExpr(value.argument, facts, block_id),
            .IfStatement => |value| {
                try self.processExpr(value.condition, facts, block_id);
                var true_facts = try self.cloneFacts(facts.items);
                try self.applyGuard(value.condition, true, &true_facts);
                try self.processStatement(value.consequent, &true_facts);
                var false_facts = try self.cloneFacts(facts.items);
                try self.applyGuard(value.condition, false, &false_facts);
                if (value.alternate) |alternate| {
                    try self.processStatement(alternate, &false_facts);
                }
                const true_exits = self.statementTerminates(value.consequent);
                const false_exits = if (value.alternate) |alternate| self.statementTerminates(alternate) else false;
                if (true_exits and !false_exits) facts.* = false_facts else if (false_exits and !true_exits) facts.* = true_facts;
            },
            .WhileStatement => |value| {
                try self.processExpr(value.condition, facts, block_id);
                var body_facts = try self.cloneFacts(facts.items);
                try self.applyGuard(value.condition, true, &body_facts);
                try self.processStatement(value.body, &body_facts);
            },
            .DoWhileStatement => |value| {
                var body_facts = try self.cloneFacts(facts.items);
                try self.processStatement(value.body, &body_facts);
                try self.processExpr(value.condition, &body_facts, block_id);
            },
            .ForStatement => |value| {
                if (value.init) |child| try self.processStatement(child, facts);
                if (value.condition) |condition| try self.processExpr(condition, facts, block_id);
                var body_facts = try self.cloneFacts(facts.items);
                if (value.condition) |condition| try self.applyGuard(condition, true, &body_facts);
                try self.processStatement(value.body, &body_facts);
                if (value.update) |update| try self.processExpr(update, &body_facts, block_id);
            },
            .LabeledStatement => |value| try self.processStatement(value.body, facts),
            else => {},
        }
    }

    fn processExpr(self: *Analyzer, node_id: ast.NodeId, facts: *std.ArrayList(Fact), block_id: u32) anyerror!void {
        if (!self.valid(node_id)) return;
        switch (self.frontend_result.ast.node(node_id).data) {
            .Identifier => if (self.symbolForNode(node_id)) |symbol| {
                const narrowed = self.factType(facts.items, symbol) orelse self.baseType(symbol);
                try self.putNode(.{ .node_id = node_id, .type_id = narrowed });
                try self.putFlow(.{ .function_node = self.function_node, .block_id = block_id, .symbol_id = symbol, .reference_node = node_id, .type_id = narrowed });
            },
            .UnaryExpression => |value| try self.processExpr(value.argument, facts, block_id),
            .BinaryExpression => |value| {
                try self.processExpr(value.left, facts, block_id);
                try self.processExpr(value.right, facts, block_id);
            },
            .AssignmentExpression => |value| {
                try self.processExpr(value.right, facts, block_id);
                try self.processExpr(value.left, facts, block_id);
                if (self.symbolForNode(value.left)) |symbol| self.removeFact(facts, symbol);
            },
            .UpdateExpression => |value| {
                try self.processExpr(value.argument, facts, block_id);
                if (self.symbolForNode(value.argument)) |symbol| self.removeFact(facts, symbol);
            },
            .CallExpression => |value| {
                try self.processExpr(value.callee, facts, block_id);
                for (value.arguments) |argument| try self.processExpr(argument, facts, block_id);
                if (self.nodeType(value.callee) == self.store.builtins.unknown or self.nodeType(value.callee) == self.store.builtins.any)
                    facts.clearRetainingCapacity();
            },
            .NewExpression => |value| {
                try self.processExpr(value.callee, facts, block_id);
                for (value.arguments) |argument| try self.processExpr(argument, facts, block_id);
            },
            .MemberExpression => |value| try self.processExpr(value.object, facts, block_id),
            .ElementAccessExpression => |value| {
                try self.processExpr(value.object, facts, block_id);
                try self.processExpr(value.index, facts, block_id);
            },
            .AsExpression => |value| try self.processExpr(value.expression, facts, block_id),
            .SatisfiesExpression => |value| try self.processExpr(value.expression, facts, block_id),
            .NonNullExpression => |value| try self.processExpr(value.expression, facts, block_id),
            .ConditionalExpression => |value| {
                try self.processExpr(value.condition, facts, block_id);
                var yes = try self.cloneFacts(facts.items);
                try self.applyGuard(value.condition, true, &yes);
                try self.processExpr(value.consequent, &yes, block_id);
                var no = try self.cloneFacts(facts.items);
                try self.applyGuard(value.condition, false, &no);
                try self.processExpr(value.alternate, &no, block_id);
            },
            .SequenceExpression => |value| for (value.expressions) |child| try self.processExpr(child, facts, block_id),
            .ArrayExpression => |value| for (value.elements) |element| if (element) |child| try self.processExpr(child, facts, block_id),
            .ObjectExpression => |value| for (value.properties) |property| try self.processExpr(property.value, facts, block_id),
            .SpreadElement => |value| try self.processExpr(value.argument, facts, block_id),
            .YieldExpression => |value| if (value.argument) |argument| try self.processExpr(argument, facts, block_id),
            else => {},
        }
    }

    fn applyGuard(self: *Analyzer, node_id: ast.NodeId, truthy: bool, facts: *std.ArrayList(Fact)) anyerror!void {
        const data = self.frontend_result.ast.node(node_id).data;
        if (data == .UnaryExpression and data.UnaryExpression.operator == .Exclamation)
            return self.applyGuard(data.UnaryExpression.argument, !truthy, facts);
        if (data == .Identifier) {
            if (self.symbolForNode(node_id)) |symbol| try self.setFact(facts, symbol, try self.removeNullish(self.currentType(facts.items, symbol), truthy));
            return;
        }
        if (data != .BinaryExpression) return;
        const binary = data.BinaryExpression;
        const equality = switch (binary.operator) {
            .EqualsEquals, .EqualsEqualsEquals => true,
            .ExclamationEquals, .ExclamationEqualsEquals => false,
            else => null,
        };
        if (equality) |equal_when_true| {
            const keep = if (truthy) equal_when_true else !equal_when_true;
            if (try self.applyTypeofEquality(binary.left, binary.right, keep, facts)) return;
            if (try self.applyTypeofEquality(binary.right, binary.left, keep, facts)) return;
            const loose = binary.operator == .EqualsEquals or binary.operator == .ExclamationEquals;
            if (try self.applyNullishEquality(binary.left, binary.right, keep, loose, facts)) return;
            if (try self.applyNullishEquality(binary.right, binary.left, keep, loose, facts)) return;
        }
        if (binary.operator == .Keyword_instanceof and truthy) {
            if (self.symbolForNode(binary.left)) |symbol| try self.setFact(facts, symbol, self.nodeType(binary.right));
        } else if (binary.operator == .Keyword_in and truthy) {
            if (self.symbolForNode(binary.right)) |symbol| {
                if (self.literalText(binary.left)) |name| try self.setFact(facts, symbol, try self.keepProperty(self.currentType(facts.items, symbol), name));
            }
        }
    }

    fn applyTypeofEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, facts: *std.ArrayList(Fact)) !bool {
        const left_data = self.frontend_result.ast.node(left).data;
        if (left_data != .UnaryExpression or left_data.UnaryExpression.operator != .Keyword_typeof) return false;
        const name = self.literalText(right) orelse return false;
        const wanted = if (std.mem.eql(u8, name, "string")) self.store.builtins.string else if (std.mem.eql(u8, name, "number")) self.store.builtins.number else if (std.mem.eql(u8, name, "boolean")) self.store.builtins.boolean else if (std.mem.eql(u8, name, "bigint")) self.store.builtins.bigint else if (std.mem.eql(u8, name, "symbol")) self.store.builtins.symbol else if (std.mem.eql(u8, name, "undefined")) self.store.builtins.undefined else return false;
        const symbol = self.symbolForNode(left_data.UnaryExpression.argument) orelse return false;
        try self.setFact(facts, symbol, try self.filterType(self.currentType(facts.items, symbol), wanted, keep));
        return true;
    }

    fn applyNullishEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, loose: bool, facts: *std.ArrayList(Fact)) !bool {
        const wanted = if (self.isNull(right)) self.store.builtins.null_ else if (self.isUndefined(right)) self.store.builtins.undefined else return false;
        const symbol = self.symbolForNode(left) orelse return false;
        const narrowed = if (loose)
            try self.filterNullish(self.currentType(facts.items, symbol), keep)
        else
            try self.filterType(self.currentType(facts.items, symbol), wanted, keep);
        try self.setFact(facts, symbol, narrowed);
        return true;
    }

    fn removeNullish(self: *Analyzer, type_id: types.TypeId, truthy: bool) !types.TypeId {
        return self.filterNullish(type_id, !truthy);
    }

    fn filterNullish(self: *Analyzer, type_id: types.TypeId, keep: bool) !types.TypeId {
        if (!keep) {
            const without_null = try self.filterType(type_id, self.store.builtins.null_, false);
            return self.filterType(without_null, self.store.builtins.undefined, false);
        }
        const null_type = try self.filterType(type_id, self.store.builtins.null_, true);
        const undefined_type = try self.filterType(type_id, self.store.builtins.undefined, true);
        return self.store.unionOf(&.{ null_type, undefined_type });
    }

    fn filterType(self: *Analyzer, type_id: types.TypeId, wanted: types.TypeId, keep: bool) !types.TypeId {
        const ty = self.store.lookup(type_id) orelse return type_id;
        if (ty.kind == .union_type) {
            var members: std.ArrayList(types.TypeId) = .empty;
            for (ty.kind.union_type) |member| if ((self.matches(member, wanted)) == keep) try members.append(self.allocator, member);
            return self.store.unionOf(members.items);
        }
        return if (self.matches(type_id, wanted) == keep) type_id else self.store.builtins.never;
    }

    fn matches(self: *Analyzer, actual: types.TypeId, wanted: types.TypeId) bool {
        if (actual == wanted) return true;
        const ty = self.store.lookup(actual) orelse return false;
        if (ty.kind != .literal) return false;
        return switch (ty.kind.literal) {
            .string => wanted == self.store.builtins.string,
            .number => wanted == self.store.builtins.number,
            .boolean => wanted == self.store.builtins.boolean,
            .bigint => wanted == self.store.builtins.bigint,
        };
    }

    fn keepProperty(self: *Analyzer, type_id: types.TypeId, name: []const u8) !types.TypeId {
        const ty = self.store.lookup(type_id) orelse return type_id;
        if (ty.kind == .union_type) {
            var members: std.ArrayList(types.TypeId) = .empty;
            for (ty.kind.union_type) |member| if (self.hasProperty(member, name)) try members.append(self.allocator, member);
            return self.store.unionOf(members.items);
        }
        return if (self.hasProperty(type_id, name)) type_id else self.store.builtins.never;
    }

    fn hasProperty(self: *Analyzer, type_id: types.TypeId, name: []const u8) bool {
        const ty = self.store.lookup(type_id) orelse return false;
        if (ty.kind != .object) return false;
        for (ty.kind.object) |property| if (std.mem.eql(u8, property.name, name)) return true;
        return false;
    }

    fn setFact(self: *Analyzer, facts: *std.ArrayList(Fact), symbol: binder.SymbolId, type_id: types.TypeId) !void {
        for (facts.items) |*fact| if (fact.symbol == symbol) { fact.type_id = type_id; return; };
        try facts.append(self.allocator, .{ .symbol = symbol, .type_id = type_id });
    }
    fn removeFact(_: *Analyzer, facts: *std.ArrayList(Fact), symbol: binder.SymbolId) void {
        for (facts.items, 0..) |fact, index| if (fact.symbol == symbol) { _ = facts.swapRemove(index); return; };
    }
    fn invalidateDeclaration(self: *Analyzer, declaration: ast.NodeId, facts: *std.ArrayList(Fact)) void {
        for (self.frontend_result.bind.symbols) |symbol| if (symbol.declaration == declaration) self.removeFact(facts, symbol.id);
    }
    fn cloneFacts(self: *Analyzer, source: []const Fact) !std.ArrayList(Fact) { var result: std.ArrayList(Fact) = .empty; try result.appendSlice(self.allocator, source); return result; }
    fn factType(_: *Analyzer, facts: []const Fact, symbol: binder.SymbolId) ?types.TypeId { for (facts) |fact| if (fact.symbol == symbol) return fact.type_id; return null; }
    fn currentType(self: *Analyzer, facts: []const Fact, symbol: binder.SymbolId) types.TypeId { return self.factType(facts, symbol) orelse self.baseType(symbol); }
    fn baseType(self: *Analyzer, symbol: binder.SymbolId) types.TypeId { for (self.symbols) |entry| if (entry.symbol_id == symbol) return entry.effective() orelse self.store.builtins.unknown; return self.store.builtins.unknown; }
    fn symbolForNode(self: *Analyzer, node: ast.NodeId) ?binder.SymbolId { for (self.frontend_result.resolve.references) |reference| if (reference.node == node) return reference.symbol; return null; }
    fn nodeType(self: *Analyzer, node: ast.NodeId) types.TypeId { for (self.nodes.items) |entry| if (entry.node_id == node) return entry.type_id; return self.store.builtins.unknown; }
    fn putNode(self: *Analyzer, value: type_info.NodeTypeInfo) !void { for (self.nodes.items) |*entry| if (entry.node_id == value.node_id) { entry.* = value; return; }; try self.nodes.append(self.allocator, value); }
    fn putFlow(self: *Analyzer, value: type_info.FlowTypeInfo) !void { for (self.flow.items) |*entry| if (entry.function_node == value.function_node and entry.block_id == value.block_id and entry.reference_node == value.reference_node) { entry.* = value; return; }; try self.flow.append(self.allocator, value); }
    fn literalText(self: *Analyzer, node: ast.NodeId) ?[]const u8 {
        const raw = switch (self.frontend_result.ast.node(node).data) { .Literal => |value| value.value, else => return null };
        if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\'')))
            return raw[1 .. raw.len - 1];
        return raw;
    }
    fn isNull(self: *Analyzer, node: ast.NodeId) bool { return if (self.literalText(node)) |value| std.mem.eql(u8, value, "null") else false; }
    fn isUndefined(self: *Analyzer, node: ast.NodeId) bool { return switch (self.frontend_result.ast.node(node).data) { .Identifier => |value| std.mem.eql(u8, value.name, "undefined"), else => false }; }
    fn valid(self: *Analyzer, node: ast.NodeId) bool { return node != ast.invalid_node and @as(usize, @intCast(node)) < self.frontend_result.ast.nodes.len; }
    fn statementTerminates(self: *Analyzer, node: ast.NodeId) bool {
        if (!self.valid(node)) return false;
        return switch (self.frontend_result.ast.node(node).data) {
            .ReturnStatement, .ThrowStatement, .BreakStatement, .ContinueStatement => true,
            .BlockStatement => |value| value.statements.len != 0 and self.statementTerminates(value.statements[value.statements.len - 1]),
            .IfStatement => |value| if (value.alternate) |alternate| self.statementTerminates(value.consequent) and self.statementTerminates(alternate) else false,
            .LabeledStatement => |value| self.statementTerminates(value.body),
            else => false,
        };
    }
    fn blockFor(self: *Analyzer, node: ast.NodeId) u32 { const function_cfg = self.function_cfg orelse return 0; for (function_cfg.graph.blocks) |block| for (block.statements) |statement| if (statement == node) return block.id; return function_cfg.graph.entry; }
};

pub fn analyze(allocator: std.mem.Allocator, result: frontend.FrontendResult, store: *types.TypeStore, symbols: []const type_info.SymbolTypeInfo, nodes: *std.ArrayList(type_info.NodeTypeInfo)) !Result {
    var analyzer: Analyzer = .{ .allocator = allocator, .frontend_result = result, .store = store, .symbols = symbols, .nodes = nodes };
    return analyzer.run();
}
