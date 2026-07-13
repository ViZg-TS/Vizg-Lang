const std = @import("std");
const ast_mod = @import("ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const tokens = @import("tokens.zig");

const NodeId = ast_mod.NodeId;

pub const ScopeId = u32;
pub const SymbolId = u32;

pub const ScopeKind = enum {
    global,
    type_parameters,
    function,
    class,
    enum_,
    block,
};

pub const SymbolKind = enum {
    variable,
    function,
    parameter,
    import,
    type_alias,
    interface,
    class,
    enum_,
    enum_member,
    type_parameter,
    field,
    method,
};

pub const SymbolNamespace = enum {
    value,
    type,
};

pub const Scope = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent: ?ScopeId,
    symbols: []const SymbolId,
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    kind: SymbolKind,
    namespace: SymbolNamespace,
    scope: ScopeId,
    declaration: NodeId,
    span: tokens.Span,
};

pub const NodeSymbol = struct {
    node: NodeId,
    symbol: SymbolId,
};

pub const ImportRecord = struct {
    local_name: []const u8,
    source: []const u8,
    kind: ast_mod.ImportSpecifierKind,
    type_only: bool,
};

pub const ExportRecord = struct {
    name: []const u8,
    local_name: []const u8,
    node: NodeId,
    kind: ast_mod.ExportKind = .local,
    type_only: bool = false,
    source: []const u8 = "",
};

pub const ModuleInfo = struct {
    imports: []const ImportRecord,
    exports: []const ExportRecord,
};

pub const BindResult = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    node_symbols: []const NodeSymbol,
    module: ModuleInfo,
    diagnostics: []const diagnostics.Diagnostic,
};

const ScopeBuilder = struct {
    id: ScopeId,
    kind: ScopeKind,
    parent: ?ScopeId,
    symbols: std.ArrayList(SymbolId) = .empty,
};

const Binder = struct {
    allocator: std.mem.Allocator,
    ast: ast_mod.Ast,
    scopes: std.ArrayList(ScopeBuilder) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    node_symbols: std.ArrayList(NodeSymbol) = .empty,
    imports: std.ArrayList(ImportRecord) = .empty,
    exports: std.ArrayList(ExportRecord) = .empty,
    diagnostic_list: std.ArrayList(diagnostics.Diagnostic) = .empty,

    fn bind(self: *Binder) !BindResult {
        const global_scope = try self.addScope(.global, null);
        try self.bindNode(self.ast.root, global_scope);

        var final_scopes: std.ArrayList(Scope) = .empty;
        errdefer final_scopes.deinit(self.allocator);
        for (self.scopes.items) |*scope| {
            try final_scopes.append(self.allocator, .{
                .id = scope.id,
                .kind = scope.kind,
                .parent = scope.parent,
                .symbols = try scope.symbols.toOwnedSlice(self.allocator),
            });
        }

        return .{
            .scopes = try final_scopes.toOwnedSlice(self.allocator),
            .symbols = try self.symbols.toOwnedSlice(self.allocator),
            .node_symbols = try self.node_symbols.toOwnedSlice(self.allocator),
            .module = .{
                .imports = try self.imports.toOwnedSlice(self.allocator),
                .exports = try self.exports.toOwnedSlice(self.allocator),
            },
            .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
        };
    }

    fn bindNode(self: *Binder, node_id: NodeId, scope: ScopeId) anyerror!void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Program => |program| {
                for (program.statements) |statement| try self.bindNode(statement, scope);
            },
            .ImportDeclaration => |import_decl| {
                for (import_decl.specifiers) |specifier| {
                    _ = try self.declareInNamespace(scope, specifier.local_name, .import, if (import_decl.type_only) .type else .value, node_id, specifier.local_span);
                    try self.imports.append(self.allocator, .{
                        .local_name = specifier.local_name,
                        .source = import_decl.source,
                        .kind = specifier.kind,
                        .type_only = import_decl.type_only,
                    });
                }
            },
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast_mod.invalid_node) {
                    const declaration = export_decl.declaration;
                    try self.bindNode(declaration, scope);
                    try self.recordDeclarationExports(declaration);
                } else {
                    for (export_decl.specifiers) |specifier| {
                        try self.appendExportDetails(specifier.exported_name, specifier.local_name, node_id, export_decl.kind, export_decl.type_only, export_decl.source);
                    }
                }

                if (export_decl.expression != ast_mod.invalid_node) try self.bindNode(export_decl.expression, scope);

                // Any export record — default or named — counts toward module exports.
                if (export_decl.default_name != null or export_decl.kind == .default_expression) {
                    _ = try self.appendExportDetails("default", export_decl.default_name orelse "", node_id, export_decl.kind, export_decl.type_only, export_decl.source);
                }
            },
            .FunctionDeclaration => |function_decl| {
                const symbol_id = try self.declare(scope, function_decl.name, .function, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });

                const declaration_scope = try self.bindTypeParameters(function_decl.type_parameters, scope, node_id);
                const function_scope = try self.addScope(.function, declaration_scope);
                for (function_decl.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindParameterInitializers(function_decl.params, function_scope);
                try self.bindNode(function_decl.body, function_scope);
            },
            .FunctionExpression => |function_expr| {
                const function_scope = try self.addScope(.function, scope);
                if (function_expr.name) |name| {
                    const symbol_id = try self.declare(function_scope, name, .function, node_id, node.span);
                    try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                }
                for (function_expr.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindParameterInitializers(function_expr.params, function_scope);
                try self.bindNode(function_expr.body, function_scope);
            },
            .YieldExpression => |yield_expr| {
                if (yield_expr.argument) |argument| try self.bindNode(argument, scope);
            },
            .ClassDeclaration => |class_decl| {
                const value_symbol = try self.declareInNamespace(scope, class_decl.name, .class, .value, node_id, node.span);
                _ = try self.declareInNamespace(scope, class_decl.name, .class, .type, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = value_symbol });
                const declaration_scope = try self.bindTypeParameters(class_decl.type_parameters, scope, node_id);
                if (class_decl.super_class) |super_class| try self.bindNode(super_class, declaration_scope);
                const class_scope = try self.addScope(.class, declaration_scope);
                for (class_decl.members) |member| try self.bindNode(member, class_scope);
            },
            .ClassExpression => |class_expr| {
                if (class_expr.super_class) |super_class| try self.bindNode(super_class, scope);
                const class_scope = try self.addScope(.class, scope);
                if (class_expr.name) |name| {
                    const symbol_id = try self.declare(class_scope, name, .class, node_id, node.span);
                    try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                }
                for (class_expr.members) |member| try self.bindNode(member, class_scope);
            },
            .ClassField => |field| {
                const symbol_id = try self.declare(scope, field.name, .field, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                if (field.initializer) |initializer| try self.bindNode(initializer, scope);
            },
            .ClassMethod => |method| {
                const symbol_id = try self.declare(scope, method.name, .method, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                const function_scope = try self.addScope(.function, scope);
                for (method.params) |param_id| switch (self.ast.node(param_id).data) {
                    .Parameter => |param| {
                        _ = try self.declare(function_scope, param.name, .parameter, param_id, self.ast.node(param_id).span);
                        if (method.kind == .constructor and (param.access != .none or param.readonly)) {
                            const property_symbol = try self.declare(scope, param.name, .field, param_id, self.ast.node(param_id).span);
                            try self.node_symbols.append(self.allocator, .{ .node = param_id, .symbol = property_symbol });
                        }
                    },
                    else => {},
                };
                try self.bindParameterInitializers(method.params, function_scope);
                try self.bindNode(method.body, function_scope);
            },
            .ArrowFunctionExpression => |arrow| {
                const function_scope = try self.addScope(.function, scope);
                for (arrow.params) |param_id| {
                    const param_node = self.ast.node(param_id);
                    switch (param_node.data) {
                        .Parameter => |param| _ = try self.declare(function_scope, param.name, .parameter, param_id, param_node.span),
                        else => {},
                    }
                }
                try self.bindParameterInitializers(arrow.params, function_scope);
                try self.bindNode(arrow.body, function_scope);
            },
            .BlockStatement => |block| {
                const block_scope = try self.addScope(.block, scope);
                for (block.statements) |statement| try self.bindNode(statement, block_scope);
            },
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration_id| try self.bindNode(declaration_id, scope);
            },
            .TypeAliasDeclaration => |decl| {
                const symbol_id = try self.declareInNamespace(scope, decl.name, .type_alias, .type, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                _ = try self.bindTypeParameters(decl.type_parameters, scope, node_id);
            },
            .InterfaceDeclaration => |decl| {
                const symbol_id = try self.declareInNamespace(scope, decl.name, .interface, .type, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                _ = try self.bindTypeParameters(decl.type_parameters, scope, node_id);
            },
            .EnumDeclaration => |decl| {
                const value_symbol = try self.declareInNamespace(scope, decl.name, .enum_, .value, node_id, node.span);
                const type_symbol = try self.declareInNamespace(scope, decl.name, .enum_, .type, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = value_symbol });
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = type_symbol });
                const enum_scope = try self.addScope(.enum_, scope);
                for (decl.members) |member| try self.bindNode(member, enum_scope);
            },
            .EnumMember => |member| {
                if (member.name.len != 0) {
                    const symbol_id = try self.declare(scope, member.name, .enum_member, node_id, node.span);
                    try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                }
                if (member.computed_name) |computed| try self.bindNode(computed, scope);
                if (member.initializer) |initializer| try self.bindNode(initializer, scope);
            },
            .VariableDeclarator => |declarator| {
                const symbol_id = try self.declare(scope, declarator.name, .variable, node_id, node.span);
                try self.node_symbols.append(self.allocator, .{ .node = node_id, .symbol = symbol_id });
                if (declarator.init) |initializer| try self.bindNode(initializer, scope);
            },
            .ReturnStatement => |return_stmt| {
                if (return_stmt.argument) |expression| try self.bindNode(expression, scope);
            },
            .ThrowStatement => |throw_stmt| try self.bindNode(throw_stmt.argument, scope),
            .TryStatement => |try_stmt| {
                try self.bindNode(try_stmt.block, scope);
                if (try_stmt.handler) |handler| try self.bindNode(handler, scope);
                if (try_stmt.finalizer) |finalizer| try self.bindNode(finalizer, scope);
            },
            .CatchClause => |catch_clause| {
                const catch_scope = try self.addScope(.block, scope);
                if (catch_clause.parameter) |parameter_id| {
                    const parameter_node = self.ast.node(parameter_id);
                    switch (parameter_node.data) {
                        .Parameter => |parameter| _ = try self.declare(catch_scope, parameter.name, .variable, parameter_id, parameter_node.span),
                        else => {},
                    }
                }
                try self.bindNode(catch_clause.body, catch_scope);
            },
            .FinallyClause => |finally_clause| try self.bindNode(finally_clause.body, scope),
            .BreakStatement, .ContinueStatement, .DebuggerStatement => {},
            .LabeledStatement => |labeled| try self.bindNode(labeled.body, scope),
            .ExpressionStatement => |statement| try self.bindNode(statement.expression, scope),
            .TemplateExpression => |template| {
                for (template.parts) |part| if (part.expression) |expression| try self.bindNode(expression, scope);
            },
            .TaggedTemplateExpression => |tagged| {
                try self.bindNode(tagged.tag, scope);
                try self.bindNode(tagged.template, scope);
            },
            .ImportExpression => |import_expr| {
                try self.bindNode(import_expr.source, scope);
                if (import_expr.options) |options| try self.bindNode(options, scope);
            },
            .MetaProperty => {},
            .RegExpLiteral => {},
            .SpreadElement => |spread| try self.bindNode(spread.argument, scope),
            .ThisExpression, .SuperExpression => {},
            .CallExpression => |call| {
                try self.bindNode(call.callee, scope);
                for (call.arguments) |arg| try self.bindNode(arg, scope);
            },
            .NewExpression => |new_expr| {
                try self.bindNode(new_expr.callee, scope);
                for (new_expr.arguments) |arg| try self.bindNode(arg, scope);
            },
            .ElementAccessExpression => |elem_access| {
                try self.bindNode(elem_access.object, scope);
                try self.bindNode(elem_access.index, scope);
            },
            .NonNullExpression => |nonnull| try self.bindNode(nonnull.expression, scope),
            .UnaryExpression => |unary| try self.bindNode(unary.argument, scope),
            .MemberExpression => |member| try self.bindNode(member.object, scope),
            .BinaryExpression => |binary| {
                try self.bindNode(binary.left, scope);
                try self.bindNode(binary.right, scope);
            },
            .SequenceExpression => |sequence| {
                for (sequence.expressions) |expression| try self.bindNode(expression, scope);
            },
            .ConditionalExpression => |conditional| {
                try self.bindNode(conditional.condition, scope);
                try self.bindNode(conditional.consequent, scope);
                try self.bindNode(conditional.alternate, scope);
            },
            .AssignmentExpression => |assignment| {
                try self.bindNode(assignment.left, scope);
                try self.bindNode(assignment.right, scope);
            },
            .IfStatement => |if_stmt| {
                try self.bindNode(if_stmt.condition, scope);
                try self.bindNode(if_stmt.consequent, scope);
                if (if_stmt.alternate) |alternate| try self.bindNode(alternate, scope);
            },
            .WhileStatement => |while_stmt| {
                try self.bindNode(while_stmt.condition, scope);
                try self.bindNode(while_stmt.body, scope);
            },
            .DoWhileStatement => |do_while_stmt| {
                try self.bindNode(do_while_stmt.body, scope);
                try self.bindNode(do_while_stmt.condition, scope);
            },
            .ForStatement => |for_stmt| {
                const loop_scope = try self.addScope(.block, scope);
                if (for_stmt.init) |init| try self.bindNode(init, loop_scope);
                if (for_stmt.condition) |condition| try self.bindNode(condition, loop_scope);
                if (for_stmt.update) |update| try self.bindNode(update, loop_scope);
                if (for_stmt.right) |right| try self.bindNode(right, loop_scope);
                try self.bindNode(for_stmt.body, loop_scope);
            },
            .SwitchStatement => |switch_stmt| {
                try self.bindNode(switch_stmt.discriminant, scope);
                const switch_scope = try self.addScope(.block, scope);
                for (switch_stmt.cases) |case| try self.bindNode(case, switch_scope);
            },
            .SwitchCase => |switch_case| {
                if (switch_case.condition) |condition| try self.bindNode(condition, scope);
                for (switch_case.consequent) |statement| try self.bindNode(statement, scope);
            },
            .ObjectExpression => |obj_expr| {
                for (obj_expr.properties) |prop| {
                    if (prop.computed_key) |key| try self.bindNode(key, scope);
                    try self.bindNode(prop.value, scope);
                }
            },
            .ArrayExpression => |arr| {
                for (arr.elements) |maybe_elem| if (maybe_elem) |elem| try self.bindNode(elem, scope);
            },
            else => {},
        }
    }

    fn addScope(self: *Binder, kind: ScopeKind, parent: ?ScopeId) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{ .id = id, .kind = kind, .parent = parent });
        return id;
    }

    fn bindTypeParameters(self: *Binder, parameters: []const ast_mod.GenericTypeParameter, parent: ScopeId, declaration: NodeId) !ScopeId {
        if (parameters.len == 0) return parent;
        const scope = try self.addScope(.type_parameters, parent);
        for (parameters) |parameter| {
            _ = try self.declareInNamespace(scope, parameter.name, .type_parameter, .type, declaration, parameter.span);
        }
        return scope;
    }

    // Defaults are traversed in the parameter scope after all names are bound.
    fn bindParameterInitializers(self: *Binder, parameters: []const NodeId, scope: ScopeId) !void {
        for (parameters) |parameter_id| switch (self.ast.node(parameter_id).data) {
            .Parameter => |parameter| if (parameter.initializer) |initializer| try self.bindNode(initializer, scope),
            else => {},
        };
    }

    fn declare(self: *Binder, scope_id: ScopeId, name: []const u8, kind: SymbolKind, declaration: NodeId, span: tokens.Span) !SymbolId {
        return self.declareInNamespace(scope_id, name, kind, .value, declaration, span);
    }

    fn declareInNamespace(self: *Binder, scope_id: ScopeId, name: []const u8, kind: SymbolKind, namespace: SymbolNamespace, declaration: NodeId, span: tokens.Span) !SymbolId {
        const scope = &self.scopes.items[@intCast(scope_id)];
        for (scope.symbols.items) |existing_id| {
            const existing = self.symbols.items[@intCast(existing_id)];
            if (existing.namespace == namespace and std.mem.eql(u8, existing.name, name)) {
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .duplicate_declaration,
                    .phase = .binder,
                    .message = "duplicate declaration",
                    .span = span,
                });
                break;
            }
        }

        const id: SymbolId = @intCast(self.symbols.items.len);
        try self.symbols.append(self.allocator, .{
            .id = id,
            .name = name,
            .kind = kind,
            .namespace = namespace,
            .scope = scope_id,
            .declaration = declaration,
            .span = span,
        });
        try scope.symbols.append(self.allocator, id);
        return id;
    }

    fn recordDeclarationExports(self: *Binder, node_id: NodeId) !void {
        const node = self.ast.node(node_id);
        switch (node.data) {
            .FunctionDeclaration => |function_decl| try self.appendExport(function_decl.name, function_decl.name, node_id),
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration_id| try self.recordDeclarationExports(declaration_id);
            },
            .VariableDeclarator => |declarator| try self.appendExport(declarator.name, declarator.name, node_id),
            .TypeAliasDeclaration => |decl| try self.appendExportDetails(decl.name, decl.name, node_id, .declaration, true, ""),
            .InterfaceDeclaration => |decl| try self.appendExportDetails(decl.name, decl.name, node_id, .declaration, true, ""),
            .EnumDeclaration => |decl| try self.appendExport(decl.name, decl.name, node_id),
            .ClassDeclaration => |decl| try self.appendExport(decl.name, decl.name, node_id),
            else => {},
        }
    }

    fn appendExport(self: *Binder, name: []const u8, local_name: []const u8, node_id: NodeId) !void {
        return self.appendExportDetails(name, local_name, node_id, .declaration, false, "");
    }

    fn appendExportDetails(self: *Binder, name: []const u8, local_name: []const u8, node_id: NodeId, kind: ast_mod.ExportKind, type_only: bool, source: []const u8) !void {
        for (self.exports.items) |export_record| {
            if (std.mem.eql(u8, export_record.name, name)) {
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .duplicate_export,
                    .phase = .binder,
                    .message = "duplicate export",
                    .span = self.ast.node(node_id).span,
                });
                return;
            }
        }

        try self.exports.append(self.allocator, .{
            .name = name,
            .local_name = local_name,
            .node = node_id,
            .kind = kind,
            .type_only = type_only,
            .source = source,
        });
    }
};

pub fn bind(allocator: std.mem.Allocator, tree: ast_mod.Ast) !BindResult {
    var binder = Binder{ .allocator = allocator, .ast = tree };
    return binder.bind();
}

fn hasSymbol(result: BindResult, name: []const u8) bool {
    for (result.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return true;
    }
    return false;
}

test "binder records imports exports scopes and declarations" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\import { log } from "console";
        \\
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    log(message);
        \\    return message;
        \\}
    ;

    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), bound.module.imports.len);
    try std.testing.expectEqual(@as(usize, 1), bound.module.exports.len);
    try std.testing.expect(hasSymbol(bound, "log"));
    try std.testing.expect(hasSymbol(bound, "main"));
    try std.testing.expect(hasSymbol(bound, "name"));
    try std.testing.expect(hasSymbol(bound, "message"));
}

test "binder binds iteration variables in loop header scopes" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\function visit(object, iterable, stream) {
        \\    for (const key in object) { key; }
        \\    for (const value of iterable) { value; }
        \\    for await (const item of stream) { item; }
        \\}
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);

    for ([_][]const u8{ "key", "value", "item" }) |name| {
        var found = false;
        for (bound.symbols) |symbol| if (std.mem.eql(u8, symbol.name, name)) {
            found = true;
            try std.testing.expectEqual(ScopeKind.block, bound.scopes[@intCast(symbol.scope)].kind);
        };
        try std.testing.expect(found);
    }
}

test "binder separates type declarations from values and rejects type duplicates" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\export type User = { name: string };
        \\interface Profile { name: string; age?: number; }
        \\export interface Admin extends User, Profile {}
        \\const User = "value";
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const alias_id = parsed.ast.node(statements[0]).data.ExportDeclaration.declaration;
    const alias = parsed.ast.node(alias_id).data.TypeAliasDeclaration;
    const alias_members = parsed.ast.typeNode(alias.type_annotation.root).data.Object;
    try std.testing.expectEqualStrings("name", alias_members[0].name);

    const profile = parsed.ast.node(statements[1]).data.InterfaceDeclaration;
    try std.testing.expect(parsed.ast.typeNode(profile.body).data.Object[1].optional);
    const admin_id = parsed.ast.node(statements[2]).data.ExportDeclaration.declaration;
    const admin = parsed.ast.node(admin_id).data.InterfaceDeclaration;
    try std.testing.expectEqual(@as(usize, 2), admin.extends.len);
    try std.testing.expectEqualStrings("User", parsed.ast.typeNode(admin.extends[0]).data.Named.name);

    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    var type_user = false;
    var value_user = false;
    for (bound.symbols) |symbol| if (std.mem.eql(u8, symbol.name, "User")) {
        type_user = type_user or symbol.namespace == .type;
        value_user = value_user or symbol.namespace == .value;
    };
    try std.testing.expect(type_user and value_user);
    try std.testing.expectEqual(@as(usize, 2), bound.module.exports.len);
    try std.testing.expect(bound.module.exports[0].type_only);
    try std.testing.expect(bound.module.exports[1].type_only);

    const duplicate_scan = try scanner.scanAll(allocator, "type Same = string; interface Same {}", true);
    const duplicate_parse = try parser.parse(allocator, duplicate_scan.tokens, .{});
    const duplicate_bound = try bind(allocator, duplicate_parse.ast);
    try std.testing.expectEqual(@as(usize, 1), duplicate_bound.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_declaration, duplicate_bound.diagnostics[0].code);
}

test "classes bind dual declarations member and function scopes" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    const resolver = @import("resolver.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator,
        \\class User {
        \\  public name: string;
        \\  constructor(name: string) { this.name = name; }
        \\  greet(): string { return this.name; }
        \\  static count: number = 0;
        \\}
        \\class Admin extends User {}
        \\const Factory = class Named extends User { protected build() { return super.greet(); } };
    , true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var user_value = false;
    var user_type = false;
    var class_scopes: usize = 0;
    var function_scopes: usize = 0;
    for (bound.symbols) |symbol| if (std.mem.eql(u8, symbol.name, "User")) {
        user_value = user_value or symbol.namespace == .value;
        user_type = user_type or symbol.namespace == .type;
    };
    for (bound.scopes) |scope| switch (scope.kind) {
        .class => class_scopes += 1,
        .function => function_scopes += 1,
        else => {},
    };
    try std.testing.expect(user_value and user_type);
    try std.testing.expectEqual(@as(usize, 3), class_scopes);
    try std.testing.expectEqual(@as(usize, 3), function_scopes);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const user = parsed.ast.node(statements[0]).data.ClassDeclaration;
    try std.testing.expectEqual(@as(usize, 4), user.members.len);
    try std.testing.expectEqual(ast_mod.AccessModifier.public, parsed.ast.node(user.members[0]).data.ClassField.access);
    try std.testing.expectEqual(ast_mod.ClassMethodKind.constructor, parsed.ast.node(user.members[1]).data.ClassMethod.kind);
    try std.testing.expect(parsed.ast.node(user.members[3]).data.ClassField.is_static);
    try std.testing.expect(parsed.ast.node(statements[1]).data.ClassDeclaration.super_class != null);
}

test "constructor parameter properties bind class members and diagnose conflicts" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator, "class Item { constructor(public name: string, readonly id: number) {} }", true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    var property_count: usize = 0;
    for (bound.symbols) |symbol| if (symbol.kind == .field and (std.mem.eql(u8, symbol.name, "name") or std.mem.eql(u8, symbol.name, "id"))) {
        property_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), property_count);

    const duplicate_scan = try scanner.scanAll(allocator, "class Conflict { name: string; constructor(public name: string) {} }", true);
    const duplicate_parse = try parser.parse(allocator, duplicate_scan.tokens, .{});
    const duplicate_bound = try bind(allocator, duplicate_parse.ast);
    try std.testing.expectEqual(@as(usize, 1), duplicate_bound.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_declaration, duplicate_bound.diagnostics[0].code);
}

test "enums bind value type and member namespaces" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator, "export enum Direction { Up, Down = Up }", true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    var value = false;
    var type_symbol = false;
    var enum_scope = false;
    for (bound.symbols) |symbol| if (std.mem.eql(u8, symbol.name, "Direction")) {
        value = value or symbol.namespace == .value;
        type_symbol = type_symbol or symbol.namespace == .type;
    };
    for (bound.scopes) |scope| {
        if (scope.kind == .enum_) enum_scope = true;
    }
    try std.testing.expect(value and type_symbol and enum_scope);
    try std.testing.expectEqual(@as(usize, 1), bound.module.exports.len);

    const duplicate_scan = try scanner.scanAll(allocator, "enum E { Same, Same }", true);
    const duplicate_parse = try parser.parse(allocator, duplicate_scan.tokens, .{});
    const duplicate_bound = try bind(allocator, duplicate_parse.ast);
    try std.testing.expectEqual(@as(usize, 1), duplicate_bound.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_declaration, duplicate_bound.diagnostics[0].code);
}

test "generic declarations bind ordered type parameter scopes" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scan = try scanner.scanAll(allocator, "export function outer<T, T>() { class Nested<U> {} } type Pair<A, B> = [A, B];", true);
    const parsed = try parser.parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const bound = try bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 1), bound.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_declaration, bound.diagnostics[0].code);

    var type_parameter_symbols: usize = 0;
    var type_parameter_scopes: usize = 0;
    for (bound.symbols) |symbol| {
        if (symbol.kind == .type_parameter) {
            type_parameter_symbols += 1;
            try std.testing.expectEqual(SymbolNamespace.type, symbol.namespace);
        }
    }
    for (bound.scopes) |scope| if (scope.kind == .type_parameters) {
        type_parameter_scopes += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), type_parameter_symbols);
    try std.testing.expectEqual(@as(usize, 3), type_parameter_scopes);
    try std.testing.expectEqual(@as(usize, 1), bound.module.exports.len);
}
