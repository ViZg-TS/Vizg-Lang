const std = @import("std");
const ast = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const cfg = @import("../frontend/cfg.zig");
const frontend = @import("../frontend/frontend.zig");
const tokens = @import("../frontend/tokens.zig");
const types = @import("../types/root.zig");
const dataflow = @import("dataflow.zig");
const type_info = @import("type_info.zig");
const type_inference = @import("type_inference.zig");

pub const Result = struct { flow_types: []const type_info.FlowTypeInfo };

const missing_index = std.math.maxInt(u32);

const AccessPath = struct {
    root_symbol: binder.SymbolId,
    parent: ?u32,
    property: []const u8,
    base_type: types.TypeId,
};

const Analyzer = struct {
    allocator: std.mem.Allocator,
    frontend_result: frontend.FrontendResult,
    store: *types.TypeStore,
    symbols: []const type_info.SymbolTypeInfo,
    nodes: *std.ArrayList(type_info.NodeTypeInfo),
    reference_seen: []const bool,
    reference_symbol_by_node: []const u32,
    flow_index_by_node: []u32,
    flow: std.ArrayList(type_info.FlowTypeInfo) = .empty,
    access_paths: std.ArrayList(AccessPath) = .empty,
    function_node: ast.NodeId = ast.invalid_node,
    block_id: cfg.BasicBlockId = 0,
    program_point: u32 = 0,

    fn run(self: *Analyzer) !Result {
        defer self.access_paths.deinit(self.allocator);
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
        return if (merged == self.baseTypeForKey(key)) null else merged;
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
            .Identifier => if (try self.factKeyForNode(node_id)) |key| {
                try self.recordFlowNode(node_id, key, facts);
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
                    const replacement = if (value.operator == .Equal)
                        try self.currentNodeType(value.right, facts)
                    else
                        self.nodeType(node_id);
                    try self.replaceAssignmentFact(value.left, replacement, facts);
                    if (value.operator == .Equal) {
                        var assignment_info = self.nodeInfo(node_id) orelse
                            type_info.NodeTypeInfo{ .node_id = node_id, .type_id = replacement };
                        assignment_info.type_id = replacement;
                        assignment_info.state = .resolved;
                        assignment_info.issue = .none;
                        try self.putNode(assignment_info);
                    }
                }
            },
            .UpdateExpression => |value| {
                try self.processExpr(value.argument, facts);
                if (try self.factKeyForNode(value.argument)) |key| self.removeFactAndDescendants(facts, key);
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
            .MemberExpression => |value| {
                try self.processExpr(value.object, facts);
                const object_type = try self.currentNodeType(value.object, facts);
                const inferred = try type_inference.inferPropertyAccessFromReceiver(
                    self.allocator,
                    object_type,
                    value.property,
                    value.optional,
                    self.frontend_result.ast,
                    self.store,
                );
                try self.putInferredAccess(node_id, inferred);
                if (try self.factKeyForNode(node_id)) |key| try self.recordFlowNode(node_id, key, facts);
            },
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
                const object_type = try self.currentNodeType(value.object, facts);
                const inferred = try type_inference.inferElementAccessFromReceiver(
                    self.allocator,
                    object_type,
                    value.index,
                    self.nodeType(value.index),
                    value.optional,
                    self.frontend_result.ast,
                    self.store,
                );
                try self.putInferredAccess(node_id, inferred);
                if (try self.factKeyForNode(node_id)) |key| try self.recordFlowNode(node_id, key, facts);
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
                const consequent_type = try self.currentNodeType(value.consequent, &yes);
                const alternate_type = try self.currentNodeType(value.alternate, &no);
                const result_type = if (consequent_type == alternate_type)
                    consequent_type
                else
                    try self.store.unionOf(&.{ consequent_type, alternate_type });
                var conditional_info = self.nodeInfo(node_id) orelse
                    type_info.NodeTypeInfo{ .node_id = node_id, .type_id = result_type };
                conditional_info.type_id = result_type;
                conditional_info.state = .resolved;
                conditional_info.issue = .none;
                try self.putNode(conditional_info);
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
        const key = (try self.factKeyForNode(target)) orelse return;
        self.removeFactAndDescendants(facts, key);
        if (replacement != self.store.builtins.unknown and replacement != self.store.builtins.any)
            try facts.set(key, replacement);
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
        const key = (try self.factKeyForNode(node_id)) orelse return;
        try facts.set(key, try self.filterNullish(self.currentTypeForKey(facts, key), keep_nullish));
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
        if (data == .Identifier or data == .MemberExpression or data == .ElementAccessExpression) {
            if (try self.factKeyForNode(node_id)) |key|
                try facts.set(key, try self.filterTruthiness(self.currentTypeForKey(facts, key), truthy));
            return;
        }
        if (data != .BinaryExpression) return;
        const binary = data.BinaryExpression;
        if (binary.operator == .AmpersandAmpersand and truthy) {
            try self.applyGuard(binary.left, true, facts);
            try self.applyGuard(binary.right, true, facts);
            return;
        }
        if (binary.operator == .BarBar and !truthy) {
            try self.applyGuard(binary.left, false, facts);
            try self.applyGuard(binary.right, false, facts);
            return;
        }
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
            if (try self.factKeyForNode(binary.left)) |key| try facts.set(
                key,
                try self.filterType(self.currentTypeForKey(facts, key), constructor.kind.class_constructor.instance_type, truthy),
            );
        } else if (binary.operator == .Keyword_in and truthy) {
            if (try self.factKeyForNode(binary.right)) |key| {
                if (self.literalText(binary.left)) |name|
                    try facts.set(key, try self.keepProperty(self.currentTypeForKey(facts, key), name));
            }
        }
    }

    fn applyTypeofEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, facts: *dataflow.StateBuilder) !bool {
        const left_data = self.frontend_result.ast.node(left).data;
        if (left_data != .UnaryExpression or left_data.UnaryExpression.operator != .Keyword_typeof) return false;
        const name = self.literalText(right) orelse return false;
        const key = (try self.factKeyForNode(left_data.UnaryExpression.argument)) orelse return false;
        const current = self.currentTypeForKey(facts, key);

        const wanted = if (std.mem.eql(u8, name, "string"))
            self.store.builtins.string
        else if (std.mem.eql(u8, name, "number"))
            self.store.builtins.number
        else if (std.mem.eql(u8, name, "boolean"))
            self.store.builtins.boolean
        else if (std.mem.eql(u8, name, "bigint"))
            self.store.builtins.bigint
        else if (std.mem.eql(u8, name, "symbol"))
            self.store.builtins.symbol
        else if (std.mem.eql(u8, name, "undefined"))
            self.store.builtins.undefined
        else if (std.mem.eql(u8, name, "object"))
            self.store.builtins.object
        else
            return false;

        // `typeof` gives a concrete runtime category even when the declared
        // checker type is any/unknown. Positive branches may therefore use
        // the category directly. Negative branches stay conservative until
        // the type model grows compact complements such as "not number".
        if (current == self.store.builtins.any or current == self.store.builtins.unknown) {
            if (keep)
                try facts.set(key, wanted)
            else
                self.removeExactFact(facts, key);
            return true;
        }

        // Object-category narrowing stays conservative for static unions.
        // The runtime object category also includes null and needs richer
        // complement modeling than filterType currently provides.
        if (std.mem.eql(u8, name, "object")) return true;

        try facts.set(key, try self.filterType(current, wanted, keep));
        return true;
    }

    fn applyNullishEquality(self: *Analyzer, left: ast.NodeId, right: ast.NodeId, keep: bool, loose: bool, facts: *dataflow.StateBuilder) !bool {
        const wanted = if (self.isNull(right)) self.store.builtins.null_ else if (self.isUndefined(right)) self.store.builtins.undefined else return false;
        const key = (try self.factKeyForNode(left)) orelse return false;
        const narrowed = if (loose)
            try self.filterNullish(self.currentTypeForKey(facts, key), keep)
        else
            try self.filterType(self.currentTypeForKey(facts, key), wanted, keep);
        try facts.set(key, narrowed);
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

    fn removeExactFact(_: *Analyzer, facts: *dataflow.StateBuilder, key: dataflow.FactKey) void {
        facts.remove(key);
    }

    fn removeFactAndDescendants(self: *Analyzer, facts: *dataflow.StateBuilder, key: dataflow.FactKey) void {
        var index = facts.facts.items.len;
        while (index > 0) {
            index -= 1;
            const candidate = facts.facts.items[index].key;
            if (candidate.symbol != key.symbol) continue;
            const remove = if (key.access_path == null)
                true
            else if (candidate.access_path) |candidate_path|
                candidate_path == key.access_path.? or self.accessPathDescendsFrom(candidate_path, key.access_path.?)
            else
                false;
            if (remove) _ = facts.facts.swapRemove(index);
        }
    }

    fn invalidateDeclaration(self: *Analyzer, declaration: ast.NodeId, facts: *dataflow.StateBuilder) void {
        for (self.frontend_result.bind.symbols) |symbol| if (symbol.declaration == declaration)
            self.removeFactAndDescendants(facts, .{ .symbol = symbol.id });
    }

    fn currentTypeForKey(self: *Analyzer, facts: *const dataflow.StateBuilder, key: dataflow.FactKey) types.TypeId {
        return facts.get(key) orelse self.baseTypeForKey(key);
    }

    fn baseTypeForKey(self: *Analyzer, key: dataflow.FactKey) types.TypeId {
        if (key.access_path) |path_id| {
            if (@as(usize, @intCast(path_id)) < self.access_paths.items.len)
                return self.access_paths.items[@intCast(path_id)].base_type;
            return self.store.builtins.unknown;
        }
        return self.baseType(key.symbol);
    }

    fn baseType(self: *Analyzer, symbol: binder.SymbolId) types.TypeId {
        const symbol_index: usize = @intCast(symbol);
        if (symbol_index < self.symbols.len and self.symbols[symbol_index].symbol_id == symbol)
            return self.symbols[symbol_index].effective() orelse self.store.builtins.unknown;
        for (self.symbols) |entry| if (entry.symbol_id == symbol) return entry.effective() orelse self.store.builtins.unknown;
        return self.store.builtins.unknown;
    }

    fn symbolForNode(self: *Analyzer, node: ast.NodeId) ?binder.SymbolId {
        const node_index: usize = @intCast(node);
        if (node_index >= self.reference_seen.len or !self.reference_seen[node_index]) return null;
        const symbol = self.reference_symbol_by_node[node_index];
        return if (symbol == missing_index) null else symbol;
    }

    fn factKeyForNode(self: *Analyzer, node: ast.NodeId) !?dataflow.FactKey {
        if (!self.valid(node)) return null;
        return switch (self.frontend_result.ast.node(node).data) {
            .Identifier => if (self.symbolForNode(node)) |symbol| .{ .symbol = symbol } else null,
            .MemberExpression => |member| blk: {
                const parent = (try self.factKeyForNode(member.object)) orelse break :blk null;
                break :blk try self.internAccessPath(parent, member.property, node);
            },
            .ElementAccessExpression => |element| blk: {
                const property = self.literalText(element.index) orelse break :blk null;
                const parent = (try self.factKeyForNode(element.object)) orelse break :blk null;
                break :blk try self.internAccessPath(parent, property, node);
            },
            else => null,
        };
    }

    fn internAccessPath(
        self: *Analyzer,
        parent: dataflow.FactKey,
        property: []const u8,
        representative: ast.NodeId,
    ) !dataflow.FactKey {
        for (self.access_paths.items, 0..) |path, index| {
            if (path.root_symbol != parent.symbol or path.parent != parent.access_path) continue;
            if (!std.mem.eql(u8, path.property, property)) continue;
            return .{ .symbol = parent.symbol, .access_path = @intCast(index) };
        }
        const base_type = self.nodeType(representative);
        try self.access_paths.append(self.allocator, .{
            .root_symbol = parent.symbol,
            .parent = parent.access_path,
            .property = property,
            .base_type = base_type,
        });
        return .{ .symbol = parent.symbol, .access_path = @intCast(self.access_paths.items.len - 1) };
    }

    fn accessPathDescendsFrom(self: *Analyzer, candidate: u32, ancestor: u32) bool {
        var current: ?u32 = candidate;
        while (current) |path_id| {
            if (path_id == ancestor) return true;
            if (@as(usize, @intCast(path_id)) >= self.access_paths.items.len) return false;
            current = self.access_paths.items[@intCast(path_id)].parent;
        }
        return false;
    }

    fn currentNodeType(
        self: *Analyzer,
        node_id: ast.NodeId,
        facts: *const dataflow.StateBuilder,
    ) !types.TypeId {
        if (try self.factKeyForNode(node_id)) |key| return self.currentTypeForKey(facts, key);
        return self.nodeType(node_id);
    }

    fn putInferredAccess(
        self: *Analyzer,
        node_id: ast.NodeId,
        inferred: type_inference.OperatorResult,
    ) !void {
        var node_info = type_info.NodeTypeInfo{
            .node_id = node_id,
            .type_id = inferred.type_id,
            .state = if (inferred.valid) .resolved else .@"error",
            .issue = inferred.issue,
            .receiver_type = inferred.receiver_type,
        };
        if (self.nodeInfo(node_id)) |entry| node_info.contextual_type = entry.contextual_type;
        try self.putNode(node_info);
    }

    fn recordFlowNode(
        self: *Analyzer,
        node_id: ast.NodeId,
        key: dataflow.FactKey,
        facts: *const dataflow.StateBuilder,
    ) !void {
        const base = self.baseTypeForKey(key);
        const active_fact = facts.get(key);
        const narrowed = active_fact orelse base;
        const node_type = if ((base == self.store.builtins.any or base == self.store.builtins.unknown) and
            narrowed == self.store.builtins.object)
            base
        else
            narrowed;
        var node_info = self.nodeInfo(node_id) orelse
            type_info.NodeTypeInfo{ .node_id = node_id, .type_id = node_type };
        node_info.type_id = node_type;
        try self.putNode(node_info);
        try self.putFlow(.{
            .function_node = self.function_node,
            .block_id = self.block_id,
            .program_point = self.program_point,
            .symbol_id = key.symbol,
            .reference_node = node_id,
            .type_id = narrowed,
            .narrowed = active_fact != null,
        });
        self.program_point += 1;
    }

    fn nodeLowerBound(self: *Analyzer, node: ast.NodeId) usize {
        var low: usize = 0;
        var high: usize = self.nodes.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.nodes.items[mid].node_id < node)
                low = mid + 1
            else
                high = mid;
        }
        return low;
    }

    fn nodeInfo(self: *Analyzer, node: ast.NodeId) ?type_info.NodeTypeInfo {
        const index = self.nodeLowerBound(node);
        if (index < self.nodes.items.len and self.nodes.items[index].node_id == node)
            return self.nodes.items[index];
        return null;
    }

    fn nodeType(self: *Analyzer, node: ast.NodeId) types.TypeId {
        return if (self.nodeInfo(node)) |entry| entry.type_id else self.store.builtins.unknown;
    }

    fn putNode(self: *Analyzer, value: type_info.NodeTypeInfo) !void {
        const index = self.nodeLowerBound(value.node_id);
        if (index < self.nodes.items.len and self.nodes.items[index].node_id == value.node_id) {
            self.nodes.items[index] = value;
            return;
        }
        try self.nodes.insert(self.allocator, index, value);
    }
    fn putFlow(self: *Analyzer, value: type_info.FlowTypeInfo) !void {
        const node_index: usize = @intCast(value.reference_node);
        if (node_index < self.flow_index_by_node.len) {
            const mapped = self.flow_index_by_node[node_index];
            if (mapped != missing_index and @as(usize, mapped) < self.flow.items.len) {
                const entry = &self.flow.items[@intCast(mapped)];
                if (entry.function_node == value.function_node and
                    entry.block_id == value.block_id and
                    entry.reference_node == value.reference_node)
                {
                    entry.* = value;
                    return;
                }
            }
        }

        for (self.flow.items, 0..) |*entry, index| {
            if (entry.function_node != value.function_node or
                entry.block_id != value.block_id or
                entry.reference_node != value.reference_node) continue;
            entry.* = value;
            if (node_index < self.flow_index_by_node.len)
                self.flow_index_by_node[node_index] = std.math.cast(u32, index) orelse missing_index;
            return;
        }

        try self.flow.append(self.allocator, value);
        if (node_index < self.flow_index_by_node.len and self.flow_index_by_node[node_index] == missing_index)
            self.flow_index_by_node[node_index] = std.math.cast(u32, self.flow.items.len - 1) orelse missing_index;
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
    const reference_seen = try allocator.alloc(bool, result.ast.nodes.len);
    defer allocator.free(reference_seen);
    @memset(reference_seen, false);
    const reference_symbol_by_node = try allocator.alloc(u32, result.ast.nodes.len);
    defer allocator.free(reference_symbol_by_node);
    @memset(reference_symbol_by_node, missing_index);
    for (result.resolve.references) |reference| {
        const node_index: usize = @intCast(reference.node);
        if (node_index >= reference_seen.len or reference_seen[node_index]) continue;
        reference_seen[node_index] = true;
        if (reference.symbol) |symbol| reference_symbol_by_node[node_index] = symbol;
    }

    const flow_index_by_node = try allocator.alloc(u32, result.ast.nodes.len);
    defer allocator.free(flow_index_by_node);
    @memset(flow_index_by_node, missing_index);

    var analyzer: Analyzer = .{
        .allocator = allocator,
        .frontend_result = result,
        .store = store,
        .symbols = symbols,
        .nodes = nodes,
        .reference_seen = reference_seen,
        .reference_symbol_by_node = reference_symbol_by_node,
        .flow_index_by_node = flow_index_by_node,
    };
    return analyzer.run();
}
