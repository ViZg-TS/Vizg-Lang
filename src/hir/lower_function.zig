//! Canonical lowering for every function-like syntax form.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const anf_builder = @import("anf_builder.zig");
const binder = @import("../frontend/binder.zig");
const builder_mod = @import("builder.zig");
const ids = @import("ids.zig");
const lower_assignment = @import("lower_assignment.zig");
const lower_expression = @import("lower_expression.zig");
const lower_control = @import("lower_control.zig");
const lower_exceptions = @import("lower_exceptions.zig");
const lower_place = @import("lower_place.zig");
const model = @import("model.zig");
const project = @import("../project/root.zig");
const region_validation = @import("region_validation.zig");
const semantics = @import("../semantics/root.zig");

pub const SymbolBinding = struct {
    symbol: binder.SymbolId,
    binding: ids.BindingId,
};

pub const Inputs = struct {
    builder: *builder_mod.Builder,
    module: *const project.ProjectModule,
    local: *const semantics.SemanticResult,
    project_module: *const semantics.ProjectSemanticModule,
    entity_ids: ?*std.ArrayList(ids.EntityId) = null,
};

pub fn lowerClassValue(
    context: anytype,
    inputs: Inputs,
    node_id: ast.NodeId,
    super_class: ?ast.NodeId,
    members: []const ast.NodeId,
    outer: []const SymbolBinding,
) !ids.ValueId {
    const derived = super_class != null;
    var constructor: ?ids.FunctionId = null;
    var methods: std.ArrayList(model.HirMethod) = .empty;
    for (members) |member_id| switch (inputs.local.frontend.ast.node(member_id).data) {
        .ClassMethod => |method| {
            const kind: model.HirFunctionKind = switch (method.kind) {
                .method => .method,
                .constructor => .constructor,
                .getter => .getter,
                .setter => .setter,
            };
            const function = if (kind == .constructor)
                try createClassConstructor(inputs, member_id, derived, outer)
            else
                try create(inputs, member_id, kind, outer);
            if (kind == .constructor) {
                if (constructor != null) return error.DuplicateClassConstructor;
                constructor = function;
            } else try methods.append(inputs.builder.allocator, .{
                .name = .{ .static = try inputs.builder.copyString(method.name) },
                .function = function,
                .is_static = method.is_static,
            });
        },
        .ClassField => {},
        else => return error.InvalidClassMember,
    };
    const constructor_id = constructor orelse try createDefaultClassConstructor(inputs, node_id, derived);
    const instance_initializer = try createFieldInitializer(inputs, node_id, members, false, outer);
    const static_initializer = try createFieldInitializer(inputs, node_id, members, true, outer);
    const entity = try inputs.builder.makeId(ids.EntityId, inputs.builder.entities.items.len);
    try inputs.builder.appendEntity(.{
        .id = entity,
        .module_id = inputs.module.id,
        .declaration = declarationId(inputs.module.id, node_id),
        .origin = .invalid,
        .kind = .{ .class = .{
            .constructor = constructor_id,
            .instance_initializer = instance_initializer,
            .static_initializer = static_initializer,
            .methods = try methods.toOwnedSlice(inputs.builder.allocator),
        } },
    });
    if (inputs.entity_ids) |sink| try sink.append(inputs.builder.allocator, entity);
    const base = if (super_class) |expression| try context.lowerExpression(expression) else null;
    return context.emitValue(.{ .create_class = .{ .entity = entity, .base = base } }, context.nodeType(node_id));
}

pub const EnumValue = struct {
    entity: ids.EntityId,
    value: ids.ValueId,
};

pub fn lowerEnumValue(
    context: anytype,
    inputs: Inputs,
    node_id: ast.NodeId,
    binding: ids.BindingId,
    members: []const ast.NodeId,
) !EnumValue {
    const entity = try inputs.builder.makeId(ids.EntityId, inputs.builder.entities.items.len);
    try inputs.builder.appendEntity(.{
        .id = entity,
        .module_id = inputs.module.id,
        .declaration = declarationId(inputs.module.id, node_id),
        .origin = .invalid,
        .kind = .{ .enum_object = .{ .binding = binding } },
    });
    if (inputs.entity_ids) |sink| try sink.append(inputs.builder.allocator, entity);
    const object = try context.emitValue(.{ .create_enum_object = entity }, context.nodeType(node_id));

    var next_numeric: f64 = 0;
    for (members) |member_id| {
        const member = inputs.local.frontend.ast.node(member_id).data.EnumMember;
        const key: model.PropertyKey = if (member.computed_name) |computed|
            .{ .computed = try context.lowerExpression(computed) }
        else
            .{ .static = try inputs.builder.copyString(member.name) };
        const string_member = if (member.initializer) |initializer| literalIsString(inputs.local, initializer) else false;
        const value = if (member.initializer) |initializer| blk: {
            const lowered = try context.lowerExpression(initializer);
            if (!string_member) {
                if (literalNumber(inputs.builder.allocator, inputs.local, initializer)) |number| next_numeric = number + 1;
            }
            break :blk lowered;
        } else blk: {
            const lowered = try context.emitValue(.{ .constant = .{ .number = next_numeric } }, inputs.builder.result.semanticResult().type_store.builtins.number);
            next_numeric += 1;
            break :blk lowered;
        };
        try context.emitVoid(.{ .define_property = .{ .object = object, .key = key, .value = value } });
        if (!string_member) {
            const name = try context.emitValue(.{ .constant = .{ .string = try inputs.builder.copyString(member.name) } }, inputs.builder.result.semanticResult().type_store.builtins.string);
            try context.emitVoid(.{ .define_property = .{ .object = object, .key = .{ .computed = value }, .value = name } });
        }
    }
    return .{ .entity = entity, .value = object };
}

const PendingFunction = struct {
    node: ast.NodeId,
    binding: ids.BindingId,
    function: ids.FunctionId,
    type_id: model.TypeId,
};

const FunctionSpec = struct {
    params: []const ast.NodeId,
    body: ast.NodeId,
    expression_body: bool,
    arrow: bool,
    flags: ast.FunctionFlags,
};

pub fn reserve(inputs: Inputs, node_id: ast.NodeId, kind: model.HirFunctionKind) !ids.FunctionId {
    const function_id = try inputs.builder.makeId(ids.FunctionId, inputs.builder.functions.items.len);
    try inputs.builder.reserveFunction(0);
    try inputs.builder.appendFunction(.{
        .id = function_id,
        .module_id = inputs.module.id,
        .symbol = declarationId(inputs.module.id, node_id),
        .kind = kind,
        .flags = .{},
        .signature_type = resolvedNodeType(inputs, node_id),
        .entry = .invalid,
        .origin = .invalid,
    });
    return function_id;
}

pub fn create(inputs: Inputs, node_id: ast.NodeId, kind: model.HirFunctionKind, outer: []const SymbolBinding) !ids.FunctionId {
    const function_id = try reserve(inputs, node_id, kind);
    try lowerReserved(inputs, function_id, node_id, kind, outer);
    return function_id;
}

pub fn createClassConstructor(inputs: Inputs, node_id: ast.NodeId, derived: bool, outer: []const SymbolBinding) !ids.FunctionId {
    const function_id = try reserve(inputs, node_id, .constructor);
    try lowerReservedInternal(inputs, function_id, node_id, .constructor, outer, derived);
    return function_id;
}

pub fn createDefaultClassConstructor(inputs: Inputs, owner: ast.NodeId, derived: bool) !ids.FunctionId {
    const function_id = try inputs.builder.makeId(ids.FunctionId, inputs.builder.functions.items.len);
    try inputs.builder.reserveFunction(0);
    var anf = try anf_builder.AnfBuilder.init(inputs.builder);
    if (derived) {
        const arguments = try anf.emitValue(.create_arguments_object, inputs.builder.result.semanticResult().type_store.builtins.unknown);
        const call_arguments = try inputs.builder.allocator.alloc(model.CallArgument, 1);
        call_arguments[0] = .{ .spread = arguments };
        _ = try anf.emitValue(.{ .call_super_constructor = call_arguments }, inputs.builder.result.semanticResult().type_store.builtins.unknown);
    }
    try anf.terminate(.{ .return_ = null });
    try inputs.builder.appendFunction(.{
        .id = function_id,
        .module_id = inputs.module.id,
        .symbol = declarationId(inputs.module.id, owner),
        .kind = .constructor,
        .flags = .{ .dynamic_this = true, .constructor = true, .uses_super = derived },
        .signature_type = inputs.builder.result.semanticResult().type_store.builtins.unknown,
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = anf.entry,
        .origin = .invalid,
    });
    return function_id;
}

pub fn createFieldInitializer(
    inputs: Inputs,
    owner: ast.NodeId,
    members: []const ast.NodeId,
    static_fields: bool,
    outer: []const SymbolBinding,
) !?ids.FunctionId {
    var count: usize = 0;
    for (members) |member_id| switch (inputs.local.frontend.ast.node(member_id).data) {
        .ClassField => |field| if (field.is_static == static_fields) {
            count += 1;
        },
        else => {},
    };
    if (count == 0) return null;

    const function_id = try inputs.builder.makeId(ids.FunctionId, inputs.builder.functions.items.len);
    try inputs.builder.reserveFunction(0);
    var anf = try anf_builder.AnfBuilder.init(inputs.builder);
    var context: Context = .{
        .inputs = inputs,
        .builder = inputs.builder,
        .local = inputs.local,
        .anf = &anf,
        .function_id = function_id,
        .function_scope = nodeScope(inputs.local, owner) orelse return error.MissingClassScope,
        .is_arrow = false,
        .is_async = false,
        .is_generator = false,
    };
    try context.visible.appendSlice(inputs.builder.allocator, outer);
    const receiver = try context.emitValue(.load_this, inputs.builder.result.semanticResult().type_store.builtins.unknown);
    for (members) |member_id| switch (inputs.local.frontend.ast.node(member_id).data) {
        .ClassField => |field| if (field.is_static == static_fields) {
            if (field.type_annotation) |annotation| context.eraseTypeNode(annotation.root);
            const value = if (field.initializer) |initializer|
                try context.lowerExpression(initializer)
            else
                try context.emitValue(.{ .constant = .undefined }, inputs.builder.result.semanticResult().type_store.builtins.undefined);
            try context.emitVoid(.{ .define_property = .{
                .object = receiver,
                .key = .{ .static = try inputs.builder.copyString(field.name) },
                .value = value,
            } });
        },
        else => {},
    };
    try anf.terminate(.{ .return_ = null });
    const function: model.HirFunction = .{
        .id = function_id,
        .module_id = inputs.module.id,
        .symbol = declarationId(inputs.module.id, owner),
        .kind = .method,
        .flags = .{ .dynamic_this = true },
        .signature_type = inputs.builder.result.semanticResult().type_store.builtins.unknown,
        .bindings = try context.bindings.toOwnedSlice(inputs.builder.allocator),
        .captures = try context.captures.toOwnedSlice(inputs.builder.allocator),
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = anf.entry,
        .origin = .invalid,
    };
    try region_validation.validateFunction(inputs.builder.allocator, &function, inputs.builder.regions.items);
    try inputs.builder.appendFunction(function);
    return function_id;
}

pub fn lowerReserved(inputs: Inputs, function_id: ids.FunctionId, node_id: ast.NodeId, kind: model.HirFunctionKind, outer: []const SymbolBinding) anyerror!void {
    return lowerReservedInternal(inputs, function_id, node_id, kind, outer, false);
}

fn lowerReservedInternal(inputs: Inputs, function_id: ids.FunctionId, node_id: ast.NodeId, kind: model.HirFunctionKind, outer: []const SymbolBinding, derived_constructor: bool) anyerror!void {
    const spec = try functionSpec(inputs.local, node_id);
    const function_scope = nodeScope(inputs.local, spec.body) orelse return error.MissingFunctionScope;
    var anf = try anf_builder.AnfBuilder.init(inputs.builder);
    var context: Context = .{
        .inputs = inputs,
        .builder = inputs.builder,
        .local = inputs.local,
        .anf = &anf,
        .function_id = function_id,
        .function_scope = function_scope,
        .is_arrow = spec.arrow,
        .is_async = spec.flags.is_async,
        .is_generator = spec.flags.is_generator,
        .is_constructor = kind == .constructor,
        .derived_constructor = derived_constructor,
    };
    try context.visible.appendSlice(inputs.builder.allocator, outer);
    try context.predeclareParameters(spec.params, kind == .constructor);
    try context.predeclare(spec.body);
    try context.lowerPendingFunctions();
    try context.lowerParameters(spec.params);
    if (kind == .constructor and !derived_constructor) try context.emitParameterProperties();
    try context.emitHoists();
    if (spec.expression_body) {
        const value = try context.lowerExpression(spec.body);
        try anf.terminate(.{ .return_ = value });
    } else {
        try context.lowerStatement(spec.body);
        if (!anf.currentTerminated()) try anf.terminate(.{ .return_ = null });
    }

    var flags: model.HirFunctionFlags = .{
        .lexical_this = spec.arrow,
        .dynamic_this = !spec.arrow,
        .constructor = kind == .constructor,
        .getter = kind == .getter,
        .setter = kind == .setter,
        .async_ = spec.flags.is_async,
        .generator = spec.flags.is_generator and !spec.flags.is_async,
        .async_generator = spec.flags.is_generator and spec.flags.is_async,
        .uses_super = context.uses_super,
        .uses_new_target = context.uses_new_target,
    };
    if (spec.arrow) flags.dynamic_this = false;
    const function: model.HirFunction = .{
        .id = function_id,
        .module_id = inputs.module.id,
        .symbol = declarationId(inputs.module.id, node_id),
        .kind = kind,
        .flags = flags,
        .signature_type = resolvedNodeType(inputs, node_id),
        .parameters = try context.parameters.toOwnedSlice(inputs.builder.allocator),
        .bindings = try context.bindings.toOwnedSlice(inputs.builder.allocator),
        .captures = try context.captures.toOwnedSlice(inputs.builder.allocator),
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = anf.entry,
        .regions = try context.regions.toOwnedSlice(inputs.builder.allocator),
        .origin = .invalid,
    };
    try region_validation.validateFunction(inputs.builder.allocator, &function, inputs.builder.regions.items);
    try inputs.builder.replaceFunction(function);
}

const Context = struct {
    inputs: Inputs,
    builder: *builder_mod.Builder,
    local: *const semantics.SemanticResult,
    anf: *anf_builder.AnfBuilder,
    function_id: ids.FunctionId,
    function_scope: binder.ScopeId,
    is_arrow: bool,
    is_async: bool,
    is_generator: bool,
    bindings: std.ArrayList(model.HirBinding) = .empty,
    parameters: std.ArrayList(model.HirParameter) = .empty,
    captures: std.ArrayList(model.HirCapture) = .empty,
    visible: std.ArrayList(SymbolBinding) = .empty,
    pending: std.ArrayList(PendingFunction) = .empty,
    regions: std.ArrayList(ids.RegionId) = .empty,
    cleanups: std.ArrayList(lower_control.CleanupFrame) = .empty,
    controls: std.ArrayList(lower_control.ControlTarget) = .empty,
    labels: std.ArrayList(lower_control.LabelFrame) = .empty,
    catch_cleanup_depths: std.ArrayList(usize) = .empty,
    uses_super: bool = false,
    uses_new_target: bool = false,
    is_constructor: bool = false,
    derived_constructor: bool = false,
    parameter_properties_emitted: bool = false,

    pub fn lowerClassExpression(self: *Context, node_id: ast.NodeId) !ids.ValueId {
        const declaration = self.inputs.local.frontend.ast.node(node_id).data.ClassExpression;
        var local_binding: ?ids.BindingId = null;
        if (declaration.name) |name| {
            if (self.symbolForDeclaration(node_id)) |symbol|
                local_binding = try self.addBinding(symbol, name, .class, false, .temporal_dead_zone, node_id);
        }
        const value = try lowerClassValue(self, self.inputs, node_id, declaration.super_class, declaration.members, self.visible.items);
        if (local_binding) |binding| try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
        return value;
    }

    fn predeclareParameters(self: *Context, params: []const ast.NodeId, constructor: bool) !void {
        for (params) |param_id| {
            const param = self.inputs.local.frontend.ast.node(param_id).data.Parameter;
            if (param.type_annotation) |annotation| self.eraseTypeNode(annotation.root);
            const symbol = self.parameterSymbol(param_id) orelse return error.MissingSemanticIdentity;
            const binding = try self.addBinding(symbol, param.name, .parameter, true, .initialized, param_id);
            try self.parameters.append(self.inputs.builder.allocator, .{
                .binding = binding,
                .type_id = self.symbolType(symbol),
                .argument_index = @intCast(self.parameters.items.len),
                .optional = false,
                .has_default = param.initializer != null,
                .rest = param.rest,
                .parameter_property = constructor and (param.access != .none or param.readonly),
                .origin = .invalid,
            });
        }
    }

    fn predeclare(self: *Context, node_id: ast.NodeId) !void {
        const node = self.inputs.local.frontend.ast.node(node_id);
        switch (node.data) {
            .BlockStatement => |block| for (block.statements) |statement| try self.predeclare(statement),
            .IfStatement => |statement| {
                try self.predeclare(statement.consequent);
                if (statement.alternate) |alternate| try self.predeclare(alternate);
            },
            .WhileStatement => |statement| try self.predeclare(statement.body),
            .DoWhileStatement => |statement| try self.predeclare(statement.body),
            .ForStatement => |statement| {
                if (statement.init) |initializer| try self.predeclare(initializer);
                try self.predeclare(statement.body);
            },
            .SwitchStatement => |statement| for (statement.cases) |case_id| try self.predeclare(case_id),
            .SwitchCase => |case| for (case.consequent) |statement| try self.predeclare(statement),
            .LabeledStatement => |statement| try self.predeclare(statement.body),
            .TryStatement => |statement| {
                try self.predeclare(statement.block);
                if (statement.handler) |handler| try self.predeclare(handler);
                if (statement.finalizer) |finalizer| try self.predeclare(finalizer);
            },
            .CatchClause => |clause| {
                if (clause.parameter) |parameter_id| {
                    const parameter = self.inputs.local.frontend.ast.node(parameter_id).data.Parameter;
                    const symbol = self.symbolForDeclaration(parameter_id) orelse return error.MissingSemanticIdentity;
                    _ = try self.addBinding(symbol, parameter.name, .catch_, true, .temporal_dead_zone, parameter_id);
                }
                try self.predeclare(clause.body);
            },
            .FinallyClause => |clause| try self.predeclare(clause.body),
            .VariableDeclaration => |declaration| for (declaration.declarations) |declarator_id| {
                const declarator = self.inputs.local.frontend.ast.node(declarator_id).data.VariableDeclarator;
                if (declarator.type_annotation) |annotation| self.eraseTypeNode(annotation.root);
                const symbol = self.symbolForDeclaration(declarator_id) orelse return error.MissingSemanticIdentity;
                const kind: model.HirBindingKind = switch (declaration.kind) {
                    .Keyword_var => .var_,
                    .Keyword_let => .let_,
                    .Keyword_const => .const_,
                    else => return error.InvalidVariableKind,
                };
                _ = try self.addBinding(symbol, declarator.name, kind, kind != .const_, if (kind == .var_) .hoisted_undefined else .temporal_dead_zone, declarator_id);
            },
            .FunctionDeclaration => |function| {
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const binding = try self.addBinding(symbol, function.name, .function, true, .hoisted_function, node_id);
                const child = try reserve(self.inputs, node_id, .ordinary);
                try self.pending.append(self.inputs.builder.allocator, .{ .node = node_id, .binding = binding, .function = child, .type_id = self.symbolType(symbol) });
            },
            .ClassDeclaration => |declaration| {
                for (declaration.type_parameters) |parameter| {
                    if (parameter.constraint) |annotation| self.eraseTypeNode(annotation.root);
                    if (parameter.default_type) |annotation| self.eraseTypeNode(annotation.root);
                }
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                _ = try self.addBinding(symbol, declaration.name, .class, false, .temporal_dead_zone, node_id);
            },
            .EnumDeclaration => |declaration| {
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                _ = try self.addBinding(symbol, declaration.name, .enum_, true, .temporal_dead_zone, node_id);
            },
            else => {},
        }
    }

    fn lowerPendingFunctions(self: *Context) anyerror!void {
        for (self.pending.items) |pending| try lowerReserved(self.inputs, pending.function, pending.node, .ordinary, self.visible.items);
    }

    fn lowerParameters(self: *Context, params: []const ast.NodeId) !void {
        const undefined_type = self.inputs.builder.result.semanticResult().type_store.builtins.undefined;
        for (params, self.parameters.items) |param_id, plan| {
            const param = self.inputs.local.frontend.ast.node(param_id).data.Parameter;
            const value = if (param.rest)
                try self.emitValue(.{ .collect_rest_arguments = plan.argument_index }, plan.type_id)
            else if (param.initializer) |initializer| blk: {
                const argument = try self.emitValue(.{ .read_argument = plan.argument_index }, plan.type_id);
                const undefined_value = try self.emitValue(.{ .constant = .undefined }, undefined_type);
                const missing = try self.emitValue(.{ .binary = .{ .operator = .equal_strict, .left = argument, .right = undefined_value, .mode = .dynamic } }, self.booleanType());
                const default_block = try self.anf.createBlock();
                const present_block = try self.anf.createBlock();
                const merge_block = try self.anf.createBlock();
                const merged = try self.anf.addParameter(merge_block, plan.type_id);
                try self.anf.terminate(.{ .branch = .{ .condition = missing, .true_target = default_block, .false_target = present_block } });
                try self.anf.beginBlock(default_block);
                const default_value = try self.lowerExpression(initializer);
                const typed_default = try self.emitValue(.{ .copy = default_value }, plan.type_id);
                try self.jumpOne(merge_block, typed_default);
                try self.anf.beginBlock(present_block);
                const typed_argument = try self.emitValue(.{ .copy = argument }, plan.type_id);
                try self.jumpOne(merge_block, typed_argument);
                try self.anf.beginBlock(merge_block);
                break :blk merged;
            } else try self.emitValue(.{ .read_argument = plan.argument_index }, plan.type_id);
            try self.emitVoid(.{ .initialize_binding = .{ .binding = plan.binding, .value = value } });
        }
    }

    fn emitHoists(self: *Context) !void {
        for (self.pending.items) |pending| {
            const closure = try self.emitValue(.{ .create_closure = pending.function }, pending.type_id);
            try self.emitVoid(.{ .initialize_binding = .{ .binding = pending.binding, .value = closure } });
        }
    }

    fn emitParameterProperties(self: *Context) !void {
        if (self.parameter_properties_emitted) return;
        self.parameter_properties_emitted = true;
        var has_property = false;
        for (self.parameters.items) |parameter| if (parameter.parameter_property) {
            has_property = true;
        };
        if (!has_property) return;
        const receiver = try self.emitValue(.load_this, self.inputs.builder.result.semanticResult().type_store.builtins.unknown);
        for (self.parameters.items) |parameter| {
            if (!parameter.parameter_property) continue;
            const value = try self.emitValue(.{ .load_binding = parameter.binding }, parameter.type_id);
            const binding = self.bindingRecord(parameter.binding) orelse return error.MissingParameterBinding;
            try self.emitVoid(.{ .define_property = .{
                .object = receiver,
                .key = .{ .static = binding.name },
                .value = value,
            } });
        }
    }

    pub fn afterSuperConstructor(self: *Context) !void {
        if (self.is_constructor and self.derived_constructor) try self.emitParameterProperties();
    }

    fn bindingRecord(self: *const Context, binding: ids.BindingId) ?model.HirBinding {
        for (self.bindings.items) |item| if (item.id.eql(binding)) return item;
        return null;
    }

    pub fn lowerStatement(self: *Context, node_id: ast.NodeId) anyerror!void {
        const node = self.inputs.local.frontend.ast.node(node_id);
        switch (node.data) {
            .BlockStatement => |block| for (block.statements) |statement| {
                if (self.anf.currentTerminated()) break;
                try self.lowerStatement(statement);
            },
            .ExpressionStatement => |statement| _ = try self.lowerExpression(statement.expression),
            .IfStatement => |statement| try lower_control.lowerIf(self, statement),
            .WhileStatement => |statement| try lower_control.lowerWhile(self, statement),
            .DoWhileStatement => |statement| try lower_control.lowerDoWhile(self, statement),
            .ForStatement => |statement| try lower_control.lowerFor(self, statement),
            .SwitchStatement => |statement| try lower_control.lowerSwitch(self, statement),
            .LabeledStatement => |statement| try lower_control.lowerLabeled(self, statement),
            .BreakStatement => |statement| try lower_control.lowerBreak(self, statement),
            .ContinueStatement => |statement| try lower_control.lowerContinue(self, statement),
            .TryStatement => |statement| try lower_exceptions.lowerTry(self, statement),
            .ThrowStatement => |statement| try lower_exceptions.lowerThrow(self, statement),
            .ReturnStatement => |statement| {
                const value = if (statement.argument) |argument| try self.lowerExpression(argument) else null;
                if (self.cleanups.items.len == 0)
                    try self.anf.terminate(.{ .return_ = value })
                else {
                    const cleanup = self.cleanups.items[self.cleanups.items.len - 1];
                    try self.anf.terminate(.{ .leave_region = .{ .region = cleanup.region, .completion = .{ .return_ = value }, .cleanup = cleanup.cleanup } });
                }
            },
            .FunctionDeclaration, .TypeAliasDeclaration, .InterfaceDeclaration => {},
            .ClassDeclaration => |declaration| {
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const binding = self.mappedBinding(symbol) orelse return error.MissingHirBinding;
                const value = try lowerClassValue(self, self.inputs, node_id, declaration.super_class, declaration.members, self.visible.items);
                try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
            },
            .EnumDeclaration => |declaration| {
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const binding = self.mappedBinding(symbol) orelse return error.MissingHirBinding;
                const lowered = try lowerEnumValue(self, self.inputs, node_id, binding, declaration.members);
                try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = lowered.value } });
            },
            .VariableDeclaration => |declaration| for (declaration.declarations) |declarator_id| {
                const declarator = self.inputs.local.frontend.ast.node(declarator_id).data.VariableDeclarator;
                const symbol = self.symbolForDeclaration(declarator_id) orelse return error.MissingSemanticIdentity;
                const binding = self.mappedBinding(symbol) orelse return error.MissingHirBinding;
                if (declarator.init) |initializer| {
                    const value = try self.lowerExpression(initializer);
                    if (declaration.kind == .Keyword_var)
                        try self.emitVoid(.{ .store_binding = .{ .binding = binding, .value = value } })
                    else
                        try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
                } else if (declaration.kind != .Keyword_var) {
                    const value = try self.emitValue(.{ .constant = .undefined }, self.inputs.builder.result.semanticResult().type_store.builtins.undefined);
                    try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
                }
            },
            else => return error.UnsupportedHirStatement,
        }
    }

    pub fn lowerExpression(self: *Context, node_id: ast.NodeId) !ids.ValueId {
        return lower_expression.lower(self, node_id);
    }

    pub fn astNode(self: *Context, node_id: ast.NodeId) ast.Node {
        return self.inputs.local.frontend.ast.node(node_id);
    }

    pub fn labelBodyIsIteration(self: *Context, node_id: ast.NodeId) bool {
        return switch (self.astNode(node_id).data) {
            .WhileStatement, .DoWhileStatement, .ForStatement => true,
            .LabeledStatement => |statement| self.labelBodyIsIteration(statement.body),
            else => false,
        };
    }

    pub fn lowerForInitializer(self: *Context, node_id: ast.NodeId) !void {
        if (self.inputs.local.frontend.ast.node(node_id).data == .VariableDeclaration)
            try self.lowerStatement(node_id)
        else
            _ = try self.lowerExpression(node_id);
    }

    pub fn assignIterationTarget(self: *Context, node_id: ast.NodeId, value: ids.ValueId) !void {
        switch (self.inputs.local.frontend.ast.node(node_id).data) {
            .VariableDeclaration => |declaration| {
                if (declaration.declarations.len != 1) return error.InvalidForStatement;
                const symbol = self.symbolForDeclaration(declaration.declarations[0]) orelse return error.MissingSemanticIdentity;
                const binding = self.mappedBinding(symbol) orelse return error.MissingHirBinding;
                if (declaration.kind == .Keyword_var)
                    try self.emitVoid(.{ .store_binding = .{ .binding = binding, .value = value } })
                else
                    try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
            },
            else => try self.emitVoid(.{ .store_place = .{ .place = try self.lowerPlace(node_id), .value = value } }),
        }
    }

    pub fn unknownType(self: *const Context) model.TypeId {
        return self.inputs.builder.result.semanticResult().type_store.builtins.unknown;
    }

    pub fn catchBinding(self: *const Context, parameter: ast.NodeId) !ids.BindingId {
        const symbol = self.symbolForDeclaration(parameter) orelse return error.MissingSemanticIdentity;
        return self.mappedBinding(symbol) orelse error.MissingHirBinding;
    }

    pub fn lowerFunctionExpression(self: *Context, node_id: ast.NodeId, kind: model.HirFunctionKind) !ids.ValueId {
        const function = try create(self.inputs, node_id, kind, self.visible.items);
        return self.emitValue(.{ .create_closure = function }, self.nodeType(node_id));
    }

    pub fn lowerThis(self: *Context, node_id: ast.NodeId) !ids.ValueId {
        if (!self.is_arrow) return self.emitValue(.load_this, self.nodeType(node_id));
        return self.emitValue(.{ .load_binding = try self.specialCapture(.this, "<this>") }, self.nodeType(node_id));
    }

    pub fn lowerSuper(self: *Context, node_id: ast.NodeId) !ids.ValueId {
        self.uses_super = true;
        if (!self.is_arrow) return self.emitValue(.load_super, self.nodeType(node_id));
        return self.emitValue(.{ .load_binding = try self.specialCapture(.super, "<super>") }, self.nodeType(node_id));
    }

    pub fn noteSuperUse(self: *Context) void {
        self.uses_super = true;
    }

    pub fn lowerMeta(self: *Context, node_id: ast.NodeId, kind: model.MetaKind) !ids.ValueId {
        if (kind != .new_target or !self.is_arrow) return self.emitValue(.{ .load_meta = kind }, self.nodeType(node_id));
        self.uses_new_target = true;
        return self.emitValue(.{ .load_binding = try self.specialCapture(.new_target, "<new.target>") }, self.nodeType(node_id));
    }

    pub fn lowerIdentifier(self: *Context, node_id: ast.NodeId) !ids.ValueId {
        const symbol = self.referenceSymbol(node_id) orelse return error.UnresolvedIdentifier;
        return self.emitValue(.{ .load_binding = try self.bindingForReference(symbol) }, self.nodeType(node_id));
    }

    pub fn lowerIdentifierPlace(self: *Context, node_id: ast.NodeId) !ids.PlaceId {
        const symbol = self.referenceSymbol(node_id) orelse return error.UnresolvedIdentifier;
        return self.emitPlace(.{ .binding = try self.bindingForReference(symbol) });
    }

    fn bindingForReference(self: *Context, symbol: binder.SymbolId) !ids.BindingId {
        if (self.scopeWithin(self.inputs.local.frontend.bind.symbols[symbol].scope))
            return self.mappedBinding(symbol) orelse error.MissingHirBinding;
        const source = self.mappedBinding(symbol) orelse return error.MissingOuterHirBinding;
        const local = try self.addCaptureBinding(self.inputs.local.frontend.bind.symbols[symbol].name, self.symbolType(symbol));
        try self.captures.append(self.inputs.builder.allocator, .{ .source = .{ .binding = source }, .local = local, .mode = .live_binding });
        try self.visible.append(self.inputs.builder.allocator, .{ .symbol = symbol, .binding = local });
        return local;
    }

    fn specialCapture(self: *Context, source: model.CaptureSource, name: []const u8) !ids.BindingId {
        for (self.captures.items) |capture| if (std.meta.activeTag(capture.source) == std.meta.activeTag(source)) return capture.local;
        const local = try self.addCaptureBinding(name, self.inputs.builder.result.semanticResult().type_store.builtins.unknown);
        try self.captures.append(self.inputs.builder.allocator, .{ .source = source, .local = local, .mode = .lexical_value });
        return local;
    }

    fn addCaptureBinding(self: *Context, name: []const u8, type_id: model.TypeId) !ids.BindingId {
        const binding = try self.inputs.builder.makeId(ids.BindingId, self.inputs.builder.budget.usage.bindings);
        try self.inputs.builder.appendBinding(&self.bindings, .{
            .id = binding,
            .name = try self.inputs.builder.copyString(name),
            .kind = .synthetic,
            .type_id = type_id,
            .declaration = null,
            .mutable = false,
            .initial_state = .initialized,
            .origin = .invalid,
        });
        return binding;
    }

    fn addBinding(self: *Context, symbol: binder.SymbolId, name: []const u8, kind: model.HirBindingKind, mutable: bool, initial_state: model.HirBindingInitialState, node_id: ast.NodeId) !ids.BindingId {
        const binding = try self.inputs.builder.makeId(ids.BindingId, self.inputs.builder.budget.usage.bindings);
        try self.inputs.builder.appendBinding(&self.bindings, .{
            .id = binding,
            .name = try self.inputs.builder.copyString(name),
            .kind = kind,
            .type_id = self.symbolType(symbol),
            .declaration = declarationId(self.inputs.module.id, node_id),
            .mutable = mutable,
            .initial_state = initial_state,
            .origin = .invalid,
        });
        try self.visible.append(self.inputs.builder.allocator, .{ .symbol = symbol, .binding = binding });
        return binding;
    }

    pub fn emitValue(self: *Context, operation: model.HirOperation, type_id: model.TypeId) !ids.ValueId {
        return self.anf.emitValue(operation, type_id);
    }
    pub fn emitSuspension(self: *Context, operation: model.HirOperation, type_id: model.TypeId) !ids.ValueId {
        return self.anf.emitValueAt(operation, type_id, try self.builder.nextOrigin());
    }
    pub fn allowsAwait(self: *const Context) bool {
        return self.is_async;
    }
    pub fn allowsYield(self: *const Context) bool {
        return self.is_generator;
    }
    pub fn emitVoid(self: *Context, operation: model.HirOperation) !void {
        try self.anf.emitVoid(operation);
    }
    pub fn emitPlace(self: *Context, kind: model.HirPlace.Kind) !ids.PlaceId {
        return self.anf.emitPlace(kind);
    }
    pub fn lowerPlace(self: *Context, node_id: ast.NodeId) !ids.PlaceId {
        return lower_place.lower(self, node_id);
    }
    pub fn lowerAssignment(self: *Context, node_id: ast.NodeId, expression: ast.AssignmentExpression) !ids.ValueId {
        return lower_assignment.lowerAssignment(self, node_id, expression);
    }
    pub fn lowerUpdate(self: *Context, node_id: ast.NodeId, expression: ast.UpdateExpression) !ids.ValueId {
        return lower_assignment.lowerUpdate(self, node_id, expression);
    }
    pub fn lowerDelete(self: *Context, node_id: ast.NodeId, argument: ast.NodeId) !ids.ValueId {
        return lower_assignment.lowerDelete(self, node_id, argument);
    }
    pub fn booleanType(self: *const Context) model.TypeId {
        return self.inputs.builder.result.semanticResult().type_store.builtins.boolean;
    }
    pub fn sourceSite(self: *Context) !ids.SourceSiteId {
        return self.inputs.builder.nextSourceSite();
    }
    pub fn lowerTemplateText(self: *Context, raw: []const u8, cooked: ?[]const u8) ![]const u8 {
        return if (cooked) |value| self.inputs.builder.copyString(value) else self.decodeString(raw);
    }
    pub fn createMethodShell(self: *Context, node_id: ast.NodeId, kind: model.HirFunctionKind) !ids.FunctionId {
        return create(self.inputs, node_id, kind, self.visible.items);
    }
    pub fn nodeType(self: *const Context, node_id: ast.NodeId) model.TypeId {
        return resolvedNodeType(self.inputs, node_id);
    }

    pub fn lowerLiteral(self: *Context, spelling: []const u8) !model.HirOperation {
        if (std.mem.eql(u8, spelling, "true")) return .{ .constant = .{ .boolean = true } };
        if (std.mem.eql(u8, spelling, "false")) return .{ .constant = .{ .boolean = false } };
        if (std.mem.eql(u8, spelling, "null")) return .{ .constant = .null_ };
        if (spelling.len >= 2 and (spelling[0] == '\'' or spelling[0] == '"'))
            return .{ .constant = .{ .string = try self.decodeString(spelling[1 .. spelling.len - 1]) } };
        if (spelling.len > 1 and spelling[spelling.len - 1] == 'n')
            return .{ .constant = .{ .bigint = try self.inputs.builder.copyString(spelling[0 .. spelling.len - 1]) } };
        return .{ .constant = .{ .number = try parseNumber(self.inputs.builder.allocator, spelling) } };
    }

    fn decodeString(self: *Context, spelling: []const u8) ![]const u8 {
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.inputs.builder.allocator);
        var index: usize = 0;
        while (index < spelling.len) {
            if (spelling[index] != '\\') {
                try decoded.append(self.inputs.builder.allocator, spelling[index]);
                index += 1;
                continue;
            }
            index += 1;
            const escape = spelling[index];
            index += 1;
            switch (escape) {
                'n' => try decoded.append(self.inputs.builder.allocator, '\n'),
                't' => try decoded.append(self.inputs.builder.allocator, '\t'),
                'r' => try decoded.append(self.inputs.builder.allocator, '\r'),
                'a' => try decoded.append(self.inputs.builder.allocator, 0x07),
                'b' => try decoded.append(self.inputs.builder.allocator, 0x08),
                'f' => try decoded.append(self.inputs.builder.allocator, 0x0c),
                'v' => try decoded.append(self.inputs.builder.allocator, 0x0b),
                '0' => try decoded.append(self.inputs.builder.allocator, 0),
                '\'', '"', '`', '\\' => try decoded.append(self.inputs.builder.allocator, escape),
                'x' => {
                    const value = (try hexValue(spelling[index])) * 16 + try hexValue(spelling[index + 1]);
                    try decoded.append(self.inputs.builder.allocator, value);
                    index += 2;
                },
                'u' => {
                    var value: u16 = 0;
                    for (spelling[index .. index + 4]) |digit| value = value * 16 + try hexValue(digit);
                    index += 4;
                    if (value < 0x80) try decoded.append(self.inputs.builder.allocator, @intCast(value)) else if (value < 0x800) {
                        try decoded.append(self.inputs.builder.allocator, @intCast(0xc0 | (value >> 6)));
                        try decoded.append(self.inputs.builder.allocator, @intCast(0x80 | (value & 0x3f)));
                    } else {
                        try decoded.append(self.inputs.builder.allocator, @intCast(0xe0 | (value >> 12)));
                        try decoded.append(self.inputs.builder.allocator, @intCast(0x80 | ((value >> 6) & 0x3f)));
                        try decoded.append(self.inputs.builder.allocator, @intCast(0x80 | (value & 0x3f)));
                    }
                },
                else => unreachable,
            }
        }
        return self.inputs.builder.copyString(decoded.items);
    }

    pub fn eraseTypeNode(self: *Context, node_id: ast.TypeNodeId) void {
        const node = self.inputs.local.frontend.ast.typeNode(node_id);
        switch (node.data) {
            .Named => |named| for (named.type_arguments) |child| self.eraseTypeNode(child),
            .Literal, .TypeQuery => {},
            .Array, .Readonly, .KeyOf, .Parenthesized => |child| self.eraseTypeNode(child),
            .IndexedAccess => |indexed| {
                self.eraseTypeNode(indexed.object_type);
                self.eraseTypeNode(indexed.index_type);
            },
            .Union, .Intersection, .Tuple => |children| for (children) |child| self.eraseTypeNode(child),
            .Object => |members| for (members) |member| self.eraseTypeNode(member.type_node),
            .Function => |function| {
                for (function.parameters) |parameter| self.eraseTypeNode(parameter.type_node);
                self.eraseTypeNode(function.return_type);
            },
        }
    }

    fn jumpOne(self: *Context, target: ids.BlockId, value: ids.ValueId) !void {
        const values = try self.inputs.builder.allocator.alloc(ids.ValueId, 1);
        values[0] = value;
        try self.anf.terminate(.{ .jump = .{ .target = target, .arguments = values } });
    }
    fn symbolForDeclaration(self: *const Context, node_id: ast.NodeId) ?binder.SymbolId {
        for (self.inputs.local.frontend.bind.node_symbols) |entry| if (entry.node == node_id and self.scopeWithin(self.inputs.local.frontend.bind.symbols[entry.symbol].scope)) return entry.symbol;
        for (self.inputs.local.frontend.bind.symbols) |symbol| if (symbol.declaration == node_id and self.scopeWithin(symbol.scope)) return symbol.id;
        return null;
    }
    fn parameterSymbol(self: *const Context, node_id: ast.NodeId) ?binder.SymbolId {
        for (self.inputs.local.frontend.bind.symbols) |symbol| if (symbol.declaration == node_id and symbol.kind == .parameter and self.scopeWithin(symbol.scope)) return symbol.id;
        return null;
    }
    fn referenceSymbol(self: *const Context, node_id: ast.NodeId) ?binder.SymbolId {
        for (self.inputs.local.frontend.resolve.references) |reference| if (reference.node == node_id) return reference.symbol;
        return null;
    }
    fn mappedBinding(self: *const Context, symbol: binder.SymbolId) ?ids.BindingId {
        var index = self.visible.items.len;
        while (index != 0) {
            index -= 1;
            if (self.visible.items[index].symbol == symbol) return self.visible.items[index].binding;
        }
        return null;
    }
    fn scopeWithin(self: *const Context, initial: binder.ScopeId) bool {
        var scope: ?binder.ScopeId = initial;
        while (scope) |current| {
            if (current == self.function_scope) return true;
            scope = self.inputs.local.frontend.bind.scopes[current].parent;
        }
        return false;
    }
    fn symbolType(self: *const Context, symbol: binder.SymbolId) model.TypeId {
        const info = self.inputs.project_module.type_info.lookupSymbol(symbol) orelse return self.inputs.builder.result.semanticResult().type_store.builtins.unknown;
        return info.effective() orelse self.inputs.builder.result.semanticResult().type_store.builtins.unknown;
    }
};

fn functionSpec(local: *const semantics.SemanticResult, node_id: ast.NodeId) !FunctionSpec {
    return switch (local.frontend.ast.node(node_id).data) {
        .FunctionDeclaration => |function| .{ .params = function.params, .body = function.body, .expression_body = false, .arrow = false, .flags = function.flags },
        .FunctionExpression => |function| .{ .params = function.params, .body = function.body, .expression_body = false, .arrow = false, .flags = function.flags },
        .ArrowFunctionExpression => |function| .{ .params = function.params, .body = function.body, .expression_body = function.expression_body, .arrow = true, .flags = function.flags },
        .ClassMethod => |function| .{ .params = function.params, .body = function.body, .expression_body = false, .arrow = false, .flags = function.flags },
        else => error.InvalidFunctionNode,
    };
}

fn nodeScope(local: *const semantics.SemanticResult, node_id: ast.NodeId) ?binder.ScopeId {
    for (local.frontend.bind.node_scopes) |entry| if (entry.node == node_id) return entry.scope;
    return null;
}

fn resolvedNodeType(inputs: Inputs, node_id: ast.NodeId) model.TypeId {
    return inputs.project_module.type_info.lookupNode(node_id) orelse inputs.builder.result.semanticResult().type_store.builtins.unknown;
}

fn declarationId(module_id: project.ModuleId, node_id: ast.NodeId) model.SemanticDeclId {
    return .init(module_id.value(), node_id);
}

fn parseNumber(allocator: std.mem.Allocator, spelling: []const u8) !f64 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    for (spelling) |byte| if (byte != '_') try cleaned.append(allocator, byte);
    const value = cleaned.items;
    if (value.len > 2 and value[0] == '0') {
        const base: ?u8 = switch (value[1]) {
            'x', 'X' => 16,
            'b', 'B' => 2,
            'o', 'O' => 8,
            else => null,
        };
        if (base) |radix| return @floatFromInt(try std.fmt.parseInt(u64, value[2..], radix));
    }
    return std.fmt.parseFloat(f64, value);
}

fn literalIsString(local: *const semantics.SemanticResult, node_id: ast.NodeId) bool {
    return switch (local.frontend.ast.node(node_id).data) {
        .Literal => |literal| literal.value.len >= 2 and (literal.value[0] == '\'' or literal.value[0] == '"'),
        else => false,
    };
}

fn literalNumber(allocator: std.mem.Allocator, local: *const semantics.SemanticResult, node_id: ast.NodeId) ?f64 {
    return switch (local.frontend.ast.node(node_id).data) {
        .Literal => |literal| if (!literalIsString(local, node_id)) parseNumber(allocator, literal.value) catch null else null,
        else => null,
    };
}

fn hexValue(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHexEscape,
    };
}
