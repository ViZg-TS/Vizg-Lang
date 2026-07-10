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
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    index: usize = 0,
    nodes: std.ArrayList(ast_mod.Node) = .empty,
    diagnostics: std.ArrayList(diagnostics.Diagnostic) = .empty,
    recover_errors: bool = true,
    // H4 — current recursion depth during descent. Bumped per recursive parse call;
    // when it reaches max_parse_depth we abort with a diagnostic rather than recursing further.
    _depth: usize = 0,
    // H4 — recursion depth counter for parser descent. Bumped per recursive parse call;
    // when it reaches max_parse_depth we abort with a diagnostic rather than recursing further.
    max_parse_depth: usize = 1000,

    fn parse(self: *Parser) anyerror!ParseResult {
        const root = try self.parseProgram();
        return .{
            .ast = .{
                .nodes = try self.nodes.toOwnedSlice(self.allocator),
                .root = root,
            },
            .diagnostics = try self.diagnostics.toOwnedSlice(self.allocator),
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
        if (self.at(.Keyword_import)) return try self.parseImportDeclaration();
        if (self.at(.Keyword_export)) return try self.parseExportDeclaration();
        if (self.at(.Keyword_function)) return try self.parseFunctionDeclaration(false);
        if (self.at(.LBrace)) return try self.parseBlockStatement();
        if (self.at(.Keyword_return)) return try self.parseReturnStatement();
        if (self.at(.Keyword_if)) return try self.parseIfStatement();
        if (self.at(.Keyword_while)) return try self.parseWhileStatement();
        if (self.at(.Keyword_for)) return try self.parseForStatement();
        if (self.isVariableKeyword(self.current().kind)) return try self.parseVariableDeclarationStatement();
        if (self.at(.Semicolon)) {
            _ = self.advance();
            return null;
        }
        return try self.parseExpressionStatement();
    }

    fn parseImportDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_import, "expected import").span;
        var names: std.ArrayList([]const u8) = .empty;
        errdefer names.deinit(self.allocator);
        var specifiers: std.ArrayList(ast_mod.ImportSpecifier) = .empty;
        errdefer specifiers.deinit(self.allocator);

        var needs_from = false;

        if (self.at(.LBrace)) {
            needs_from = true;
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
            try names.append(self.allocator, self.advance().lexeme);
        } else if (self.at(.Asterisk)) {
            needs_from = true;
            _ = self.advance();
            _ = self.expectContextualIdentifier("as", "expected as");
            _ = self.expectIdentifierLike("expected namespace import");
            if (self.previous()) |name_token| {
                try names.append(self.allocator, name_token.lexeme);
            }
        }

        if (needs_from) _ = self.expectContextualIdentifier("from", "expected from");

        const tok: ?Token = if (self.at(.StringLiteral)) blk: {
            break :blk self.advance();
        } else null;
        const source_span: tokens.Span = if (tok) |t| t.span else start;
        var source_unquoted: []const u8 = "";
        if (tok) |t| source_unquoted = trimString(t.lexeme);

        _ = self.eat(.Semicolon);

        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ImportDeclaration = .{
                .names = try names.toOwnedSlice(self.allocator),
                .specifiers = try specifiers.toOwnedSlice(self.allocator),
                .source = source_unquoted,
                .source_span = source_span,
            } },
        });
    }

    fn parseExportDeclaration(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_export, "expected export").span;

        if (self.at(.Keyword_function)) {
            const function = try self.parseFunctionDeclaration(true);
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(function)].span),
                .data = .{ .ExportDeclaration = .{ .declaration = function } },
            });
        }

        if (self.isVariableKeyword(self.current().kind)) {
            const declaration = try self.parseVariableDeclarationStatement();
            return self.addNode(.{
                .span = joinSpans(start, self.nodes.items[@intCast(declaration)].span),
                .data = .{ .ExportDeclaration = .{ .declaration = declaration } },
            });
        }

        if (self.at(.Keyword_default)) {
            _ = self.advance();

            // export default function <name>() {} — parse as a named
            // FunctionDeclaration and tag the wrapper with default_name.
            if (self.at(.Keyword_function)) {
                const function_id = try self.parseFunctionDeclaration(true);
                const func_node = self.nodes.items[@intCast(function_id)];
                return self.addNode(.{
                    .span = joinSpans(start, func_node.span),
                    .data = .{ .ExportDeclaration = .{
                        .declaration = function_id,
                        .default_name = func_node.data.FunctionDeclaration.name,
                    } },
                });
            }

            const name = if (self.at(.Identifier)) self.advance().lexeme else "";
            _ = self.eat(.Semicolon);
            return self.addNode(.{
                .span = joinSpans(start, self.previousOrCurrent().span),
                .data = .{ .ExportDeclaration = .{ .default_name = name } },
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
        _ = self.eat(.Semicolon);
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ExportDeclaration = .{ .specifiers = try specifiers.toOwnedSlice(self.allocator) } },
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

    fn parseFunctionDeclaration(self: *Parser, exported: bool) anyerror!NodeId {
        const start = self.expect(.Keyword_function, "expected function").span;
        const name = self.expectIdentifierLike("expected function name").lexeme;
        _ = self.expect(.LParen, "expected (");

        var params: std.ArrayList(NodeId) = .empty;
        errdefer params.deinit(self.allocator);
        while (!self.at(.RParen) and !self.at(.EOF)) {
            const param_token = self.expectIdentifierLike("expected parameter name");
            const param_type: ?ast_mod.TypeAnnotation = self.parseOptionalTypeAnnotation();
            while (!self.at(.Comma) and !self.at(.RParen) and !self.at(.EOF)) _ = self.advance();
            try params.append(self.allocator, try self.addNode(.{
                .span = param_token.span,
                .data = .{ .Parameter = .{ .name = param_token.lexeme, .type_annotation = param_type } },
            }));
            _ = self.eat(.Comma);
        }
        _ = self.expect(.RParen, "expected )");
        const return_type: ?ast_mod.TypeAnnotation = self.parseOptionalTypeAnnotation();

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
                .return_type = return_type,
            } },
        });
    }
    fn parseOptionalTypeAnnotation(self: *Parser) ?ast_mod.TypeAnnotation {
        if (!self.at(.Colon)) return null;
        _ = self.advance(); // consume colon
        if (self.at(.Identifier) or self.at(.PrivateIdentifier)) {
            const type_token = self.advance();
            const span: tokens.Span = .{
                .start = type_token.span.start,
                .end = type_token.span.end,
                .line = type_token.span.line,
                .column = type_token.span.column,
            };
            return .{ .name = type_token.lexeme, .span = span };
        }
        self.report("expected type name after ':'", .expected_token);
        return null;
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
        const start = self.advance();
        var declarations: std.ArrayList(NodeId) = .empty;
        errdefer declarations.deinit(self.allocator);

        while (!self.at(.Semicolon) and !self.at(.EOF)) {
            const name = self.expectIdentifierLike("expected variable name");
            const type_annotation: ?ast_mod.TypeAnnotation = self.parseOptionalTypeAnnotation();
            while (!self.at(.Equal) and !self.at(.Comma) and !self.at(.Semicolon) and !self.at(.EOF)) _ = self.advance();
            const init = if (self.eat(.Equal)) try self.parseExpression() else null;
            try declarations.append(self.allocator, try self.addNode(.{
                .span = joinSpans(name.span, self.previousOrCurrent().span),
                .data = .{ .VariableDeclarator = .{ .name = name.lexeme, .init = init, .type_annotation = type_annotation } },
            }));
            if (!self.eat(.Comma)) break;
        }
        _ = self.eat(.Semicolon);

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

    fn parseForStatement(self: *Parser) anyerror!NodeId {
        const start = self.expect(.Keyword_for, "expected for").span;
        _ = self.expect(.LParen, "expected (");

        const init: ?NodeId = if (self.eat(.Semicolon))
            null
        else if (self.isVariableKeyword(self.current().kind))
            try self.parseVariableDeclarationStatement()
        else init: {
            const expression = try self.parseExpression();
            _ = self.expect(.Semicolon, "expected ;");
            break :init expression;
        };

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
        defer { if (self._depth > 0) self._depth -= 1; }

        return self.parseAssignmentExpression();
    }

    fn binaryPrecedence(kind: TokenType) ?u8 {
        return switch (kind) {
            .PlusEqual, .MinusEqual, .AsteriskEqual, .SlashEqual, .PercentEqual => @as(u8, 0),
            .BarBar => @as(u8, 1),
            .AmpersandAmpersand => @as(u8, 2),
            .EqualsEquals, .ExclamationEquals, .EqualsEqualsEquals, .ExclamationEqualsEquals => @as(u8, 4),
            .LessThan, .LessThanEquals, .GreaterThan, .GreaterThanEquals => @as(u8, 5),
            .Plus, .Minus => @as(u8, 6),
            .Asterisk, .Slash, .Percent => @as(u8, 7),
            else => null,
        };
    }

    fn parseAssignmentExpression(self: *Parser) anyerror!NodeId {
        const left = try self.parseLogicalOrExpression();

        // Assignment (=, +=, -=, *=, /= %=). Right-associative.
        if (self.current().kind == .Equal or
            self.current().kind == .PlusEqual or
            self.current().kind == .MinusEqual or
            self.current().kind == .AsteriskEqual or
            self.current().kind == .SlashEqual or
            self.current().kind == .PercentEqual)
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
        var left = try self.parseEqualityExpression();
        while (self.at(.AmpersandAmpersand)) {
            const op_tok = self.advance();
            const right = try self.parseEqualityExpression();
            left = try self.addNode(.{
                .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                .data = .{ .BinaryExpression = .{ .operator = op_tok.kind, .left = left, .right = right } },
            });
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
        var left = try self.parseAdditiveExpression();
        while (true) {
            left = switch (self.current().kind) {
                .LessThan => blk: {
                    _ = self.advance();
                    const right = try self.parseAdditiveExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .LessThan, .left = left, .right = right } },
                    });
                },
                .LessThanEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseAdditiveExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .LessThanEquals, .left = left, .right = right } },
                    });
                },
                .GreaterThan => blk: {
                    _ = self.advance();
                    const right = try self.parseAdditiveExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .GreaterThan, .left = left, .right = right } },
                    });
                },
                .GreaterThanEquals => blk: {
                    _ = self.advance();
                    const right = try self.parseAdditiveExpression();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .GreaterThanEquals, .left = left, .right = right } },
                    });
                },
                else => break,
            };
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
        var left = try self.parsePrimary();
        while (true) {
            left = switch (self.current().kind) {
                .Asterisk => blk: {
                    _ = self.advance();
                    const right = try self.parsePrimary();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Asterisk, .left = left, .right = right } },
                    });
                },
                .Slash => blk: {
                    _ = self.advance();
                    const right = try self.parsePrimary();
                    break :blk try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                        .data = .{ .BinaryExpression = .{ .operator = .Slash, .left = left, .right = right } },
                    });
                },
                .Percent => blk: {
                    _ = self.advance();
                    const right = try self.parsePrimary();
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

    fn isLogicalOrOperator(_: *const Parser, kind: TokenType) bool {
        return kind == .BarBar or kind == .AmpersandAmpersand;
    }

    fn parseObjectExpression(self: *Parser) anyerror!NodeId {
        // The LBrace was already consumed by parsePrimary before dispatching here.
        const start = self.previous().?.span;
        var properties: std.ArrayList(ast_mod.ObjectProperty) = .empty;
        errdefer properties.deinit(self.allocator);
        while (!self.at(.RBrace) and !self.at(.EOF)) {
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

            _ = self.expect(.Colon, "expected :");
            const value = try self.parseExpression();
            try properties.append(self.allocator, .{
                .key = key,
                .key_span = key_tok.span,
                .value = value,
            });
            if (!self.eat(.Comma)) break;
        }
        _ = self.expect(.RBrace, "expected }");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = @unionInit(ast_mod.NodeData, "ObjectExpression", .{ .properties = try properties.toOwnedSlice(self.allocator) }),
        });
    }

    fn parseArrayExpression(self: *Parser) anyerror!NodeId {
        // The LBracket was already consumed by parsePrimary before dispatching here.
        const start = self.previous().?.span;
        var elements: std.ArrayList(NodeId) = .empty;
        errdefer elements.deinit(self.allocator);

        while (!self.at(.RBracket) and !self.at(.EOF)) {
            if (self.eat(.Comma)) continue;   // trailing comma — allow it
            const elem = try self.parseExpression();
            try elements.append(self.allocator, elem);
            _ = self.eat(.Comma);             // trailing comma allowed by spec
        }

        _ = self.expect(.RBracket, "expected ]");
        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = @unionInit(ast_mod.NodeData, "ArrayExpression", .{ .elements = try elements.toOwnedSlice(self.allocator) }),
        });
    }

    fn parsePrimary(self: *Parser) anyerror!NodeId {
        var node: NodeId = undefined;
        const token = self.advance();
        switch (token.kind) {
            .Identifier, .PrivateIdentifier => node = try self.addNode(.{
                .span = token.span,
                .data = .{ .Identifier = .{ .name = token.lexeme } },
            }),
            .StringLiteral, .NoSubstitutionTemplate, .NumberLiteral, .BigIntLiteral, .TrueLiteral, .FalseLiteral, .NullLiteral => node = try self.addNode(.{
                .span = token.span,
                .data = .{ .Literal = .{ .value = token.lexeme } },
            }),
            .LParen => {
                node = try self.parseExpression();
                _ = self.expect(.RParen, "expected )");
            },
            .LBrace => {
                node = try self.parseObjectExpression();
            },
            .LBracket => {
                node = try self.parseArrayExpression();
            },
            else => {
                self.reportAt(token, "expected expression", .expected_token);
                node = try self.addNode(.{
                    .span = token.span,
                    .data = .{ .Identifier = .{ .name = "" } },
                });
            },
        }

        while (true) {
            if (self.eat(.LParen)) {
                var args: std.ArrayList(NodeId) = .empty;
                errdefer args.deinit(self.allocator);
                while (!self.at(.RParen) and !self.at(.EOF)) {
                    try args.append(self.allocator, try self.parseExpression());
                    _ = self.eat(.Comma);
                }
                _ = self.expect(.RParen, "expected )");
                node = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                    .data = .{ .CallExpression = .{ .callee = node, .arguments = try args.toOwnedSlice(self.allocator) } },
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
            if (self.eat(.Exclamation)) {
                const non_null = try self.addNode(.{
                    .span = joinSpans(self.nodes.items[@intCast(node)].span, self.previousOrCurrent().span),
                    .data = .{ .NonNullExpression = .{ .expression = node } },
                });
                node = non_null;
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
            // TypeScript `as` assertion: value as TypeAnnotation (v1 supports simple type identifiers).
            if (self.atIdentifierText("as")) {
                const as_tok = self.advance();
                const type_token_opt = if (self.at(.Identifier) or self.at(.PrivateIdentifier)) self.advance() else null;
                if (type_token_opt) |unwrapped_type_token| {
                    const span: tokens.Span = .{
                        .start = as_tok.span.start,
                        .end = unwrapped_type_token.span.end,
                        .line = as_tok.span.line,
                        .column = as_tok.span.column,
                    };
                    node = try self.addNode(.{
                        .span = joinSpans(self.nodes.items[@intCast(node)].span, span),
                        .data = .{ .AsExpression = .{
                            .expression = node,
                            .type_annotation = .{ .name = unwrapped_type_token.lexeme, .span = span },
                        } },
                    });
                    continue;
                } else {
                    self.reportAt(as_tok, "expected type name after 'as'", .expected_token);
                    break;
                }
            }
            break;
        }

        return node;
    }

    fn addNode(self: *Parser, node: ast_mod.Node) anyerror!NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return id;
    }

    fn current(self: *const Parser) Token {
        return self.tokens[@min(self.index, self.tokens.len - 1)];
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
        }) catch {};
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
