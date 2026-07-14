const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const cfg = @import("../frontend/cfg.zig");
const frontend = @import("../frontend/frontend.zig");
const tokens = @import("../frontend/tokens.zig");
const types = @import("../types/root.zig");
const dataflow = @import("dataflow.zig");
const type_info = @import("type_info.zig");

pub const Result = struct { flow_types: []const type_info.FlowTypeInfo };

const Analyzer = struct {
    allocator: std.mem.Allocator,
    frontend_result: frontend.FrontendResult,
    store: *types.TypeStore,
    symbols: []const type_info.SymbolTypeInfo,
    nodes: *std.ArrayList(type_info.NodeTypeInfo),
    flow: std.ArrayList(type_info.FlowTypeInfo) = .empty,
    function_node: ast.NodeId = ast.invalid_node,
    block_id: cfg.BasicBlockId = 0,
    program_point: u32 = 0,

    fn run(self: *Analyzer) !Result {
        for (self.frontend_result.cfgs) |function_cfg| {
            self.function_node = function_cfg.function;
            var solved = try dataflow.solve(self.allocator, function_cfg.graph, &.{}, self);
            defer solved.deinit();
        }
        return .{ .flow_types = try self.flow.toOwnedSlice(self.allocator) };
    }

    pub fn transferBlock(self: *Analyzer, block: cfg.BasicBlock, facts: *dataflow.StateBuilder) !void {
        self.block_id = block.id;
        self.program_point = 0;
        for (block.statements) |statement| try self.processStatement(statement, facts);
    }

    pub fn transferEdge(self: *Analyzer, predecessor: cfg.BasicBlock, successor: cfg.BasicBlock, facts: *dataflow.StateBuilder) !void {
        if (predecessor.kind != .condition or predecessor.statements.len == 0) return;
        var successor_index: ?usize = null;
        for (predecessor.successors, 0..) |candidate, index| if (candidate == successor.id) {
            successor_index = index;
            break;
        };
        const truthy = (successor_index orelse return) == 0;
        const statement = predecessor.statements[predecessor.statements.len - 1];
        switch (self.frontend_result.ast.node(statement).data) {
            .IfStatement => |value| try self.applyGuard(value.condition, truthy, facts),
            .WhileStatement => |value| try self.applyGuard(value.condition, truthy, facts),
            .DoWhileStatement => |value| try self.applyGuard(value.condition, truthy, facts),
            .ForStatement => |value| if (value.condition) |condition| try self.applyGuard(condition, truthy, facts),
            else => {},
        }
    }

    pub fn mergeValues(self: *Analyzer, key: dataflow.FactKey, left: u32, right: u32) !?u32 {
        if (left == right) return left;
        const merged = try self.store.unionOf(&.{ left, right });
        return if (merged == self.baseType(key.symbol)) null else merged;
    }

    fn processStatement(self: *Analyzer, node_id: ast.NodeId, facts: *dataflow.StateBuilder) anyerror!void {
        if (!self.valid(node_id)) return;
        switch (self.frontend_result.ast.node(node_id).data) {
            .ExpressionStatement => |value| try self.processExpr(value.expression, facts),
            .VariableDeclaration => |value| for (value.declarations) |declaration| try self.processStatement(declaration, facts),
            .VariableDeclarator => |value| {
                if (value.init) |initializer| try self.processExpr(initializer, facts);
                self.invalidateDeclaration(node_id, facts);
            },
            .ReturnStatement => |value| if (value.argument) |argument| try self.processExpr(argument, facts),
            .ThrowStatement => |value| try self.processExpr(value.argument, facts),
            .IfStatement => |value| try self.processExpr(value.condition, facts),
            .WhileStatement => |value| try self.processExpr(value.condition, facts),
            .DoWhileStatement => |value| try self.processExpr(value.condition, facts),
            .ForStatement => |value| {
                if (value.condition) |condition| try self.processExpr(condition, facts);
            },
            .SwitchStatement => |value| try self.processExpr(value.discriminant, facts),
            .Identifier,
            .UnaryExpression,
            .BinaryExpression,
            .AssignmentExpression,
            .UpdateExpression,
            .CallExpression,
            .NewExpression,
            .MemberExpression,
            .ElementAccessExpression,
            .AsExpression,
            .SatisfiesExpression,
            .NonNullExpression,
            .ConditionalExpression,
            .SequenceExpression,
            .ArrayExpression,
            .ObjectExpression,
            .SpreadElement,
            .YieldExpression,
            => try self.processExpr(node_id, facts),
            else => {},
        }
    }

    fn processExpr(self: *Analyzer, node_id: ast.NodeId, facts: *dataflow.StateBuilder) anyerror!void {
        if (!self.valid(node_id)) return;
        switch (self.frontend_result.ast.node(node_id).data) {
            .Identifier => if (self.symbolForNode(node_id)) |symbol| {
                const narrowed = self.factType(facts, symbol) orelse self.baseType(symbol);
                try self.putNode(.{ .node_id = node_id, .type_id = narrowed });
                try self.putFlow(.{ .function_node = self.function_node, .block_id = self.block_id, .program_point = self.program_point, .symbol_id = symbol, .reference_node = node_id, .type_id = narrowed });
                self.program_point += 1;
            },
            .UnaryExpression => |value| try self.processExpr(value.argument, facts),
            .BinaryExpression => |value| {
                try self.processExpr(value.left, facts);
                switch (value.operator) {
                    .AmpersandAmpersand, .BarBar, .QuestionQuestion => {
                        var skipped = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                        defer skipped.deinit();
                        var taken = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                        defer taken.deinit();
                        if (value.operator == .QuestionQuestion) {
                            try self.applyNullishGuard(value.left, true, &skipped);
                            try self.applyNullishGuard(value.left, false, &taken);
                        } else {
                            const execute_when_truthy = value.operator == .AmpersandAmpersand;
                            try self.applyGuard(value.left, !execute_when_truthy, &skipped);
                            try self.applyGuard(value.left, execute_when_truthy, &taken);
                        }
                        try self.processExpr(value.right, &taken);
                        try self.joinExpressionStates(facts, &skipped, &taken);
                    },
                    else => try self.processExpr(value.right, facts),
                }
            },
            .AssignmentExpression => |value| {
                try self.processExpr(value.left, facts);
                if (value.operator == .AmpersandAmpersandEqual or value.operator == .BarBarEqual or value.operator == .QuestionQuestionEqual) {
                    var skipped = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer skipped.deinit();
                    var taken = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer taken.deinit();
                    if (value.operator == .QuestionQuestionEqual) {
                        try self.applyNullishGuard(value.left, true, &taken);
                        try self.applyNullishGuard(value.left, false, &skipped);
                    } else {
                        const execute_when_truthy = value.operator == .AmpersandAmpersandEqual;
                        try self.applyGuard(value.left, execute_when_truthy, &taken);
                        try self.applyGuard(value.left, !execute_when_truthy, &skipped);
                    }
                    try self.processExpr(value.right, &taken);
                    try self.replaceAssignmentFact(value.left, self.nodeType(value.right), &taken);
                    try self.joinExpressionStates(facts, &skipped, &taken);
                } else {
                    try self.processExpr(value.right, facts);
                    try self.replaceAssignmentFact(value.left, self.nodeType(node_id), facts);
                }
            },
            .UpdateExpression => |value| {
                try self.processExpr(value.argument, facts);
                if (self.symbolForNode(value.argument)) |symbol| self.removeFact(facts, symbol);
            },
            .CallExpression => |value| {
                try self.processExpr(value.callee, facts);
                if (self.optionalChainBase(value.callee) != null or value.optional) {
                    var skipped = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer skipped.deinit();
                    var taken = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer taken.deinit();
                    const guard = self.optionalChainBase(value.callee) orelse value.callee;
                    try self.applyNullishGuard(guard, true, &skipped);
                    try self.applyNullishGuard(guard, false, &taken);
                    try self.processCallTail(value.callee, value.arguments, &taken);
                    try self.joinExpressionStates(facts, &skipped, &taken);
                } else try self.processCallTail(value.callee, value.arguments, facts);
            },
            .NewExpression => |value| {
                try self.processExpr(value.callee, facts);
                for (value.arguments) |argument| try self.processExpr(argument, facts);
            },
            .MemberExpression => |value| try self.processExpr(value.object, facts),
            .ElementAccessExpression => |value| {
                try self.processExpr(value.object, facts);
                if (self.optionalChainBase(value.object) != null or value.optional) {
                    var skipped = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer skipped.deinit();
                    var taken = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                    defer taken.deinit();
                    const guard = self.optionalChainBase(value.object) orelse value.object;
                    try self.applyNullishGuard(guard, true, &skipped);
                    try self.applyNullishGuard(guard, false, &taken);
                    try self.processExpr(value.index, &taken);
                    try self.joinExpressionStates(facts, &skipped, &taken);
                } else try self.processExpr(value.index, facts);
            },
            .AsExpression => |value| try self.processExpr(value.expression, facts),
            .SatisfiesExpression => |value| try self.processExpr(value.expression, facts),
            .NonNullExpression => |value| try self.processExpr(value.expression, facts),
            .ConditionalExpression => |value| {
                try self.processExpr(value.condition, facts);
                var yes = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                defer yes.deinit();
                try self.applyGuard(value.condition, true, &yes);
                try self.processExpr(value.consequent, &yes);
                var no = try dataflow.StateBuilder.initFrom(self.allocator, facts.facts.items);
                defer no.deinit();
                try self.applyGuard(value.condition, false, &no);
                try self.processExpr(value.alternate, &no);
                try self.joinExpressionStates(facts, &yes, &no);
            },
            .SequenceExpression => |value| for (value.expressions) |child| try self.processExpr(child, facts),
            .ArrayExpression => |value| for (value.elements) |element| if (element) |child| try self.processExpr(child, facts),
            .ObjectExpression => |value| for (value.properties) |property| try self.processExpr(property.value, facts),
            .SpreadElement => |value| try self.processExpr(value.argument, facts),
            .YieldExpression => |value| if (value.argument) |argument| try self.processExpr(argument, facts),
            else => {},
        }
    }

    fn processCallTail(self: *Analyzer, callee: ast.NodeId, arguments: []const ast.NodeId, facts: *dataflow.StateBuilder) !void {
        for (arguments) |argument| try self.processExpr(argument, facts);
        if (self.nodeType(callee) == self.store.builtins.unknown or self.nodeType(callee) == self.store.builtins.any)
            facts.clear();
    }

    fn replaceAssignmentFact(self: *Analyzer, target: ast.NodeId, replacement: types.TypeId, facts: *dataflow.StateBuilder) !void {
        const symbol = self.symbolForNode(target) orelse return;
        if (replacement == self.store.builtins.unknown or replacement == self.store.builtins.any)
            self.removeFact(facts, symbol)
        else
            try self.setFact(facts, symbol, replacement);
    }

    fn joinExpressionStates(self: *Analyzer, output: *dataflow.StateBuilder, left: *const dataflow.StateBuilder, right: *const dataflow.StateBuilder) !void {
        var joined: dataflow.StateBuilder = .{ .allocator = self.allocator };
        defer joined.deinit();
        for (left.facts.items) |fact| {
            const right_value = right.get(fact.key) orelse continue;
            if (try self.mergeValues(fact.key, fact.value, right_value)) |value|
                try joined.set(fact.key, value);
        }
        output.clear();
        try output.facts.appendSlice(self.allocator, joined.facts.items);
    }

    fn applyNullishGuard(self: *Analyzer, node_id: ast.NodeId, keep_nullish: bool, facts: *dataflow.StateBuilder) !void {
        const symbol = self.symbolForNode(node_id) orelse return;
        try self.setFact(facts, symbol, try self.filterNullish(self.currentType(facts, symbol), keep_nullish));
    }

    fn optionalChainBase(self: *Analyzer, node_id: ast.NodeId) ?ast.NodeId {
        if (!self.valid(node_id)) return null;
        return switch (self.frontend_result.ast.node(node_id).data) {
            .MemberExpression => |value| if (value.optional) value.object else self.optionalChainBase(value.object),
            .ElementAccessExpression => |value| if (value.optional) value.object else self.optionalChainBase(value.object),
            .CallExpression => |value| if (value.optional) value.callee else self.optionalChainBase(value.callee),
            else => null,
        };
    }

    fn applyGuard(self: *Analyzer, node_id: ast.NodeId, truthy: bool, facts: *dataflow.StateBuilder) anyerror!void {
        const data = self.frontend_result.ast.node(node_id).data;
        if (data == .UnaryExpression and data.UnaryExpression.operator == .Exclamation)
            return self.applyGuard(data.UnaryExpression.argument, !truthy, facts);
        if (data == .Identifier) {
            if (self.symbolForNode(node_id)) |symbol| try self.setFact(facts, symbol, try self.filterTruthiness(self.currentType(facts, symbol), truthy));
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
        if (binary.operator == .Keyword_instanceof) {
            const constructor = self.store.lookup(self.nodeType(binary.right)) orelse return;
            if (constructor.kind != .class_constructor) return;
            if (self.symbolForNode(binary.left)) |symbol| try self.setFact(
                facts,
                symbol,
                try self.filterType(self.currentType(facts, symbol), constructor.kind.class_constructor.instance_type, truthy),
            );
        } else if (binary.operator == .Keyword_in and truthy) {
            if (self.symbolForNode(binary.right)) |symbol| {
                if (self.literalText(binary.left)) |name| try self.setFact(facts, symbol, try self.keepProperty(self.currentType(facts, symbol), name));
            }
        }
    }

    fn applyTypeofEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, facts: *dataflow.StateBuilder) !bool {
        const left_data = self.frontend_result.ast.node(left).data;
        if (left_data != .UnaryExpression or left_data.UnaryExpression.operator != .Keyword_typeof) return false;
        const name = self.literalText(right) orelse return false;
        const wanted = if (std.mem.eql(u8, name, "string")) self.store.builtins.string else if (std.mem.eql(u8, name, "number")) self.store.builtins.number else if (std.mem.eql(u8, name, "boolean")) self.store.builtins.boolean else if (std.mem.eql(u8, name, "bigint")) self.store.builtins.bigint else if (std.mem.eql(u8, name, "symbol")) self.store.builtins.symbol else if (std.mem.eql(u8, name, "undefined")) self.store.builtins.undefined else return false;
        const symbol = self.symbolForNode(left_data.UnaryExpression.argument) orelse return false;
        try self.setFact(facts, symbol, try self.filterType(self.currentType(facts, symbol), wanted, keep));
        return true;
    }

    fn applyNullishEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, loose: bool, facts: *dataflow.StateBuilder) !bool {
        const wanted = if (self.isNull(right)) self.store.builtins.null_ else if (self.isUndefined(right)) self.store.builtins.undefined else return false;
        const symbol = self.symbolForNode(left) orelse return false;
        const narrowed = if (loose)
            try self.filterNullish(self.currentType(facts, symbol), keep)
        else
            try self.filterType(self.currentType(facts, symbol), wanted, keep);
        try self.setFact(facts, symbol, narrowed);
        return true;
    }

    const Truthiness = enum { always_falsy, always_truthy, maybe };

    fn filterTruthiness(self: *Analyzer, type_id: types.TypeId, truthy: bool) !types.TypeId {
        const ty = self.store.lookup(type_id) orelse return type_id;
        if (ty.kind == .union_type) {
            var members: std.ArrayList(types.TypeId) = .empty;
            defer members.deinit(self.allocator);
            for (ty.kind.union_type) |member| {
                const classification = self.classifyTruthiness(member);
                if (classification == .maybe or (classification == .always_truthy) == truthy)
                    try members.append(self.allocator, member);
            }
            return self.store.unionOf(members.items);
        }
        const classification = self.classifyTruthiness(type_id);
        return if (classification == .maybe or (classification == .always_truthy) == truthy)
            type_id
        else
            self.store.builtins.never;
    }

    fn classifyTruthiness(self: *Analyzer, type_id: types.TypeId) Truthiness {
        const ty = self.store.lookup(type_id) orelse return .maybe;
        return switch (ty.kind) {
            .primitive => |primitive| switch (primitive) {
                .never => .always_truthy,
                .undefined, .null_, .void => .always_falsy,
                .symbol, .object => .always_truthy,
                .boolean, .number, .bigint, .string, .any, .unknown => .maybe,
            },
            .literal => |literal| switch (literal) {
                .boolean => |value| if (value) .always_truthy else .always_falsy,
                .number => |value| if (value == 0 or std.math.isNan(value)) .always_falsy else .always_truthy,
                .bigint => |value| if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "0n")) .always_falsy else .always_truthy,
                .string => |value| if (value.len == 0) .always_falsy else .always_truthy,
            },
            .union_type => .maybe,
            .function, .promise, .generator, .array, .tuple, .object, .class, .class_constructor, .interface => .always_truthy,
            .intersection, .enum_type, .type_parameter => .maybe,
            .applied_generic => blk: {
                const target = self.store.resolveAppliedTarget(type_id) catch break :blk .maybe;
                break :blk if (target == type_id) .maybe else self.classifyTruthiness(target);
            },
        };
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
            defer members.deinit(self.allocator);
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
            defer members.deinit(self.allocator);
            for (ty.kind.union_type) |member| if (self.hasProperty(member, name)) try members.append(self.allocator, member);
            return self.store.unionOf(members.items);
        }
        return if (self.hasProperty(type_id, name)) type_id else self.store.builtins.never;
    }

    fn hasProperty(self: *Analyzer, type_id: types.TypeId, name: []const u8) bool {
        const ty = self.store.lookup(type_id) orelse return false;
        return switch (ty.kind) {
            .object => |properties| blk: {
                for (properties) |property| if (std.mem.eql(u8, property.name, name)) break :blk true;
                break :blk false;
            },
            .class => |instance| self.classHasProperty(instance.identity, name, self.store.count() + 1),
            .interface => |interface| self.interfaceHasProperty(interface.identity, name, self.store.count() + 1),
            .applied_generic => blk: {
                const target = self.store.resolveAppliedTarget(type_id) catch break :blk false;
                break :blk target != type_id and self.hasProperty(target, name);
            },
            else => false,
        };
    }

    fn classHasProperty(self: *Analyzer, identity: types.SemanticDeclId, name: []const u8, remaining: usize) bool {
        if (remaining == 0) return false;
        const class = self.store.lookupClassSemanticType(identity) orelse return false;
        for (class.instance_members.members) |member| if (std.mem.eql(u8, member.name, name)) return true;
        const base_id = class.inheritance.extends orelse return false;
        const base = self.store.lookup(base_id) orelse return false;
        return base.kind == .class and self.classHasProperty(base.kind.class.identity, name, remaining - 1);
    }

    fn interfaceHasProperty(self: *Analyzer, identity: types.SemanticDeclId, name: []const u8, remaining: usize) bool {
        if (remaining == 0) return false;
        const interface = self.store.lookupInterfaceSemanticType(identity) orelse return false;
        for (interface.members.members) |member| if (std.mem.eql(u8, member.name, name)) return true;
        for (interface.inheritance.extends) |base_id| {
            const base = self.store.lookup(base_id) orelse continue;
            if (base.kind == .interface and self.interfaceHasProperty(base.kind.interface.identity, name, remaining - 1)) return true;
        }
        return false;
    }

    fn setFact(_: *Analyzer, facts: *dataflow.StateBuilder, symbol: binder.SymbolId, type_id: types.TypeId) !void {
        try facts.set(.{ .symbol = symbol }, type_id);
    }
    fn removeFact(_: *Analyzer, facts: *dataflow.StateBuilder, symbol: binder.SymbolId) void {
        facts.remove(.{ .symbol = symbol });
    }
    fn invalidateDeclaration(self: *Analyzer, declaration: ast.NodeId, facts: *dataflow.StateBuilder) void {
        for (self.frontend_result.bind.symbols) |symbol| if (symbol.declaration == declaration) self.removeFact(facts, symbol.id);
    }
    fn factType(_: *Analyzer, facts: *const dataflow.StateBuilder, symbol: binder.SymbolId) ?types.TypeId {
        return facts.get(.{ .symbol = symbol });
    }
    fn currentType(self: *Analyzer, facts: *const dataflow.StateBuilder, symbol: binder.SymbolId) types.TypeId {
        return self.factType(facts, symbol) orelse self.baseType(symbol);
    }
    fn baseType(self: *Analyzer, symbol: binder.SymbolId) types.TypeId {
        for (self.symbols) |entry| if (entry.symbol_id == symbol) return entry.effective() orelse self.store.builtins.unknown;
        return self.store.builtins.unknown;
    }
    fn symbolForNode(self: *Analyzer, node: ast.NodeId) ?binder.SymbolId {
        for (self.frontend_result.resolve.references) |reference| if (reference.node == node) return reference.symbol;
        return null;
    }
    fn nodeType(self: *Analyzer, node: ast.NodeId) types.TypeId {
        for (self.nodes.items) |entry| if (entry.node_id == node) return entry.type_id;
        return self.store.builtins.unknown;
    }
    fn putNode(self: *Analyzer, value: type_info.NodeTypeInfo) !void {
        for (self.nodes.items) |*entry| if (entry.node_id == value.node_id) {
            entry.* = value;
            return;
        };
        try self.nodes.append(self.allocator, value);
    }
    fn putFlow(self: *Analyzer, value: type_info.FlowTypeInfo) !void {
        for (self.flow.items) |*entry| if (entry.function_node == value.function_node and entry.block_id == value.block_id and entry.reference_node == value.reference_node) {
            entry.* = value;
            return;
        };
        try self.flow.append(self.allocator, value);
    }
    fn literalText(self: *Analyzer, node: ast.NodeId) ?[]const u8 {
        const raw = switch (self.frontend_result.ast.node(node).data) {
            .Literal => |value| value.value,
            else => return null,
        };
        if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\'')))
            return raw[1 .. raw.len - 1];
        return raw;
    }
    fn isNull(self: *Analyzer, node: ast.NodeId) bool {
        return if (self.literalText(node)) |value| std.mem.eql(u8, value, "null") else false;
    }
    fn isUndefined(self: *Analyzer, node: ast.NodeId) bool {
        return switch (self.frontend_result.ast.node(node).data) {
            .Identifier => |value| std.mem.eql(u8, value.name, "undefined"),
            else => false,
        };
    }
    fn valid(self: *Analyzer, node: ast.NodeId) bool {
        return node != ast.invalid_node and @as(usize, @intCast(node)) < self.frontend_result.ast.nodes.len;
    }
};

pub fn analyze(allocator: std.mem.Allocator, result: frontend.FrontendResult, store: *types.TypeStore, symbols: []const type_info.SymbolTypeInfo, nodes: *std.ArrayList(type_info.NodeTypeInfo)) !Result {
    var analyzer: Analyzer = .{ .allocator = allocator, .frontend_result = result, .store = store, .symbols = symbols, .nodes = nodes };
    return analyzer.run();
}
