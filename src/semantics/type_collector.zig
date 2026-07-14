const std = @import("std");
const frontend = @import("../frontend/frontend.zig");
const ast_mod = @import("../frontend/ast.zig");
const binder = @import("../frontend/binder.zig");
const builtin_kind = @import("../types/builtin.zig");
const diagnostics_mod = @import("../diagnostics/root.zig");
const types = @import("../types/root.zig");
const type_inference = @import("type_inference.zig");
const type_compat = @import("type_compat.zig");
const type_info_mod = @import("type_info.zig");

pub const DeclaredSymbolType = struct {
    symbol_id: binder.SymbolId,
    declared_type: ?types.TypeId,
};

/// Project-owned type identity made visible by one import binding. A missing
/// target uses `unknown` as a cycle-safe placeholder and emits no local-name
/// diagnostic while module linking is incomplete.
pub const ImportedTypeBinding = struct {
    local_name: []const u8,
    symbol_id: ?binder.SymbolId,
    type_id: types.TypeId,
    declaration: ?types.SemanticDeclId = null,
    placeholder: bool = false,
};

pub const FunctionSignatureEntry = struct {
    symbol_id: binder.SymbolId,
    signature_id: types.TypeId,
    resolved_return_type: ?types.TypeId = null,
};

pub const TypeInfoCollectResult = struct {
    symbol_declared_types: []const DeclaredSymbolType,
    function_signatures: []const FunctionSignatureEntry,
    resolved_type_nodes: []const type_info_mod.ResolvedTypeNode,
    diagnostics: []const diagnostics_mod.Diagnostic,

    pub fn hasAny(self: TypeInfoCollectResult) bool {
        return self.function_signatures.len > 0;
    }
};

pub const UnresolvedTypeReason = enum {
    unknown_name,
    value_only,
    unavailable_declaration,
};

/// Structured type-name lookup. Local resolutions retain the binder SymbolId
/// and module-qualified declaration identity instead of degrading to strings.
pub const TypeNameResolution = union(enum) {
    resolved: struct {
        type_id: types.TypeId,
        symbol_id: ?binder.SymbolId = null,
        declaration: ?types.SemanticDeclId = null,
    },
    unresolved: struct {
        name: []const u8,
        reason: UnresolvedTypeReason,
    },
};

/// Inputs and mutable semantic state needed to resolve one annotation.
pub const TypeResolutionContext = struct {
    allocator: std.mem.Allocator,
    current_module: u32,
    scope: binder.ScopeId,
    symbols: []const binder.Symbol,
    scopes: []const binder.Scope,
    semantic_symbol_types: *std.ArrayList(DeclaredSymbolType),
    value_symbol_types: []const type_info_mod.SymbolTypeInfo,
    resolved_type_nodes: *std.ArrayList(type_info_mod.ResolvedTypeNode),
    diagnostics: *std.ArrayList(diagnostics_mod.Diagnostic),
    source_path: ?[]const u8,
    tree: ast_mod.Ast,
    type_store: *types.TypeStore,
    alias_states: []u8,
    imported_types: []const ImportedTypeBinding,
    bind: binder.BindResult,
};

pub fn collectDeclaredTypes(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    type_store: *types.TypeStore,
) !TypeInfoCollectResult {
    return collectDeclaredTypesInModule(allocator, source, tree, bind, 0, type_store);
}

pub fn collectDeclaredTypesInModule(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    module_id: u32,
    type_store: *types.TypeStore,
) !TypeInfoCollectResult {
    return collectDeclaredTypesInModuleWithImports(allocator, source, tree, bind, module_id, type_store, &.{}, true);
}

pub fn collectDeclaredTypesInModuleWithImports(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    module_id: u32,
    type_store: *types.TypeStore,
    imported_types: []const ImportedTypeBinding,
    complete_nominals: bool,
) !TypeInfoCollectResult {
    return collectDeclaredTypesInModuleWithImportsAndValues(
        allocator, source, tree, bind, module_id, type_store, imported_types, &.{}, complete_nominals,
    );
}

pub fn collectDeclaredTypesInModuleWithImportsAndValues(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    tree: ast_mod.Ast,
    bind: binder.BindResult,
    module_id: u32,
    type_store: *types.TypeStore,
    imported_types: []const ImportedTypeBinding,
    value_symbol_types: []const type_info_mod.SymbolTypeInfo,
    complete_nominals: bool,
) !TypeInfoCollectResult {
    var diagnostics: std.ArrayList(diagnostics_mod.Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);
    var signatures: std.ArrayList(FunctionSignatureEntry) = .empty;
    errdefer signatures.deinit(allocator);
    var declared: std.ArrayList(DeclaredSymbolType) = .empty;
    errdefer declared.deinit(allocator);
    var resolved_type_nodes: std.ArrayList(type_info_mod.ResolvedTypeNode) = .empty;
    errdefer resolved_type_nodes.deinit(allocator);
    const alias_states = try allocator.alloc(u8, bind.symbols.len);
    @memset(alias_states, 0);

    var context: TypeResolutionContext = .{
        .allocator = allocator,
        .current_module = module_id,
        .scope = 0,
        .symbols = bind.symbols,
        .scopes = bind.scopes,
        .semantic_symbol_types = &declared,
        .value_symbol_types = value_symbol_types,
        .resolved_type_nodes = &resolved_type_nodes,
        .diagnostics = &diagnostics,
        .source_path = source.path,
        .tree = tree,
        .type_store = type_store,
        .alias_states = alias_states,
        .imported_types = imported_types,
        .bind = bind,
    };

    // Declaration identities exist before annotations are resolved. A class
    // binds a constructor value and a distinct instance type; enums still share
    // one nominal TypeId across their value/type namespaces.
    for (bind.symbols) |symbol| {
        if (symbol.namespace != .type) continue;
        const identity = types.SemanticDeclId.init(module_id, symbol.declaration);
        switch (symbol.kind) {
            .class => {
                const class_type = try type_store.createClassSemanticType(identity, symbol.name);
                for (bind.symbols) |peer| {
                    if (peer.declaration == symbol.declaration and peer.kind == .class) try putDeclared(
                        &declared,
                        allocator,
                        peer.id,
                        if (peer.namespace == .value) class_type.constructor_type else class_type.instance_type,
                    );
                }
            },
            .interface => {
                const interface_type = try type_store.createInterfaceSemanticType(identity, symbol.name);
                try putDeclared(&declared, allocator, symbol.id, interface_type.type_id);
            },
            .enum_ => {
                const type_id = try type_store.intern(.{ .enum_type = .{ .identity = identity, .name = symbol.name } });
                try putDeclared(&declared, allocator, symbol.id, type_id);
                for (bind.symbols) |peer| {
                    if (peer.declaration == symbol.declaration and peer.kind == symbol.kind)
                        try putDeclared(&declared, allocator, peer.id, type_id);
                }
            },
            else => {},
        }
    }

    // Class expressions have the same module-qualified nominal identity as
    // declarations, even when anonymous. A named expression's private value
    // symbol points at its constructor; the instance identity remains distinct.
    for (tree.nodes, 0..) |node, raw_id| switch (node.data) {
        .ClassExpression => |class_expression| {
            const node_id: ast_mod.NodeId = @intCast(raw_id);
            const class_type = try type_store.createClassSemanticType(
                types.SemanticDeclId.init(module_id, node_id),
                class_expression.name orelse "<anonymous class>",
            );
            for (bind.symbols) |symbol| {
                if (symbol.declaration == node_id and symbol.kind == .class)
                    try putDeclared(&declared, allocator, symbol.id, class_type.constructor_type);
            }
        },
        else => {},
    };

    // Generic names are declaration identities, not spelling-based aliases.
    // Predeclare the complete environment so references among parameters and
    // all parameter/return annotations share one stable TypeId.
    for (bind.symbols) |symbol| {
        if (symbol.kind != .type_parameter or symbol.namespace != .type) continue;
        const type_id = try type_store.intern(.{ .type_parameter = .{
            .identity = types.SemanticDeclId.init(module_id, symbol.declaration),
            .parameter_id = symbol.id,
            .name = symbol.name,
        } });
        try putDeclared(&declared, allocator, symbol.id, type_id);
    }

    // Register every generic declaration before resolving any constraint,
    // default, or alias body. Imported modules share this project TypeStore,
    // so declaration identity is also the cross-module arity contract.
    for (bind.symbols) |symbol| {
        if (symbol.namespace != .type or
            (symbol.kind != .type_alias and symbol.kind != .interface and symbol.kind != .class)) continue;
        const parameters = genericTypeParameters(tree, symbol.declaration) orelse continue;
        if (parameters.len == 0) continue;
        const generic_parameters = try collectGenericParameterShells(&context, symbol.declaration, parameters);
        const template_type = declaredType(declared.items, symbol.id) orelse type_store.builtins.unknown;
        try type_store.registerGenericDeclaration(
            types.SemanticDeclId.init(module_id, symbol.declaration),
            template_type,
            generic_parameters,
        );
    }

    // Resolve constraints and defaults in declaration order. Defaults may use
    // earlier parameters; later instantiation substitutes those bindings.
    for (bind.symbols) |symbol| {
        if (symbol.namespace != .type or
            (symbol.kind != .type_alias and symbol.kind != .interface and symbol.kind != .class)) continue;
        const parameters = genericTypeParameters(tree, symbol.declaration) orelse continue;
        if (parameters.len == 0) continue;
        context.scope = declarationTypeScope(&context, symbol.declaration, symbol.scope);
        const metadata = try resolveGenericParameterMetadata(&context, symbol.declaration, parameters);
        const identity = types.SemanticDeclId.init(module_id, symbol.declaration);
        const declaration = type_store.lookupGenericDeclaration(identity) orelse continue;
        try type_store.updateGenericDeclaration(identity, declaration.template_type, metadata);
    }
    if (complete_nominals) {
        // Only the designated final declaration pass completes nominal tables.
        // Indexed access and keyof then consume the immutable canonical tables.
        for (tree.nodes, 0..) |node, raw_id| switch (node.data) {
            .ClassExpression => |class_expression| try collectClassBody(
                &context,
                @intCast(raw_id),
                class_expression.members,
                class_expression.super_class,
                classBodyScope(bind, @intCast(raw_id), class_expression.members),
                &signatures,
            ),
            else => {},
        };

        // No compatibility or override checks belong in this pass.
        for (bind.symbols) |symbol| {
            if (symbol.namespace != .type) continue;
            switch (symbol.kind) {
                .class => try collectClassMembers(&context, symbol, &signatures),
                .interface => try collectInterfaceMembers(&context, symbol),
                else => {},
            }
        }
    }

    // Resolve aliases after all nominal identities and member tables are
    // available. Recursion in ensureSymbolType supports forward aliases and
    // breaks cycles to unknown.
    for (bind.symbols) |symbol| {
        if (symbol.kind == .type_alias and symbol.namespace == .type) {
            context.scope = declarationTypeScope(&context, symbol.declaration, symbol.scope);
            _ = try ensureSymbolType(&context, symbol.id) orelse continue;
        }
    }

    for (bind.symbols) |symbol| {
        // Type-parameter symbols point at their owning declaration. They were
        // predeclared above and must not collect that function a second time.
        if (symbol.kind == .type_parameter) continue;
        context.scope = symbol.scope;
        const node = tree.node(symbol.declaration);
        switch (node.data) {
            .VariableDeclarator => |declaration| if (declaration.type_annotation) |annotation| {
                try putDeclared(&declared, allocator, symbol.id, try resolveTypeAnnotation(&context, annotation));
            },
            .FunctionDeclaration => |declaration| {
                var parameters: std.ArrayList(types.ParameterType) = .empty;
                defer parameters.deinit(allocator);
                for (declaration.params) |parameter_id| {
                    const parameter = switch (tree.node(parameter_id).data) {
                        .Parameter => |value| value,
                        else => continue,
                    };
                    const parameter_symbol = findDeclarationSymbol(bind.symbols, parameter_id, .parameter);
                    context.scope = if (parameter_symbol) |value| value.scope else symbol.scope;
                    const type_id = if (parameter.type_annotation) |annotation|
                        try resolveTypeAnnotation(&context, annotation)
                    else
                        type_store.builtins.unknown;
                    try parameters.append(allocator, .{
                        .name = parameter.name,
                        .type_id = type_id,
                        .optional = parameter.optional,
                        .has_default = parameter.initializer != null,
                        .rest = parameter.rest,
                    });
                    if (parameter_symbol) |value| if (parameter.type_annotation != null)
                        try putDeclared(&declared, allocator, value.id, type_id);
                }
                context.scope = declarationTypeScope(&context, symbol.declaration, symbol.scope);
                var return_type = if (declaration.return_type) |annotation|
                    try resolveTypeAnnotation(&context, annotation)
                else
                    type_store.builtins.unknown;
                return_type = try type_inference.wrapFunctionReturn(return_type, declaration.flags, type_store);
                const signature_id = try type_store.addFunctionDetailed(
                    parameters.items,
                    return_type,
                    @intCast(declaration.type_parameters.len),
                    .{ .is_async = declaration.flags.is_async, .is_generator = declaration.flags.is_generator },
                );
                if (declaration.return_type != null) try putDeclared(&declared, allocator, symbol.id, signature_id);
                try signatures.append(allocator, .{
                    .symbol_id = symbol.id,
                    .signature_id = signature_id,
                    .resolved_return_type = return_type,
                });
            },
            // Function/arrow/method parameter symbols are also visited outside
            // FunctionDeclaration. Reuse an entry already captured above.
            .Parameter => |parameter| if (parameter.type_annotation) |annotation| {
                if (declaredType(declared.items, symbol.id) == null)
                    try putDeclared(&declared, allocator, symbol.id, try resolveTypeAnnotation(&context, annotation));
            },
            else => {},
        }
    }

    try resolveRemainingAnnotations(&context, bind);

    return .{
        .symbol_declared_types = try declared.toOwnedSlice(allocator),
        .function_signatures = try signatures.toOwnedSlice(allocator),
        .resolved_type_nodes = try resolved_type_nodes.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn genericTypeParameters(tree: ast_mod.Ast, declaration: ast_mod.NodeId) ?[]const ast_mod.GenericTypeParameter {
    return switch (tree.node(declaration).data) {
        .TypeAliasDeclaration => |value| value.type_parameters,
        .InterfaceDeclaration => |value| value.type_parameters,
        .ClassDeclaration => |value| value.type_parameters,
        else => null,
    };
}

fn collectGenericParameterShells(
    context: *TypeResolutionContext,
    declaration: ast_mod.NodeId,
    parameters: []const ast_mod.GenericTypeParameter,
) ![]const types.GenericParameter {
    const result = try context.allocator.alloc(types.GenericParameter, parameters.len);
    for (parameters, 0..) |parameter, index| {
        const symbol = findTypeParameterSymbol(context.symbols, declaration, parameter.name) orelse {
            result[index] = .{ .type_id = context.type_store.builtins.unknown };
            continue;
        };
        result[index] = .{
            .type_id = declaredType(context.semantic_symbol_types.items, symbol.id) orelse context.type_store.builtins.unknown,
        };
    }
    return result;
}

fn resolveGenericParameterMetadata(
    context: *TypeResolutionContext,
    declaration: ast_mod.NodeId,
    parameters: []const ast_mod.GenericTypeParameter,
) ![]const types.GenericParameter {
    const result = try context.allocator.alloc(types.GenericParameter, parameters.len);
    for (parameters, 0..) |parameter, index| {
        const symbol = findTypeParameterSymbol(context.symbols, declaration, parameter.name) orelse {
            result[index] = .{ .type_id = context.type_store.builtins.unknown };
            continue;
        };
        const type_id = declaredType(context.semantic_symbol_types.items, symbol.id) orelse context.type_store.builtins.unknown;
        const constraint = if (parameter.constraint) |annotation|
            try resolveTypeAnnotation(context, annotation)
        else
            null;
        const default = if (parameter.default_type) |annotation|
            try resolveTypeAnnotation(context, annotation)
        else
            null;
        try context.type_store.updateTypeParameter(type_id, constraint, default);
        result[index] = .{ .type_id = type_id, .constraint = constraint, .default = default };
    }
    return result;
}

fn instantiateGeneric(
    context: *TypeResolutionContext,
    generic: types.GenericDeclaration,
    explicit: []const types.TypeId,
    name: []const u8,
    span: ast_mod.tokens.Span,
) !types.TypeId {
    if (explicit.len > generic.parameters.len) {
        try emitTypeOperationOnce(context, "generic type has too many type arguments", name, span);
        return context.type_store.builtins.unknown;
    }
    const arguments = try context.allocator.alloc(types.TypeId, generic.parameters.len);
    @memcpy(arguments[0..explicit.len], explicit);
    var index = explicit.len;
    while (index < generic.parameters.len) : (index += 1) {
        const default = generic.parameters[index].default orelse {
            try emitTypeOperationOnce(context, "generic type is missing required type arguments", name, span);
            return context.type_store.builtins.unknown;
        };
        arguments[index] = try context.type_store.substitute(
            default,
            generic.parameters[0..index],
            arguments[0..index],
        );
    }
    for (generic.parameters, arguments, 0..) |parameter, argument, parameter_index| {
        const raw_constraint = parameter.constraint orelse continue;
        const constraint = try context.type_store.substitute(
            raw_constraint,
            generic.parameters[0..parameter_index],
            arguments[0..parameter_index],
        );
        if (!type_compat.isAssignableInStore(argument, constraint, context.type_store)) {
            try emitTypeOperationOnce(context, "type argument does not satisfy generic constraint", name, span);
            return context.type_store.builtins.unknown;
        }
    }
    return context.type_store.instantiateGeneric(generic.identity, arguments);
}

fn resolveRemainingAnnotations(context: *TypeResolutionContext, bind: binder.BindResult) !void {
    for (context.tree.nodes, 0..) |node, raw_id| {
        const node_id: ast_mod.NodeId = @intCast(raw_id);
        context.scope = scopeForNode(bind, node_id);
        switch (node.data) {
            .AsExpression => |expression| _ = try resolveTypeAnnotation(context, expression.type_annotation),
            .SatisfiesExpression => |expression| _ = try resolveTypeAnnotation(context, expression.type_annotation),
            .FunctionExpression => |function| if (function.return_type) |annotation| {
                _ = try resolveTypeAnnotation(context, annotation);
            },
            .ArrowFunctionExpression => |function| if (function.return_type) |annotation| {
                _ = try resolveTypeAnnotation(context, annotation);
            },
            .ClassField => |field| if (field.type_annotation) |annotation| {
                _ = try resolveTypeAnnotation(context, annotation);
            },
            .ClassMethod => |method| if (method.return_type) |annotation| {
                _ = try resolveTypeAnnotation(context, annotation);
            },
            .Parameter => |parameter| if (parameter.type_annotation) |annotation| {
                _ = try resolveTypeAnnotation(context, annotation);
            },
            else => {},
        }
    }
}

fn scopeForNode(bind: binder.BindResult, node_id: ast_mod.NodeId) binder.ScopeId {
    for (bind.node_scopes) |entry| {
        if (entry.node == node_id) return entry.scope;
    }
    for (bind.symbols) |symbol| {
        if (symbol.declaration == node_id) return symbol.scope;
    }
    return 0;
}

fn collectClassMembers(
    context: *TypeResolutionContext,
    symbol: binder.Symbol,
    signatures: *std.ArrayList(FunctionSignatureEntry),
) !void {
    const declaration = switch (context.tree.node(symbol.declaration).data) {
        .ClassDeclaration => |value| value,
        else => return,
    };
    try collectClassBody(
        context,
        symbol.declaration,
        declaration.members,
        declaration.super_class,
        classBodyScope(context.bind, symbol.declaration, declaration.members),
        signatures,
    );
}

fn collectClassBody(
    context: *TypeResolutionContext,
    declaration_id: ast_mod.NodeId,
    members: []const ast_mod.NodeId,
    super_class: ?ast_mod.NodeId,
    class_scope: binder.ScopeId,
    signatures: *std.ArrayList(FunctionSignatureEntry),
) !void {
    const identity = types.SemanticDeclId.init(context.current_module, declaration_id);
    const class_type = context.type_store.lookupClassSemanticType(identity) orelse return;
    var static_members: std.ArrayList(types.SemanticMember) = .empty;
    defer static_members.deinit(context.allocator);
    var instance_members: std.ArrayList(types.SemanticMember) = .empty;
    defer instance_members.deinit(context.allocator);
    var constructor_signature: ?types.TypeId = null;

    for (members) |member_id| {
        const node = context.tree.node(member_id);
        switch (node.data) {
            .ClassField => |field| {
                const member_symbol = findDeclarationSymbol(context.symbols, member_id, .field);
                context.scope = if (member_symbol) |value| value.scope else class_scope;
                const type_id = if (field.type_annotation) |annotation|
                    try resolveTypeAnnotation(context, annotation)
                else
                    context.type_store.builtins.unknown;
                const member: types.SemanticMember = .{
                    .name = field.name,
                    .type_id = type_id,
                    .visibility = visibility(field.access),
                    .readonly = field.readonly,
                    .optional = field.optional,
                };
                if (field.is_static)
                    try static_members.append(context.allocator, member)
                else
                    try instance_members.append(context.allocator, member);
                if (member_symbol) |value| try putDeclared(context.semantic_symbol_types, context.allocator, value.id, type_id);
            },
            .ClassMethod => |method| {
                const method_symbol = findDeclarationSymbol(context.symbols, member_id, .method);
                const signature_id = try collectMethodSignature(
                    context,
                    class_scope,
                    method,
                    method_symbol,
                    if (method.kind == .constructor) class_type.instance_type else null,
                    signatures,
                );
                if (method.kind == .constructor) {
                    constructor_signature = signature_id;
                    for (method.params) |parameter_id| {
                        const parameter = switch (context.tree.node(parameter_id).data) {
                            .Parameter => |value| value,
                            else => continue,
                        };
                        if (parameter.access == .none and !parameter.readonly) continue;
                        const parameter_symbol = findDeclarationSymbol(context.symbols, parameter_id, .parameter);
                        context.scope = if (parameter_symbol) |value| value.scope else class_scope;
                        const parameter_type = if (parameter.type_annotation) |annotation|
                            try resolveTypeAnnotation(context, annotation)
                        else
                            context.type_store.builtins.unknown;
                        try instance_members.append(context.allocator, .{
                            .name = parameter.name,
                            .type_id = parameter_type,
                            .visibility = visibility(parameter.access),
                            .readonly = parameter.readonly,
                            .optional = parameter.optional,
                        });
                        if (findDeclarationSymbol(context.symbols, parameter_id, .field)) |field_symbol|
                            try putDeclared(context.semantic_symbol_types, context.allocator, field_symbol.id, parameter_type);
                    }
                } else {
                    const member: types.SemanticMember = .{
                        .name = method.name,
                        .type_id = signature_id,
                        .visibility = visibility(method.access),
                    };
                    if (method.is_static)
                        try static_members.append(context.allocator, member)
                    else
                        try instance_members.append(context.allocator, member);
                }
            },
            else => {},
        }
    }

    var extends: ?types.TypeId = null;
    if (super_class) |super_id| switch (context.tree.node(super_id).data) {
        .Identifier => |identifier| {
            context.scope = declarationTypeScope(context, declaration_id, class_scope);
            const resolution = try resolveTypeName(context, identifier.name);
            if (resolution == .resolved) extends = resolution.resolved.type_id;
        },
        else => {},
    };
    try context.type_store.completeClassSemanticType(
        identity,
        .{ .members = static_members.items },
        .{ .members = instance_members.items },
        constructor_signature,
        .{ .extends = extends },
    );
}

fn classBodyScope(bind: binder.BindResult, declaration_id: ast_mod.NodeId, members: []const ast_mod.NodeId) binder.ScopeId {
    if (members.len != 0) return scopeForNode(bind, members[0]);
    for (bind.symbols) |symbol| {
        if (symbol.declaration == declaration_id and symbol.kind == .class) return symbol.scope;
    }
    return scopeForNode(bind, declaration_id);
}

fn collectInterfaceMembers(context: *TypeResolutionContext, symbol: binder.Symbol) !void {
    const declaration = switch (context.tree.node(symbol.declaration).data) {
        .InterfaceDeclaration => |value| value,
        else => return,
    };
    context.scope = declarationTypeScope(context, symbol.declaration, symbol.scope);
    const body = context.tree.typeNode(declaration.body);
    var members: std.ArrayList(types.SemanticMember) = .empty;
    defer members.deinit(context.allocator);
    switch (body.data) {
        .Object => |properties| for (properties) |property| try members.append(context.allocator, .{
            .name = property.name,
            .type_id = try resolveTypeNode(context, property.type_node, property.span, false),
            .readonly = property.readonly,
            .optional = property.optional,
        }),
        else => {},
    }
    var heritage: std.ArrayList(types.TypeId) = .empty;
    defer heritage.deinit(context.allocator);
    for (declaration.extends) |extended| try heritage.append(
        context.allocator,
        try resolveTypeNode(context, extended, context.tree.typeNode(extended).span, false),
    );
    try context.type_store.completeInterfaceSemanticType(
        types.SemanticDeclId.init(context.current_module, symbol.declaration),
        .{ .members = members.items },
        .{ .extends = heritage.items },
    );
}

fn collectMethodSignature(
    context: *TypeResolutionContext,
    fallback_scope: binder.ScopeId,
    method: ast_mod.ClassMethod,
    method_symbol: ?binder.Symbol,
    forced_return_type: ?types.TypeId,
    signatures: *std.ArrayList(FunctionSignatureEntry),
) !types.TypeId {
    var parameters: std.ArrayList(types.ParameterType) = .empty;
    defer parameters.deinit(context.allocator);
    for (method.params) |parameter_id| {
        const parameter = switch (context.tree.node(parameter_id).data) {
            .Parameter => |value| value,
            else => continue,
        };
        const parameter_symbol = findDeclarationSymbol(context.symbols, parameter_id, .parameter);
        context.scope = if (parameter_symbol) |value| value.scope else fallback_scope;
        const type_id = if (parameter.type_annotation) |annotation|
            try resolveTypeAnnotation(context, annotation)
        else
            context.type_store.builtins.unknown;
        try parameters.append(context.allocator, .{
            .name = parameter.name,
            .type_id = type_id,
            .optional = parameter.optional,
            .has_default = parameter.initializer != null,
            .rest = parameter.rest,
        });
        if (parameter_symbol) |value| if (parameter.type_annotation != null)
            try putDeclared(context.semantic_symbol_types, context.allocator, value.id, type_id);
    }
    context.scope = if (method_symbol) |value| value.scope else fallback_scope;
    var return_type = if (forced_return_type) |type_id|
        type_id
    else if (method.return_type) |annotation|
        try resolveTypeAnnotation(context, annotation)
    else
        context.type_store.builtins.unknown;
    return_type = try type_inference.wrapFunctionReturn(return_type, method.flags, context.type_store);
    const signature_id = try context.type_store.addFunctionDetailed(parameters.items, return_type, 0, .{
        .is_async = method.flags.is_async,
        .is_generator = method.flags.is_generator,
    });
    if (method_symbol) |value| {
        try signatures.append(context.allocator, .{
            .symbol_id = value.id,
            .signature_id = signature_id,
            .resolved_return_type = return_type,
        });
        if (forced_return_type != null or method.return_type != null)
            try putDeclared(context.semantic_symbol_types, context.allocator, value.id, signature_id);
    }
    return signature_id;
}

fn visibility(access: ast_mod.AccessModifier) types.Visibility {
    return switch (access) {
        .none => .none,
        .public => .public,
        .protected => .protected,
        .private => .private,
    };
}

pub fn resolveTypeAnnotation(context: *TypeResolutionContext, annotation: ast_mod.TypeAnnotation) anyerror!types.TypeId {
    return resolveTypeNode(context, annotation.root, annotation.span, false);
}

fn resolveTypeNode(
    context: *TypeResolutionContext,
    node_id: ast_mod.TypeNodeId,
    annotation_span: ast_mod.tokens.Span,
    readonly: bool,
) anyerror!types.TypeId {
    for (context.resolved_type_nodes.items) |entry| {
        if (entry.node_id == node_id) return entry.type_id;
    }

    const node = context.tree.typeNode(node_id);
    const resolved = switch (node.data) {
        .Named => |named| blk: {
            const resolution = try resolveTypeName(context, named.name);
            break :blk switch (resolution) {
                .resolved => |value| resolved: {
                    if (context.type_store.lookup(value.type_id)) |resolved_type| {
                        if (resolved_type.kind == .type_parameter) {
                            if (named.type_arguments.len != 0) {
                                try emitTypeOperationOnce(context, "type parameter does not accept type arguments", named.name, annotation_span);
                                break :resolved context.type_store.builtins.unknown;
                            }
                            break :resolved value.type_id;
                        }
                    }
                    if (value.declaration) |identity| if (context.type_store.lookupGenericDeclaration(identity)) |generic| {
                        const explicit = try context.allocator.alloc(types.TypeId, named.type_arguments.len);
                        for (named.type_arguments, 0..) |argument, index|
                            explicit[index] = try resolveTypeNode(context, argument, annotation_span, false);
                        break :resolved try instantiateGeneric(context, generic, explicit, named.name, annotation_span);
                    };
                    if (named.type_arguments.len != 0) {
                        try emitTypeOperationOnce(context, "this type does not accept type arguments", named.name, annotation_span);
                        break :resolved context.type_store.builtins.unknown;
                    }
                    break :resolved value.type_id;
                },
                .unresolved => |value| unresolved: {
                    try emitUnknownOnce(context, value.name, annotation_span);
                    break :unresolved context.type_store.builtins.unknown;
                },
            };
        },
        .Literal => |literal| try resolveLiteralType(context, literal, annotation_span),
        .Array => |element| try context.type_store.intern(.{ .array = .{
            .element_type = try resolveTypeNode(context, element, annotation_span, false),
            .readonly = readonly,
        } }),
        .Tuple => |items| blk: {
            const elements = try context.allocator.alloc(types.TupleElement, items.len);
            for (items, 0..) |item, index| elements[index] = .{ .type_id = try resolveTypeNode(context, item, annotation_span, false) };
            break :blk try context.type_store.intern(.{ .tuple = .{ .elements = elements, .readonly = readonly } });
        },
        .Object => |members| blk: {
            const properties = try context.allocator.alloc(types.ObjectProperty, members.len);
            for (members, 0..) |member, index| properties[index] = .{
                .name = member.name,
                .type_id = try resolveTypeNode(context, member.type_node, annotation_span, false),
                .optional = member.optional,
                .readonly = readonly or member.readonly,
            };
            break :blk try context.type_store.intern(.{ .object = properties });
        },
        .Function => |function| blk: {
            const parameters = try context.allocator.alloc(types.ParameterType, function.parameters.len);
            for (function.parameters, 0..) |parameter, index| parameters[index] = .{
                .name = parameter.name,
                .type_id = try resolveTypeNode(context, parameter.type_node, annotation_span, false),
                .optional = parameter.optional,
            };
            break :blk try context.type_store.addFunction(parameters, try resolveTypeNode(context, function.return_type, annotation_span, false));
        },
        .Readonly => |inner| try resolveTypeNode(context, inner, annotation_span, true),
        .IndexedAccess => |indexed| blk: {
            const object_type = try resolveTypeNode(context, indexed.object_type, annotation_span, false);
            const index_type = try resolveTypeNode(context, indexed.index_type, annotation_span, false);
            break :blk try resolveIndexedAccess(context, object_type, index_type, annotation_span);
        },
        .KeyOf => |inner| try resolveKeyOf(
            context,
            try resolveTypeNode(context, inner, annotation_span, false),
            annotation_span,
        ),
        .TypeQuery => |name| try resolveTypeQuery(context, name, annotation_span),
        .Parenthesized => |inner| try resolveTypeNode(context, inner, annotation_span, readonly),
        .Union => |items| blk: {
            const members = try context.allocator.alloc(types.TypeId, items.len);
            for (items, 0..) |item, index| members[index] = try resolveTypeNode(context, item, annotation_span, false);
            break :blk try context.type_store.unionOf(members);
        },
        .Intersection => |items| blk: {
            const members = try context.allocator.alloc(types.TypeId, items.len);
            for (items, 0..) |item, index| members[index] = try resolveTypeNode(context, item, annotation_span, false);
            break :blk try context.type_store.intersectionOf(members);
        },
    };
    try context.resolved_type_nodes.append(context.allocator, .{
        .node_id = node_id,
        .type_id = resolved,
    });
    return resolved;
}

fn resolveLiteralType(context: *TypeResolutionContext, literal: ast_mod.LiteralType, span: ast_mod.tokens.Span) !types.TypeId {
    return switch (literal.kind) {
        .string => blk: {
            if (literal.spelling.len < 2) {
                try emitTypeOperationOnce(context, "invalid string literal type", literal.spelling, span);
                break :blk context.type_store.builtins.unknown;
            }
            break :blk try context.type_store.intern(.{ .literal = .{ .string = literal.spelling[1 .. literal.spelling.len - 1] } });
        },
        .number => blk: {
            const value = std.fmt.parseFloat(f64, literal.spelling) catch {
                try emitTypeOperationOnce(context, "invalid number literal type", literal.spelling, span);
                break :blk context.type_store.builtins.unknown;
            };
            break :blk try context.type_store.intern(.{ .literal = .{ .number = value } });
        },
        .bigint => blk: {
            if (literal.spelling.len < 2) {
                try emitTypeOperationOnce(context, "invalid bigint literal type", literal.spelling, span);
                break :blk context.type_store.builtins.unknown;
            }
            break :blk try context.type_store.intern(.{ .literal = .{ .bigint = literal.spelling[0 .. literal.spelling.len - 1] } });
        },
        .boolean => context.type_store.intern(.{ .literal = .{ .boolean = std.mem.eql(u8, literal.spelling, "true") } }),
        .null => context.type_store.builtins.null_,
    };
}

fn resolveIndexedAccess(context: *TypeResolutionContext, object_type: types.TypeId, index_type: types.TypeId, span: ast_mod.tokens.Span) !types.TypeId {
    const index = context.type_store.lookup(index_type) orelse {
        try emitTypeOperationOnce(context, "indexed access requires a known key", "index", span);
        return context.type_store.builtins.unknown;
    };
    return switch (index.kind) {
        .literal => |literal| switch (literal) {
            .string => |key| if (try lookupStringProperty(context, object_type, key)) |property|
                propertyValueType(context, property)
            else blk: {
                try emitTypeOperationOnce(context, "property does not exist on indexed type", key, span);
                break :blk context.type_store.builtins.unknown;
            },
            .number => |value| resolveNumericIndex(context, object_type, value, span),
            else => unsupportedIndex(context, "indexed access requires a string or number key", span),
        },
        .primitive => |primitive| if (primitive == .number)
            resolveNumericIndex(context, object_type, null, span)
        else
            unsupportedIndex(context, "indexed access requires a literal property key or number", span),
        else => unsupportedIndex(context, "indexed access requires a literal property key or number", span),
    };
}

fn resolveKeyOf(context: *TypeResolutionContext, object_type: types.TypeId, span: ast_mod.tokens.Span) !types.TypeId {
    var keys: std.ArrayList(types.TypeId) = .empty;
    if (!try collectKeyTypes(context, object_type, &keys)) {
        try emitTypeOperationOnce(context, "keyof requires an object-like type", "keyof", span);
        return context.type_store.builtins.unknown;
    }
    return context.type_store.unionOf(keys.items);
}

/// v1 operator policy: `keyof (A | B)` is the intersection of keys safe on
/// every branch; `keyof (A & B)` is the union of keys contributed by branches.
fn collectKeyTypes(context: *TypeResolutionContext, type_id: types.TypeId, keys: *std.ArrayList(types.TypeId)) anyerror!bool {
    const ty = context.type_store.lookup(type_id) orelse return false;
    switch (ty.kind) {
        .object => |properties| for (properties) |property| try appendUniqueType(
            context,
            keys,
            try context.type_store.intern(.{ .literal = .{ .string = property.name } }),
        ),
        .interface => |nominal| {
            const semantic = context.type_store.lookupInterfaceSemanticType(nominal.identity) orelse return false;
            for (semantic.members.members) |member| try appendUniqueType(
                context,
                keys,
                try context.type_store.intern(.{ .literal = .{ .string = member.name } }),
            );
            for (semantic.inheritance.extends) |base| _ = try collectKeyTypes(context, base, keys);
        },
        .class => |nominal| {
            const semantic = context.type_store.lookupClassSemanticType(nominal.identity) orelse return false;
            for (semantic.instance_members.members) |member| try appendUniqueType(
                context,
                keys,
                try context.type_store.intern(.{ .literal = .{ .string = member.name } }),
            );
            if (semantic.inheritance.extends) |base| _ = try collectKeyTypes(context, base, keys);
        },
        .applied_generic => |applied| {
            const generic = context.type_store.lookupGenericDeclaration(applied.declaration) orelse return false;
            _ = try collectKeyTypes(context, generic.template_type, keys);
        },
        .tuple => |tuple| for (tuple.elements, 0..) |_, index| try appendUniqueType(
            context,
            keys,
            try context.type_store.intern(.{ .literal = .{ .number = @floatFromInt(index) } }),
        ),
        .array => try appendUniqueType(context, keys, context.type_store.builtins.number),
        .intersection => |members| {
            for (members) |member| _ = try collectKeyTypes(context, member, keys);
        },
        .union_type => |members| {
            if (members.len == 0) return false;
            var common: std.ArrayList(types.TypeId) = .empty;
            if (!try collectKeyTypes(context, members[0], &common)) return false;
            for (members[1..]) |member| {
                var branch: std.ArrayList(types.TypeId) = .empty;
                if (!try collectKeyTypes(context, member, &branch)) return false;
                var index: usize = 0;
                while (index < common.items.len) {
                    if (containsType(branch.items, common.items[index])) {
                        index += 1;
                    } else {
                        _ = common.orderedRemove(index);
                    }
                }
            }
            for (common.items) |key| try appendUniqueType(context, keys, key);
        },
        else => return false,
    }
    return true;
}

fn appendUniqueType(context: *TypeResolutionContext, values: *std.ArrayList(types.TypeId), value: types.TypeId) !void {
    if (!containsType(values.items, value)) try values.append(context.allocator, value);
}

fn containsType(values: []const types.TypeId, value: types.TypeId) bool {
    for (values) |candidate| if (candidate == value) return true;
    return false;
}

fn lookupStringProperty(context: *TypeResolutionContext, type_id: types.TypeId, key: []const u8) anyerror!?types.ObjectProperty {
    const ty = context.type_store.lookup(type_id) orelse return null;
    return switch (ty.kind) {
        .object => |properties| findObjectProperty(properties, key),
        .interface => |nominal| lookupInterfaceProperty(context, nominal.identity, key),
        .class => |nominal| lookupClassProperty(context, nominal.identity, key),
        .applied_generic => |applied| blk: {
            const generic = context.type_store.lookupGenericDeclaration(applied.declaration) orelse break :blk null;
            const property = try lookupStringProperty(context, generic.template_type, key) orelse break :blk null;
            break :blk .{
                .name = property.name,
                .type_id = try context.type_store.substitute(property.type_id, generic.parameters, applied.arguments),
                .optional = property.optional,
                .readonly = property.readonly,
            };
        },
        .intersection => |members| blk: {
            var values: std.ArrayList(types.TypeId) = .empty;
            var optional = false;
            var readonly = true;
            for (members) |member| if (try lookupStringProperty(context, member, key)) |property| {
                try values.append(context.allocator, property.type_id);
                optional = optional or property.optional;
                readonly = readonly and property.readonly;
            };
            if (values.items.len == 0) break :blk null;
            break :blk .{ .name = key, .type_id = try context.type_store.unionOf(values.items), .optional = optional, .readonly = readonly };
        },
        .union_type => |members| blk: {
            var values: std.ArrayList(types.TypeId) = .empty;
            var optional = false;
            var readonly = true;
            for (members) |member| {
                const property = try lookupStringProperty(context, member, key) orelse break :blk null;
                try values.append(context.allocator, property.type_id);
                optional = optional or property.optional;
                readonly = readonly and property.readonly;
            }
            break :blk .{ .name = key, .type_id = try context.type_store.unionOf(values.items), .optional = optional, .readonly = readonly };
        },
        else => null,
    };
}

fn findObjectProperty(properties: []const types.ObjectProperty, key: []const u8) ?types.ObjectProperty {
    for (properties) |property| if (std.mem.eql(u8, property.name, key)) return property;
    return null;
}

fn semanticProperty(member: types.SemanticMember) types.ObjectProperty {
    return .{ .name = member.name, .type_id = member.type_id, .optional = member.optional, .readonly = member.readonly };
}

fn lookupInterfaceProperty(context: *TypeResolutionContext, identity: types.SemanticDeclId, key: []const u8) anyerror!?types.ObjectProperty {
    const semantic = context.type_store.lookupInterfaceSemanticType(identity) orelse return null;
    for (semantic.members.members) |member| if (std.mem.eql(u8, member.name, key)) return semanticProperty(member);
    for (semantic.inheritance.extends) |base| if (try lookupStringProperty(context, base, key)) |property| return property;
    return null;
}

fn lookupClassProperty(context: *TypeResolutionContext, identity: types.SemanticDeclId, key: []const u8) anyerror!?types.ObjectProperty {
    const semantic = context.type_store.lookupClassSemanticType(identity) orelse return null;
    for (semantic.instance_members.members) |member| if (std.mem.eql(u8, member.name, key)) return semanticProperty(member);
    if (semantic.inheritance.extends) |base| return lookupStringProperty(context, base, key);
    return null;
}

fn propertyValueType(context: *TypeResolutionContext, property: types.ObjectProperty) !types.TypeId {
    if (!property.optional) return property.type_id;
    return context.type_store.unionOf(&.{ property.type_id, context.type_store.builtins.undefined });
}

fn unsupportedIndex(context: *TypeResolutionContext, message: []const u8, span: ast_mod.tokens.Span) !types.TypeId {
    try emitTypeOperationOnce(context, message, "index", span);
    return context.type_store.builtins.unknown;
}

fn resolveNumericIndex(context: *TypeResolutionContext, object_type: types.TypeId, value: ?f64, span: ast_mod.tokens.Span) anyerror!types.TypeId {
    const ty = context.type_store.lookup(object_type) orelse return unsupportedIndex(context, "numeric index requires an array or tuple", span);
    return switch (ty.kind) {
        .array => |array| array.element_type,
        .tuple => |tuple| blk: {
            if (value == null) {
                var members: std.ArrayList(types.TypeId) = .empty;
                for (tuple.elements) |element| try members.append(context.allocator, element.type_id);
                break :blk try context.type_store.unionOf(members.items);
            }
            if (!std.math.isFinite(value.?) or value.? < 0 or @floor(value.?) != value.? or
                value.? > @as(f64, @floatFromInt(std.math.maxInt(usize))))
            {
                try emitTypeOperationOnce(context, "tuple index is outside its declared elements", "index", span);
                break :blk context.type_store.builtins.unknown;
            }
            const index: usize = @intFromFloat(value.?);
            if (index >= tuple.elements.len) {
                try emitTypeOperationOnce(context, "tuple index is outside its declared elements", "index", span);
                break :blk context.type_store.builtins.unknown;
            }
            const element = tuple.elements[index];
            break :blk if (element.optional)
                try context.type_store.unionOf(&.{ element.type_id, context.type_store.builtins.undefined })
            else
                element.type_id;
        },
        .union_type => |members| blk: {
            var results: std.ArrayList(types.TypeId) = .empty;
            for (members) |member| {
                const result = try resolveNumericIndex(context, member, value, span);
                if (result == context.type_store.builtins.unknown) break :blk result;
                try results.append(context.allocator, result);
            }
            break :blk try context.type_store.unionOf(results.items);
        },
        .intersection => |members| blk: {
            var results: std.ArrayList(types.TypeId) = .empty;
            for (members) |member| {
                const member_ty = context.type_store.lookup(member) orelse continue;
                if (member_ty.kind != .array and member_ty.kind != .tuple) continue;
                try results.append(context.allocator, try resolveNumericIndex(context, member, value, span));
            }
            if (results.items.len == 0) break :blk try unsupportedIndex(context, "numeric index requires an array or tuple", span);
            break :blk try context.type_store.unionOf(results.items);
        },
        else => unsupportedIndex(context, "numeric index requires an array or tuple", span),
    };
}

fn resolveTypeQuery(context: *TypeResolutionContext, name: []const u8, span: ast_mod.tokens.Span) !types.TypeId {
    if (std.mem.eql(u8, name, "<unsupported-import>")) {
        try emitTypeOperationOnce(context, "typeof import() is outside the supported type-query subset", name, span);
        return context.type_store.builtins.unknown;
    }
    const symbol = findVisibleSymbol(context, name, .value) orelse {
        try emitTypeOperationOnce(context, "type query cannot find value", name, span);
        return context.type_store.builtins.unknown;
    };
    if (symbol.kind == .import) if (findImportedType(context, name, symbol.id)) |imported| {
        if (!imported.placeholder) return imported.type_id;
    };
    for (context.value_symbol_types) |entry| if (entry.symbol_id == symbol.id) {
        if (entry.effective()) |type_id| return type_id;
        break;
    };
    if (declaredType(context.semantic_symbol_types.items, symbol.id)) |type_id| return type_id;
    const declaration = switch (context.tree.node(symbol.declaration).data) {
        .VariableDeclarator => |value| value,
        else => {
            try emitTypeOperationOnce(context, "type query target has no resolved value type", name, span);
            return context.type_store.builtins.unknown;
        },
    };
    const annotation = declaration.type_annotation orelse {
        try emitTypeOperationOnce(context, "type query target has no resolved value type", name, span);
        return context.type_store.builtins.unknown;
    };
    const old_scope = context.scope;
    defer context.scope = old_scope;
    context.scope = symbol.scope;
    const type_id = try resolveTypeAnnotation(context, annotation);
    try putDeclared(context.semantic_symbol_types, context.allocator, symbol.id, type_id);
    return type_id;
}

pub fn resolveTypeName(context: *TypeResolutionContext, name: []const u8) anyerror!TypeNameResolution {
    if (findVisibleSymbol(context, name, .type)) |symbol| {
        if (symbol.kind == .import) if (findImportedType(context, name, symbol.id)) |imported| return importedResolution(imported);
        const type_id = try ensureSymbolType(context, symbol.id) orelse return .{ .unresolved = .{
            .name = name,
            .reason = .unavailable_declaration,
        } };
        return .{ .resolved = .{
            .type_id = type_id,
            .symbol_id = symbol.id,
            .declaration = types.SemanticDeclId.init(context.current_module, symbol.declaration),
        } };
    }
    if (findImportedType(context, name, null)) |imported| return importedResolution(imported);
    inline for (builtin_kind.builtinKinds) |kind| {
        if (std.mem.eql(u8, name, builtin_kind.builtinKindName(kind))) return .{ .resolved = .{
            .type_id = context.type_store.builtins.id(kind),
        } };
    }
    return .{ .unresolved = .{
        .name = name,
        .reason = if (findVisibleSymbol(context, name, .value) != null) .value_only else .unknown_name,
    } };
}

fn ensureSymbolType(context: *TypeResolutionContext, symbol_id: binder.SymbolId) anyerror!?types.TypeId {
    if (declaredType(context.semantic_symbol_types.items, symbol_id)) |type_id| return type_id;
    const symbol = findSymbol(context.symbols, symbol_id) orelse return null;
    if (symbol.kind != .type_alias) return null;
    const index: usize = @intCast(symbol.id);
    if (index >= context.alias_states.len) return null;
    if (context.alias_states[index] == 1) return context.type_store.builtins.unknown;
    context.alias_states[index] = 1;
    const declaration = switch (context.tree.node(symbol.declaration).data) {
        .TypeAliasDeclaration => |value| value,
        else => return null,
    };
    const old_scope = context.scope;
    defer context.scope = old_scope;
    context.scope = declarationTypeScope(context, symbol.declaration, symbol.scope);
    const type_id = try resolveTypeAnnotation(context, declaration.type_annotation);
    context.alias_states[index] = 2;
    try putDeclared(context.semantic_symbol_types, context.allocator, symbol.id, type_id);
    const identity = types.SemanticDeclId.init(context.current_module, symbol.declaration);
    if (context.type_store.lookupGenericDeclaration(identity)) |generic|
        try context.type_store.updateGenericDeclaration(identity, type_id, generic.parameters);
    return type_id;
}

fn findImportedType(context: *const TypeResolutionContext, name: []const u8, symbol_id: ?binder.SymbolId) ?ImportedTypeBinding {
    for (context.imported_types) |binding| {
        if (!std.mem.eql(u8, binding.local_name, name)) continue;
        if (symbol_id) |expected| if (binding.symbol_id != expected) continue;
        return binding;
    }
    return null;
}

fn importedResolution(binding: ImportedTypeBinding) TypeNameResolution {
    return .{ .resolved = .{
        .type_id = binding.type_id,
        .symbol_id = binding.symbol_id,
        .declaration = binding.declaration,
    } };
}

fn declarationTypeScope(context: *const TypeResolutionContext, declaration: ast_mod.NodeId, fallback: binder.ScopeId) binder.ScopeId {
    for (context.scopes) |scope| {
        if (scope.kind != .type_parameters or scope.parent != fallback) continue;
        for (scope.symbols) |symbol_id| {
            const symbol = findSymbol(context.symbols, symbol_id) orelse continue;
            if (symbol.kind == .type_parameter and symbol.declaration == declaration) return scope.id;
        }
    }
    return fallback;
}

fn findVisibleSymbol(context: *const TypeResolutionContext, name: []const u8, namespace: binder.SymbolNamespace) ?binder.Symbol {
    var scope_id: ?binder.ScopeId = context.scope;
    while (scope_id) |id| {
        const scope = findScope(context.scopes, id) orelse return null;
        for (scope.symbols) |symbol_id| {
            const symbol = findSymbol(context.symbols, symbol_id) orelse continue;
            if (symbol.namespace == namespace and std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        scope_id = scope.parent;
    }
    return null;
}

fn emitUnknownOnce(context: *TypeResolutionContext, name: []const u8, span: ast_mod.tokens.Span) !void {
    for (context.diagnostics.items) |diagnostic| {
        if (diagnostic.code == .unknown_type_name and diagnostic.span.start == span.start and diagnostic.span.end == span.end and
            std.mem.eql(u8, diagnostic.label orelse "", name)) return;
    }
    try context.diagnostics.append(context.allocator, .{
        .severity = .@"error",
        .code = .unknown_type_name,
        .phase = .type_checker,
        .message = "cannot find type name",
        .span = span,
        .label = name,
        .path = context.source_path,
    });
}

fn emitTypeOperationOnce(
    context: *TypeResolutionContext,
    message: []const u8,
    label: []const u8,
    span: ast_mod.tokens.Span,
) !void {
    for (context.diagnostics.items) |diagnostic| {
        if (diagnostic.code == .type_mismatch and diagnostic.span.start == span.start and
            diagnostic.span.end == span.end and std.mem.eql(u8, diagnostic.label orelse "", label)) return;
    }
    try context.diagnostics.append(context.allocator, .{
        .severity = .@"error",
        .code = .type_mismatch,
        .phase = .type_checker,
        .message = message,
        .span = span,
        .label = label,
        .path = context.source_path,
    });
}

fn putDeclared(list: *std.ArrayList(DeclaredSymbolType), allocator: std.mem.Allocator, symbol_id: binder.SymbolId, type_id: types.TypeId) !void {
    for (list.items) |*entry| {
        if (entry.symbol_id == symbol_id) {
            entry.declared_type = type_id;
            return;
        }
    }
    try list.append(allocator, .{ .symbol_id = symbol_id, .declared_type = type_id });
}

fn declaredType(entries: []const DeclaredSymbolType, symbol_id: binder.SymbolId) ?types.TypeId {
    for (entries) |entry| if (entry.symbol_id == symbol_id) return entry.declared_type;
    return null;
}

fn findSymbol(symbols: []const binder.Symbol, id: binder.SymbolId) ?binder.Symbol {
    for (symbols) |symbol| if (symbol.id == id) return symbol;
    return null;
}

fn findScope(scopes: []const binder.Scope, id: binder.ScopeId) ?binder.Scope {
    for (scopes) |scope| if (scope.id == id) return scope;
    return null;
}

fn findDeclarationSymbol(symbols: []const binder.Symbol, declaration: ast_mod.NodeId, kind: binder.SymbolKind) ?binder.Symbol {
    for (symbols) |symbol| if (symbol.declaration == declaration and symbol.kind == kind) return symbol;
    return null;
}

fn findTypeParameterSymbol(symbols: []const binder.Symbol, declaration: ast_mod.NodeId, name: []const u8) ?binder.Symbol {
    for (symbols) |symbol| if (symbol.declaration == declaration and symbol.kind == .type_parameter and
        symbol.namespace == .type and std.mem.eql(u8, symbol.name, name)) return symbol;
    return null;
}
