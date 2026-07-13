const std = @import("std");
const ast_mod = @import("ast.zig");
const binder = @import("binder.zig");
const diagnostics = @import("../diagnostics/root.zig");
const tokens = @import("tokens.zig");

const NodeId = ast_mod.NodeId;

/// Hardcoded ambient globals (predeclared, no-stdlib style).
/// Future: load from external declarations / lib files / `ambient_globals` option.
const PredeclaredAmbients: []const []const u8 = &.{
    "console",
};

pub const ReferenceId = u32;

pub const ReferenceKind = enum {
    read,
    write,
    call,
    export_ref,
};

pub const Reference = struct {
    node: NodeId,
    name: []const u8,
    symbol: ?binder.SymbolId,
    scope: binder.ScopeId,
    kind: ReferenceKind,
    span: tokens.Span,
};

pub const ResolveResult = struct {
    references: []const Reference,
    diagnostics: []const diagnostics.Diagnostic,

    pub fn deinit(self: *ResolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.references);
        allocator.free(self.diagnostics);
        self.* = .{ .references = &.{}, .diagnostics = &.{} };
    }
};

const Resolver = struct {
    allocator: std.mem.Allocator,
    ast: ast_mod.Ast,
    bind: binder.BindResult,
    references: std.ArrayList(Reference) = .empty,
    diagnostic_list: std.ArrayList(diagnostics.Diagnostic) = .empty,
    next_scope: binder.ScopeId = 1,

    fn resolve(self: *Resolver) !ResolveResult {
        if (self.bind.scopes.len == 0) {
            return .{
                .references = try self.references.toOwnedSlice(self.allocator),
                .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
            };
        }

        try self.resolveNode(self.ast.root, 0);
        return .{
            .references = try self.references.toOwnedSlice(self.allocator),
            .diagnostics = try self.diagnostic_list.toOwnedSlice(self.allocator),
        };
    }

    fn resolveNode(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) anyerror!void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Program => |program| {
                for (program.statements) |statement| try self.resolveNode(statement, scope);
            },
            .ImportDeclaration => {},
            .ExportDeclaration => |export_decl| {
                if (export_decl.declaration != ast_mod.invalid_node) {
                    try self.resolveNode(export_decl.declaration, scope);
                } else if (export_decl.expression != ast_mod.invalid_node) {
                    try self.resolveNode(export_decl.expression, scope);
                } else if (export_decl.source.len == 0) {
                    for (export_decl.specifiers) |specifier| {
                        const local_node = if (specifier.local != ast_mod.invalid_node) specifier.local else node_id;
                        try self.addReference(local_node, specifier.local_name, scope, .export_ref);
                    }
                }
            },
            .FunctionDeclaration => |function_decl| {
                const function_scope = self.takeScope();
                for (function_decl.params) |_| {}
                try self.resolveNode(function_decl.body, function_scope);
            },
            .FunctionExpression => |function_expr| {
                const function_scope = self.takeScope();
                try self.resolveNode(function_expr.body, function_scope);
            },
            .ClassDeclaration => |class_decl| {
                if (class_decl.super_class) |super_class| try self.resolveNode(super_class, scope);
                const class_scope = self.takeScope();
                for (class_decl.members) |member| try self.resolveNode(member, class_scope);
            },
            .ClassExpression => |class_expr| {
                if (class_expr.super_class) |super_class| try self.resolveNode(super_class, scope);
                const class_scope = self.takeScope();
                for (class_expr.members) |member| try self.resolveNode(member, class_scope);
            },
            .ClassField => |field| {
                if (field.initializer) |initializer| try self.resolveNode(initializer, scope);
            },
            .ClassMethod => |method| {
                const function_scope = self.takeScope();
                try self.resolveNode(method.body, function_scope);
            },
            .ArrowFunctionExpression => |arrow| {
                const function_scope = self.takeScope();
                try self.resolveNode(arrow.body, function_scope);
            },
            .BlockStatement => |block| {
                const block_scope = self.takeScope();
                for (block.statements) |statement| try self.resolveNode(statement, block_scope);
            },
            .VariableDeclaration => |var_decl| {
                for (var_decl.declarations) |declaration| try self.resolveNode(declaration, scope);
            },
            .TypeAliasDeclaration, .InterfaceDeclaration => {},
            .VariableDeclarator => |declarator| {
                if (declarator.init) |initializer| try self.resolveNode(initializer, scope);
            },
            .Parameter => {},
            .SpreadElement => |spread| try self.resolveNode(spread.argument, scope),
            .ReturnStatement => |return_stmt| {
                if (return_stmt.argument) |expression| try self.resolveNode(expression, scope);
            },
            .ThrowStatement => |throw_stmt| try self.resolveNode(throw_stmt.argument, scope),
            .TryStatement => |try_stmt| {
                try self.resolveNode(try_stmt.block, scope);
                if (try_stmt.handler) |handler| try self.resolveNode(handler, scope);
                if (try_stmt.finalizer) |finalizer| try self.resolveNode(finalizer, scope);
            },
            .CatchClause => |catch_clause| {
                const catch_scope = self.takeScope();
                try self.resolveNode(catch_clause.body, catch_scope);
            },
            .FinallyClause => |finally_clause| try self.resolveNode(finally_clause.body, scope),
            .BreakStatement, .ContinueStatement => {},
            .ExpressionStatement => |statement| try self.resolveNode(statement.expression, scope),
            .Identifier => |identifier| try self.addReference(node_id, identifier.name, scope, .read),
            .ThisExpression, .SuperExpression => {},
            .Literal => {},
            .RegExpLiteral => {},
            .TemplateExpression => |template| {
                for (template.parts) |part| if (part.expression) |expression| try self.resolveNode(expression, scope);
            },
            .TaggedTemplateExpression => |tagged| {
                try self.resolveCallee(tagged.tag, scope);
                try self.resolveNode(tagged.template, scope);
            },
            .ImportExpression => |import_expr| {
                try self.resolveNode(import_expr.source, scope);
                if (import_expr.options) |options| try self.resolveNode(options, scope);
            },
            .MetaProperty => {},
            .CallExpression => |call| {
                _ = call.optional; // Syntax metadata only; resolution traverses both call forms identically.
                try self.resolveCallee(call.callee, scope);
                for (call.arguments) |arg| try self.resolveNode(arg, scope);
            },
            .NewExpression => |new_expr| {
                try self.resolveCallee(new_expr.callee, scope);
                for (new_expr.arguments) |arg| try self.resolveNode(arg, scope);
            },
            .ElementAccessExpression => |elem_access| {
                _ = elem_access.optional; // Optionality has no nullability semantics yet.
                try self.resolveNode(elem_access.object, scope);
                try self.resolveNode(elem_access.index, scope);
            },
            .AsExpression => |as_expr| {
                // Resolve only the inner expression; do NOT resolve type_annotation as a value.
                _ = as_expr.type_annotation; // type names are not resolved at runtime
                try self.resolveNode(as_expr.expression, scope);
            },
            .SatisfiesExpression => |satisfies_expr| {
                _ = satisfies_expr.type_annotation;
                try self.resolveNode(satisfies_expr.expression, scope);
            },
            .NonNullExpression => |nonnull| try self.resolveNode(nonnull.expression, scope),
            .UnaryExpression => |unary| try self.resolveNode(unary.argument, scope),
            .MemberExpression => |member| {
                _ = member.optional; // Preserve syntax while resolving the same object reference.
                try self.resolveNode(member.object, scope);
            },
            .BinaryExpression => |binary| {
                try self.resolveNode(binary.left, scope);
                try self.resolveNode(binary.right, scope);
            },
            .SequenceExpression => |sequence| {
                for (sequence.expressions) |expression| try self.resolveNode(expression, scope);
            },
            .ConditionalExpression => |conditional| {
                try self.resolveNode(conditional.condition, scope);
                try self.resolveNode(conditional.consequent, scope);
                try self.resolveNode(conditional.alternate, scope);
            },
            .UpdateExpression => |update_expr| {
                _ = update_expr.prefix;
                try self.resolveUpdateTarget(update_expr.argument, scope);
            },
            .AssignmentExpression => |assignment| {
                try self.resolveAssignmentTarget(assignment.left, scope, assignment.operator != .Equal);
                try self.resolveNode(assignment.right, scope);
            },
            .IfStatement => |if_stmt| {
                try self.resolveNode(if_stmt.condition, scope);
                try self.resolveNode(if_stmt.consequent, scope);
                if (if_stmt.alternate) |alternate| try self.resolveNode(alternate, scope);
            },
            .WhileStatement => |while_stmt| {
                try self.resolveNode(while_stmt.condition, scope);
                try self.resolveNode(while_stmt.body, scope);
            },
            .DoWhileStatement => |do_while_stmt| {
                try self.resolveNode(do_while_stmt.body, scope);
                try self.resolveNode(do_while_stmt.condition, scope);
            },
            .ForStatement => |for_stmt| {
                const loop_scope = self.takeScope();
                if (for_stmt.init) |init| try self.resolveNode(init, loop_scope);
                if (for_stmt.condition) |condition| try self.resolveNode(condition, loop_scope);
                if (for_stmt.update) |update| try self.resolveNode(update, loop_scope);
                if (for_stmt.right) |right| try self.resolveNode(right, loop_scope);
                try self.resolveNode(for_stmt.body, loop_scope);
            },
            .SwitchStatement => |switch_stmt| {
                try self.resolveNode(switch_stmt.discriminant, scope);
                const switch_scope = self.takeScope();
                for (switch_stmt.cases) |case| try self.resolveNode(case, switch_scope);
            },
            .SwitchCase => |switch_case| {
                if (switch_case.condition) |condition| try self.resolveNode(condition, scope);
                for (switch_case.consequent) |statement| try self.resolveNode(statement, scope);
            },
            .ObjectExpression => |obj_expr| {
                for (obj_expr.properties) |prop| {
                    if (prop.computed_key) |key| try self.resolveNode(key, scope);
                    try self.resolveNode(prop.value, scope);
                }
            },
            .ArrayExpression => |arr| {
                for (arr.elements) |maybe_elem| if (maybe_elem) |elem| try self.resolveNode(elem, scope);
            },
        }
    }

    fn resolveCallee(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) !void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Identifier => |identifier| try self.addReference(node_id, identifier.name, scope, .call),
            .ElementAccessExpression => |elem_access| try self.resolveNode(elem_access.object, scope),
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            else => try self.resolveNode(node_id, scope),
        }
    }

    fn resolveAssignmentTarget(self: *Resolver, node_id: NodeId, scope: binder.ScopeId, read_before_write: bool) !void {
        if (node_id == ast_mod.invalid_node) return;
        const node = self.ast.node(node_id);
        switch (node.data) {
            .Identifier => |identifier| {
                if (read_before_write) try self.addReference(node_id, identifier.name, scope, .read);
                try self.addReference(node_id, identifier.name, scope, .write);
            },
            .ElementAccessExpression => |elem_access| {
                try self.resolveNode(elem_access.object, scope);
                try self.resolveNode(elem_access.index, scope);
            },
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            else => try self.resolveNode(node_id, scope),
        }
    }

    fn resolveUpdateTarget(self: *Resolver, node_id: NodeId, scope: binder.ScopeId) !void {
        if (node_id == ast_mod.invalid_node) return;
        switch (self.ast.node(node_id).data) {
            .Identifier => |identifier| {
                try self.addReference(node_id, identifier.name, scope, .read);
                try self.addReference(node_id, identifier.name, scope, .write);
            },
            .ElementAccessExpression => |element| {
                try self.resolveNode(element.object, scope);
                try self.resolveNode(element.index, scope);
            },
            .MemberExpression => |member| try self.resolveNode(member.object, scope),
            else => try self.resolveNode(node_id, scope),
        }
    }

    fn addReference(self: *Resolver, node_id: NodeId, name: []const u8, scope: binder.ScopeId, kind: ReferenceKind) !void {
        if (name.len == 0) return;
        const node = self.ast.node(node_id);
        const symbol = self.lookup(scope, name);
        try self.references.append(self.allocator, .{
            .node = node_id,
            .name = name,
            .symbol = symbol,
            .scope = scope,
            .kind = kind,
            .span = node.span,
        });

        if (symbol == null) {
            const is_ambient: bool = blk: for (PredeclaredAmbients) |ambient| {
                if (std.mem.eql(u8, ambient, name)) break :blk true;
            } else false;
            if (!is_ambient) {
                const message = try std.fmt.allocPrint(self.allocator, "cannot find name '{s}'", .{name});
                try self.diagnostic_list.append(self.allocator, .{
                    .severity = .@"error",
                    .code = .cannot_find_name,
                    .phase = .resolver,
                    .message = message,
                    .span = node.span,
                    .label = "name is not declared in this scope",
                });
            }
        }
    }

    fn lookup(self: *Resolver, start_scope: binder.ScopeId, name: []const u8) ?binder.SymbolId {
        var scope_id: ?binder.ScopeId = start_scope;
        while (scope_id) |id| {
            const scope = self.bind.scopes[@intCast(id)];
            for (scope.symbols) |symbol_id| {
                const symbol = self.bind.symbols[@intCast(symbol_id)];
                if (std.mem.eql(u8, symbol.name, name)) return symbol_id;
            }
            scope_id = scope.parent;
        }
        return null;
    }

    fn takeScope(self: *Resolver) binder.ScopeId {
        const scope = self.next_scope;
        self.next_scope += 1;
        return scope;
    }
};

pub fn resolve(allocator: std.mem.Allocator, tree: ast_mod.Ast, bound: binder.BindResult) !ResolveResult {
    var resolver = Resolver{
        .allocator = allocator,
        .ast = tree,
        .bind = bound,
    };
    return resolver.resolve();
}

test "resolver distinguishes plain and compound assignment references" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let value = 0;
        \\let next = 1;
        \\let object = [value];
        \\let index = 0;
        \\value = next;
        \\value += next;
        \\value &= next;
        \\value &&= next;
        \\value ||= next;
        \\value ??= next;
        \\object[index] += next;
    ;
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var value_reads: usize = 0;
    var value_writes: usize = 0;
    var object_reads: usize = 0;
    var index_reads: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "value")) switch (reference.kind) {
            .read => value_reads += 1,
            .write => value_writes += 1,
            else => {},
        };
        if (std.mem.eql(u8, reference.name, "object") and reference.kind == .read) object_reads += 1;
        if (std.mem.eql(u8, reference.name, "index") and reference.kind == .read) index_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), value_reads);
    try std.testing.expectEqual(@as(usize, 6), value_writes);
    try std.testing.expectEqual(@as(usize, 1), object_reads);
    try std.testing.expectEqual(@as(usize, 1), index_reads);
}

test "resolver visits only the value side of satisfies expressions" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\let value = 1;
        \\const checked = value satisfies MissingType;
    , true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var value_reads: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "value") and reference.kind == .read) value_reads += 1;
        try std.testing.expect(!std.mem.eql(u8, reference.name, "MissingType"));
    }
    try std.testing.expectEqual(@as(usize, 1), value_reads);
}

test "resolver visits tagged template tag and interpolations" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\let name = "x";
        \\tag`<p>${name}</p>`;
        \\obj.tag`text`;
    , true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);

    var tag_calls: usize = 0;
    var name_reads: usize = 0;
    var obj_reads: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "tag") and reference.kind == .call) tag_calls += 1;
        if (std.mem.eql(u8, reference.name, "name") and reference.kind == .read) name_reads += 1;
        if (std.mem.eql(u8, reference.name, "obj") and reference.kind == .read) obj_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tag_calls);
    try std.testing.expectEqual(@as(usize, 1), name_reads);
    try std.testing.expectEqual(@as(usize, 1), obj_reads);
}

test "resolver visits dynamic import source and options" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scanned = try scanner.scanAll(allocator, "import(specifier, attributes);", true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    var source_reads: usize = 0;
    var options_reads: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "specifier") and reference.kind == .read) source_reads += 1;
        if (std.mem.eql(u8, reference.name, "attributes") and reference.kind == .read) options_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), source_reads);
    try std.testing.expectEqual(@as(usize, 1), options_reads);
}

test "resolver does not create references for meta-properties" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scanned = try scanner.scanAll(allocator, "import.meta.url; function f() { return new.target; }", true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.references.len);
}

test "resolver visits prefix unary operands" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let value = 1;
        \\let object = { key: value };
        \\function fn() { return value; }
        \\let a = !-value;
        \\let b = typeof object.key;
        \\let c = await fn();
    ;
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var saw_value = false;
    var saw_object = false;
    var saw_fn_call = false;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "value") and reference.kind == .read) saw_value = true;
        if (std.mem.eql(u8, reference.name, "object") and reference.kind == .read) saw_object = true;
        if (std.mem.eql(u8, reference.name, "fn") and reference.kind == .call) saw_fn_call = true;
    }
    try std.testing.expect(saw_value);
    try std.testing.expect(saw_object);
    try std.testing.expect(saw_fn_call);
}

test "resolver treats update targets as read-modify-write" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let i = 0;
        \\let object = { value: i };
        \\let items = [i];
        \\let index = 0;
        \\++i;
        \\i--;
        \\++object.value;
        \\--items[index];
    ;
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var i_reads: usize = 0;
    var i_writes: usize = 0;
    var object_reads: usize = 0;
    var items_reads: usize = 0;
    var index_reads: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, "i")) switch (reference.kind) {
            .read => i_reads += 1,
            .write => i_writes += 1,
            else => {},
        };
        if (std.mem.eql(u8, reference.name, "object") and reference.kind == .read) object_reads += 1;
        if (std.mem.eql(u8, reference.name, "items") and reference.kind == .read) items_reads += 1;
        if (std.mem.eql(u8, reference.name, "index") and reference.kind == .read) index_reads += 1;
    }
    try std.testing.expect(i_reads >= 4);
    try std.testing.expectEqual(@as(usize, 2), i_writes);
    try std.testing.expectEqual(@as(usize, 1), object_reads);
    try std.testing.expectEqual(@as(usize, 1), items_reads);
    try std.testing.expectEqual(@as(usize, 1), index_reads);
}

test "resolver visits every conditional expression branch" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let condition = true;
        \\let consequent = 1;
        \\let alternate = 2;
        \\let result = condition ? consequent : alternate;
    ;
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    var condition_seen = false;
    var consequent_seen = false;
    var alternate_seen = false;
    for (resolved.references) |reference| {
        if (reference.kind != .read) continue;
        if (std.mem.eql(u8, reference.name, "condition")) condition_seen = true;
        if (std.mem.eql(u8, reference.name, "consequent")) consequent_seen = true;
        if (std.mem.eql(u8, reference.name, "alternate")) alternate_seen = true;
    }
    try std.testing.expect(condition_seen);
    try std.testing.expect(consequent_seen);
    try std.testing.expect(alternate_seen);
}

test "resolver keeps catch binding inside catch scope" {
    const scanner = @import("scanner.zig");
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\try {} catch (caught) { caught; }
        \\caught;
    , true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolve(allocator, parsed.ast, bound);

    var catch_symbol: ?binder.Symbol = null;
    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "caught")) catch_symbol = symbol;
    }
    try std.testing.expect(catch_symbol != null);
    try std.testing.expect(catch_symbol.?.scope != 0);
    try std.testing.expectEqual(binder.ScopeKind.block, bound.scopes[@intCast(catch_symbol.?.scope)].kind);
    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, resolved.diagnostics[0].code);

    var bound_reads: usize = 0;
    var unresolved_reads: usize = 0;
    for (resolved.references) |reference| {
        if (!std.mem.eql(u8, reference.name, "caught")) continue;
        if (reference.symbol == catch_symbol.?.id) bound_reads += 1;
        if (reference.symbol == null) unresolved_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bound_reads);
    try std.testing.expectEqual(@as(usize, 1), unresolved_reads);
}
