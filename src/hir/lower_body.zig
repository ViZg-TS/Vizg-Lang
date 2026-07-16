//! Semantic-identity-driven lowering for the first executable HIR subset.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const anf_builder = @import("anf_builder.zig");
const binder = @import("../frontend/binder.zig");
const builder_mod = @import("builder.zig");
const ids = @import("ids.zig");
const lower_expression = @import("lower_expression.zig");
const lower_function = @import("lower_function.zig");
const lower_control = @import("lower_control.zig");
const lower_exceptions = @import("lower_exceptions.zig");
const lower_assignment = @import("lower_assignment.zig");
const lower_place = @import("lower_place.zig");
const model = @import("model.zig");
const project = @import("../project/root.zig");
const semantics = @import("../semantics/root.zig");

pub const SymbolBinding = lower_function.SymbolBinding;

pub const Output = struct {
    bindings: []const model.HirBinding,
    places: []const model.HirPlace,
    blocks: []const model.HirBlock,
    entry: ids.BlockId,
    entities: []const ids.EntityId,
    symbol_bindings: []const SymbolBinding,
    symbol_entities: []const SymbolEntity,
    regions: []const ids.RegionId,
};

pub const SymbolEntity = struct {
    symbol: binder.SymbolId,
    entity: ids.EntityId,
};

const FunctionShell = struct {
    node: ast.NodeId,
    binding: ids.BindingId,
    function: ids.FunctionId,
    type_id: model.TypeId,
};

const ClassShell = struct {
    node: ast.NodeId,
    binding: ids.BindingId,
    symbol: binder.SymbolId,
};

const EnumShell = struct {
    node: ast.NodeId,
    binding: ids.BindingId,
    symbol: binder.SymbolId,
};

const Lowerer = struct {
    builder: *builder_mod.Builder,
    anf: *anf_builder.AnfBuilder,
    module: *const project.ProjectModule,
    local: *const semantics.SemanticResult,
    project_module: *const semantics.ProjectSemanticModule,
    bindings: std.ArrayList(model.HirBinding) = .empty,
    entity_ids: std.ArrayList(ids.EntityId) = .empty,
    symbol_bindings: std.ArrayList(SymbolBinding) = .empty,
    symbol_entities: std.ArrayList(SymbolEntity) = .empty,
    function_shells: std.ArrayList(FunctionShell) = .empty,
    class_shells: std.ArrayList(ClassShell) = .empty,
    enum_shells: std.ArrayList(EnumShell) = .empty,
    function_id: ids.FunctionId,
    regions: std.ArrayList(ids.RegionId) = .empty,
    cleanups: std.ArrayList(lower_control.CleanupFrame) = .empty,
    controls: std.ArrayList(lower_control.ControlTarget) = .empty,
    labels: std.ArrayList(lower_control.LabelFrame) = .empty,
    catch_cleanup_depths: std.ArrayList(usize) = .empty,

    fn predeclare(self: *Lowerer, node_id: ast.NodeId) !void {
        const node = self.local.frontend.ast.node(node_id);
        switch (node.data) {
            .Program => |program| for (program.statements) |statement| try self.predeclare(statement),
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
                    const parameter = self.local.frontend.ast.node(parameter_id).data.Parameter;
                    const symbol = self.symbolForDeclaration(parameter_id) orelse return error.MissingSemanticIdentity;
                    const binding = try self.builder.makeId(ids.BindingId, self.builder.budget.usage.bindings);
                    try self.builder.appendBinding(&self.bindings, .{
                        .id = binding,
                        .name = try self.builder.copyString(parameter.name),
                        .kind = .catch_,
                        .type_id = self.symbolType(symbol),
                        .declaration = self.declarationId(parameter_id),
                        .mutable = true,
                        .initial_state = .temporal_dead_zone,
                        .origin = .invalid,
                    });
                    try self.symbol_bindings.append(self.builder.allocator, .{ .symbol = symbol, .binding = binding });
                }
                try self.predeclare(clause.body);
            },
            .FinallyClause => |clause| try self.predeclare(clause.body),
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast.invalid_node) try self.predeclare(export_decl.declaration);
            },
            .VariableDeclaration => |declaration| {
                for (declaration.declarations) |declarator_id| {
                    const declarator = self.local.frontend.ast.node(declarator_id).data.VariableDeclarator;
                    if (declarator.type_annotation) |annotation| self.eraseTypeNode(annotation.root);
                    const symbol_id = self.symbolForDeclaration(declarator_id) orelse return error.MissingSemanticIdentity;
                    const binding_id = try self.builder.makeId(ids.BindingId, self.builder.budget.usage.bindings);
                    const kind: model.HirBindingKind = switch (declaration.kind) {
                        .Keyword_var => .var_,
                        .Keyword_let => .let_,
                        .Keyword_const => .const_,
                        else => return error.InvalidVariableKind,
                    };
                    try self.builder.appendBinding(&self.bindings, .{
                        .id = binding_id,
                        .name = try self.builder.copyString(declarator.name),
                        .kind = kind,
                        .type_id = self.symbolType(symbol_id),
                        .declaration = self.declarationId(declarator_id),
                        .mutable = kind != .const_,
                        .initial_state = if (kind == .var_) .hoisted_undefined else .temporal_dead_zone,
                        .origin = .invalid,
                    });
                    try self.symbol_bindings.append(self.builder.allocator, .{ .symbol = symbol_id, .binding = binding_id });
                }
            },
            .FunctionDeclaration => |function| {
                for (function.type_parameters) |parameter| {
                    if (parameter.constraint) |annotation| self.eraseTypeNode(annotation.root);
                    if (parameter.default_type) |annotation| self.eraseTypeNode(annotation.root);
                }
                if (function.return_type) |annotation| self.eraseTypeNode(annotation.root);
                const symbol_id = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const type_id = self.symbolType(symbol_id);
                const binding_id = try self.builder.makeId(ids.BindingId, self.builder.budget.usage.bindings);
                try self.builder.appendBinding(&self.bindings, .{
                    .id = binding_id,
                    .name = try self.builder.copyString(function.name),
                    .kind = .function,
                    .type_id = type_id,
                    .declaration = self.declarationId(node_id),
                    .mutable = true,
                    .initial_state = .hoisted_function,
                    .origin = .invalid,
                });
                try self.symbol_bindings.append(self.builder.allocator, .{ .symbol = symbol_id, .binding = binding_id });

                const function_id = try lower_function.reserve(self.functionInputs(), node_id, .ordinary);
                const entity_id = try self.builder.makeId(ids.EntityId, self.builder.entities.items.len);
                try self.builder.appendEntity(.{
                    .id = entity_id,
                    .module_id = self.module.id,
                    .declaration = self.declarationId(node_id),
                    .origin = .invalid,
                    .kind = .{ .function = .{ .function = function_id } },
                });
                try self.entity_ids.append(self.builder.allocator, entity_id);
                try self.symbol_entities.append(self.builder.allocator, .{ .symbol = symbol_id, .entity = entity_id });
                try self.function_shells.append(self.builder.allocator, .{ .node = node_id, .binding = binding_id, .function = function_id, .type_id = type_id });
            },
            .ClassDeclaration => |declaration| {
                for (declaration.type_parameters) |parameter| {
                    if (parameter.constraint) |annotation| self.eraseTypeNode(annotation.root);
                    if (parameter.default_type) |annotation| self.eraseTypeNode(annotation.root);
                }
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const binding = try self.appendLexicalBinding(node_id, declaration.name, symbol, .class, false);
                try self.class_shells.append(self.builder.allocator, .{ .node = node_id, .binding = binding, .symbol = symbol });
            },
            .EnumDeclaration => |declaration| {
                const symbol = self.symbolForDeclaration(node_id) orelse return error.MissingSemanticIdentity;
                const binding = try self.appendLexicalBinding(node_id, declaration.name, symbol, .enum_, true);
                try self.enum_shells.append(self.builder.allocator, .{ .node = node_id, .binding = binding, .symbol = symbol });
            },
            .TypeAliasDeclaration => |declaration| {
                for (declaration.type_parameters) |parameter| {
                    if (parameter.constraint) |annotation| self.eraseTypeNode(annotation.root);
                    if (parameter.default_type) |annotation| self.eraseTypeNode(annotation.root);
                }
                self.eraseTypeNode(declaration.type_annotation.root);
            },
            .InterfaceDeclaration => |declaration| {
                for (declaration.type_parameters) |parameter| {
                    if (parameter.constraint) |annotation| self.eraseTypeNode(annotation.root);
                    if (parameter.default_type) |annotation| self.eraseTypeNode(annotation.root);
                }
                for (declaration.extends) |type_node| self.eraseTypeNode(type_node);
                self.eraseTypeNode(declaration.body);
            },
            else => {},
        }
    }

    fn emitHoists(self: *Lowerer) !void {
        for (self.function_shells.items) |shell| {
            const closure = try self.emitValue(.{ .create_closure = shell.function }, shell.type_id);
            try self.emitVoid(.{ .initialize_binding = .{ .binding = shell.binding, .value = closure } });
        }
    }

    fn lowerFunctions(self: *Lowerer) !void {
        for (self.function_shells.items) |shell| {
            try lower_function.lowerReserved(self.functionInputs(), shell.function, shell.node, .ordinary, self.symbol_bindings.items);
        }
    }

    pub fn lowerStatement(self: *Lowerer, node_id: ast.NodeId) anyerror!void {
        const node = self.local.frontend.ast.node(node_id);
        switch (node.data) {
            .Program => |program| for (program.statements) |statement| {
                if (self.anf.currentTerminated()) break;
                try self.lowerStatement(statement);
            },
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
            .ImportDeclaration, .FunctionDeclaration, .TypeAliasDeclaration, .InterfaceDeclaration => {},
            .ClassDeclaration => try self.lowerClassDeclaration(node_id),
            .EnumDeclaration => try self.lowerEnumDeclaration(node_id),
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast.invalid_node) {
                    try self.lowerStatement(export_decl.declaration);
                } else if (export_decl.expression != ast.invalid_node) {
                    _ = try self.lowerExpression(export_decl.expression);
                }
            },
            .VariableDeclaration => |declaration| {
                for (declaration.declarations) |declarator_id| {
                    const declarator = self.local.frontend.ast.node(declarator_id).data.VariableDeclarator;
                    const symbol_id = self.symbolForDeclaration(declarator_id) orelse return error.MissingSemanticIdentity;
                    const binding_id = self.bindingForSymbol(symbol_id) orelse return error.MissingHirBinding;
                    if (declarator.init) |initializer| {
                        const value = try self.lowerExpression(initializer);
                        if (declaration.kind == .Keyword_var)
                            try self.emitVoid(.{ .store_binding = .{ .binding = binding_id, .value = value } })
                        else
                            try self.emitVoid(.{ .initialize_binding = .{ .binding = binding_id, .value = value } });
                    } else if (declaration.kind != .Keyword_var) {
                        const value = try self.emitValue(.{ .constant = .undefined }, self.builder.result.semanticResult().type_store.builtins.undefined);
                        try self.emitVoid(.{ .initialize_binding = .{ .binding = binding_id, .value = value } });
                    }
                }
            },
            else => return error.UnsupportedHirStatement,
        }
    }

    pub fn lowerExpression(self: *Lowerer, node_id: ast.NodeId) !ids.ValueId {
        return lower_expression.lower(self, node_id);
    }

    pub fn lowerClassExpression(self: *Lowerer, node_id: ast.NodeId) !ids.ValueId {
        const declaration = self.local.frontend.ast.node(node_id).data.ClassExpression;
        var local_binding: ?ids.BindingId = null;
        if (declaration.name) |name| {
            if (self.symbolForDeclaration(node_id)) |symbol|
                local_binding = try self.appendLexicalBinding(node_id, name, symbol, .class, false);
        }
        const value = try lower_function.lowerClassValue(self, self.functionInputs(), node_id, declaration.super_class, declaration.members, self.symbol_bindings.items);
        if (local_binding) |binding| try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
        return value;
    }

    pub fn afterSuperConstructor(_: *Lowerer) !void {}

    pub fn noteSuperUse(_: *Lowerer) void {}

    pub fn astNode(self: *Lowerer, node_id: ast.NodeId) ast.Node {
        return self.local.frontend.ast.node(node_id);
    }

    pub fn labelBodyIsIteration(self: *Lowerer, node_id: ast.NodeId) bool {
        return switch (self.astNode(node_id).data) {
            .WhileStatement, .DoWhileStatement, .ForStatement => true,
            .LabeledStatement => |statement| self.labelBodyIsIteration(statement.body),
            else => false,
        };
    }

    pub fn lowerForInitializer(self: *Lowerer, node_id: ast.NodeId) !void {
        if (self.local.frontend.ast.node(node_id).data == .VariableDeclaration)
            try self.lowerStatement(node_id)
        else
            _ = try self.lowerExpression(node_id);
    }

    pub fn assignIterationTarget(self: *Lowerer, node_id: ast.NodeId, value: ids.ValueId) !void {
        switch (self.local.frontend.ast.node(node_id).data) {
            .VariableDeclaration => |declaration| {
                if (declaration.declarations.len != 1) return error.InvalidForStatement;
                const declarator_id = declaration.declarations[0];
                const symbol = self.symbolForDeclaration(declarator_id) orelse return error.MissingSemanticIdentity;
                const binding = self.bindingForSymbol(symbol) orelse return error.MissingHirBinding;
                if (declaration.kind == .Keyword_var)
                    try self.emitVoid(.{ .store_binding = .{ .binding = binding, .value = value } })
                else
                    try self.emitVoid(.{ .initialize_binding = .{ .binding = binding, .value = value } });
            },
            else => try self.emitVoid(.{ .store_place = .{ .place = try self.lowerPlace(node_id), .value = value } }),
        }
    }

    pub fn unknownType(self: *const Lowerer) model.TypeId {
        return self.builder.result.semanticResult().type_store.builtins.unknown;
    }

    pub fn catchBinding(self: *const Lowerer, parameter: ast.NodeId) !ids.BindingId {
        const symbol = self.symbolForDeclaration(parameter) orelse return error.MissingSemanticIdentity;
        return self.bindingForSymbol(symbol) orelse error.MissingHirBinding;
    }

    pub fn lowerFunctionExpression(self: *Lowerer, node_id: ast.NodeId, kind: model.HirFunctionKind) !ids.ValueId {
        const function_id = try lower_function.create(self.functionInputs(), node_id, kind, self.symbol_bindings.items);
        return self.emitValue(.{ .create_closure = function_id }, self.nodeType(node_id));
    }

    pub fn lowerThis(self: *Lowerer, node_id: ast.NodeId) !ids.ValueId {
        return self.emitValue(.load_this, self.nodeType(node_id));
    }

    pub fn lowerSuper(self: *Lowerer, node_id: ast.NodeId) !ids.ValueId {
        return self.emitValue(.load_super, self.nodeType(node_id));
    }

    pub fn lowerMeta(self: *Lowerer, node_id: ast.NodeId, kind: model.MetaKind) !ids.ValueId {
        return self.emitValue(.{ .load_meta = kind }, self.nodeType(node_id));
    }

    pub fn emitValue(self: *Lowerer, operation: model.HirOperation, type_id: model.TypeId) !ids.ValueId {
        return self.anf.emitValue(operation, type_id);
    }

    pub fn emitSuspension(self: *Lowerer, operation: model.HirOperation, type_id: model.TypeId) !ids.ValueId {
        return self.anf.emitValueAt(operation, type_id, try self.builder.nextOrigin());
    }

    pub fn allowsAwait(_: *const Lowerer) bool {
        return false;
    }

    pub fn allowsYield(_: *const Lowerer) bool {
        return false;
    }

    pub fn emitVoid(self: *Lowerer, operation: model.HirOperation) !void {
        try self.anf.emitVoid(operation);
    }

    pub fn emitPlace(self: *Lowerer, kind: model.HirPlace.Kind) !ids.PlaceId {
        return self.anf.emitPlace(kind);
    }

    pub fn lowerPlace(self: *Lowerer, node_id: ast.NodeId) !ids.PlaceId {
        return lower_place.lower(self, node_id);
    }

    pub fn lowerAssignment(self: *Lowerer, node_id: ast.NodeId, expression: ast.AssignmentExpression) !ids.ValueId {
        return lower_assignment.lowerAssignment(self, node_id, expression);
    }

    pub fn lowerUpdate(self: *Lowerer, node_id: ast.NodeId, expression: ast.UpdateExpression) !ids.ValueId {
        return lower_assignment.lowerUpdate(self, node_id, expression);
    }

    pub fn lowerDelete(self: *Lowerer, node_id: ast.NodeId, argument: ast.NodeId) !ids.ValueId {
        return lower_assignment.lowerDelete(self, node_id, argument);
    }

    pub fn lowerIdentifier(self: *Lowerer, node_id: ast.NodeId) !ids.ValueId {
        const symbol_id = self.referenceSymbol(node_id) orelse return error.UnresolvedIdentifier;
        const binding_id = self.bindingForSymbol(symbol_id) orelse return error.MissingHirBinding;
        return self.emitValue(.{ .load_binding = binding_id }, self.nodeType(node_id));
    }

    pub fn lowerIdentifierPlace(self: *Lowerer, node_id: ast.NodeId) !ids.PlaceId {
        const symbol_id = self.referenceSymbol(node_id) orelse return error.UnresolvedIdentifier;
        const binding_id = self.bindingForSymbol(symbol_id) orelse return error.MissingHirBinding;
        return self.emitPlace(.{ .binding = binding_id });
    }

    pub fn booleanType(self: *const Lowerer) model.TypeId {
        return self.builder.result.semanticResult().type_store.builtins.boolean;
    }

    pub fn sourceSite(self: *Lowerer) !ids.SourceSiteId {
        return self.builder.nextSourceSite();
    }

    pub fn lowerTemplateText(self: *Lowerer, raw: []const u8, cooked: ?[]const u8) ![]const u8 {
        return if (cooked) |value| self.builder.copyString(value) else self.decodeString(raw);
    }

    pub fn createMethodShell(self: *Lowerer, node_id: ast.NodeId, kind: model.HirFunctionKind) !ids.FunctionId {
        const function_id = try lower_function.create(self.functionInputs(), node_id, kind, self.symbol_bindings.items);
        const entity_id = try self.builder.makeId(ids.EntityId, self.builder.entities.items.len);
        try self.builder.appendEntity(.{
            .id = entity_id,
            .module_id = self.module.id,
            .declaration = self.declarationId(node_id),
            .origin = .invalid,
            .kind = .{ .function = .{ .function = function_id } },
        });
        try self.entity_ids.append(self.builder.allocator, entity_id);
        return function_id;
    }

    fn functionInputs(self: *Lowerer) lower_function.Inputs {
        return .{ .builder = self.builder, .module = self.module, .local = self.local, .project_module = self.project_module, .entity_ids = &self.entity_ids };
    }

    fn appendLexicalBinding(
        self: *Lowerer,
        node_id: ast.NodeId,
        name: []const u8,
        symbol: binder.SymbolId,
        kind: model.HirBindingKind,
        mutable: bool,
    ) !ids.BindingId {
        const binding = try self.builder.makeId(ids.BindingId, self.builder.budget.usage.bindings);
        try self.builder.appendBinding(&self.bindings, .{
            .id = binding,
            .name = try self.builder.copyString(name),
            .kind = kind,
            .type_id = self.symbolType(symbol),
            .declaration = self.declarationId(node_id),
            .mutable = mutable,
            .initial_state = .temporal_dead_zone,
            .origin = .invalid,
        });
        try self.symbol_bindings.append(self.builder.allocator, .{ .symbol = symbol, .binding = binding });
        return binding;
    }

    fn lowerClassDeclaration(self: *Lowerer, node_id: ast.NodeId) !void {
        const declaration = self.local.frontend.ast.node(node_id).data.ClassDeclaration;
        const shell = self.classShell(node_id) orelse return error.MissingClassShell;
        const value = try lower_function.lowerClassValue(self, self.functionInputs(), node_id, declaration.super_class, declaration.members, self.symbol_bindings.items);
        const entity = self.entity_ids.items[self.entity_ids.items.len - 1];
        try self.symbol_entities.append(self.builder.allocator, .{ .symbol = shell.symbol, .entity = entity });
        try self.emitVoid(.{ .initialize_binding = .{ .binding = shell.binding, .value = value } });
    }

    fn lowerEnumDeclaration(self: *Lowerer, node_id: ast.NodeId) !void {
        const declaration = self.local.frontend.ast.node(node_id).data.EnumDeclaration;
        const shell = self.enumShell(node_id) orelse return error.MissingEnumShell;
        const lowered = try lower_function.lowerEnumValue(self, self.functionInputs(), node_id, shell.binding, declaration.members);
        try self.symbol_entities.append(self.builder.allocator, .{ .symbol = shell.symbol, .entity = lowered.entity });
        try self.emitVoid(.{ .initialize_binding = .{ .binding = shell.binding, .value = lowered.value } });
    }

    fn classShell(self: *const Lowerer, node_id: ast.NodeId) ?ClassShell {
        for (self.class_shells.items) |shell| if (shell.node == node_id) return shell;
        return null;
    }

    fn enumShell(self: *const Lowerer, node_id: ast.NodeId) ?EnumShell {
        for (self.enum_shells.items) |shell| if (shell.node == node_id) return shell;
        return null;
    }

    fn literalIsString(self: *const Lowerer, node_id: ast.NodeId) bool {
        return switch (self.local.frontend.ast.node(node_id).data) {
            .Literal => |literal| literal.value.len >= 2 and (literal.value[0] == '\'' or literal.value[0] == '"'),
            else => false,
        };
    }

    fn literalNumber(self: *const Lowerer, node_id: ast.NodeId) ?f64 {
        return switch (self.local.frontend.ast.node(node_id).data) {
            .Literal => |literal| if (!self.literalIsString(node_id)) parseNumber(self.builder.allocator, literal.value) catch null else null,
            else => null,
        };
    }

    pub fn lowerLiteral(self: *Lowerer, spelling: []const u8) !model.HirOperation {
        if (std.mem.eql(u8, spelling, "true")) return .{ .constant = .{ .boolean = true } };
        if (std.mem.eql(u8, spelling, "false")) return .{ .constant = .{ .boolean = false } };
        if (std.mem.eql(u8, spelling, "null")) return .{ .constant = .null_ };
        if (spelling.len >= 2 and (spelling[0] == '\'' or spelling[0] == '"')) {
            return .{ .constant = .{ .string = try self.decodeString(spelling[1 .. spelling.len - 1]) } };
        }
        if (spelling.len > 1 and spelling[spelling.len - 1] == 'n') {
            return .{ .constant = .{ .bigint = try self.builder.copyString(spelling[0 .. spelling.len - 1]) } };
        }
        return .{ .constant = .{ .number = try parseNumber(self.builder.allocator, spelling) } };
    }

    fn decodeString(self: *Lowerer, spelling: []const u8) ![]const u8 {
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.builder.allocator);
        var index: usize = 0;
        while (index < spelling.len) {
            if (spelling[index] != '\\') {
                try decoded.append(self.builder.allocator, spelling[index]);
                index += 1;
                continue;
            }
            index += 1;
            const escape = spelling[index];
            index += 1;
            switch (escape) {
                'n' => try decoded.append(self.builder.allocator, '\n'),
                't' => try decoded.append(self.builder.allocator, '\t'),
                'r' => try decoded.append(self.builder.allocator, '\r'),
                'a' => try decoded.append(self.builder.allocator, 0x07),
                'b' => try decoded.append(self.builder.allocator, 0x08),
                'f' => try decoded.append(self.builder.allocator, 0x0c),
                'v' => try decoded.append(self.builder.allocator, 0x0b),
                '0' => try decoded.append(self.builder.allocator, 0),
                '\'', '"', '`', '\\' => try decoded.append(self.builder.allocator, escape),
                'x' => {
                    const value = (try hexValue(spelling[index])) * 16 + try hexValue(spelling[index + 1]);
                    try decoded.append(self.builder.allocator, value);
                    index += 2;
                },
                'u' => {
                    var value: u16 = 0;
                    for (spelling[index .. index + 4]) |digit| value = value * 16 + try hexValue(digit);
                    index += 4;
                    if (value < 0x80) {
                        try decoded.append(self.builder.allocator, @intCast(value));
                    } else if (value < 0x800) {
                        try decoded.append(self.builder.allocator, @intCast(0xc0 | (value >> 6)));
                        try decoded.append(self.builder.allocator, @intCast(0x80 | (value & 0x3f)));
                    } else {
                        // Preserve lone UTF-16 surrogates losslessly as WTF-8.
                        try decoded.append(self.builder.allocator, @intCast(0xe0 | (value >> 12)));
                        try decoded.append(self.builder.allocator, @intCast(0x80 | ((value >> 6) & 0x3f)));
                        try decoded.append(self.builder.allocator, @intCast(0x80 | (value & 0x3f)));
                    }
                },
                else => unreachable,
            }
        }
        return self.builder.copyString(decoded.items);
    }

    pub fn eraseTypeNode(self: *Lowerer, node_id: ast.TypeNodeId) void {
        const node = self.local.frontend.ast.typeNode(node_id);
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

    fn symbolForDeclaration(self: *const Lowerer, node_id: ast.NodeId) ?binder.SymbolId {
        for (self.local.frontend.bind.node_symbols) |entry| if (entry.node == node_id) return entry.symbol;
        return null;
    }

    fn referenceSymbol(self: *const Lowerer, node_id: ast.NodeId) ?binder.SymbolId {
        for (self.local.frontend.resolve.references) |reference| if (reference.node == node_id) return reference.symbol;
        return null;
    }

    fn bindingForSymbol(self: *const Lowerer, symbol: binder.SymbolId) ?ids.BindingId {
        for (self.symbol_bindings.items) |entry| if (entry.symbol == symbol) return entry.binding;
        return null;
    }

    fn symbolType(self: *const Lowerer, symbol: binder.SymbolId) model.TypeId {
        const info = self.project_module.type_info.lookupSymbol(symbol) orelse return self.builder.result.semanticResult().type_store.builtins.unknown;
        return info.effective() orelse self.builder.result.semanticResult().type_store.builtins.unknown;
    }

    pub fn nodeType(self: *const Lowerer, node_id: ast.NodeId) model.TypeId {
        return self.project_module.type_info.lookupNode(node_id) orelse self.builder.result.semanticResult().type_store.builtins.unknown;
    }

    fn declarationId(self: *const Lowerer, node_id: ast.NodeId) model.SemanticDeclId {
        return .init(self.module.id.value(), node_id);
    }
};

pub fn lower(
    builder: *builder_mod.Builder,
    module: *const project.ProjectModule,
    function_id: ids.FunctionId,
    imported_bindings: []const model.HirBinding,
    imported_symbols: []const SymbolBinding,
) !Output {
    const local = module.semantic_result orelse return error.ModuleNotAnalyzed;
    const project_module = builder.result.semanticResult().lookupModule(module.id.value()) orelse return error.ModuleNotAnalyzed;
    var anf = try anf_builder.AnfBuilder.init(builder);
    var lowerer: Lowerer = .{ .builder = builder, .anf = &anf, .module = module, .local = local, .project_module = project_module, .function_id = function_id };
    try lowerer.bindings.appendSlice(builder.allocator, imported_bindings);
    try lowerer.symbol_bindings.appendSlice(builder.allocator, imported_symbols);
    try lowerer.predeclare(local.frontend.ast.root);
    try lowerer.lowerFunctions();
    try lowerer.emitHoists();
    try lowerer.lowerStatement(local.frontend.ast.root);
    try anf.terminate(.{ .return_ = null });
    return .{
        .bindings = try lowerer.bindings.toOwnedSlice(builder.allocator),
        .places = try anf.finishPlaces(),
        .blocks = try anf.finish(),
        .entry = anf.entry,
        .entities = try lowerer.entity_ids.toOwnedSlice(builder.allocator),
        .symbol_bindings = try lowerer.symbol_bindings.toOwnedSlice(builder.allocator),
        .symbol_entities = try lowerer.symbol_entities.toOwnedSlice(builder.allocator),
        .regions = try lowerer.regions.toOwnedSlice(builder.allocator),
    };
}

pub fn entityForSymbol(output: Output, symbol: binder.SymbolId) ?ids.EntityId {
    for (output.symbol_entities) |entry| if (entry.symbol == symbol) return entry.entity;
    return null;
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
    return try std.fmt.parseFloat(f64, value);
}

fn hexValue(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHexEscape,
    };
}
