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
        const source = if (self.at(.StringLiteral)) trimString(self.advance().lexeme) else "";
        _ = self.eat(.Semicolon);

        return self.addNode(.{
            .span = joinSpans(start, self.previousOrCurrent().span),
            .data = .{ .ImportDeclaration = .{
                .names = try names.toOwnedSlice(self.allocator),
                .specifiers = try specifiers.toOwnedSlice(self.allocator),
                .source = source,
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
            while (!self.at(.Comma) and !self.at(.RParen) and !self.at(.EOF)) _ = self.advance();
            try params.append(self.allocator, try self.addNode(.{
                .span = param_token.span,
                .data = .{ .Parameter = .{ .name = param_token.lexeme } },
            }));
            _ = self.eat(.Comma);
        }
        _ = self.expect(.RParen, "expected )");

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
            } },
        });
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
            while (!self.at(.Equal) and !self.at(.Comma) and !self.at(.Semicolon) and !self.at(.EOF)) _ = self.advance();
            const init = if (self.eat(.Equal)) try self.parseExpression() else null;
            try declarations.append(self.allocator, try self.addNode(.{
                .span = joinSpans(name.span, self.previousOrCurrent().span),
                .data = .{ .VariableDeclarator = .{ .name = name.lexeme, .init = init } },
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
        return self.parseAssignmentExpression();
    }

    fn parseAssignmentExpression(self: *Parser) anyerror!NodeId {
        const left = try self.parseBinaryExpression();
        if (!self.eat(.Equal)) return left;

        const right = try self.parseExpression();
        return self.addNode(.{
            .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
            .data = .{ .AssignmentExpression = .{ .left = left, .right = right } },
        });
    }

    fn parseBinaryExpression(self: *Parser) anyerror!NodeId {
        var left = try self.parsePrimary();
        while (self.isBinaryOperator(self.current().kind)) {
            const op = self.advance();
            const right = try self.parsePrimary();
            left = try self.addNode(.{
                .span = joinSpans(self.nodes.items[@intCast(left)].span, self.nodes.items[@intCast(right)].span),
                .data = .{ .BinaryExpression = .{ .operator = op.kind, .left = left, .right = right } },
            });
        }
        return left;
    }

    fn parsePrimary(self: *Parser) anyerror!NodeId {
        var node: NodeId = undefined;
        const token = self.advance();
        switch (token.kind) {
            .Identifier, .PrivateIdentifier => node = try self.addNode(.{
                .span = token.span,
                .data = .{ .Identifier = .{ .name = token.lexeme } },
            }),
            .StringLiteral, .NumberLiteral, .BigIntLiteral, .TrueLiteral, .FalseLiteral, .NullLiteral => node = try self.addNode(.{
                .span = token.span,
                .data = .{ .Literal = .{ .value = token.lexeme } },
            }),
            .LParen => {
                node = try self.parseExpression();
                _ = self.expect(.RParen, "expected )");
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

pub fn parse(allocator: std.mem.Allocator, token_list: []const Token, recover_errors: bool) anyerror!ParseResult {
    var parser = Parser{
        .allocator = allocator,
        .tokens = token_list,
        .recover_errors = recover_errors,
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
    const parsed = try parse(allocator, scan.tokens, true);

    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    const root = parsed.ast.node(parsed.ast.root);
    try std.testing.expectEqual(@as(usize, 2), root.data.Program.statements.len);
}
