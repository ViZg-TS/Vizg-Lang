const std = @import("std");
const ast_mod = @import("ast.zig");
const diagnostics = @import("../diagnostics/root.zig");
const tokens = @import("tokens.zig");

const Token = tokens.Token;
const TokenType = tokens.TokenType;
const NodeId = ast_mod.NodeId;

pub const ParseResult = struct {
    ast: ast_mod.Ast,
    diagnostics: []const diagnostics.Diagnostic,
    /// Number of non-EOF tokens consumed by top-level parsing.
    consumed_tokens: usize,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,
    nodes: std.ArrayList(ast_mod.Node) = .empty,
    type_nodes: std.ArrayList(ast_mod.TypeNode) = .empty,
    diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty,
    parenthesized_nodes: std.ArrayList(NodeId) = .empty,
    allow_in: bool = true,
    recover_errors: bool = true,
    allocation_error: ?anyerror = null,
    // H4 — current recursion depth during descent. Bumped per recursive parse call;
    // when it reaches max_parse_depth we abort with a diagnostic rather than recursing further.
    _depth: usize = 0,
    // H4 — recursion depth counter for parser descent. Bumped per recursive parse call;
    // when it reaches max_parse_depth we abort with a diagnostic rather than recursing further.
    max_parse_depth: usize = 1000,

    fn parse(self: *Parser) anyerror!ParseResult {
        defer self.parenthesized_nodes.deinit(self.allocator);
        const root = try self.parseProgram();
        if (self.allocation_error) |err| return err;
        return .{
            .ast = .{
                .nodes = try self.nodes.toOwnedSlice(self.allocator),
                .type_nodes = try self.type_nodes.toOwnedSlice(self.allocator),
                .root = root,
            },
            .diagnostics = try self.diagnostics.toOwnedSlice(self.allocator),
            .consumed_tokens = self.index,
        };
    }

    fn parseProgram(self: *Parser) anyerror!NodeId {
        var statements: std.ArrayList(NodeId) = .empty;
        errdefer statements.deinit(self.allocator);

        const start = self.current().span;
        while (!self.at(.EOF)) {
            const before = self.index;
            if (try self.parseStatement()) |statement| {
                try statements.append(self.allocator, statement);
            }
            if (self.index == before) _ = self.advance();
        }

        return self.addNode(.{
            .span = joinSpans(start, self.current().span),
            .data = .{ .Program = .{ .statements = try statements.toOwnedSlice(self.allocator) } },
        });
    }

    fn parseStatement(self: *Parser) anyerror!?NodeId {
        if (self.at(.At)) {
            self.report("decorators are not supported", .unsupported_syntax);
            self.recoverUnsupportedStatement();
            return null;
        }
        if (self.atIdentifierText("namespace") or self.atIdentifierText("module")) {
            self.report("TypeScript namespaces are not supported", .unsupported_ts_syntax);
            self.recoverUnsupportedStatement();
            return null;
        }
        if (self.at(.Keyword_import) and self.peek(1).kind != .LParen and self.peek(1).kind != .Dot) return try self.parseImportDeclaration();
        if (self.at(.Keyword_export)) return try self.parseExportDeclaration();
        if (self.atTypeAliasDeclaration()) return try self.parseTypeAliasDeclaration();
        if (self.atInterfaceDeclaration()) return try self.parseInterfaceDeclaration();
        if (self.at(.Keyword_class)) return try self.parseClassDeclaration();
        if (self.at(.Keyword_function)) return try self.parseFunctionDeclaration(false, false);
        if (self.atIdentifierText("async") and self.peek(1).kind == .Keyword_function) {
            _ = self.advance();
            return try self.parseFunctionDeclaration(false, true);
        }
        if (self.at(.LBrace)) return try self.parseBlockStatement();
        if (self.at(.Keyword_return)) return try self.parseReturnStatement();
        if (self.at(.Keyword_throw)) return try self.parseThrowStatement();
        if (self.at(.Keyword_try)) return try self.parseTryStatement();
        if (self.at(.Keyword_break)) return try self.parseLoopControlStatement(.Keyword_break);
        if (self.at(.Keyword_continue)) return try self.parseLoopControlStatement(.Keyword_continue);
        if (self.at(.Keyword_if)) return try self.parseIfStatement();
        if (self.at(.Keyword_do)) return try self.parseDoWhileStatement();
        if (self.at(.Keyword_while)) return try self.parseWhileStatement();
        if (self.at(.Keyword_for)) return try self.parseForStatement();
        if (self.at(.Keyword_switch)) return try self.parseSwitchStatement();
        if (self.isVariableKeyword(self.current().kind)) return try self.parseVariableDeclarationStatement();
        if (self.at(.Semicolon)) {
            _ = self.advance();
            return null;
        }
        return try self.parseExpressionStatement();
    }

    fn atTypeAliasDeclaration(self: *const Parser) bool {
        return self.atIdentifierText("type") and
            self.peek(1).kind == .Identifier and
            self.peek(2).kind == .Equal;
    }

    fn atInterfaceDeclaration(self: *const Parser) bool {
        return self.atIdentifierText("interface") and self.peek(1).kind == .Identifier;
    }

    fn parseTypeAliasDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.advance();
        const name = self.expect(.Identifier, "expected type alias name");
        _ = self.expect(.Equal, "expected '=' after type alias name");
        const type_node = if (self.findUnsupportedTypeSyntax()) |unsupported| blk: {
            self.reportAt(unsupported.token, unsupported.message, .unsupported_ts_syntax);
            self.recoverUnsupportedType();
            break :blk try self.addTypeNode(.{
                .span = unsupported.token.span,
                .data = .{ .Named = .{ .name = "<unsupported>" } },
            });
        } else try self.parseType();
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = joinSpans(start.span, self.previousOrCurrent().span),
            .data = .{ .TypeAliasDeclaration = .{
                .name = name.lexeme,
                .type_annotation = .{ .root = type_node, .span = self.typeSpan(type_node) },
            } },
        });
    }

    fn parseInterfaceDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.advance();
        const name = self.expect(.Identifier, "expected interface name");
        var heritage: std.ArrayList(ast_mod.TypeNodeId) = .empty;
        errdefer heritage.deinit(self.allocator);
        if (self.eat(.Keyword_extends)) {
            while (!self.at(.LBrace) and !self.at(.EOF)) {
                const before = self.index;
                try heritage.append(self.allocator, try self.parsePostfixType());
                if (!self.eat(.Comma)) break;
                if (self.index == before) _ = self.advance();
            }
        }
        const body = try self.parsePrimaryType();
        return self.addNode(.{
            .span = joinSpans(start.span, self.typeSpan(body)),
            .data = .{ .InterfaceDeclaration = .{
                .name = name.lexeme,
                .extends = try heritage.toOwnedSlice(self.allocator),
                .body = body,
            } },
        });
    }

    fn parseImportDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_import, "expected import").span;
        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(self.allocator);
        var specifiers: std.ArrayList(ast_mod.ImportSpecifier) = .empty;
        errdefer specifiers.deinit(self.allocator);

        const type_only = if (self.atIdentifierText("type")) type_only: {
            _ = self.advance();
            break :type_only true;
        } else false;
        var needs_from = false;
        var has_named = false;
        var has_default = false;
        var has_namespace = false;

        if (self.at(.LBrace)) {
            needs_from = true;
            has_named = true;
            _ = self.advance();
            while (!self.at(.RBrace) and !self.at(.EOF)) {
                if (self.at(.Identifier) and !self.atIdentifierText("as")) {
                    const imported = self.advance();
                    const local = if (self.atIdentifierText("as")) local: {
                        _ = self.advance();
                        break :local self.expectIdentifierLike("expected import alias");
                    } else imported;
                    try names.append(self.allocator, local.lexeme);
                    try specifiers.append(self.allocator, .{
                        .kind = .named,
                        .imported_name = imported.lexeme,
                        .local_name = local.lexeme,
                        .imported_span = imported.span,
                        .local_span = local.span,
                    });
                    if (self.at(.Comma)) _ = self.advance();
                    continue;
                }
                self.report("expected imported name", .expected_token);
                _ = self.advance();
            }
            _ = self.expect(.RBrace, "expected }");
        } else if (self.at(.Identifier)) {
            needs_from = true;
            has_default = true;
            const default_local = self.advance();
            try names.append(self.allocator, default_local.lexeme);
            try specifiers.append(self.allocator, .{
                .kind = .default,
                .imported_name = "default",
                .local_name = default_local.lexeme,
                .imported_span = default_local.span,
                .local_span = default_local.span,
            });

            if (self.at(.Comma)) {
                _ = self.advance();
                if (self.at(.LBrace)) {
                    has_named = true;
                    _ = self.advance();
                    while (!self.at(.RBrace) and !self.at(.EOF)) {
                        if (self.at(.Identifier) and !self.atIdentifierText("as")) {
                            const imported = self.advance();
                            const alias = if (self.atIdentifierText("as")) alias: {
                                _ = self.advance();
                                break :alias self.expectIdentifierLike("expected import alias");
                            } else imported;
                            try names.append(self.allocator, alias.lexeme);
                            try specifiers.append(self.allocator, .{
                                .kind = .named,
                                .imported_name = imported.lexeme,
                                .local_name = alias.lexeme,
                                .imported_span = imported.span,
                                .local_span = alias.span,
                            });
                            if (self.at(.Comma)) _ = self.advance();
                            continue;
                        }
                        self.report("expected imported name", .expected_token);
                        _ = self.advance();
                    }
                    _ = self.expect(.RBrace, "expected }");
                } else if (self.at(.Asterisk)) {
                    has_namespace = true;
                    const imported = self.advance();
                    _ = self.expectContextualIdentifier("as", "expected as");
                    const local = self.expectIdentifierLike("expected namespace import");
                    try names.append(self.allocator, local.lexeme);
                    try specifiers.append(self.allocator, .{
                        .kind = .namespace,
                        .imported_name = "*",
                        .local_name = local.lexeme,
                        .imported_span = imported.span,
                        .local_span = local.span,
                    });
                } else {
                    self.report("expected named or namespace import", .expected_token);
                }
            }
        } else if (self.at(.Asterisk)) {
            needs_from = true;
            has_namespace = true;
            const imported = self.advance();
            _ = self.expectContextualIdentifier("as", "expected as");
            const local = self.expectIdentifierLike("expected namespace import");
            try names.append(self.allocator, local.lexeme);
            try specifiers.append(self.allocator, .{
                .kind = .namespace,
                .imported_name = "*",
                .local_name = local.lexeme,
                .imported_span = imported.span,
                .local_span = local.span,
            });
        }

        if (needs_from) _ = self.expectContextualIdentifier("from", "expected from");

        const tok: ?Token = if (self.at(.StringLiteral)) blk: {
            break :blk self.advance();
        } else null;
        const source_span: tokens.Span = if (tok) |t| t.span else start;
        var source_unquoted: []const u8 = "";
        if (tok) |t| source_unquoted = trimString(t.lexeme);

        _ = self.eat(.Semicolon);

        const kind: ast_mod.ImportKind = if (!needs_from)
            .side_effect
        else if (@as(u8, @intFromBool(has_named)) + @as(u8, @intFromBool(has_default)) + @as(u8, @intFromBool(has_namespace)) > 1)
            .mixed
        else if (has_named)
            .named
        else if (has_default)
            .default
        else
            .namespace;

        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ImportDeclaration = .{
                .kind = kind,
                .type_only = type_only,
                .names = try names.toOwnedSlice(self.allocator),
                .specifiers = try specifiers.toOwnedSlice(self.allocator),
                .source = source_unquoted,
                .source_span = source_span,
            } },
        });
    }

    fn parseImportExpression(self: *Parser, start: Token) anyerror!NodeId {
        _ = self.expect(.LParen, "expected ( after import");
        const source = try self.parseAssignmentExpression();
        const options = if (self.eat(.Comma)) try self.parseAssignmentExpression() else null;
        const end = self.expect(.RParen, "expected ) after import expression").span;
        return self.addNode(.{
            .span = joinSpans(start.span, end),
            .data = .{ .ImportExpression = .{ .source = source, .options = options } },
        });
    }

    fn parseMetaProperty(self: *Parser, start: Token, expected: []const u8, kind: ast_mod.MetaPropertyKind) anyerror!NodeId {
        _ = self.expect(.Dot, "expected . in meta-property");
        const property = self.expectIdentifierLike("expected meta-property name");
        if (!std.mem.eql(u8, property.lexeme, expected)) {
            self.reportAt(property, if (kind == .import_meta) "expected 'meta' after import." else "expected 'target' after new.", .unexpected_token);
            return self.addNode(.{
                .span = joinSpans(start.span, property.span),
                .data = .{ .Identifier = .{ .name = "" } },
            });
        }
        return self.addNode(.{
            .span = joinSpans(start.span, property.span),
            .data = .{ .MetaProperty = .{ .kind = kind } },
        });
    }

    fn parseExportDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_export, "expected export").span;

        if (self.atTypeAliasDeclaration() or self.atInterfaceDeclaration()) {
            const declaration = if (self.atTypeAliasDeclaration())
                try self.parseTypeAliasDeclaration()
            else
                try self.parseInterfaceDeclaration();
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(declaration)].span),
                .data = .{ .ExportDeclaration = .{ .kind = .declaration, .type_only = true, .declaration = declaration } },
            });
        }

        const async_function = self.atIdentifierText("async") and self.peek(1).kind == .Keyword_function;
        if (self.at(.Keyword_function) or async_function) {
            if (async_function) _ = self.advance();
            const function = try self.parseFunctionDeclaration(true, async_function);
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(function)].span),
                .data = .{ .ExportDeclaration = .{ .kind = .declaration, .declaration = function } },
            });
        }

        if (self.at(.Keyword_class)) {
            const class = try self.parseClassDeclaration();
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(class)].span),
                .data = .{ .ExportDeclaration = .{ .kind = .declaration, .declaration = class } },
            });
        }

        if (self.isVariableKeyword(self.current().kind)) {
            const declaration = try self.parseVariableDeclarationStatement();
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(declaration)].span),
                .data = .{ .ExportDeclaration = .{ .kind = .declaration, .declaration = declaration } },
            });
        }

        if (self.at(.Keyword_default)) {
            _ = self.advance();

            // export default function <name>() {} — parse as a named
            // FunctionDeclaration and tag the wrapper with default_name.
            const async_default_function = self.atIdentifierText("async") and self.peek(1).kind == .Keyword_function;
            if (self.at(.Keyword_function) or async_default_function) {
                const async_start: ?Token = if (async_default_function) self.advance() else null;
                const function_token = self.current();
                if (self.peek(1).kind == .LParen) {
                    _ = self.advance();
                    const function_id = try self.parseFunctionExpression(async_start orelse function_token, async_default_function);
                    const function_node = self.nodes.items[@intCast(function_id)];
                    return self.addNode(.{
                        .span = joinSpans(start, function_node.span),
                        .data = .{ .ExportDeclaration = .{ .kind = .default_expression, .expression = function_id } },
                    });
                }
                const function_id = try self.parseFunctionDeclaration(true, async_default_function);
                const func_node = self.nodes.items[@intCast(function_id)];
                return self.addNode(.{
                    .span = joinSpans(start, func_node.span),
                    .data = .{ .ExportDeclaration = .{
                        .kind = .declaration,
                        .declaration = function_id,
                        .default_name = func_node.data.FunctionDeclaration.name,
                    } },
                });
            }

            const expression = try self.parseAssignmentExpression();
            const expression_node = self.nodes.items[@intCast(expression)];
            const name: ?[]const u8 = switch (expression_node.data) {
                .Identifier => |identifier| identifier.name,
                else => null,
            };
            _ = self.eat(.Semicolon);
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .ExportDeclaration = .{
                    .kind = .default_expression,
                    .expression = expression,
                    .default_name = name,
                } },
            });
        }

        const type_only = self.atIdentifierText("type") and self.peek(1).kind == .LBrace;
        if (type_only) _ = self.advance();

        if (self.eat(.Asterisk)) {
            _ = self.expectContextualIdentifier("from", "expected from");
            const source_token = self.expect(.StringLiteral, "expected module specifier");
            _ = self.eat(.Semicolon);
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .ExportDeclaration = .{
                    .kind = .export_all,
                    .type_only = type_only,
                    .source = trimString(source_token.lexeme),
                    .source_span = source_token.span,
                } },
            });
        }

        var specifiers: std.ArrayList(ast_mod.ExportSpecifier) = .empty;
        errdefer specifiers.deinit(self.allocator);
        if (self.eat(.LBrace)) {
            while (!self.at(.RBrace) and !self.at(.EOF)) {
                if (self.at(.Identifier) or self.at(.PrivateIdentifier)) {
                    const local_token = self.expectExportSpecifierName("expected exported name", false);
                    if (local_token) |local| {
                        const exported_token = if (self.atIdentifierText("as")) exported: {
                            _ = self.advance();
                            break :exported self.expectExportSpecifierName("expected export alias", true);
                        } else local;

                        if (exported_token) |exported| {
                            const local_node = try self.addNode(.{
                                .span = local.span,
                                .data = .{ .Identifier = .{ .name = local.lexeme } },
                            });
                            const exported_node = try self.addNode(.{
                                .span = exported.span,
                                .data = .{ .Identifier = .{ .name = exported.lexeme } },
                            });
                            try specifiers.append(self.allocator, .{
                                .local_name = local.lexeme,
                                .exported_name = exported.lexeme,
                                .local = local_node,
                                .exported = exported_node,
                            });
                        }
                    }

                    if (!self.at(.Comma) and !self.at(.RBrace) and !self.at(.EOF)) {
                        self.report("expected as or }", .expected_token);
                        self.recoverExportSpecifier();
                    }
                } else {
                    self.report("expected exported name", .expected_token);
                    self.recoverExportSpecifier();
                }
                _ = self.eat(.Comma);
            }
            _ = self.expect(.RBrace, "expected }");
        }
        var source: []const u8 = "";
        var source_span: ?tokens.Span = null;
        if (self.atIdentifierText("from")) {
            _ = self.advance();
            const source_token = self.expect(.StringLiteral, "expected module specifier");
            source = trimString(source_token.lexeme);
            source_span = source_token.span;
        }
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ExportDeclaration = .{
                .kind = if (source.len > 0) .re_export else .local,
                .type_only = type_only,
                .specifiers = try specifiers.toOwnedSlice(self.allocator),
                .source = source,
                .source_span = source_span,
            } },
        });
    }

    fn expectExportSpecifierName(self: *Parser, message: []const u8, allow_as: bool) ?Token {
        if ((self.at(.Identifier) or self.at(.PrivateIdentifier)) and (allow_as or !self.atIdentifierText("as"))) {
            return self.advance();
        }

        self.report(message, .expected_token);
        if (!self.at(.Comma) and !self.at(.RBrace) and !self.at(.EOF)) _ = self.advance();
        return null;
    }

    fn recoverExportSpecifier(self: *Parser) void {
        while (!self.at(.Comma) and !self.at(.RBrace) and !self.at(.EOF)) _ = self.advance();
    }

    fn expectContextualIdentifier(self: *Parser, text: []const u8, message: []const u8) bool {
        if (self.atIdentifierText(text)) {
            _ = self.advance();
            return true;
        }

        self.report(message, .expected_token);
        if (self.at(.Identifier)) _ = self.advance();
        return false;
    }

    fn parseFunctionDeclaration(self: *Parser, exported: bool, is_async: bool) anyerror!NodeId {
        const start = self.expect(.Keyword_function, "expected function").span;
        const name = self.expectIdentifierLike("expected function name").lexeme;
        _ = self.expect(.LParen, "expected (");

        var params: std.ArrayList(NodeId) = .empty;
        errdefer params.deinit(self.allocator);
        try self.parseParameterList(&params);
        _ = self.expect(.RParen, "expected )");
        const return_type: ?ast_mod.TypeAnnotation = try self.parseOptionalTypeAnnotation();

        const body = if (self.at(.LBrace)) try self.parseBlockStatement() else ast_mod.invalid_node;
        const end_span = if (body == ast_mod.invalid_node)
            self.previousOrCurrent().span
        else
            self.nodes.items[@intCast(body)].span;
        return self.addNode(.{
            .span = joinSpans(start, end_span),
            .data = .{ .FunctionDeclaration = .{
                .name = name,
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
                .exported = exported,
                .flags = .{ .is_async = is_async },
                .return_type = return_type,
            } },
        });
    }

    fn parseFunctionExpression(self: *Parser, start: Token, is_async: bool) anyerror!NodeId {
        if (is_async) _ = self.expect(.Keyword_function, "expected function");
        const name: ?[]const u8 = if (self.at(.Identifier) or self.at(.PrivateIdentifier)) self.advance().lexeme else null;
        _ = self.expect(.LParen, "expected (");

        var params: std.ArrayList(NodeId) = .empty;
        errdefer params.deinit(self.allocator);
        try self.parseParameterList(&params);
        _ = self.expect(.RParen, "expected )");
        const return_type: ?ast_mod.TypeAnnotation = try self.parseOptionalTypeAnnotation();
        const body = if (self.at(.LBrace)) try self.parseBlockStatement() else blk: {
            self.report("expected function body", .expected_token);
            break :blk ast_mod.invalid_node;
        };
        const end_span = if (body == ast_mod.invalid_node) self.previousOrCurrent().span else self.nodes.items[@intCast(body)].span;
        return self.addNode(.{
            .span = joinSpans(start.span, end_span),
            .data = .{ .FunctionExpression = .{
                .name = name,
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
                .flags = .{ .is_async = is_async },
                .return_type = return_type,
            } },
        });
    }

    fn parseClassDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_class, "expected class").span;
        const name = self.expectIdentifierLike("expected class name").lexeme;
        const parts = try self.parseClassBody();
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ClassDeclaration = .{ .name = name, .super_class = parts.super_class, .members = parts.members } },
        });
    }

    const ParsedClassBody = struct { super_class: ?NodeId, members: []const NodeId };

    fn parseClassExpression(self: *Parser, start: Token) anyerror!NodeId {
        const name: ?[]const u8 = if (self.at(.Identifier) or self.at(.PrivateIdentifier)) self.advance().lexeme else null;
        const parts = try self.parseClassBody();
        return self.addNode(.{
            .span = joinSpans(start.span, self.previousOrCurrent().span),
            .data = .{ .ClassExpression = .{ .name = name, .super_class = parts.super_class, .members = parts.members } },
        });
    }

    fn parseClassBody(self: *Parser) anyerror!ParsedClassBody {
        const super_class: ?NodeId = if (self.eat(.Keyword_extends)) try self.parsePrimary() else null;
        _ = self.expect(.LBrace, "expected {");
        var members: std.ArrayList(NodeId) = .empty;
        errdefer members.deinit(self.allocator);
        while (!self.at(.RBrace) and !self.at(.EOF)) {
            if (self.eat(.Semicolon)) continue;
            if (self.at(.PrivateIdentifier) or self.at(.At)) {
                const is_private = self.at(.PrivateIdentifier);
                self.report(
                    if (is_private) "private class fields and methods are not supported" else "decorators are not supported",
                    .unsupported_syntax,
                );
                self.recoverUnsupportedClassMember();
                continue;
            }
            try members.append(self.allocator, try self.parseClassMember());
        }
        _ = self.expect(.RBrace, "expected }");
        return .{ .super_class = super_class, .members = try members.toOwnedSlice(self.allocator) };
    }

    fn parseClassMember(self: *Parser) anyerror!NodeId {
        const start = self.current().span;
        var access: ast_mod.AccessModifier = .none;
        var is_static = false;
        var is_async = false;
        while (self.at(.Identifier)) {
            if (self.atIdentifierText("static")) is_static = true else if (self.atIdentifierText("public")) access = .public else if (self.atIdentifierText("private")) access = .private else if (self.atIdentifierText("protected")) access = .protected else break;
            _ = self.advance();
        }
        if (self.atIdentifierText("async") and
            (self.peek(1).kind == .Identifier or self.peek(1).kind == .PrivateIdentifier) and
            self.peek(2).kind == .LParen)
        {
            is_async = true;
            _ = self.advance();
        }
        const name_token = self.expectIdentifierLike("expected class member name");
        if (self.eat(.LParen)) {
            var params: std.ArrayList(NodeId) = .empty;
            errdefer params.deinit(self.allocator);
            try self.parseParameterList(&params);
            _ = self.expect(.RParen, "expected )");
            const return_type = try self.parseOptionalTypeAnnotation();
            const body = if (self.at(.LBrace)) try self.parseBlockStatement() else blk: {
                self.report("expected method body", .expected_token);
                break :blk ast_mod.invalid_node;
            };
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .ClassMethod = .{
                    .name = name_token.lexeme,
                    .params = try params.toOwnedSlice(self.allocator),
                    .body = body,
                    .return_type = return_type,
                    .is_static = is_static,
                    .access = access,
                    .kind = if (std.mem.eql(u8, name_token.lexeme, "constructor")) .constructor else .method,
                    .flags = .{ .is_async = is_async },
                } },
            });
        }
        const type_annotation = try self.parseOptionalTypeAnnotation();
        const initializer: ?NodeId = if (self.eat(.Equal)) try self.parseAssignmentExpression() else null;
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ClassField = .{ .name = name_token.lexeme, .type_annotation = type_annotation, .initializer = initializer, .is_static = is_static, .access = access } },
        });
    }

    fn parseOptionalTypeAnnotation(self: *Parser) !?ast_mod.TypeAnnotation {
        if (!self.at(.Colon)) return null;
        _ = self.advance(); // consume colon
        const root = try self.parseType();
        if (root == ast_mod.invalid_type_node) return null;
        return .{ .root = root, .span = self.type_nodes.items[@intCast(root)].span };
    }

    fn parseType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        if (self.looksLikeFunctionType()) return self.parseFunctionType();
        return self.parseUnionType();
    }

    fn parseUnionType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        var members: std.ArrayList(ast_mod.TypeNodeId) = .empty;
        errdefer members.deinit(self.allocator);
        try members.append(self.allocator, try self.parseIntersectionType());
        while (self.eat(.Bar)) try members.append(self.allocator, try self.parseIntersectionType());
        if (members.items.len == 1) {
            const only = members.items[0];
            members.deinit(self.allocator);
            return only;
        }
        const span = joinSpans(self.typeSpan(members.items[0]), self.typeSpan(members.items[members.items.len - 1]));
        return self.addTypeNode(.{ .span = span, .data = .{ .Union = try members.toOwnedSlice(self.allocator) } });
    }

    fn parseIntersectionType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        var members: std.ArrayList(ast_mod.TypeNodeId) = .empty;
        errdefer members.deinit(self.allocator);
        try members.append(self.allocator, try self.parsePostfixType());
        while (self.eat(.Ampersand)) try members.append(self.allocator, try self.parsePostfixType());
        if (members.items.len == 1) {
            const only = members.items[0];
            members.deinit(self.allocator);
            return only;
        }
        const span = joinSpans(self.typeSpan(members.items[0]), self.typeSpan(members.items[members.items.len - 1]));
        return self.addTypeNode(.{ .span = span, .data = .{ .Intersection = try members.toOwnedSlice(self.allocator) } });
    }

    fn parsePostfixType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        var node: ast_mod.TypeNodeId = if (self.atIdentifierText("readonly")) blk: {
            const start = self.advance().span;
            const inner = try self.parsePostfixType();
            break :blk try self.addTypeNode(.{ .span = joinSpans(start, self.typeSpan(inner)), .data = .{ .Readonly = inner } });
        } else try self.parsePrimaryType();

        while (self.at(.LBracket) and self.peek(1).kind == .RBracket) {
            _ = self.advance();
            const close = self.advance();
            node = try self.addTypeNode(.{ .span = joinSpans(self.typeSpan(node), close.span), .data = .{ .Array = node } });
        }
        return node;
    }

    fn parsePrimaryType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        if (self.at(.Identifier) or self.at(.PrivateIdentifier)) {
            const name = self.advance();
            var arguments: std.ArrayList(ast_mod.TypeNodeId) = .empty;
            errdefer arguments.deinit(self.allocator);
            var end = name.span;
            if (self.eat(.LessThan)) {
                while (!self.at(.GreaterThan) and !self.at(.EOF)) {
                    const before = self.index;
                    try arguments.append(self.allocator, try self.parseType());
                    if (!self.eat(.Comma)) break;
                    if (self.index == before) _ = self.advance();
                }
                end = self.expect(.GreaterThan, "expected '>' after type arguments").span;
            }
            return self.addTypeNode(.{
                .span = joinSpans(name.span, end),
                .data = .{ .Named = .{ .name = name.lexeme, .type_arguments = try arguments.toOwnedSlice(self.allocator) } },
            });
        }

        if (self.eat(.LParen)) {
            const open = self.previousOrCurrent();
            const inner = try self.parseType();
            const close = self.expect(.RParen, "expected ')' after type");
            return self.addTypeNode(.{ .span = joinSpans(open.span, close.span), .data = .{ .Parenthesized = inner } });
        }

        if (self.eat(.LBracket)) {
            const open = self.previousOrCurrent();
            var elements: std.ArrayList(ast_mod.TypeNodeId) = .empty;
            errdefer elements.deinit(self.allocator);
            while (!self.at(.RBracket) and !self.at(.EOF)) {
                const before = self.index;
                try elements.append(self.allocator, try self.parseType());
                if (!self.eat(.Comma)) break;
                if (self.index == before) _ = self.advance();
            }
            const close = self.expect(.RBracket, "expected ']' after tuple type");
            return self.addTypeNode(.{ .span = joinSpans(open.span, close.span), .data = .{ .Tuple = try elements.toOwnedSlice(self.allocator) } });
        }

        if (self.eat(.LBrace)) {
            const open = self.previousOrCurrent();
            var members: std.ArrayList(ast_mod.TypeMember) = .empty;
            errdefer members.deinit(self.allocator);
            while (!self.at(.RBrace) and !self.at(.EOF)) {
                const before = self.index;
                const name = self.expectIdentifierLike("expected property name in object type");
                const optional = self.eat(.Question);
                _ = self.expect(.Colon, "expected ':' after property name");
                const member_type = try self.parseType();
                try members.append(self.allocator, .{
                    .name = name.lexeme,
                    .optional = optional,
                    .type_node = member_type,
                    .span = joinSpans(name.span, self.typeSpan(member_type)),
                });
                if (!self.eat(.Semicolon) and !self.eat(.Comma) and !self.at(.RBrace)) {
                    self.report("expected ';' or '}' after object type member", .expected_token);
                    self.recoverTypeMember();
                }
                if (self.index == before) _ = self.advance();
            }
            const close = self.expect(.RBrace, "expected '}' after object type");
            return self.addTypeNode(.{ .span = joinSpans(open.span, close.span), .data = .{ .Object = try members.toOwnedSlice(self.allocator) } });
        }

        const bad = self.current();
        self.report("expected type", .expected_token);
        if (!self.isTypeBoundary(bad.kind)) _ = self.advance();
        return self.addTypeNode(.{ .span = bad.span, .data = .{ .Named = .{ .name = "<error>" } } });
    }

    fn looksLikeFunctionType(self: *const Parser) bool {
        if (!self.at(.LParen)) return false;
        var depth: usize = 0;
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .LParen => depth += 1,
                .RParen => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) return i + 1 < self.tokens.len and self.tokens[i + 1].kind == .EqualsGreaterThan;
                },
                .EOF => return false,
                else => {},
            }
        }
        return false;
    }

    fn parseFunctionType(self: *Parser) anyerror!ast_mod.TypeNodeId {
        const open = self.expect(.LParen, "expected '('");
        var parameters: std.ArrayList(ast_mod.TypeParameter) = .empty;
        errdefer parameters.deinit(self.allocator);
        while (!self.at(.RParen) and !self.at(.EOF)) {
            const before = self.index;
            const name = self.expectIdentifierLike("expected function type parameter name");
            const optional = self.eat(.Question);
            _ = self.expect(.Colon, "expected ':' after function type parameter");
            const parameter_type = try self.parseType();
            try parameters.append(self.allocator, .{
                .name = name.lexeme,
                .optional = optional,
                .type_node = parameter_type,
                .span = joinSpans(name.span, self.typeSpan(parameter_type)),
            });
            if (!self.eat(.Comma)) break;
            if (self.index == before) _ = self.advance();
        }
        _ = self.expect(.RParen, "expected ')' after function type parameters");
        _ = self.expect(.EqualsGreaterThan, "expected '=>' in function type");
        const return_type = try self.parseType();
        return self.addTypeNode(.{
            .span = joinSpans(open.span, self.typeSpan(return_type)),
            .data = .{ .Function = .{ .parameters = try parameters.toOwnedSlice(self.allocator), .return_type = return_type } },
        });
    }

    fn recoverTypeMember(self: *Parser) void {
        while (!self.at(.Semicolon) and !self.at(.Comma) and !self.at(.RBrace) and !self.at(.EOF)) _ = self.advance();
        if (self.at(.Semicolon) or self.at(.Comma)) _ = self.advance();
    }

    const UnsupportedTypeSyntax = struct {
        token: Token,
        message: []const u8,
    };

    fn findUnsupportedTypeSyntax(self: *const Parser) ?UnsupportedTypeSyntax {
        var mapped: ?Token = null;
        var conditional: ?Token = null;
        var advanced: ?Token = null;
        var bracket_depth: usize = 0;
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            const token = self.tokens[i];
            if (token.kind == .EOF or (token.kind == .Semicolon and bracket_depth == 0)) break;
            if (token.kind == .LBrace or token.kind == .LParen or token.kind == .LBracket) bracket_depth += 1;
            if ((token.kind == .RBrace or token.kind == .RParen or token.kind == .RBracket) and bracket_depth > 0) bracket_depth -= 1;

            if (mapped == null and token.kind == .LBracket) {
                var j = i + 1;
                while (j < self.tokens.len and self.tokens[j].kind != .RBracket and self.tokens[j].kind != .EOF) : (j += 1) {
                    if (self.tokens[j].kind == .Keyword_in) {
                        mapped = token;
                        break;
                    }
                }
            }
            if (conditional == null and token.kind == .Keyword_extends) conditional = token;
            if (advanced == null and token.kind == .Identifier and
                (std.mem.eql(u8, token.lexeme, "keyof") or std.mem.eql(u8, token.lexeme, "infer") or
                    std.mem.eql(u8, token.lexeme, "unique") or std.mem.eql(u8, token.lexeme, "abstract")))
            {
                advanced = token;
            }
        }
        if (mapped) |token| return .{ .token = token, .message = "mapped types are not supported" };
        if (conditional) |token| return .{ .token = token, .message = "conditional types are not supported" };
        if (advanced) |token| return .{ .token = token, .message = "advanced TypeScript types are not supported" };
        return null;
    }

    fn recoverUnsupportedType(self: *Parser) void {
        while (!self.at(.Semicolon) and !self.at(.EOF)) _ = self.advance();
    }

    fn recoverUnsupportedStatement(self: *Parser) void {
        var brace_depth: usize = 0;
        while (!self.at(.EOF)) {
            const kind = self.advance().kind;
            if (kind == .LBrace) brace_depth += 1;
            if (kind == .RBrace) {
                if (brace_depth > 0) brace_depth -= 1;
                if (brace_depth == 0) return;
            }
            if (kind == .Semicolon and brace_depth == 0) return;
        }
    }

    fn recoverUnsupportedClassMember(self: *Parser) void {
        var brace_depth: usize = 0;
        while (!self.at(.RBrace) and !self.at(.EOF)) {
            const kind = self.advance().kind;
            if (kind == .LBrace) brace_depth += 1;
            if (kind == .RBrace and brace_depth > 0) {
                brace_depth -= 1;
                if (brace_depth == 0) return;
            }
            if (kind == .Semicolon and brace_depth == 0) return;
        }
    }

    fn isTypeBoundary(self: *const Parser, kind: TokenType) bool {
        _ = self;
        return switch (kind) {
            .Comma, .Semicolon, .RParen, .RBracket, .RBrace, .Equal, .EqualsGreaterThan, .EOF => true,
            else => false,
        };
    }

    fn typeSpan(self: *const Parser, id: ast_mod.TypeNodeId) tokens.Span {
        return self.type_nodes.items[@intCast(id)].span;
    }

    fn parseParameterList(self: *Parser, params: *std.ArrayList(NodeId)) !void {
        while (!self.at(.RParen) and !self.at(.EOF)) {
            const rest_token: ?Token = if (self.at(.Spread)) self.advance() else null;
            const param_token = self.expectIdentifierLike("expected parameter name");
            const param_type = try self.parseOptionalTypeAnnotation();
            while (!self.at(.Comma) and !self.at(.RParen) and !self.at(.EOF)) _ = self.advance();
            try params.append(self.allocator, try self.addNode(.{
                .span = if (rest_token) |token| joinSpans(token.span, param_token.span) else param_token.span,
                .data = .{ .Parameter = .{
                    .name = param_token.lexeme,
                    .type_annotation = param_type,
                    .rest = rest_token != null,
                } },
            }));
            if (!self.eat(.Comma)) break;
            if (rest_token != null) self.reportAt(self.previous().?, "rest parameter must be last", .unexpected_token);
        }
    }

    fn parseBlockStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.LBrace, "expected {").span;
        var statements: std.ArrayList(NodeId) = .empty;
        errdefer statements.deinit(self.allocator);
        while (!self.at(.RBrace) and !self.at(.EOF)) {
            if (try self.parseStatement()) |statement| try statements.append(self.allocator, statement);
        }
        _ = self.expect(.RBrace, "expected }");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .BlockStatement = .{ .statements = try statements.toOwnedSlice(self.allocator) } },
        });
    }

    fn parseVariableDeclarationStatement(self: *Parser) anyerror!NodeId {
        return self.parseVariableDeclaration(false);
    }

    fn parseVariableDeclaration(self: *Parser, for_header: bool) anyerror!NodeId {
        const start = self.advance();
        var declarations: std.ArrayList(NodeId) = .empty;
        errdefer declarations.deinit(self.allocator);

        while (!self.at(.Semicolon) and !self.at(.EOF) and !(for_header and (self.at(.Keyword_in) or self.atIdentifierText("of")))) {
            const name = self.expectIdentifierLike("expected variable name");
            const type_annotation: ?ast_mod.TypeAnnotation = try self.parseOptionalTypeAnnotation();
            while (!self.at(.Equal) and !self.at(.Comma) and !self.at(.Semicolon) and !self.at(.EOF) and !(for_header and (self.at(.Keyword_in) or self.atIdentifierText("of")))) _ = self.advance();
            const init = if (self.eat(.Equal)) try self.parseAssignmentExpression() else null;
            try declarations.append(self.allocator, try self.addNode(.{
                .span = joinSpans(name.span, self.previousOrCurrent().span),
                .data = .{ .VariableDeclarator = .{ .name = name.lexeme, .init = init, .type_annotation = type_annotation } },
            }));
            if (!self.eat(.Comma)) break;
        }
        if (!for_header) _ = self.eat(.Semicolon);

        return self.addNode(.{
            .span = joinSpans(start.span, self.previousOrCurrent().span),
            .data = .{ .VariableDeclaration = .{
                .kind = start.kind,
                .declarations = try declarations.toOwnedSlice(self.allocator),
            } },
        });
    }

    fn parseReturnStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_return, "expected return").span;
        const argument = if (!self.at(.Semicolon) and !self.at(.RBrace) and !self.at(.EOF)) try self.parseExpression() else null;
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ReturnStatement = .{ .argument = argument } },
        });
    }

    fn parseThrowStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_throw, "expected throw").span;
        var argument = ast_mod.invalid_node;

        if (self.current().span.line != start.line) {
            self.report("line terminator not allowed after throw", .unexpected_token);
        } else if (self.at(.Semicolon) or self.at(.RBrace) or self.at(.EOF)) {
            self.report("expected expression after throw", .expected_token);
        } else {
            argument = try self.parseExpression();
        }

        _ = self.eat(.Semicolon);
        const end = if (argument == ast_mod.invalid_node) start else self.previousOrCurrent().span;
        return self.addNode(.{
            .span = joinSpans(start, end),
            .data = .{ .ThrowStatement = .{ .argument = argument } },
        });
    }

    fn parseTryStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_try, "expected try").span;
        const block = try self.parseBlockStatement();

        var handler: ?NodeId = null;
        if (self.at(.Keyword_catch)) {
            const catch_start = self.advance().span;
            var parameter: ?NodeId = null;
            if (self.eat(.LParen)) {
                if (self.at(.Identifier)) {
                    const binding = self.advance();
                    parameter = try self.addNode(.{
                        .span = binding.span,
                        .data = .{ .Parameter = .{ .name = binding.lexeme } },
                    });
                } else {
                    self.report("expected catch binding", .expected_token);
                }
                _ = self.expect(.RParen, "expected ) after catch binding");
            }
            const body = try self.parseBlockStatement();
            handler = try self.addNode(.{
                .span = joinSpans(catch_start, self.nodes.items[@intCast(body)].span),
                .data = .{ .CatchClause = .{ .parameter = parameter, .body = body } },
            });
        }

        var finalizer: ?NodeId = null;
        if (self.at(.Keyword_finally)) {
            const finally_start = self.advance().span;
            const body = try self.parseBlockStatement();
            finalizer = try self.addNode(.{
                .span = joinSpans(finally_start, self.nodes.items[@intCast(body)].span),
                .data = .{ .FinallyClause = .{ .body = body } },
            });
        }

        if (handler == null and finalizer == null) {
            self.report("expected catch or finally after try", .expected_token);
        }
        const end_node = finalizer orelse handler orelse block;
        return self.addNode(.{
            .span = joinSpans(start, self.nodes.items[@intCast(end_node)].span),
            .data = .{ .TryStatement = .{ .block = block, .handler = handler, .finalizer = finalizer } },
        });
    }

    fn parseLoopControlStatement(self: *Parser, kind: TokenType) anyerror!NodeId {
        const start = self.advance();
        if (self.at(.Identifier)) {
            try self.diagnostics.append(self.allocator, .{
                .severity = .@"error",
                .code = .unexpected_token,
                .phase = .parser,
                .message = "labeled break and continue statements are not supported",
                .span = self.current().span,
            });
            _ = self.advance();
        }
        _ = self.eat(.Semicolon);
        const span = joinSpans(start.span, self.previousOrCurrent().span);
        return self.addNode(.{
            .span = span,
            .data = switch (kind) {
                .Keyword_break => .{ .BreakStatement = .{} },
                .Keyword_continue => .{ .ContinueStatement = .{} },
                else => unreachable,
            },
        });
    }

    fn parseExpressionStatement(self: *Parser) anyerror!NodeId {
        const expression = try self.parseExpression();
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = self.nodes.items[@intCast(expression)].span,
            .data = .{ .ExpressionStatement = .{ .expression = expression } },
        });
    }

    fn parseIfStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_if, "expected if").span;
        _ = self.expect(.LParen, "expected (");
        const condition = try self.parseExpression();
        _ = self.expect(.RParen, "expected )");
        const consequent = (try self.parseStatement()) orelse ast_mod.invalid_node;
        const alternate = if (self.eat(.Keyword_else)) (try self.parseStatement()) else null;
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .IfStatement = .{ .condition = condition, .consequent = consequent, .alternate = alternate } },
        });
    }

    fn parseWhileStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_while, "expected while").span;
        _ = self.expect(.LParen, "expected (");
        const condition = try self.parseExpression();
        _ = self.expect(.RParen, "expected )");
        const body = (try self.parseStatement()) orelse ast_mod.invalid_node;
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .WhileStatement = .{ .condition = condition, .body = body } },
        });
    }

    fn parseDoWhileStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_do, "expected do").span;
        const body = (try self.parseStatement()) orelse ast_mod.invalid_node;

        if (!self.at(.Keyword_while)) {
            self.report("expected while after do-while body", .expected_token);
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .DoWhileStatement = .{ .body = body, .condition = ast_mod.invalid_node } },
            });
        }

        _ = self.advance();
        _ = self.expect(.LParen, "expected (");
        const condition = try self.parseExpression();
        _ = self.expect(.RParen, "expected )");
        _ = self.expect(.Semicolon, "expected ; after do-while statement");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .DoWhileStatement = .{ .body = body, .condition = condition } },
        });
    }

    fn parseForStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_for, "expected for").span;
        const is_await = self.eat(.Keyword_await);
        _ = self.expect(.LParen, "expected (");

        const init = try self.parseForInitializer();

        const iteration_kind: ?ast_mod.ForStatementKind = if (self.eat(.Keyword_in))
            .in
        else if (self.atIdentifierText("of")) kind: {
            _ = self.advance();
            break :kind .of;
        } else null;

        if (iteration_kind) |kind| {
            if (is_await and kind != .of) self.report("for await requires an of loop", .unexpected_token);
            if (init) |init_node| switch (self.nodes.items[@intCast(init_node)].data) {
                .VariableDeclaration => |declaration| {
                    if (declaration.declarations.len != 1) self.report("for-in/of declaration must contain exactly one variable", .unexpected_token);
                    if (declaration.declarations.len > 0) {
                        const declarator = self.nodes.items[@intCast(declaration.declarations[0])].data.VariableDeclarator;
                        if (declarator.init != null) self.report("for-in/of declaration may not have an initializer", .unexpected_token);
                    }
                },
                else => {},
            };
            const right = try self.parseExpression();
            _ = self.expect(.RParen, "expected )");
            const body = if (self.at(.LBrace)) try self.parseBlockStatement() else (try self.parseStatement()) orelse ast_mod.invalid_node;
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .ForStatement = .{ .kind = kind, .await = is_await, .init = init, .condition = null, .update = null, .right = right, .body = body } },
            });
        }

        if (is_await) self.report("for await requires an of loop", .unexpected_token);
        _ = self.expect(.Semicolon, "expected ;");

        const condition: ?NodeId = if (self.eat(.Semicolon))
            null
        else condition: {
            const expression = try self.parseExpression();
            _ = self.expect(.Semicolon, "expected ;");
            break :condition expression;
        };

        const update: ?NodeId = if (self.at(.RParen))
            null
        else
            try self.parseExpression();
        _ = self.expect(.RParen, "expected )");

        const body = if (self.at(.LBrace)) try self.parseBlockStatement() else (try self.parseStatement()) orelse ast_mod.invalid_node;
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ForStatement = .{ .init = init, .condition = condition, .update = update, .body = body } },
        });
    }

    fn parseForInitializer(self: *Parser) anyerror!?NodeId {
        if (self.at(.Semicolon)) return null;

        const previous_allow_in = self.allow_in;
        self.allow_in = false;
        defer self.allow_in = previous_allow_in;

        if (self.isVariableKeyword(self.current().kind)) return try self.parseVariableDeclaration(true);
        return try self.parseExpression();
    }

    fn parseSwitchStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_switch, "expected switch").span;
        _ = self.expect(.LParen, "expected (");
        const discriminant = try self.parseExpression();
        _ = self.expect(.RParen, "expected )");
        _ = self.expect(.LBrace, "expected {");

        var cases: std.ArrayList(NodeId) = .empty;
        errdefer cases.deinit(self.allocator);
        var seen_default = false;
        while (!self.at(.RBrace) and !self.at(.EOF)) {
            const clause_start = self.current().span;
            var condition: ?NodeId = null;
            if (self.eat(.Keyword_case)) {
                condition = try self.parseExpression();
            } else if (self.eat(.Keyword_default)) {
                if (seen_default) self.report("duplicate default clause in switch statement", .unexpected_token);
                seen_default = true;
            } else {
                self.report("expected case or default in switch statement", .expected_token);
                _ = self.advance();
                continue;
            }
            _ = self.expect(.Colon, "expected : after switch clause");

            var consequent: std.ArrayList(NodeId) = .empty;
            errdefer consequent.deinit(self.allocator);
            while (!self.at(.Keyword_case) and !self.at(.Keyword_default) and !self.at(.RBrace) and !self.at(.EOF)) {
                const before = self.index;
                if (try self.parseStatement()) |statement| try consequent.append(self.allocator, statement);
                if (self.index == before) _ = self.advance();
            }
            const clause = try self.addNode(.{
                .span = joinSpans(clause_start, self.previousOrCurrent().span),
                .data = .{ .SwitchCase = .{ .condition = condition, .consequent = try consequent.toOwnedSlice(self.allocator) } },
            });
            try cases.append(self.allocator, clause);
        }
        _ = self.expect(.RBrace, "expected }");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .SwitchStatement = .{ .discriminant = discriminant, .cases = try cases.toOwnedSlice(self.allocator) } },
        });
    }

    fn parseExpression(self: *Parser) anyerror!NodeId {
        // H4 — prevent runaway recursion on deeply nested / pathological input.
        if (self._depth >= self.max_parse_depth) {
            _ = try self.diagnostics.append(self.allocator, .{
                .severity = .@"error",
                .code = .parse_recursion_limit_reached,
                .phase = .parser,
                .message = "maximum parse depth exceeded: input too deeply nested",
                .span = .{ .start = 0, .end = 0, .line = 0, .column = 0 },
                .label = "reduce nesting or increase max_parse_depth in BuildOptions",
            });
            return error.ParseRecursionLimitReached;
        }
        self._depth += 1;
        defer {
            if (self._depth > 0) self._depth -= 1;
        }

        const first = try self.parseAssignmentExpression();
        if (!self.eat(.Comma)) return first;

        var expressions: std.ArrayList(NodeId) = .empty;
        errdefer expressions.deinit(self.allocator);
        try expressions.append(self.allocator, first);
        while (true) {
            try expressions.append(self.allocator, try self.parseAssignmentExpression());
            if (!self.eat(.Comma)) break;
        }
        const last = expressions.items[expressions.items.len - 1];
        return self.addNode(.{
            .span = joinSpans(self.nodes.items[@intCast(first)].span, self.nodes.items[@intCast(last)].span),
            .data = .{ .SequenceExpression = .{ .expressions = try expressions.toOwnedSlice(self.allocator) } },
        });
    }

    fn binaryPrecedence(kind: TokenType) ?u8 {
        return switch (kind) {
            .PlusEqual, .MinusEqual, .AsteriskEqual, .AsteriskAsteriskEqual, .SlashEqual, .PercentEqual, .AmpersandEqual, .BarEqual, .CaretEqual, .LessThanLessThanEqual, .GreaterThanGreaterThanEqual, .GreaterThanGreaterThanGreaterThanEqual, .AmpersandAmpersandEqual, .BarBarEqual, .QuestionQuestionEqual => @as(u8, 0),
            .Question => @as(u8, 1),
            .QuestionQuestion => @as(u8, 2),
            .BarBar => @as(u8, 3),
            .AmpersandAmpersand => @as(u8, 4),
            .Bar => @as(u8, 5),
            .Caret => @as(u8, 6),
            .Ampersand => @as(u8, 7),
            .EqualsEquals, .ExclamationEquals, .EqualsEqualsEquals, .ExclamationEqualsEquals => @as(u8, 8),
            .LessThan, .LessThanEquals, .GreaterThan, .GreaterThanEquals, .Keyword_in, .Keyword_instanceof => @as(u8, 9),
            .LessThanLessThan, .GreaterThanGreaterThan, .GreaterThanGreaterThanGreaterThan => @as(u8, 10),
            .Plus, .Minus => @as(u8, 11),
            .Asterisk, .Slash, .Percent => @as(u8, 12),
            .AsteriskAsterisk => @as(u8, 13),
            else => null,
        };
    }

    fn parseAssignmentExpression(self: *Parser) anyerror!NodeId {
        if (self.isArrowFunctionStart()) return self.parseArrowFunctionExpression();

        const left = try self.parseConditionalExpression();

        // Assignment (=, +=, -=, *=, /= %=). Right-associative.
        if (self.current().kind == .Equal or
            self.current().kind == .PlusEqual or
            self.current().kind == .MinusEqual or
            self.current().kind == .AsteriskEqual or
            self.current().kind == .AsteriskAsteriskEqual or
            self.current().kind == .SlashEqual or
            self.current().kind == .PercentEqual or
            self.current().kind == .AmpersandEqual or
            self.current().kind == .BarEqual or
            self.current().kind == .CaretEqual or
            self.current().kind == .LessThanLessThanEqual or
            self.current().kind == .GreaterThanGreaterThanEqual or
            self.current().kind == .GreaterThanGreaterThanGreaterThanEqual or
            self.current().kind == .AmpersandAmpersandEqual or
            self.current().kind == .BarBarEqual or
            self.current().kind == .QuestionQuestionEqual)
        {
            const op_tok = self.advance();
            // RHS is at the SAME level (assignment), not lower. This makes `a = b = c` group as `a = (b = c)`.
            const right = try self.parseAssignmentExpression();
            return self.addNode(.{
                .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                .data = .{ .AssignmentExpression = .{ .operator = op_tok.kind, .left = left, .right = right } },
            });
        }
        return left;
    }

    fn isArrowFunctionStart(self: *const Parser) bool {
        var cursor = self.index;
        if (self.tokens[cursor].kind == .Identifier and
            std.mem.eql(u8, self.tokens[cursor].lexeme, "async") and
            self.tokens[cursor + 1].kind != .EqualsGreaterThan)
        {
            cursor += 1;
        }

        if (self.tokens[cursor].kind == .Identifier) return self.tokens[cursor + 1].kind == .EqualsGreaterThan;
        if (self.tokens[cursor].kind != .LParen) return false;
        cursor += 1;

        if (self.tokens[cursor].kind != .RParen) {
            while (true) {
                if (self.tokens[cursor].kind == .Spread) cursor += 1;
                if (self.tokens[cursor].kind != .Identifier and self.tokens[cursor].kind != .PrivateIdentifier) return false;
                cursor += 1;
                if (self.tokens[cursor].kind == .Colon) {
                    cursor += 1;
                    if (self.tokens[cursor].kind != .Identifier and self.tokens[cursor].kind != .PrivateIdentifier) return false;
                    cursor += 1;
                }
                if (self.tokens[cursor].kind != .Comma) break;
                cursor += 1;
                if (self.tokens[cursor].kind == .RParen) break;
            }
        }
        if (self.tokens[cursor].kind != .RParen) return false;
        cursor += 1;
        if (self.tokens[cursor].kind == .Colon) {
            cursor += 1;
            if (self.tokens[cursor].kind != .Identifier and self.tokens[cursor].kind != .PrivateIdentifier) return false;
            cursor += 1;
        }
        return self.tokens[cursor].kind == .EqualsGreaterThan;
    }

    fn parseArrowFunctionExpression(self: *Parser) anyerror!NodeId {
        const start = self.current().span;
        const is_async = self.atIdentifierText("async") and self.tokens[self.index + 1].kind != .EqualsGreaterThan;
        if (is_async) _ = self.advance();

        var params: std.ArrayList(NodeId) = .empty;
        errdefer params.deinit(self.allocator);
        var return_type: ?ast_mod.TypeAnnotation = null;
        if (self.eat(.LParen)) {
            try self.parseParameterList(&params);
            _ = self.expect(.RParen, "expected )");
            return_type = try self.parseOptionalTypeAnnotation();
        } else {
            const param_token = self.expectIdentifierLike("expected parameter name");
            try params.append(self.allocator, try self.addNode(.{
                .span = param_token.span,
                .data = .{ .Parameter = .{ .name = param_token.lexeme } },
            }));
        }

        _ = self.expect(.EqualsGreaterThan, "expected =>");
        const expression_body = !self.at(.LBrace);
        const body = if (expression_body) try self.parseAssignmentExpression() else try self.parseBlockStatement();
        return self.addNode(.{
            .span = joinSpans(start, self.nodes.items[@intCast(body)].span),
            .data = .{ .ArrowFunctionExpression = .{
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
                .flags = .{ .is_async = is_async },
                .expression_body = expression_body,
                .return_type = return_type,
            } },
        });
    }

    fn parseConditionalExpression(self: *Parser) anyerror!NodeId {
        const condition = try self.parseCoalescingExpression();
        if (!self.eat(.Question)) return condition;

        const consequent = try self.parseAssignmentExpression();
        _ = self.expect(.Colon, "expected : in conditional expression");
        const alternate = try self.parseAssignmentExpression();
        return self.addNode(.{
            .span = joinSpans(self.nodes.items[@intCast(condition)].span, self.nodes.items[@intCast(alternate)].span),
            .data = .{ .ConditionalExpression = .{
                .condition = condition,
                .consequent = consequent,
                .alternate = alternate,
            } },
        });
    }

    fn parseCoalescingExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseLogicalOrExpression();
        while (self.at(.QuestionQuestion)) {
            const operator = self.advance();
            const left_mixes_logical = self.isUnparenthesizedLogicalExpression(left);
            const right = try self.parseLogicalOrExpression();
            if (left_mixes_logical or self.isUnparenthesizedLogicalExpression(right)) {
                self.reportAt(operator, "cannot mix ?? with && or || without parentheses", .unexpected_token);
            }
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn isUnparenthesizedLogicalExpression(self: *const Parser, node_id: NodeId) bool {
        if (std.mem.indexOfScalar(NodeId, self.parenthesized_nodes.items, node_id) != null) return false;
        return switch (self.nodes.items[@intCast(node_id)].data) {
            .BinaryExpression => |binary| binary.operator == .AmpersandAmpersand or binary.operator == .BarBar,
            else => false,
        };
    }

    fn parseLogicalOrExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseLogicalAndExpression();
        while (self.at(.BarBar)) {
            const op_tok = self.advance();
            const right = try self.parseLogicalAndExpression();
            left = try self.addNode(.{
                .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                .data = .{ .BinaryExpression = .{ .operator = op_tok.kind, .left = left, .right = right } },
            });
        }
        return left;
    }

    fn parseLogicalAndExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseBitwiseOrExpression();
        while (self.at(.AmpersandAmpersand)) {
            const op_tok = self.advance();
            const right = try self.parseBitwiseOrExpression();
            left = try self.addNode(.{
                .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                .data = .{ .BinaryExpression = .{ .operator = op_tok.kind, .left = left, .right = right } },
            });
        }
        return left;
    }

    fn parseBitwiseOrExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseBitwiseXorExpression();
        while (self.at(.Bar)) {
            const operator = self.advance();
            const right = try self.parseBitwiseXorExpression();
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn parseBitwiseXorExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseBitwiseAndExpression();
        while (self.at(.Caret)) {
            const operator = self.advance();
            const right = try self.parseBitwiseAndExpression();
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn parseBitwiseAndExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseEqualityExpression();
        while (self.at(.Ampersand)) {
            const operator = self.advance();
            const right = try self.parseEqualityExpression();
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn parseEqualityExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseRelationalExpression();
        while (true) {
            left = switch (self.current().kind) {
                .EqualsEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseRelationalExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .EqualsEquals, .left = left, .right = right } },
                    });
                },
                .ExclamationEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseRelationalExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .ExclamationEquals, .left = left, .right = right } },
                    });
                },
                .EqualsEqualsEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseRelationalExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .EqualsEqualsEquals, .left = left, .right = right } },
                    });
                },
                .ExclamationEqualsEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseRelationalExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .ExclamationEqualsEquals, .left = left, .right = right } },
                    });
                },
                else => break,
            };
        }
        return left;
    }

    fn parseRelationalExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseShiftExpression();
        while (true) {
            const operator = switch (self.current().kind) {
                .LessThan, .LessThanEquals, .GreaterThan, .GreaterThanEquals, .Keyword_instanceof => self.advance(),
                .Keyword_in => if (self.allow_in) self.advance() else break,
                else => break,
            };
            const right = try self.parseShiftExpression();
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn parseShiftExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseAdditiveExpression();
        while (true) {
            const operator = switch (self.current().kind) {
                .LessThanLessThan, .GreaterThanGreaterThan, .GreaterThanGreaterThanGreaterThan => self.advance(),
                else => break,
            };
            const right = try self.parseAdditiveExpression();
            left = try self.addBinaryExpression(operator.kind, left, right);
        }
        return left;
    }

    fn parseAdditiveExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseMultiplicativeExpression();
        while (true) {
            left = switch (self.current().kind) {
                .Plus => blk: {
                    _ = self.advance();
                    const right = try self.parseMultiplicativeExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Plus, .left = left, .right = right } },
                    });
                },
                .Minus => blk: {
                    _ = self.advance();
                    const right = try self.parseMultiplicativeExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Minus, .left = left, .right = right } },
                    });
                },
                else => break,
            };
        }
        return left;
    }

    fn parseMultiplicativeExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parseExponentiationExpression();
        while (true) {
            left = switch (self.current().kind) {
                .Asterisk => blk: {
                    _ = self.advance();
                    const right = try self.parseExponentiationExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Asterisk, .left = left, .right = right } },
                    });
                },
                .Slash => blk: {
                    _ = self.advance();
                    const right = try self.parseExponentiationExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Slash, .left = left, .right = right } },
                    });
                },
                .Percent => blk: {
                    _ = self.advance();
                    const right = try self.parseExponentiationExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Percent, .left = left, .right = right } },
                    });
                },
                else => break,
            };
        }
        return left;
    }

    fn parseExponentiationExpression(self: *Parser) anyerror!NodeId {
        const left = try self.parseUnaryExpression();
        if (!self.at(.AsteriskAsterisk)) return left;

        const operator = self.advance();
        const right = try self.parseExponentiationExpression();
        return self.addBinaryExpression(operator.kind, left, right);
    }

    fn addBinaryExpression(self: *Parser, operator: TokenType, left: NodeId, right: NodeId) anyerror!NodeId {
        return self.addNode(.{
            .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
            .data = .{ .BinaryExpression = .{ .operator = operator, .left = left, .right = right } },
        });
    }

    fn parseUnaryExpression(self: *Parser) anyerror!NodeId {
        return switch (self.current().kind) {
            .PlusPlus, .MinusMinus => blk: {
                const operator = self.advance();
                const argument = try self.parseUnaryExpression();
                break :blk try self.addNode(.{
                    .span = joinSpans(operator.span, self.nodes.items[@intCast(argument)].span),
                    .data = .{ .UpdateExpression = .{ .operator = operator.kind, .argument = argument, .prefix = true } },
                });
            },
            .Exclamation,
            .Tilde,
            .Minus,
            .Plus,
            .Keyword_typeof,
            .Keyword_void,
            .Keyword_delete,
            .Keyword_await,
            => blk: {
                const operator = self.advance();
                const argument = try self.parseUnaryExpression();
                break :blk try self.addNode(.{
                    .span = joinSpans(operator.span, self.nodes.items[@intCast(argument)].span),
                    .data = .{ .UnaryExpression = .{ .operator = operator.kind, .argument = argument } },
                });
            },
            else => self.parsePrimary(),
        };
    }

    fn isLogicalOrOperator(_: *const Parser, kind: TokenType) bool {
        return kind == .BarBar or kind == .AmpersandAmpersand;
    }

    fn isObjectPropertyKeyToken(token: Token) bool {
        return token.kind == .Identifier or token.kind == .PrivateIdentifier or
            token.kind == .StringLiteral or token.kind == .NumberLiteral;
    }

    fn objectPropertyKey(token: Token) []const u8 {
        return switch (token.kind) {
            .Identifier, .PrivateIdentifier, .NumberLiteral => token.lexeme,
            .StringLiteral => token.lexeme[1 .. token.lexeme.len - 1],
            else => unreachable,
        };
    }

    fn parseObjectExpression(self: *Parser) anyerror!NodeId {
        // The LBrace was already consumed by parsePrimary before dispatching here.
        const start = self.previous().?.span;
        var properties: std.ArrayList(ast_mod.ObjectProperty) = .empty;
        errdefer properties.deinit(self.allocator);
        while (!self.at(.RBrace) and !self.at(.EOF)) {
            if (self.at(.Spread)) {
                const spread_token = self.advance();
                const value = try self.parseSpreadElement(spread_token);
                try properties.append(self.allocator, .{
                    .kind = .spread,
                    .key_span = spread_token.span,
                    .value = value,
                });
                if (!self.eat(.Comma)) break;
                continue;
            }
            if (self.at(.LBracket)) {
                const key_start = self.advance();
                const computed_key = try self.parseExpression();
                const key_end = self.expect(.RBracket, "expected ]");
                _ = self.expect(.Colon, "expected :");
                const value = try self.parseAssignmentExpression();
                try properties.append(self.allocator, .{
                    .kind = .computed,
                    .key_span = joinSpans(key_start.span, key_end.span),
                    .computed_key = computed_key,
                    .value = value,
                });
                if (!self.eat(.Comma)) break;
                continue;
            }
            const key_tok = self.advance();
            const key_tok_kind = key_tok.kind;

            // Accept Identifier, PrivateIdentifier, StringLiteral; also NumberLiteral for "0: ..." keys.
            if (key_tok_kind != .Identifier and key_tok_kind != .PrivateIdentifier and
                key_tok_kind != .StringLiteral and key_tok_kind != .NumberLiteral)
            {
                self.reportAt(key_tok, "expected property key", .expected_token);
                break;
            }

            const key = switch (key_tok_kind) {
                .Identifier, .PrivateIdentifier => key_tok.lexeme,
                .StringLiteral => blk: {
                    // Strip surrounding quotes. StringLiteral lexeme includes the quote chars.
                    const s = key_tok.lexeme;
                    break :blk s[1 .. s.len - 1];
                },
                .NumberLiteral => blk: {
                    // Numeric literal key — use its textual form as the property name.
                    break :blk key_tok.lexeme;
                },
                else => unreachable,
            };

            if ((std.mem.eql(u8, key, "async") or std.mem.eql(u8, key, "get") or std.mem.eql(u8, key, "set")) and
                isObjectPropertyKeyToken(self.current()) and self.peek(1).kind == .LParen)
            {
                const modifier = key;
                const method_key = self.advance();
                const method_name = objectPropertyKey(method_key);
                const kind: ast_mod.ObjectPropertyKind = if (std.mem.eql(u8, modifier, "async"))
                    .async_method
                else if (std.mem.eql(u8, modifier, "get"))
                    .getter
                else
                    .setter;
                const value = try self.parseObjectMethod(key_tok, kind == .async_method);
                try properties.append(self.allocator, .{
                    .kind = kind,
                    .key = method_name,
                    .key_span = method_key.span,
                    .value = value,
                });
            } else if (self.at(.LParen)) {
                const value = try self.parseObjectMethod(key_tok, false);
                try properties.append(self.allocator, .{
                    .kind = .method,
                    .key = key,
                    .key_span = key_tok.span,
                    .value = value,
                });
            } else if ((key_tok_kind == .Identifier or key_tok_kind == .PrivateIdentifier) and
                (self.at(.Comma) or self.at(.RBrace)))
            {
                const value = try self.addNode(.{
                    .span = key_tok.span,
                    .data = .{ .Identifier = .{ .name = key } },
                });
                try properties.append(self.allocator, .{
                    .kind = .shorthand,
                    .key = key,
                    .key_span = key_tok.span,
                    .value = value,
                });
            } else {
                _ = self.expect(.Colon, "expected :");
                const value = try self.parseAssignmentExpression();
                try properties.append(self.allocator, .{
                    .kind = .key_value,
                    .key = key,
                    .key_span = key_tok.span,
                    .value = value,
                });
            }
            if (!self.eat(.Comma)) break;
        }
        _ = self.expect(.RBrace, "expected }");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = @unionInit(ast_mod.NodeData, "ObjectExpression", .{ .properties = try properties.toOwnedSlice(self.allocator) }),
        });
    }

    fn parseObjectMethod(self: *Parser, start: Token, is_async: bool) anyerror!NodeId {
        _ = self.expect(.LParen, "expected (");
        var params: std.ArrayList(NodeId) = .empty;
        errdefer params.deinit(self.allocator);
        try self.parseParameterList(&params);
        _ = self.expect(.RParen, "expected )");
        const return_type = try self.parseOptionalTypeAnnotation();
        const body = if (self.at(.LBrace)) try self.parseBlockStatement() else blk: {
            self.report("expected function body", .expected_token);
            break :blk ast_mod.invalid_node;
        };
        const end_span = if (body == ast_mod.invalid_node) self.previousOrCurrent().span else self.nodes.items[@intCast(body)].span;
        return self.addNode(.{
            .span = joinSpans(start.span, end_span),
            .data = .{ .FunctionExpression = .{
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
                .flags = .{ .is_async = is_async },
                .return_type = return_type,
            } },
        });
    }

    fn parseArrayExpression(self: *Parser) anyerror!NodeId {
        // The LBracket was already consumed by parsePrimary before dispatching here.
        const start = self.previous().?.span;
        var elements: std.ArrayList(?NodeId) = .empty;
        errdefer elements.deinit(self.allocator);

        while (!self.at(.RBracket) and !self.at(.EOF)) {
            if (self.eat(.Comma)) {
                try elements.append(self.allocator, null);
                continue;
            }
            const elem = if (self.at(.Spread)) blk: {
                const spread_token = self.advance();
                break :blk try self.parseSpreadElement(spread_token);
            } else try self.parseAssignmentExpression();
            try elements.append(self.allocator, elem);
            _ = self.eat(.Comma); // trailing comma allowed by spec
        }

        _ = self.expect(.RBracket, "expected ]");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = @unionInit(ast_mod.NodeData, "ArrayExpression", .{ .elements = try elements.toOwnedSlice(self.allocator) }),
        });
    }

    fn parseTemplateExpression(self: *Parser, head: Token) anyerror!NodeId {
        var parts: std.ArrayList(ast_mod.TemplatePart) = .empty;
        errdefer parts.deinit(self.allocator);

        if (head.kind == .NoSubstitutionTemplate) {
            try parts.append(self.allocator, .{
                .raw = head.lexeme[1 .. head.lexeme.len - 1],
                .cooked = null,
                .expression = null,
                .span = .{
                    .start = head.span.start + 1,
                    .end = head.span.end - 1,
                    .line = head.span.line,
                    .column = head.span.column + 1,
                },
            });
            return self.addNode(.{
                .span = head.span,
                .data = .{ .TemplateExpression = .{ .parts = try parts.toOwnedSlice(self.allocator) } },
            });
        }

        var chunk = head;

        while (true) {
            const expression = try self.parseExpression();
            try parts.append(self.allocator, .{
                .raw = chunk.lexeme[1 .. chunk.lexeme.len - 2],
                .cooked = null,
                .expression = expression,
                .span = .{
                    .start = chunk.span.start + 1,
                    .end = chunk.span.end - 2,
                    .line = chunk.span.line,
                    .column = chunk.span.column + 1,
                },
            });

            if (!self.at(.TemplateMiddle) and !self.at(.TemplateTail)) {
                self.reportAt(self.current(), "expected template continuation", .expected_token);
                break;
            }
            chunk = self.advance();
            if (chunk.kind == .TemplateTail) {
                try parts.append(self.allocator, .{
                    .raw = chunk.lexeme[1 .. chunk.lexeme.len - 1],
                    .cooked = null,
                    .expression = null,
                    .span = .{
                        .start = chunk.span.start + 1,
                        .end = chunk.span.end - 1,
                        .line = chunk.span.line,
                        .column = chunk.span.column + 1,
                    },
                });
                break;
            }
        }

        return self.addNode(.{
            .span = joinSpans(head.span, chunk.span),
            .data = .{ .TemplateExpression = .{ .parts = try parts.toOwnedSlice(self.allocator) } },
        });
    }

    fn parsePrimary(self: *Parser) anyerror!NodeId {
        var node = try self.parsePrimaryAtom();

        while (true) {
            if (self.eat(.QuestionDot)) {
                if (self.eat(.LParen)) {
                    const args = try self.parseArguments();
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                        .data = .{ .CallExpression = .{ .callee = node, .arguments = args, .optional = true } },
                    });
                    continue;
                }
                if (self.eat(.LBracket)) {
                    const index_expr = try self.parseExpression();
                    _ = self.expect(.RBracket, "expected ]");
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                        .data = .{ .ElementAccessExpression = .{ .object = node, .index = index_expr, .optional = true } },
                    });
                    continue;
                }
                if (self.at(.Identifier) or self.at(.PrivateIdentifier)) {
                    const property = self.advance();
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, property.span),
                        .data = .{ .MemberExpression = .{ .object = node, .property = property.lexeme, .optional = true } },
                    });
                    continue;
                }
                self.report("expected property name, [ or ( after ?.", .expected_token);
                break;
            }
            if (self.eat(.LParen)) {
                const args = try self.parseArguments();
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                    .data = .{ .CallExpression = .{ .callee = node, .arguments = args } },
                });
                continue;
            }
            if (self.eat(.Dot)) {
                const property = self.expectIdentifierLike("expected property name");
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, property.span),
                    .data = .{ .MemberExpression = .{ .object = node, .property = property.lexeme } },
                });
                continue;
            }
            if (self.eat(.LBracket)) {
                const index_expr = try self.parseExpression();
                _ = self.expect(.RBracket, "expected ]");
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                    .data = .{ .ElementAccessExpression = .{ .object = node, .index = index_expr } },
                });
                continue;
            }
            if (self.at(.NoSubstitutionTemplate) or self.at(.TemplateHead)) {
                const template = try self.parseTemplateExpression(self.advance());
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.nodes.items[@intCast(template)].span),
                    .data = .{ .TaggedTemplateExpression = .{ .tag = node, .template = template } },
                });
                continue;
            }
            if (self.eat(.Exclamation)) {
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                    .data = .{ .NonNullExpression = .{ .expression = node } },
                });
                continue;
            }
            if (self.at(.PlusPlus) or self.at(.MinusMinus)) {
                const op_tok = self.advance();
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, op_tok.span),
                    .data = .{ .UpdateExpression = .{ .operator = op_tok.kind, .argument = node, .prefix = false } },
                });
                continue;
            }
            // TypeScript `as` assertion uses the same structured type grammar as declarations.
            if (self.atIdentifierText("as")) {
                const as_tok = self.advance();
                const type_root = try self.parseType();
                if (type_root != ast_mod.invalid_type_node) {
                    const type_span = self.typeSpan(type_root);
                    const span = joinSpans(as_tok.span, type_span);
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, span),
                        .data = .{ .AsExpression = .{
                            .expression = node,
                            .type_annotation = .{ .root = type_root, .span = type_span },
                        } },
                    });
                    continue;
                } else {
                    self.reportAt(as_tok, "expected type after 'as'", .expected_token);
                    break;
                }
            }
            // TypeScript `satisfies` shares `as` precedence but remains a distinct node.
            if (self.atIdentifierText("satisfies")) {
                const satisfies_tok = self.advance();
                const type_root = try self.parseType();
                if (type_root != ast_mod.invalid_type_node) {
                    const type_span = self.typeSpan(type_root);
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, type_span),
                        .data = .{ .SatisfiesExpression = .{
                            .expression = node,
                            .type_annotation = .{ .root = type_root, .span = type_span },
                        } },
                    });
                    continue;
                } else {
                    self.reportAt(satisfies_tok, "expected type after 'satisfies'", .expected_token);
                    break;
                }
            }
            break;
        }

        return node;
    }

    fn parsePrimaryAtom(self: *Parser) anyerror!NodeId {
        var node: NodeId = undefined;
        const token = self.advance();
        switch (token.kind) {
            .Identifier, .PrivateIdentifier => {
                if (std.mem.eql(u8, token.lexeme, "async") and self.at(.Keyword_function)) {
                    node = try self.parseFunctionExpression(token, true);
                } else {
                    node = try self.addNode(.{
                        .span = token.span,
                        .data = .{ .Identifier = .{ .name = token.lexeme } },
                    });
                }
            },
            .Keyword_function => node = try self.parseFunctionExpression(token, false),
            .Keyword_class => node = try self.parseClassExpression(token),
            .Keyword_this => node = try self.addNode(.{ .span = token.span, .data = .{ .ThisExpression = .{} } }),
            .Keyword_super => node = try self.addNode(.{ .span = token.span, .data = .{ .SuperExpression = .{} } }),
            .Keyword_new => node = if (self.at(.Dot)) try self.parseMetaProperty(token, "target", .new_target) else try self.parseNewExpression(token),
            .Keyword_import => node = if (self.at(.Dot)) try self.parseMetaProperty(token, "meta", .import_meta) else try self.parseImportExpression(token),
            .StringLiteral, .NumberLiteral, .BigIntLiteral, .TrueLiteral, .FalseLiteral, .NullLiteral => node = try self.addNode(.{
                .span = token.span,
                .data = .{ .Literal = .{ .value = token.lexeme } },
            }),
            .RegExpLiteral => {
                const closing_slash = std.mem.lastIndexOfScalar(u8, token.lexeme, '/').?;
                var flags = tokens.RegExpFlags{};
                for (token.lexeme[closing_slash + 1 ..]) |flag_char| flags.set(tokens.regexpFlagFromChar(flag_char).?);
                node = try self.addNode(.{
                    .span = token.span,
                    .data = .{ .RegExpLiteral = .{
                        .pattern = token.lexeme[1..closing_slash],
                        .flags = flags,
                    } },
                });
            },
            .NoSubstitutionTemplate, .TemplateHead => node = try self.parseTemplateExpression(token),
            .LParen => {
                const previous_allow_in = self.allow_in;
                self.allow_in = true;
                defer self.allow_in = previous_allow_in;
                node = try self.parseExpression();
                _ = self.expect(.RParen, "expected )");
                try self.parenthesized_nodes.append(self.allocator, node);
            },
            .LBrace => {
                node = try self.parseObjectExpression();
            },
            .LBracket => {
                node = try self.parseArrayExpression();
            },
            .LessThan => {
                self.reportAt(token, "JSX and TSX syntax is not supported", .unsupported_jsx);
                while (!self.at(.Semicolon) and !self.at(.Comma) and !self.at(.RParen) and !self.at(.EOF)) _ = self.advance();
                node = try self.addNode(.{
                    .span = token.span,
                    .data = .{ .Identifier = .{ .name = "" } },
                });
            },
            else => {
                self.reportAt(token, "expected expression", .expected_token);
                node = try self.addNode(.{
                    .span = token.span,
                    .data = .{ .Identifier = .{ .name = "" } },
                });
            },
        }
        return node;
    }

    fn parseNewExpression(self: *Parser, new_token: Token) anyerror!NodeId {
        var callee = try self.parsePrimaryAtom();
        while (true) {
            if (self.eat(.Dot)) {
                const property = self.expectIdentifierLike("expected property name");
                callee = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(callee)].span, property.span),
                    .data = .{ .MemberExpression = .{ .object = callee, .property = property.lexeme } },
                });
                continue;
            }
            if (self.eat(.LBracket)) {
                const index_expr = try self.parseExpression();
                _ = self.expect(.RBracket, "expected ]");
                callee = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(callee)].span, self.previousOrCurrent().span),
                    .data = .{ .ElementAccessExpression = .{ .object = callee, .index = index_expr } },
                });
                continue;
            }
            break;
        }

        const arguments = if (self.eat(.LParen)) try self.parseArguments() else try self.allocator.alloc(NodeId, 0);
        const end_span = if (arguments.len > 0 or self.previousOrCurrent().kind == .RParen)
            self.previousOrCurrent().span
        else
            self.nodes.items[@intCast(callee)].span;
        return self.addNode(.{
            .span = joinSpans(new_token.span, end_span),
            .data = .{ .NewExpression = .{ .callee = callee, .arguments = arguments } },
        });
    }

    fn parseArguments(self: *Parser) anyerror![]const NodeId {
        var args: std.ArrayList(NodeId) = .empty;
        errdefer args.deinit(self.allocator);
        while (!self.at(.RParen) and !self.at(.EOF)) {
            const argument = if (self.at(.Spread)) blk: {
                const spread_token = self.advance();
                break :blk try self.parseSpreadElement(spread_token);
            } else try self.parseAssignmentExpression();
            try args.append(self.allocator, argument);
            _ = self.eat(.Comma);
        }
        _ = self.expect(.RParen, "expected )");
        return args.toOwnedSlice(self.allocator);
    }

    fn parseSpreadElement(self: *Parser, spread_token: Token) anyerror!NodeId {
        const argument = try self.parseAssignmentExpression();
        return self.addNode(.{
            .span = joinSpans(spread_token.span, self.nodes.items[@intCast(argument)].span),
            .data = .{ .SpreadElement = .{ .argument = argument } },
        });
    }

    fn addNode(self: *Parser, node: ast_mod.Node) anyerror!NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return id;
    }

    fn addTypeNode(self: *Parser, node: ast_mod.TypeNode) anyerror!ast_mod.TypeNodeId {
        const id: ast_mod.TypeNodeId = @intCast(self.type_nodes.items.len);
        try self.type_nodes.append(self.allocator, node);
        return id;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peek(self: *const Parser, offset: usize) Token {
        return self.tokens[@min(self.index + offset, self.tokens.len - 1)];
    }

    fn previous(self: *const Parser) ?Token {
        if (self.index == 0) return null;
        return self.tokens[self.index - 1];
    }

    fn previousOrCurrent(self: *const Parser) Token {
        return self.previous() orelse self.current();
    }

    fn advance(self: *Parser) Token {
        const token = self.current();
        if (!self.at(.EOF)) self.index += 1;
        return token;
    }

    fn at(self: *const Parser, kind: TokenType) bool {
        return self.current().kind == kind;
    }

    fn atIdentifierText(self: *const Parser, text: []const u8) bool {
        return self.at(.Identifier) and std.mem.eql(u8, self.current().lexeme, text);
    }

    fn eat(self: *Parser, kind: TokenType) bool {
        if (!self.at(kind)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Parser, kind: TokenType, message: []const u8) Token {
        if (self.at(kind)) return self.advance();
        self.report(message, .expected_token);
        return self.current();
    }

    fn expectIdentifierLike(self: *Parser, message: []const u8) Token {
        if (self.at(.Identifier) or self.at(.PrivateIdentifier)) return self.advance();
        self.report(message, .expected_token);
        return self.current();
    }

    fn report(self: *Parser, message: []const u8, code: diagnostics.DiagnosticCode) void {
        self.reportAt(self.current(), message, code);
    }

    fn reportAt(self: *Parser, token: Token, message: []const u8, code: diagnostics.DiagnosticCode) void {
        self.diagnostics.append(self.allocator, .{
            .severity = .@"error",
            .code = code,
            .phase = .parser,
            .message = message,
            .span = token.span,
        }) catch |err| {
            self.allocation_error = err;
        };
    }

    fn isVariableKeyword(_: *const Parser, kind: TokenType) bool {
        return kind == .Keyword_const or kind == .Keyword_let or kind == .Keyword_var;
    }

    fn isBinaryOperator(_: *const Parser, kind: TokenType) bool {
        return switch (kind) {
            .Plus,
            .Minus,
            .Asterisk,
            .Slash,
            .Percent,
            .AsteriskAsterisk,
            .Ampersand,
            .Bar,
            .Caret,
            .LessThanLessThan,
            .GreaterThanGreaterThan,
            .GreaterThanGreaterThanGreaterThan,
            .EqualsEquals,
            .EqualsEqualsEquals,
            .ExclamationEquals,
            .ExclamationEqualsEquals,
            .LessThan,
            .LessThanEquals,
            .GreaterThan,
            .GreaterThanEquals,
            .AmpersandAmpersand,
            .BarBar,
            .QuestionQuestion,
            => true,
            else => false,
        };
    }
};

pub const ParseOptions = struct {
    // Whether to recover from unexpected tokens rather than abort. Default: true (error recovery on).
    recover_errors: bool = true,
    // Maximum recursive descent depth before rejecting with diagnostic; protects against pathological
    // nesting DoS (H4). Defaults to 1024 which is plenty for real code but stops runaway builds.
    max_parse_depth: usize = 1024,
};

pub fn parse(allocator: std.mem.Allocator, token_list: []const Token, options: ParseOptions) anyerror!ParseResult {
    var parser = Parser{
        .allocator = allocator,
        .tokens = token_list,
        .recover_errors = options.recover_errors,
        .max_parse_depth = options.max_parse_depth,
    };
    return parser.parse();
}

test "parser preserves logical assignments and right associativity" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\value &&= next;
        \\value ||= fallback;
        \\value ??= fallback;
        \\a ||= b ||= c;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(scan.tokens.len - 1, parsed.consumed_tokens);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const operators = [_]TokenType{ .AmpersandAmpersandEqual, .BarBarEqual, .QuestionQuestionEqual };
    for (operators, 0..) |operator, index| {
        const expression = parsed.ast.node(statements[index]).data.ExpressionStatement.expression;
        try std.testing.expectEqual(operator, parsed.ast.node(expression).data.AssignmentExpression.operator);
    }

    const outer_id = parsed.ast.node(statements[3]).data.ExpressionStatement.expression;
    const outer = parsed.ast.node(outer_id).data.AssignmentExpression;
    try std.testing.expectEqual(TokenType.BarBarEqual, outer.operator);
    try std.testing.expectEqualStrings("a", parsed.ast.node(outer.left).data.Identifier.name);
    const inner = parsed.ast.node(outer.right).data.AssignmentExpression;
    try std.testing.expectEqual(TokenType.BarBarEqual, inner.operator);
    try std.testing.expectEqualStrings("b", parsed.ast.node(inner.left).data.Identifier.name);
    try std.testing.expectEqualStrings("c", parsed.ast.node(inner.right).data.Identifier.name);
}

test "parser preserves satisfies expressions precedence and as chains" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\const config = value satisfies Config;
        \\const chained = value as Input satisfies Output;
        \\const reverse = value satisfies Input as Output;
        \\const selected = value satisfies Config ? yes : no;
        \\const satisfies = value;
        \\satisfies;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(scan.tokens.len - 1, parsed.consumed_tokens);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const config_decl = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const config_id = parsed.ast.node(config_decl.declarations[0]).data.VariableDeclarator.init.?;
    const config = parsed.ast.node(config_id).data.SatisfiesExpression;
    try std.testing.expectEqualStrings("value", parsed.ast.node(config.expression).data.Identifier.name);
    try std.testing.expectEqualStrings("Config", parsed.ast.typeNode(config.type_annotation.root).data.Named.name);

    const chained_decl = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const chained_id = parsed.ast.node(chained_decl.declarations[0]).data.VariableDeclarator.init.?;
    const chained = parsed.ast.node(chained_id).data.SatisfiesExpression;
    try std.testing.expectEqual(.AsExpression, std.meta.activeTag(parsed.ast.node(chained.expression).data));

    const reverse_decl = parsed.ast.node(statements[2]).data.VariableDeclaration;
    const reverse_id = parsed.ast.node(reverse_decl.declarations[0]).data.VariableDeclarator.init.?;
    const reverse = parsed.ast.node(reverse_id).data.AsExpression;
    try std.testing.expectEqual(.SatisfiesExpression, std.meta.activeTag(parsed.ast.node(reverse.expression).data));

    const selected_decl = parsed.ast.node(statements[3]).data.VariableDeclaration;
    const selected_id = parsed.ast.node(selected_decl.declarations[0]).data.VariableDeclarator.init.?;
    const selected = parsed.ast.node(selected_id).data.ConditionalExpression;
    try std.testing.expectEqual(.SatisfiesExpression, std.meta.activeTag(parsed.ast.node(selected.condition).data));

    const identifier_expression = parsed.ast.node(statements[5]).data.ExpressionStatement.expression;
    try std.testing.expectEqualStrings("satisfies", parsed.ast.node(identifier_expression).data.Identifier.name);
}

test "parser preserves tagged template tags and raw payload availability" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\const html = tag`<p>${name}</p>`;
        \\const member = obj.tag`text\n`;
        \\const plain = `untagged`;
        \\const called = factory()`value`;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const html_decl = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const html_id = parsed.ast.node(html_decl.declarations[0]).data.VariableDeclarator.init.?;
    const html = parsed.ast.node(html_id).data.TaggedTemplateExpression;
    try std.testing.expectEqual(.Identifier, std.meta.activeTag(parsed.ast.node(html.tag).data));
    const html_template = parsed.ast.node(html.template).data.TemplateExpression;
    try std.testing.expectEqualStrings("<p>", html_template.parts[0].raw);
    try std.testing.expectEqualStrings("</p>", html_template.parts[1].raw);
    try std.testing.expect(html_template.parts[0].cooked == null);

    const member_decl = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const member_id = parsed.ast.node(member_decl.declarations[0]).data.VariableDeclarator.init.?;
    const member = parsed.ast.node(member_id).data.TaggedTemplateExpression;
    try std.testing.expectEqual(.MemberExpression, std.meta.activeTag(parsed.ast.node(member.tag).data));
    const member_template = parsed.ast.node(member.template).data.TemplateExpression;
    try std.testing.expectEqualStrings("text\\n", member_template.parts[0].raw);
    try std.testing.expect(member_template.parts[0].cooked == null);

    const plain_decl = parsed.ast.node(statements[2]).data.VariableDeclaration;
    const plain_id = parsed.ast.node(plain_decl.declarations[0]).data.VariableDeclarator.init.?;
    const plain = parsed.ast.node(plain_id).data.TemplateExpression;
    try std.testing.expectEqualStrings("untagged", plain.parts[0].raw);

    const called_decl = parsed.ast.node(statements[3]).data.VariableDeclaration;
    const called_id = parsed.ast.node(called_decl.declarations[0]).data.VariableDeclarator.init.?;
    const called = parsed.ast.node(called_id).data.TaggedTemplateExpression;
    try std.testing.expectEqual(.CallExpression, std.meta.activeTag(parsed.ast.node(called.tag).data));
}

test "parser distinguishes dynamic imports from static declarations" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scan = try scanner.scanAll(allocator,
        \\import value from "./static";
        \\const mod = import("./dynamic", options);
        \\consume(flag ? import("./a") : import("./b"));
    , true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    try std.testing.expectEqual(.ImportDeclaration, std.meta.activeTag(parsed.ast.node(statements[0]).data));
    const declaration = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const import_id = parsed.ast.node(declaration.declarations[0]).data.VariableDeclarator.init.?;
    const import_expr = parsed.ast.node(import_id).data.ImportExpression;
    try std.testing.expectEqual(.Literal, std.meta.activeTag(parsed.ast.node(import_expr.source).data));
    try std.testing.expect(import_expr.options != null);
    const call = parsed.ast.node(statements[2]).data.ExpressionStatement.expression;
    const conditional = parsed.ast.node(parsed.ast.node(call).data.CallExpression.arguments[0]).data.ConditionalExpression;
    try std.testing.expectEqual(.ImportExpression, std.meta.activeTag(parsed.ast.node(conditional.consequent).data));
    try std.testing.expectEqual(.ImportExpression, std.meta.activeTag(parsed.ast.node(conditional.alternate).data));
}

test "parser preserves strict meta-properties, spans, nesting, and recovery" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const url = import.meta.url;
        \\function current() { return new.target; }
        \\import.target;
        \\const afterImport = 1;
        \\new.meta;
        \\const afterNew = 2;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.diagnostics.len);
    try std.testing.expectEqualStrings("expected 'meta' after import.", parsed.diagnostics[0].message);
    try std.testing.expectEqualStrings("expected 'target' after new.", parsed.diagnostics[1].message);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    try std.testing.expectEqual(@as(usize, 6), statements.len);

    const url_decl = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const url_member_id = parsed.ast.node(url_decl.declarations[0]).data.VariableDeclarator.init.?;
    const url_member = parsed.ast.node(url_member_id).data.MemberExpression;
    const import_meta_node = parsed.ast.node(url_member.object);
    try std.testing.expectEqual(.import_meta, import_meta_node.data.MetaProperty.kind);
    try std.testing.expectEqualStrings("import.meta", source[import_meta_node.span.start..import_meta_node.span.end]);

    const function = parsed.ast.node(statements[1]).data.FunctionDeclaration;
    const body = parsed.ast.node(function.body).data.BlockStatement.statements;
    const returned = parsed.ast.node(body[0]).data.ReturnStatement.argument.?;
    const new_target_node = parsed.ast.node(returned);
    try std.testing.expectEqual(.new_target, new_target_node.data.MetaProperty.kind);
    try std.testing.expectEqualStrings("new.target", source[new_target_node.span.start..new_target_node.span.end]);

    try std.testing.expectEqual(.VariableDeclaration, std.meta.activeTag(parsed.ast.node(statements[3]).data));
    try std.testing.expectEqual(.VariableDeclaration, std.meta.activeTag(parsed.ast.node(statements[5]).data));
}

fn joinSpans(a: tokens.Span, b: tokens.Span) tokens.Span {
    return .{ .start = a.start, .end = b.end, .line = a.line, .column = a.column };
}

fn trimString(lexeme: []const u8) []const u8 {
    if (lexeme.len >= 2) return lexeme[1 .. lexeme.len - 1];
    return lexeme;
}

test "parser builds declarations and function body" {
    const scanner = @import("scanner.zig");
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
    const parsed = try parse(allocator, scan.tokens, .{});

    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const root = parsed.ast.node(parsed.ast.root);
    try std.testing.expectEqual(@as(usize, 2), root.data.Program.statements.len);
}

test "parser builds prefix unary expressions with correct precedence" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let a = !value;
        \\let b = ~value;
        \\let c = -value;
        \\let d = +value;
        \\let e = typeof object.key;
        \\let f = void value;
        \\let g = delete object.key;
        \\let h = await fn();
        \\let i = !-value;
        \\let j = -value * value;
        \\let k = value!;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const expected = [_]TokenType{ .Exclamation, .Tilde, .Minus, .Plus, .Keyword_typeof, .Keyword_void, .Keyword_delete, .Keyword_await };
    for (expected, 0..) |operator, index| {
        const declaration = parsed.ast.node(statements[index]).data.VariableDeclaration;
        const init = parsed.ast.node(declaration.declarations[0]).data.VariableDeclarator.init.?;
        try std.testing.expectEqual(operator, parsed.ast.node(init).data.UnaryExpression.operator);
    }

    const chain_decl = parsed.ast.node(statements[8]).data.VariableDeclaration;
    const chain_init = parsed.ast.node(chain_decl.declarations[0]).data.VariableDeclarator.init.?;
    const chain = parsed.ast.node(chain_init).data.UnaryExpression;
    try std.testing.expectEqual(TokenType.Exclamation, chain.operator);
    try std.testing.expectEqual(TokenType.Minus, parsed.ast.node(chain.argument).data.UnaryExpression.operator);

    const product_decl = parsed.ast.node(statements[9]).data.VariableDeclaration;
    const product_init = parsed.ast.node(product_decl.declarations[0]).data.VariableDeclarator.init.?;
    const product = parsed.ast.node(product_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.Asterisk, product.operator);
    try std.testing.expectEqual(TokenType.Minus, parsed.ast.node(product.left).data.UnaryExpression.operator);

    const postfix_decl = parsed.ast.node(statements[10]).data.VariableDeclaration;
    const postfix_init = parsed.ast.node(postfix_decl.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(.NonNullExpression, std.meta.activeTag(parsed.ast.node(postfix_init).data));
}

test "parser preserves prefix and postfix update expressions" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\++i;
        \\--i;
        \\++object.value;
        \\--items[index];
        \\++i * 2;
        \\i++;
        \\i--;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(scan.tokens.len - 1, parsed.consumed_tokens);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const expected_prefix_operators = [_]TokenType{ .PlusPlus, .MinusMinus, .PlusPlus, .MinusMinus };
    for (expected_prefix_operators, 0..) |operator, index| {
        const expression = parsed.ast.node(statements[index]).data.ExpressionStatement.expression;
        const update = parsed.ast.node(expression).data.UpdateExpression;
        try std.testing.expect(update.prefix);
        try std.testing.expectEqual(operator, update.operator);
        try std.testing.expect(parsed.ast.node(expression).span.start < parsed.ast.node(update.argument).span.start);
        try std.testing.expectEqual(parsed.ast.node(expression).span.end, parsed.ast.node(update.argument).span.end);
    }

    const member_update_id = parsed.ast.node(statements[2]).data.ExpressionStatement.expression;
    try std.testing.expectEqual(.MemberExpression, std.meta.activeTag(parsed.ast.node(parsed.ast.node(member_update_id).data.UpdateExpression.argument).data));
    const element_update_id = parsed.ast.node(statements[3]).data.ExpressionStatement.expression;
    try std.testing.expectEqual(.ElementAccessExpression, std.meta.activeTag(parsed.ast.node(parsed.ast.node(element_update_id).data.UpdateExpression.argument).data));

    const product_id = parsed.ast.node(statements[4]).data.ExpressionStatement.expression;
    const product = parsed.ast.node(product_id).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.Asterisk, product.operator);
    try std.testing.expect(parsed.ast.node(product.left).data.UpdateExpression.prefix);

    for (statements[5..7]) |statement| {
        const expression = parsed.ast.node(statement).data.ExpressionStatement.expression;
        try std.testing.expect(!parsed.ast.node(expression).data.UpdateExpression.prefix);
    }
}

test "parser preserves sequence expressions and structural commas" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\a = 1, b = 2, a + b;
        \\for (i = 0, j = 10; ok; i++, j--) {}
        \\fn(a, b);
        \\const array = [a, b];
        \\const object = { a: x, b: y };
        \\let first = 1, second = 2;
        \\const grouped = (a, b);
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const top_sequence_id = parsed.ast.node(statements[0]).data.ExpressionStatement.expression;
    const top_sequence = parsed.ast.node(top_sequence_id).data.SequenceExpression;
    try std.testing.expectEqual(@as(usize, 3), top_sequence.expressions.len);

    const loop = parsed.ast.node(statements[1]).data.ForStatement;
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(loop.init.?).data.SequenceExpression.expressions.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(loop.update.?).data.SequenceExpression.expressions.len);

    const call_id = parsed.ast.node(statements[2]).data.ExpressionStatement.expression;
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(call_id).data.CallExpression.arguments.len);

    const array_decl = parsed.ast.node(statements[3]).data.VariableDeclaration;
    const array_init = parsed.ast.node(array_decl.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(array_init).data.ArrayExpression.elements.len);

    const object_decl = parsed.ast.node(statements[4]).data.VariableDeclaration;
    const object_init = parsed.ast.node(object_decl.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(object_init).data.ObjectExpression.properties.len);

    const variable_decl = parsed.ast.node(statements[5]).data.VariableDeclaration;
    try std.testing.expectEqual(@as(usize, 2), variable_decl.declarations.len);

    const grouped_decl = parsed.ast.node(statements[6]).data.VariableDeclaration;
    const grouped_init = parsed.ast.node(grouped_decl.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(grouped_init).data.SequenceExpression.expressions.len);
}

test "parser distinguishes relational keywords from for loop separators" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\const contained = "name" in object;
        \\const matched = value instanceof Constructor;
        \\for (key in object) {}
        \\for (const item of values) {}
        \\for (let index = 0; index < 10; index++) {}
        \\for ((key in object); ready; step()) {}
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    try std.testing.expectEqual(scan.tokens.len - 1, parsed.consumed_tokens);

    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    const contained_declaration = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const contained_init = parsed.ast.node(contained_declaration.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(TokenType.Keyword_in, parsed.ast.node(contained_init).data.BinaryExpression.operator);

    const matched_declaration = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const matched_init = parsed.ast.node(matched_declaration.declarations[0]).data.VariableDeclarator.init.?;
    try std.testing.expectEqual(TokenType.Keyword_instanceof, parsed.ast.node(matched_init).data.BinaryExpression.operator);

    try std.testing.expectEqual(ast_mod.ForStatementKind.in, parsed.ast.node(statements[2]).data.ForStatement.kind);
    try std.testing.expectEqual(ast_mod.ForStatementKind.of, parsed.ast.node(statements[3]).data.ForStatement.kind);
    try std.testing.expectEqual(ast_mod.ForStatementKind.classic, parsed.ast.node(statements[4]).data.ForStatement.kind);

    const parenthesized = parsed.ast.node(statements[5]).data.ForStatement;
    try std.testing.expectEqual(ast_mod.ForStatementKind.classic, parenthesized.kind);
    try std.testing.expectEqual(TokenType.Keyword_in, parsed.ast.node(parenthesized.init.?).data.BinaryExpression.operator);
}

test "parser groups exponentiation shifts and bitwise operators" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let power = 2 ** 3 ** 2;
        \\let shifted = 1 + 2 << 3;
        \\let compared = a & b == c;
        \\let logical = a | b && c;
        \\let shifts = a << b >> c >>> d;
        \\let bits = a | b ^ c & d;
        \\a **= b;
        \\a &= b;
        \\a |= b;
        \\a ^= b;
        \\a <<= b;
        \\a >>= b;
        \\a >>>= b;
    ;
    const scan = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;

    const power_decl = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const power_init = parsed.ast.node(power_decl.declarations[0]).data.VariableDeclarator.init.?;
    const power = parsed.ast.node(power_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.AsteriskAsterisk, power.operator);
    try std.testing.expectEqual(TokenType.AsteriskAsterisk, parsed.ast.node(power.right).data.BinaryExpression.operator);

    const shift_decl = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const shift_init = parsed.ast.node(shift_decl.declarations[0]).data.VariableDeclarator.init.?;
    const shift = parsed.ast.node(shift_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.LessThanLessThan, shift.operator);
    try std.testing.expectEqual(TokenType.Plus, parsed.ast.node(shift.left).data.BinaryExpression.operator);

    const compared_decl = parsed.ast.node(statements[2]).data.VariableDeclaration;
    const compared_init = parsed.ast.node(compared_decl.declarations[0]).data.VariableDeclarator.init.?;
    const compared = parsed.ast.node(compared_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.Ampersand, compared.operator);
    try std.testing.expectEqual(TokenType.EqualsEquals, parsed.ast.node(compared.right).data.BinaryExpression.operator);

    const logical_decl = parsed.ast.node(statements[3]).data.VariableDeclaration;
    const logical_init = parsed.ast.node(logical_decl.declarations[0]).data.VariableDeclarator.init.?;
    const logical = parsed.ast.node(logical_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.AmpersandAmpersand, logical.operator);
    try std.testing.expectEqual(TokenType.Bar, parsed.ast.node(logical.left).data.BinaryExpression.operator);

    const shifts_decl = parsed.ast.node(statements[4]).data.VariableDeclaration;
    const shifts_init = parsed.ast.node(shifts_decl.declarations[0]).data.VariableDeclarator.init.?;
    const unsigned_shift = parsed.ast.node(shifts_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.GreaterThanGreaterThanGreaterThan, unsigned_shift.operator);
    const signed_shift = parsed.ast.node(unsigned_shift.left).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.GreaterThanGreaterThan, signed_shift.operator);
    try std.testing.expectEqual(TokenType.LessThanLessThan, parsed.ast.node(signed_shift.left).data.BinaryExpression.operator);

    const bits_decl = parsed.ast.node(statements[5]).data.VariableDeclaration;
    const bits_init = parsed.ast.node(bits_decl.declarations[0]).data.VariableDeclarator.init.?;
    const bit_or = parsed.ast.node(bits_init).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.Bar, bit_or.operator);
    const bit_xor = parsed.ast.node(bit_or.right).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.Caret, bit_xor.operator);
    try std.testing.expectEqual(TokenType.Ampersand, parsed.ast.node(bit_xor.right).data.BinaryExpression.operator);

    const assignment_operators = [_]TokenType{
        .AsteriskAsteriskEqual,
        .AmpersandEqual,
        .BarEqual,
        .CaretEqual,
        .LessThanLessThanEqual,
        .GreaterThanGreaterThanEqual,
        .GreaterThanGreaterThanGreaterThanEqual,
    };
    for (assignment_operators, 6..) |operator, index| {
        const expression = parsed.ast.node(statements[index]).data.ExpressionStatement.expression;
        try std.testing.expectEqual(operator, parsed.ast.node(expression).data.AssignmentExpression.operator);
    }
}

test "parser handles nullish coalescing precedence assignment and mixing restriction" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const valid_source =
        \\let simple = a ?? b;
        \\let chain = a ?? b ?? c;
        \\let grouped_left = (a ?? b) || c;
        \\let grouped_right = a ?? (b || c);
        \\a ??= b;
    ;
    const valid_scan = try scanner.scanAll(allocator, valid_source, true);
    const valid = try parse(allocator, valid_scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), valid.diagnostics.len);
    const statements = valid.ast.node(valid.ast.root).data.Program.statements;

    const simple_decl = valid.ast.node(statements[0]).data.VariableDeclaration;
    const simple = valid.ast.node(valid.ast.node(simple_decl.declarations[0]).data.VariableDeclarator.init.?).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.QuestionQuestion, simple.operator);

    const chain_decl = valid.ast.node(statements[1]).data.VariableDeclaration;
    const chain = valid.ast.node(valid.ast.node(chain_decl.declarations[0]).data.VariableDeclarator.init.?).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.QuestionQuestion, chain.operator);
    try std.testing.expectEqual(TokenType.QuestionQuestion, valid.ast.node(chain.left).data.BinaryExpression.operator);

    const grouped_left_decl = valid.ast.node(statements[2]).data.VariableDeclaration;
    const grouped_left = valid.ast.node(valid.ast.node(grouped_left_decl.declarations[0]).data.VariableDeclarator.init.?).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.BarBar, grouped_left.operator);
    try std.testing.expectEqual(TokenType.QuestionQuestion, valid.ast.node(grouped_left.left).data.BinaryExpression.operator);

    const grouped_right_decl = valid.ast.node(statements[3]).data.VariableDeclaration;
    const grouped_right = valid.ast.node(valid.ast.node(grouped_right_decl.declarations[0]).data.VariableDeclarator.init.?).data.BinaryExpression;
    try std.testing.expectEqual(TokenType.QuestionQuestion, grouped_right.operator);
    try std.testing.expectEqual(TokenType.BarBar, valid.ast.node(grouped_right.right).data.BinaryExpression.operator);

    const assignment = valid.ast.node(statements[4]).data.ExpressionStatement.expression;
    try std.testing.expectEqual(TokenType.QuestionQuestionEqual, valid.ast.node(assignment).data.AssignmentExpression.operator);

    const invalid_sources = [_][]const u8{
        "let value = a ?? b || c;",
        "let value = a || b ?? c;",
        "let value = a ?? b && c;",
        "let value = a && b ?? c;",
    };
    for (invalid_sources) |source| {
        const invalid_scan = try scanner.scanAll(allocator, source, true);
        const invalid = try parse(allocator, invalid_scan.tokens, .{});
        try std.testing.expectEqual(@as(usize, 1), invalid.diagnostics.len);
        try std.testing.expectEqual(diagnostics.DiagnosticCode.unexpected_token, invalid.diagnostics[0].code);
        try std.testing.expectEqualStrings("cannot mix ?? with && or || without parentheses", invalid.diagnostics[0].message);
    }
}

test "parser handles conditional expressions associativity assignments and recovery" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let simple = condition ? whenTrue : whenFalse;
        \\let nested = a ? b : c ? d : e;
        \\target = condition ? whenTrue : whenFalse;
        \\let branches = condition ? left = one : right = two;
    ;
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;

    const simple_decl = parsed.ast.node(statements[0]).data.VariableDeclaration;
    const simple = parsed.ast.node(parsed.ast.node(simple_decl.declarations[0]).data.VariableDeclarator.init.?).data.ConditionalExpression;
    try std.testing.expectEqualStrings("condition", parsed.ast.node(simple.condition).data.Identifier.name);
    try std.testing.expectEqualStrings("whenTrue", parsed.ast.node(simple.consequent).data.Identifier.name);
    try std.testing.expectEqualStrings("whenFalse", parsed.ast.node(simple.alternate).data.Identifier.name);

    const nested_decl = parsed.ast.node(statements[1]).data.VariableDeclaration;
    const nested = parsed.ast.node(parsed.ast.node(nested_decl.declarations[0]).data.VariableDeclarator.init.?).data.ConditionalExpression;
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).ConditionalExpression, std.meta.activeTag(parsed.ast.node(nested.alternate).data));

    const outer_assignment = parsed.ast.node(parsed.ast.node(statements[2]).data.ExpressionStatement.expression).data.AssignmentExpression;
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).ConditionalExpression, std.meta.activeTag(parsed.ast.node(outer_assignment.right).data));

    const branches_decl = parsed.ast.node(statements[3]).data.VariableDeclaration;
    const branches = parsed.ast.node(parsed.ast.node(branches_decl.declarations[0]).data.VariableDeclarator.init.?).data.ConditionalExpression;
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).AssignmentExpression, std.meta.activeTag(parsed.ast.node(branches.consequent).data));
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).AssignmentExpression, std.meta.activeTag(parsed.ast.node(branches.alternate).data));

    const recovery_scan = try scanner.scanAll(allocator, "let recovered = a ? b c; let after = d;", true);
    const recovered = try parse(allocator, recovery_scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.expected_token, recovered.diagnostics[0].code);
    try std.testing.expectEqualStrings("expected : in conditional expression", recovered.diagnostics[0].message);
    const recovered_statements = recovered.ast.node(recovered.ast.root).data.Program.statements;
    try std.testing.expectEqual(@as(usize, 2), recovered_statements.len);
    const recovered_decl = recovered.ast.node(recovered_statements[0]).data.VariableDeclaration;
    const recovered_conditional = recovered.ast.node(recovered.ast.node(recovered_decl.declarations[0]).data.VariableDeclarator.init.?).data.ConditionalExpression;
    try std.testing.expectEqualStrings("c", recovered.ast.node(recovered_conditional.alternate).data.Identifier.name);
}

test "parser builds do while and recovers from missing while or semicolon" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const valid_scan = try scanner.scanAll(allocator, "do { work(); } while (condition);", true);
    const valid = try parse(allocator, valid_scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), valid.diagnostics.len);
    const statement = valid.ast.node(valid.ast.node(valid.ast.root).data.Program.statements[0]).data.DoWhileStatement;
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).BlockStatement, std.meta.activeTag(valid.ast.node(statement.body).data));
    try std.testing.expectEqual(std.meta.Tag(ast_mod.NodeData).Identifier, std.meta.activeTag(valid.ast.node(statement.condition).data));

    const missing_while_scan = try scanner.scanAll(allocator, "do {} let recovered = 1;", true);
    const missing_while = try parse(allocator, missing_while_scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 1), missing_while.diagnostics.len);
    try std.testing.expectEqualStrings("expected while after do-while body", missing_while.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 2), missing_while.ast.node(missing_while.ast.root).data.Program.statements.len);

    const missing_semicolon_scan = try scanner.scanAll(allocator, "do {} while (condition) let recovered = 1;", true);
    const missing_semicolon = try parse(allocator, missing_semicolon_scan.tokens, .{});
    try std.testing.expectEqual(@as(usize, 1), missing_semicolon.diagnostics.len);
    try std.testing.expectEqualStrings("expected ; after do-while statement", missing_semicolon.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 2), missing_semicolon.ast.node(missing_semicolon.ast.root).data.Program.statements.len);
}

test "parser distinguishes classic for in for of and for await" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\for (let index = 0; index < limit; index = index + 1) {}
        \\for (const key in object) {}
        \\for (const value of iterable) {}
        \\for await (const value of stream) {}
    , true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    try std.testing.expectEqual(@as(usize, 4), statements.len);

    const classic = parsed.ast.node(statements[0]).data.ForStatement;
    try std.testing.expectEqual(ast_mod.ForStatementKind.classic, classic.kind);
    try std.testing.expect(!classic.await);
    try std.testing.expect(classic.init != null);
    try std.testing.expect(classic.condition != null);
    try std.testing.expect(classic.update != null);
    try std.testing.expect(classic.right == null);

    const for_in = parsed.ast.node(statements[1]).data.ForStatement;
    try std.testing.expectEqual(ast_mod.ForStatementKind.in, for_in.kind);
    try std.testing.expect(!for_in.await);
    try std.testing.expect(for_in.right != null);

    const for_of = parsed.ast.node(statements[2]).data.ForStatement;
    try std.testing.expectEqual(ast_mod.ForStatementKind.of, for_of.kind);
    try std.testing.expect(!for_of.await);

    const for_await = parsed.ast.node(statements[3]).data.ForStatement;
    try std.testing.expectEqual(ast_mod.ForStatementKind.of, for_await.kind);
    try std.testing.expect(for_await.await);
    try std.testing.expectEqualStrings("stream", parsed.ast.node(for_await.right.?).data.Identifier.name);
}

test "parser diagnoses invalid for in and for of declaration shapes" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "for (const first, second in object) {}", .message = "for-in/of declaration must contain exactly one variable" },
        .{ .source = "for (const value = initial of iterable) {}", .message = "for-in/of declaration may not have an initializer" },
        .{ .source = "for await (const key in object) {}", .message = "for await requires an of loop" },
    };
    for (cases) |case| {
        const scanned = try scanner.scanAll(allocator, case.source, true);
        const parsed = try parse(allocator, scanned.tokens, .{});
        try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
        try std.testing.expectEqualStrings(case.message, parsed.diagnostics[0].message);
        try std.testing.expectEqual(@as(usize, 1), parsed.ast.node(parsed.ast.root).data.Program.statements.len);
    }
}

test "parser builds switch clauses and preserves empty case labels" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\switch (value) {
        \\    case 1:
        \\    case 2: work(); break;
        \\    default: fallback();
        \\}
    , true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statement = parsed.ast.node(parsed.ast.node(parsed.ast.root).data.Program.statements[0]).data.SwitchStatement;
    try std.testing.expectEqualStrings("value", parsed.ast.node(statement.discriminant).data.Identifier.name);
    try std.testing.expectEqual(@as(usize, 3), statement.cases.len);
    const first = parsed.ast.node(statement.cases[0]).data.SwitchCase;
    const second = parsed.ast.node(statement.cases[1]).data.SwitchCase;
    const default = parsed.ast.node(statement.cases[2]).data.SwitchCase;
    try std.testing.expect(first.condition != null);
    try std.testing.expectEqual(@as(usize, 0), first.consequent.len);
    try std.testing.expect(second.condition != null);
    try std.testing.expectEqual(@as(usize, 2), second.consequent.len);
    try std.testing.expect(default.condition == null);
    try std.testing.expectEqual(@as(usize, 1), default.consequent.len);
}

test "parser diagnoses duplicate switch defaults and recovers" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, "switch (value) { default: break; default: break; } let recovered = 1;", true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unexpected_token, parsed.diagnostics[0].code);
    try std.testing.expectEqualStrings("duplicate default clause in switch statement", parsed.diagnostics[0].message);
    try std.testing.expectEqual(@as(usize, 2), parsed.ast.node(parsed.ast.root).data.Program.statements.len);
    const statement = parsed.ast.node(parsed.ast.node(parsed.ast.root).data.Program.statements[0]).data.SwitchStatement;
    try std.testing.expectEqual(@as(usize, 2), statement.cases.len);
}

test "parser builds explicit try catch finally branches" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator,
        \\try {} catch (error) {} finally {}
        \\try {} catch {}
        \\try {} finally {}
    , true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const statements = parsed.ast.node(parsed.ast.root).data.Program.statements;
    try std.testing.expectEqual(@as(usize, 3), statements.len);

    const complete = parsed.ast.node(statements[0]).data.TryStatement;
    try std.testing.expect(complete.handler != null);
    try std.testing.expect(complete.finalizer != null);
    try std.testing.expect(parsed.ast.node(complete.handler.?).data.CatchClause.parameter != null);
    _ = parsed.ast.node(complete.finalizer.?).data.FinallyClause;

    const bindingless = parsed.ast.node(statements[1]).data.TryStatement;
    try std.testing.expect(parsed.ast.node(bindingless.handler.?).data.CatchClause.parameter == null);
    try std.testing.expect(bindingless.finalizer == null);

    const finally_only = parsed.ast.node(statements[2]).data.TryStatement;
    try std.testing.expect(finally_only.handler == null);
    try std.testing.expect(finally_only.finalizer != null);
}

test "parser diagnoses try without catch or finally" {
    const scanner = @import("scanner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, "try {}", true);
    const parsed = try parse(allocator, scanned.tokens, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.expected_token, parsed.diagnostics[0].code);
    try std.testing.expectEqualStrings("expected catch or finally after try", parsed.diagnostics[0].message);
}
