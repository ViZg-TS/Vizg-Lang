const std = @import("std");

const ast_mod = @import("ast.zig");
const binder = @import("binder.zig");
const cfg = @import("cfg.zig");
const diagnostics = @import("../diagnostic/root.zig");
const frontend = @import("frontend.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const scanner = @import("scanner.zig");
const tokens = @import("tokens.zig");

const NodeId = ast_mod.NodeId;
const TokenType = tokens.TokenType;

fn scanOk(allocator: std.mem.Allocator, source: []const u8, collect_comments: bool) !scanner.ScanResult {
    const scanned = try scanner.scanAll(allocator, source, collect_comments);
    try std.testing.expectEqual(@as(usize, 0), scanned.diagnostics.len);
    return scanned;
}

fn parseOk(allocator: std.mem.Allocator, source: []const u8) !parser.ParseResult {
    const scanned = try scanOk(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, true);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
    return parsed;
}

fn expectTokenKinds(actual: []const tokens.Token, expected: []const TokenType) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |kind, index| {
        try std.testing.expectEqual(kind, actual[index].kind);
    }
}

fn expectNodeTag(tree: ast_mod.Ast, id: NodeId, comptime tag: std.meta.Tag(ast_mod.NodeData)) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(tree.node(id).data));
}

fn symbolByName(bound: binder.BindResult, name: []const u8) ?binder.Symbol {
    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn symbolByNameKindScope(bound: binder.BindResult, name: []const u8, kind: binder.SymbolKind, scope: ?binder.ScopeId) ?binder.Symbol {
    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, name) and symbol.kind == kind and (scope == null or symbol.scope == scope.?)) return symbol;
    }
    return null;
}

fn expectReference(resolved: resolver.ResolveResult, name: []const u8, kind: resolver.ReferenceKind, symbol: binder.SymbolId) !void {
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, name) and reference.kind == kind and reference.symbol != null and reference.symbol.? == symbol) return;
    }
    return error.ReferenceNotFound;
}

fn countReferences(resolved: resolver.ResolveResult, name: []const u8, kind: ?resolver.ReferenceKind) usize {
    var count: usize = 0;
    for (resolved.references) |reference| {
        if (std.mem.eql(u8, reference.name, name) and (kind == null or reference.kind == kind.?)) count += 1;
    }
    return count;
}

fn exportByName(bound: binder.BindResult, name: []const u8) ?binder.ExportRecord {
    for (bound.module.exports) |export_record| {
        if (std.mem.eql(u8, export_record.name, name)) return export_record;
    }
    return null;
}

fn hasEdge(block: cfg.BasicBlock, target: cfg.BasicBlockId) bool {
    for (block.successors) |successor| {
        if (successor == target) return true;
    }
    return false;
}

fn blockById(graph: cfg.ControlFlowGraph, id: cfg.BasicBlockId) cfg.BasicBlock {
    return graph.blocks[@intCast(id)];
}

fn blockContainingStatementKind(tree: ast_mod.Ast, graph: cfg.ControlFlowGraph, comptime tag: std.meta.Tag(ast_mod.NodeData)) ?cfg.BasicBlockId {
    for (graph.blocks) |block| {
        for (block.statements) |statement| {
            if (std.meta.activeTag(tree.node(statement).data) == tag) return block.id;
        }
    }
    return null;
}

fn blockContainsStatementKind(tree: ast_mod.Ast, block: cfg.BasicBlock, comptime tag: std.meta.Tag(ast_mod.NodeData)) bool {
    for (block.statements) |statement| {
        if (std.meta.activeTag(tree.node(statement).data) == tag) return true;
    }
    return false;
}

fn expectBlockHasSuccessor(graph: cfg.ControlFlowGraph, from: cfg.BasicBlockId, to: cfg.BasicBlockId) !void {
    try std.testing.expect(hasEdge(blockById(graph, from), to));
}

fn expectNoBlockHasSuccessor(graph: cfg.ControlFlowGraph, from: cfg.BasicBlockId, to: cfg.BasicBlockId) !void {
    try std.testing.expect(!hasEdge(blockById(graph, from), to));
}

fn expectPathExists(graph: cfg.ControlFlowGraph, from: cfg.BasicBlockId, to: cfg.BasicBlockId) !void {
    var visited = [_]bool{false} ** 128;
    try std.testing.expect(graph.blocks.len <= visited.len);
    try std.testing.expect(pathExists(graph, from, to, &visited));
}

fn expectNoPathExists(graph: cfg.ControlFlowGraph, from: cfg.BasicBlockId, to: cfg.BasicBlockId) !void {
    var visited = [_]bool{false} ** 128;
    try std.testing.expect(graph.blocks.len <= visited.len);
    try std.testing.expect(!pathExists(graph, from, to, &visited));
}

fn pathExists(graph: cfg.ControlFlowGraph, from: cfg.BasicBlockId, to: cfg.BasicBlockId, visited: []bool) bool {
    if (from == to) return true;
    if (visited[@intCast(from)]) return false;
    visited[@intCast(from)] = true;
    for (blockById(graph, from).successors) |successor| {
        if (pathExists(graph, successor, to, visited)) return true;
    }
    return false;
}

test "frontend suite: scanner tokenizes module declarations and literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\import { log } from "console";
        \\export function main(name: string) { return name + "ok"; }
        \\const count = 1;
    ;
    const scanned = try scanOk(allocator, source, false);

    try expectTokenKinds(scanned.tokens, &.{
        .Keyword_import, .LBrace,           .Identifier,     .RBrace,     .Identifier,    .StringLiteral, .Semicolon,
        .Keyword_export, .Keyword_function, .Identifier,     .LParen,     .Identifier,    .Colon,         .Identifier,
        .RParen,         .LBrace,           .Keyword_return, .Identifier, .Plus,          .StringLiteral, .Semicolon,
        .RBrace,         .Keyword_const,    .Identifier,     .Equal,      .NumberLiteral, .Semicolon,     .EOF,
    });
    try std.testing.expectEqualStrings("from", scanned.tokens[4].lexeme);
    try std.testing.expectEqualStrings("\"console\"", scanned.tokens[5].lexeme);
}

test "frontend suite: scanner keeps contextual keywords as identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanOk(allocator,
        \\let from = 1;
        \\let as = 2;
        \\let string = "ok";
        \\let number = 123;
    , false);

    try expectTokenKinds(scanned.tokens, &.{
        .Keyword_let, .Identifier, .Equal, .NumberLiteral, .Semicolon,
        .Keyword_let, .Identifier, .Equal, .NumberLiteral, .Semicolon,
        .Keyword_let, .Identifier, .Equal, .StringLiteral, .Semicolon,
        .Keyword_let, .Identifier, .Equal, .NumberLiteral, .Semicolon,
        .EOF,
    });

    try std.testing.expectEqualStrings("from", scanned.tokens[1].lexeme);
    try std.testing.expectEqual(tokens.ContextualKeyword.Contextual_from, scanned.tokens[1].contextualKeyword().?);
    try std.testing.expectEqualStrings("as", scanned.tokens[6].lexeme);
    try std.testing.expectEqual(tokens.ContextualKeyword.Contextual_as, scanned.tokens[6].contextualKeyword().?);
    try std.testing.expectEqualStrings("string", scanned.tokens[11].lexeme);
    try std.testing.expectEqual(tokens.ContextualKeyword.Contextual_string, scanned.tokens[11].contextualKeyword().?);
    try std.testing.expectEqualStrings("number", scanned.tokens[16].lexeme);
    try std.testing.expectEqual(tokens.ContextualKeyword.Contextual_number, scanned.tokens[16].contextualKeyword().?);
}

test "frontend suite: scanner records comments and leading line breaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanOk(
        allocator,
        "let a = 1; // line\n/* block\ncomment */ const b = 2;",
        true,
    );

    try std.testing.expectEqual(@as(usize, 2), scanned.comments.len);
    try std.testing.expectEqual(TokenType.LineComment, scanned.comments[0].kind);
    try std.testing.expectEqual(TokenType.BlockComment, scanned.comments[1].kind);
    try std.testing.expectEqual(TokenType.Keyword_const, scanned.tokens[5].kind);
    try std.testing.expect(scanned.tokens[5].flags.has_leading_line_break);
}

test "frontend suite: scanner reports lexical failures and still emits eof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_char = try scanner.scanAll(allocator, "\\", false);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.invalid_character, invalid_char.diagnostics[0].code);
    try std.testing.expectEqual(TokenType.EOF, invalid_char.tokens[invalid_char.tokens.len - 1].kind);

    const invalid_string = try scanner.scanAll(allocator, "\"unterminated", false);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_string, invalid_string.diagnostics[0].code);

    const invalid_comment = try scanner.scanAll(allocator, "/* unterminated", false);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_block_comment, invalid_comment.diagnostics[0].code);
}

test "frontend suite: parser builds variable function import export and call shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\import { log } from "console";
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    console.log(message);
        \\    return message;
        \\}
    );

    const root = parsed.ast.node(parsed.ast.root);
    const program = root.data.Program;
    try std.testing.expectEqual(@as(usize, 2), program.statements.len);
    try expectNodeTag(parsed.ast, program.statements[0], .ImportDeclaration);
    try expectNodeTag(parsed.ast, program.statements[1], .ExportDeclaration);

    const export_decl = parsed.ast.node(program.statements[1]).data.ExportDeclaration;
    const function_decl = parsed.ast.node(export_decl.declaration).data.FunctionDeclaration;
    try std.testing.expectEqualStrings("main", function_decl.name);
    try std.testing.expectEqual(@as(usize, 1), function_decl.params.len);

    const body = parsed.ast.node(function_decl.body).data.BlockStatement;
    try std.testing.expectEqual(@as(usize, 3), body.statements.len);
    try expectNodeTag(parsed.ast, body.statements[0], .VariableDeclaration);
    try expectNodeTag(parsed.ast, body.statements[1], .ExpressionStatement);
    try expectNodeTag(parsed.ast, body.statements[2], .ReturnStatement);

    const call_stmt = parsed.ast.node(body.statements[1]).data.ExpressionStatement;
    const call = parsed.ast.node(call_stmt.expression).data.CallExpression;
    try std.testing.expectEqual(@as(usize, 1), call.arguments.len);
    const member = parsed.ast.node(call.callee).data.MemberExpression;
    try std.testing.expectEqualStrings("log", member.property);
}

test "frontend suite: parser validates contextual import syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const valid = try parseOk(allocator,
        \\import defaultLogger from "console";
        \\import { log, warn } from "console";
    );
    const program = valid.ast.node(valid.ast.root).data.Program;
    try std.testing.expectEqual(@as(usize, 2), program.statements.len);
    try expectNodeTag(valid.ast, program.statements[0], .ImportDeclaration);
    try expectNodeTag(valid.ast, program.statements[1], .ImportDeclaration);

    const invalid_imports = [_][]const u8{
        "import defaultLogger potato \"console\";",
        "import { log } potato \"console\";",
    };
    for (invalid_imports) |source| {
        const scanned = try scanOk(allocator, source, false);
        const parsed = try parser.parse(allocator, scanned.tokens, true);
        try std.testing.expect(parsed.diagnostics.len > 0);
        try std.testing.expectEqual(diagnostics.DiagnosticCode.expected_token, parsed.diagnostics[0].code);
    }
}

test "frontend suite: parser validates contextual export aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let localName = "dev";
        \\export { localName };
        \\export { localName as exportedName };
    );
    const bound = try binder.bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    try std.testing.expectEqualStrings("localName", exportByName(bound, "localName").?.local_name);
    try std.testing.expectEqualStrings("localName", exportByName(bound, "exportedName").?.local_name);

    const invalid_exports = [_][]const u8{
        "export { localName potato exportedName };",
        "export { as };",
        "export { localName as };",
    };
    for (invalid_exports) |source| {
        const scanned = try scanOk(allocator, source, false);
        const invalid = try parser.parse(allocator, scanned.tokens, true);
        try std.testing.expect(invalid.diagnostics.len > 0);
        try std.testing.expectEqual(diagnostics.DiagnosticCode.expected_token, invalid.diagnostics[0].code);
    }
}

test "frontend suite: parser accepts contextual words as identifiers outside import export syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function test(from: number) {
        \\  let as = from;
        \\  return as;
        \\}
    );

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    const function_decl = parsed.ast.node(program.statements[0]).data.FunctionDeclaration;
    const param = parsed.ast.node(function_decl.params[0]).data.Parameter;
    try std.testing.expectEqualStrings("from", param.name);

    const body = parsed.ast.node(function_decl.body).data.BlockStatement;
    const variable_decl = parsed.ast.node(body.statements[0]).data.VariableDeclaration;
    const declarator = parsed.ast.node(variable_decl.declarations[0]).data.VariableDeclarator;
    try std.testing.expectEqualStrings("as", declarator.name);
}

test "frontend suite: parser represents export declaration forms consistently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let x = 0;
        \\export let a = 1;
        \\export const b = 1;
        \\export var c = 1;
        \\export function f() {}
        \\export { x };
        \\export { x as y };
    );

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expectEqual(@as(usize, 7), program.statements.len);

    const let_export = parsed.ast.node(program.statements[1]).data.ExportDeclaration;
    try std.testing.expect(let_export.declaration != ast_mod.invalid_node);
    try std.testing.expectEqual(@as(usize, 0), let_export.specifiers.len);
    const let_decl = parsed.ast.node(let_export.declaration).data.VariableDeclaration;
    try std.testing.expectEqual(TokenType.Keyword_let, let_decl.kind);

    const const_export = parsed.ast.node(program.statements[2]).data.ExportDeclaration;
    const const_decl = parsed.ast.node(const_export.declaration).data.VariableDeclaration;
    try std.testing.expectEqual(TokenType.Keyword_const, const_decl.kind);

    const var_export = parsed.ast.node(program.statements[3]).data.ExportDeclaration;
    const var_decl = parsed.ast.node(var_export.declaration).data.VariableDeclaration;
    try std.testing.expectEqual(TokenType.Keyword_var, var_decl.kind);

    const function_export = parsed.ast.node(program.statements[4]).data.ExportDeclaration;
    const function_decl = parsed.ast.node(function_export.declaration).data.FunctionDeclaration;
    try std.testing.expectEqualStrings("f", function_decl.name);

    const named_export = parsed.ast.node(program.statements[5]).data.ExportDeclaration;
    try std.testing.expectEqual(ast_mod.invalid_node, named_export.declaration);
    try std.testing.expectEqual(@as(usize, 1), named_export.specifiers.len);
    try std.testing.expectEqualStrings("x", named_export.specifiers[0].local_name);
    try std.testing.expectEqualStrings("x", named_export.specifiers[0].exported_name);

    const aliased_export = parsed.ast.node(program.statements[6]).data.ExportDeclaration;
    try std.testing.expectEqual(ast_mod.invalid_node, aliased_export.declaration);
    try std.testing.expectEqual(@as(usize, 1), aliased_export.specifiers.len);
    try std.testing.expectEqualStrings("x", aliased_export.specifiers[0].local_name);
    try std.testing.expectEqualStrings("y", aliased_export.specifiers[0].exported_name);
}

test "frontend suite: parser reports syntax errors without aborting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanOk(allocator, "let = ;", true);
    const parsed = try parser.parse(allocator, scanned.tokens, true);

    try std.testing.expect(parsed.diagnostics.len > 0);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.expected_token, parsed.diagnostics[0].code);
    try expectNodeTag(parsed.ast, parsed.ast.root, .Program);
}

test "frontend suite: binder records scopes symbols imports exports and duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\import { log } from "console";
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    { let inner = message; }
        \\    return message;
        \\}
    );
    const bound = try binder.bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), bound.module.imports.len);
    try std.testing.expectEqualStrings("log", bound.module.imports[0].local_name);
    try std.testing.expectEqual(@as(usize, 1), bound.module.exports.len);
    try std.testing.expectEqualStrings("main", bound.module.exports[0].name);

    try std.testing.expectEqual(binder.SymbolKind.import, symbolByName(bound, "log").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.function, symbolByName(bound, "main").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.parameter, symbolByName(bound, "name").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "message").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "inner").?.kind);
    try std.testing.expectEqual(binder.ScopeKind.global, bound.scopes[0].kind);
    try std.testing.expect(bound.scopes.len >= 3);

    const duplicate = try parseOk(allocator, "let x = 1; let x = 2;");
    const duplicate_bound = try binder.bind(allocator, duplicate.ast);
    try std.testing.expectEqual(@as(usize, 1), duplicate_bound.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_declaration, duplicate_bound.diagnostics[0].code);
}

test "frontend suite: binder records all export declaration forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let x = 0;
        \\export let a = 1;
        \\export const b = 1;
        \\export var c = 1;
        \\export function f() {}
        \\export { x };
        \\export { x as y };
    );
    const bound = try binder.bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 6), bound.module.exports.len);

    try std.testing.expectEqualStrings("a", exportByName(bound, "a").?.local_name);
    try std.testing.expectEqualStrings("b", exportByName(bound, "b").?.local_name);
    try std.testing.expectEqualStrings("c", exportByName(bound, "c").?.local_name);
    try std.testing.expectEqualStrings("f", exportByName(bound, "f").?.local_name);
    try std.testing.expectEqualStrings("x", exportByName(bound, "x").?.local_name);
    try std.testing.expectEqualStrings("x", exportByName(bound, "y").?.local_name);

    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "a").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "b").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "c").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.function, symbolByName(bound, "f").?.kind);
    try std.testing.expectEqual(binder.SymbolKind.variable, symbolByName(bound, "x").?.kind);
}

test "frontend suite: binder reports duplicate exports once in module records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let x = 0;
        \\export let a = 1;
        \\export { a };
        \\export { x };
        \\export { x };
        \\export { x as y };
        \\export { x as y };
    );
    const bound = try binder.bind(allocator, parsed.ast);

    try std.testing.expectEqual(@as(usize, 3), bound.diagnostics.len);
    for (bound.diagnostics) |diagnostic| {
        try std.testing.expectEqual(diagnostics.DiagnosticCode.duplicate_export, diagnostic.code);
    }
    try std.testing.expectEqual(@as(usize, 3), bound.module.exports.len);
    try std.testing.expectEqualStrings("a", exportByName(bound, "a").?.local_name);
    try std.testing.expectEqualStrings("x", exportByName(bound, "x").?.local_name);
    try std.testing.expectEqualStrings("x", exportByName(bound, "y").?.local_name);
}

test "frontend suite: resolver resolves local and parameter reads without type annotation references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let x = 1;
        \\let y = x + 2;
        \\function f(value: number) {
        \\    return value;
        \\}
    );
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try expectReference(resolved, "x", .read, symbolByNameKindScope(bound, "x", .variable, 0).?.id);
    try expectReference(resolved, "value", .read, symbolByNameKindScope(bound, "value", .parameter, null).?.id);
    try std.testing.expectEqual(@as(usize, 0), countReferences(resolved, "y", null));
    try std.testing.expectEqual(@as(usize, 0), countReferences(resolved, "number", null));
}

test "frontend suite: resolver handles shadowing and outer scope lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let x = 1;
        \\function f() {
        \\    let x = 2;
        \\    return x;
        \\}
        \\function g() {
        \\    return x;
        \\}
    );
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);

    const global_x = symbolByNameKindScope(bound, "x", .variable, 0).?;
    var inner_x: ?binder.Symbol = null;
    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "x") and symbol.kind == .variable and symbol.scope != 0) inner_x = symbol;
    }

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try std.testing.expect(inner_x != null);
    try expectReference(resolved, "x", .read, inner_x.?.id);
    try expectReference(resolved, "x", .read, global_x.id);
    try std.testing.expectEqual(@as(usize, 2), countReferences(resolved, "x", .read));
}

test "frontend suite: resolver records calls assignments members imports and exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\import defaultLogger from "console";
        \\import { log } from "console";
        \\let x = 1;
        \\let localName = "dev";
        \\function makeGreeting(name: string) {
        \\    return name;
        \\}
        \\function getObject() {
        \\    return defaultLogger;
        \\}
        \\function f(name: string) {
        \\    x = x + 1;
        \\    log("hi");
        \\    defaultLogger.log("hi");
        \\    let obj = getObject();
        \\    obj.log("hi");
        \\    return makeGreeting(name);
        \\}
        \\export { localName as exportedName };
    );
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try expectReference(resolved, "x", .write, symbolByNameKindScope(bound, "x", .variable, 0).?.id);
    try expectReference(resolved, "x", .read, symbolByNameKindScope(bound, "x", .variable, 0).?.id);
    try expectReference(resolved, "log", .call, symbolByNameKindScope(bound, "log", .import, 0).?.id);
    try expectReference(resolved, "defaultLogger", .read, symbolByNameKindScope(bound, "defaultLogger", .import, 0).?.id);
    try expectReference(resolved, "getObject", .call, symbolByNameKindScope(bound, "getObject", .function, 0).?.id);
    try expectReference(resolved, "obj", .read, symbolByNameKindScope(bound, "obj", .variable, null).?.id);
    try expectReference(resolved, "makeGreeting", .call, symbolByNameKindScope(bound, "makeGreeting", .function, 0).?.id);
    try expectReference(resolved, "name", .read, symbolByNameKindScope(bound, "name", .parameter, null).?.id);
    try expectReference(resolved, "localName", .export_ref, symbolByNameKindScope(bound, "localName", .variable, 0).?.id);
    try std.testing.expectEqual(@as(usize, 1), countReferences(resolved, "log", null));
    try std.testing.expectEqual(@as(usize, 0), countReferences(resolved, "exportedName", null));
}

test "frontend suite: frontend analyze includes resolver diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try frontend.analyze(allocator, .{ .path = "bad-ref.ts", .text =
        \\function f() {
        \\    return missingName;
        \\}
    }, .{});

    try std.testing.expectEqual(@as(usize, 1), result.resolve.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, result.resolve.diagnostics[0].code);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, result.diagnostics[result.diagnostics.len - 1].code);
    try std.testing.expectEqual(diagnostics.DiagnosticPhase.resolver, result.resolve.diagnostics[0].phase);
    try std.testing.expect(std.mem.indexOf(u8, result.resolve.diagnostics[0].message, "missingName") != null);
}

test "frontend suite: cfg keeps straight line return connected to exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f() {
        \\    let x = 1;
        \\    return x;
        \\}
    );
    const graphs = try cfg.build(allocator, parsed.ast);
    const graph = graphs[0].graph;
    const return_block = blockContainingStatementKind(parsed.ast, graph, .ReturnStatement).?;

    try std.testing.expectEqual(@as(usize, 1), graphs.len);
    try std.testing.expectEqualStrings("f", graphs[0].name);
    try std.testing.expectEqual(@as(cfg.BasicBlockId, 0), graphs[0].graph.entry);
    try expectBlockHasSuccessor(graph, return_block, graph.exit);
}

test "frontend suite: cfg return has no fallthrough to later statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f() {
        \\    return 1;
        \\    let x = 2;
        \\}
    );
    const graphs = try cfg.build(allocator, parsed.ast);
    const graph = graphs[0].graph;
    const return_block = blockContainingStatementKind(parsed.ast, graph, .ReturnStatement).?;
    const unreachable_block = blockContainingStatementKind(parsed.ast, graph, .VariableDeclaration).?;

    try expectBlockHasSuccessor(graph, return_block, graph.exit);
    try expectNoBlockHasSuccessor(graph, return_block, unreachable_block);
    try expectNoPathExists(graph, return_block, unreachable_block);
    try std.testing.expectEqual(@as(usize, 0), blockById(graph, unreachable_block).predecessors.len);
}

test "frontend suite: cfg if without else has true and false paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f(x: number) {
        \\    if (x > 0) { return x; }
        \\    return 0;
        \\}
    );
    const graph = (try cfg.build(allocator, parsed.ast))[0].graph;
    const if_block = blockContainingStatementKind(parsed.ast, graph, .IfStatement).?;

    try std.testing.expectEqual(@as(usize, 2), blockById(graph, if_block).successors.len);
    var successor_returns: usize = 0;
    for (blockById(graph, if_block).successors) |successor| {
        const block = blockById(graph, successor);
        if (blockContainsStatementKind(parsed.ast, block, .ReturnStatement)) successor_returns += 1;
        try expectPathExists(graph, successor, graph.exit);
    }
    try std.testing.expectEqual(@as(usize, 2), successor_returns);
}

test "frontend suite: cfg if with else has explicit branch exits and no merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f(x: number) {
        \\    if (x > 0) { return x; } else { return 0; }
        \\}
    );
    const graph = (try cfg.build(allocator, parsed.ast))[0].graph;
    const if_block = blockContainingStatementKind(parsed.ast, graph, .IfStatement).?;

    try std.testing.expectEqual(@as(usize, 2), blockById(graph, if_block).successors.len);
    for (blockById(graph, if_block).successors) |successor| {
        try std.testing.expectEqual(@as(usize, 1), blockById(graph, successor).successors.len);
        try expectBlockHasSuccessor(graph, successor, graph.exit);
    }
}

test "frontend suite: cfg while creates loop edge and false path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f(x: number) {
        \\    while (x > 0) { x = x - 1; }
        \\    return x;
        \\}
    );
    const graph = (try cfg.build(allocator, parsed.ast))[0].graph;
    const while_block = blockContainingStatementKind(parsed.ast, graph, .WhileStatement).?;

    try std.testing.expectEqual(@as(usize, 2), blockById(graph, while_block).successors.len);
    var has_back_edge = false;
    for (graph.blocks) |block| {
        if (hasEdge(block, while_block)) has_back_edge = true;
    }
    try std.testing.expect(has_back_edge);
    var false_path_reaches_return = false;
    for (blockById(graph, while_block).successors) |successor| {
        if (blockContainsStatementKind(parsed.ast, blockById(graph, successor), .ReturnStatement)) {
            false_path_reaches_return = true;
        }
        try expectPathExists(graph, successor, graph.exit);
    }
    try std.testing.expect(false_path_reaches_return);
}

test "frontend suite: parser and cfg preserve for init test update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f(limit: number) {
        \\    let total = 0;
        \\    for (let i = 0; i < limit; i = i + 1) {
        \\        total = total + i;
        \\    }
        \\    return total;
        \\}
    );
    const graph = (try cfg.build(allocator, parsed.ast))[0].graph;
    const for_block = blockContainingStatementKind(parsed.ast, graph, .ForStatement).?;
    const for_stmt = parsed.ast.node(blockById(graph, for_block).statements[0]).data.ForStatement;

    try std.testing.expect(for_stmt.init != null);
    try std.testing.expect(for_stmt.condition != null);
    try std.testing.expect(for_stmt.update != null);
    try expectNodeTag(parsed.ast, for_stmt.update.?, .AssignmentExpression);
    const update = parsed.ast.node(for_stmt.update.?).data.AssignmentExpression;
    try expectNodeTag(parsed.ast, update.left, .Identifier);
    try expectNodeTag(parsed.ast, update.right, .BinaryExpression);
    try std.testing.expectEqual(@as(usize, 2), blockById(graph, for_block).successors.len);

    var update_in_cfg = false;
    for (graph.blocks) |block| {
        for (block.statements) |statement| {
            if (statement == for_stmt.update.?) update_in_cfg = true;
        }
    }
    try std.testing.expect(update_in_cfg);

    var has_loop_edge = false;
    for (graph.blocks) |block| {
        if (block.id != graph.entry and hasEdge(block, for_block)) has_loop_edge = true;
    }
    try std.testing.expect(has_loop_edge);
    var false_path_reaches_return = false;
    for (blockById(graph, for_block).successors) |successor| {
        if (blockContainsStatementKind(parsed.ast, blockById(graph, successor), .ReturnStatement)) {
            false_path_reaches_return = true;
        }
        try expectPathExists(graph, successor, graph.exit);
    }
    try std.testing.expect(false_path_reaches_return);
}

test "frontend suite: cfg nested if in loop keeps return and back edge separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\function f(x: number) {
        \\    while (x > 0) {
        \\        if (x > 10) { return x; }
        \\        x = x - 1;
        \\    }
        \\    return 0;
        \\}
    );
    const graph = (try cfg.build(allocator, parsed.ast))[0].graph;
    const while_block = blockContainingStatementKind(parsed.ast, graph, .WhileStatement).?;
    const if_block = blockContainingStatementKind(parsed.ast, graph, .IfStatement).?;

    try std.testing.expect(while_block != if_block);
    try expectPathExists(graph, if_block, graph.exit);
    var non_return_loops = false;
    for (graph.blocks) |block| {
        if (block.id != while_block and hasEdge(block, while_block)) non_return_loops = true;
    }
    try std.testing.expect(non_return_loops);
}

test "frontend suite: diagnostics preserve severity code span and message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, "\"unterminated", false);
    try std.testing.expectEqual(@as(usize, 1), scanned.diagnostics.len);
    try std.testing.expectEqual(diagnostics.Severity.@"error", scanned.diagnostics[0].severity);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_string, scanned.diagnostics[0].code);
    try std.testing.expectEqual(diagnostics.DiagnosticPhase.scanner, scanned.diagnostics[0].phase);
    try std.testing.expectEqualStrings("unterminated string", scanned.diagnostics[0].message);
    try std.testing.expect(scanned.diagnostics[0].span.end >= scanned.diagnostics[0].span.start);
}

test "frontend suite: diagnostic metadata maps cannot_find_name" {
    try std.testing.expectEqualStrings("VZG4001", diagnostics.diagnosticCodeId(.cannot_find_name));
    try std.testing.expectEqualStrings("cannot_find_name", diagnostics.diagnosticCodeName(.cannot_find_name));

    const diagnostic = diagnostics.Diagnostic{
        .severity = .@"error",
        .code = .cannot_find_name,
        .phase = .resolver,
        .message = "cannot find name 'missing'",
        .span = .{ .start = 8, .end = 15, .line = 1, .column = 9 },
    };

    try std.testing.expectEqual(diagnostics.Severity.@"error", diagnostic.severity);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, diagnostic.code);
    try std.testing.expectEqual(diagnostics.DiagnosticPhase.resolver, diagnostic.phase);
}

test "frontend suite: missing name diagnostic includes name and span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try frontend.analyze(allocator, .{ .path = "missing.ts", .text = "let y = missing + 1;" }, .{});
    try std.testing.expectEqual(@as(usize, 1), result.resolve.diagnostics.len);
    const diagnostic = result.resolve.diagnostics[0];
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, diagnostic.code);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "missing") != null);
    try std.testing.expectEqual(@as(usize, 8), diagnostic.span.start);
    try std.testing.expectEqual(@as(usize, 15), diagnostic.span.end);
}

test "frontend suite: facade integrates positive and negative analysis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ok = try frontend.analyze(allocator, .{ .path = "ok.ts", .text =
        \\import { log } from "console";
        \\export function main(name: string) {
        \\    log(name);
        \\    return name;
        \\}
    }, .{});

    try std.testing.expectEqual(@as(usize, 0), ok.diagnostics.len);
    try std.testing.expect(ok.tokens.len > 0);
    try std.testing.expectEqual(@as(usize, 1), ok.bind.module.imports.len);
    try std.testing.expectEqual(@as(usize, 1), ok.bind.module.exports.len);
    try std.testing.expectEqual(@as(usize, 1), ok.cfgs.len);

    const bad = try frontend.analyze(allocator, .{ .path = "bad.ts", .text = "export function broken( {" }, .{});
    try std.testing.expect(bad.diagnostics.len > 0);
    try std.testing.expectEqual(TokenType.EOF, bad.tokens[bad.tokens.len - 1].kind);
}
