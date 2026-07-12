const std = @import("std");

const ast_mod = @import("ast.zig");
const binder = @import("binder.zig");
const cfg = @import("cfg.zig");
const diagnostics = @import("../diagnostics/root.zig");
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
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });
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

// -- Binary expression precedence --------------------------------------------------------

/// Look inside `tree` for the first node whose active tag equals `tag`. Returns its id or invalid_node.
fn findFirst(tree: ast_mod.Ast, tag: std.meta.Tag(ast_mod.NodeData)) !NodeId {
    for (tree.nodes) |n| if (@intFromEnum(std.meta.activeTag(n.data)) == @intFromEnum(tag)) return n.id;
    return ast_mod.invalid_node;
}

fn binaryOperatorId(tree: ast_mod.Ast, id: NodeId) TokenType {
    const op = tree.node(id).data.BinaryExpression.operator;
    // Skip assignment-wrapped operators to surface the underlying comparison/arithmetic token.
    return switch (op) {
        .PlusEqual, .MinusEqual, .AsteriskEqual, .SlashEqual, .PercentEqual => switch (@intFromEnum(op)) {
            @intFromEnum(.MinusEqual) => .Minus,
            else => unreachable,
        },
        else => op,
    };
}

fn childTag(tree: ast_mod.Ast, id: NodeId) std.meta.Tag(ast_mod.NodeData) {
    return std.meta.activeTag(tree.node(id).data);
}

test "parser precedence: 1 + 2 * 3 groups under +" {
    const source =
        \\let x = 1 + 2 * 3;
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, source, false);
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    // The initializer of `x` is a BinaryExpression with operator `+`.
    const program = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const var_decl_id = program.statements[0];
    const declarator = parsed.ast.node(var_decl_id).data.VariableDeclarator;
    try std.testing.expect(declarator.init != null);

    const plus_id = declarator.init.?;
    try expectNodeTag(parsed.ast, plus_id, .BinaryExpression);
    // The `+` node's operator must be Plus.
    {
        const op_tok = parsed.ast.node(plus_id).data.BinaryExpression.operator;
        try std.testing.expect(op_tok == .Plus);
    }

    // Left child: literal "1". Right child: multiplication (2 * 3).
    const plus_left = parsed.ast.node(plus_id).data.BinaryExpression.left;
    const plus_right = parsed.ast.node(plus_id).data.BinaryExpression.right;
    try expectNodeTag(parsed.ast, plus_left, .Literal);
    try std.testing.expect(std.mem.eql(u8, parsed.ast.node(plus_left).data.Literal.value, "1"));

    try expectNodeTag(parsed.ast, plus_right, .BinaryExpression);
    {
        const op_tok = parsed.ast.node(plus_right).data.BinaryExpression.operator;
        try std.testing.expect(op_tok == .Asterisk);
        // Inner multiplication: left is literal "2", right is literal "3".
        const mul_left = parsed.ast.node(plus_right).data.BinaryExpression.left;
        const mul_right = parsed.ast.node(plus_right).data.BinaryExpression.right;
        try expectNodeTag(parsed.ast, mul_left, .Literal);
        try std.testing.expect(std.mem.eql(u8, parsed.ast.node(mul_left).data.Literal.value, "2"));
        try expectNodeTag(parsed.ast, mul_right, .Literal);
        try std.testing.expect(std.mem.eql(u8, parsed.ast.node(mul_right).data.Literal.value, "3"));
    }
}

test "parser precedence: a || b && c groups (b && c) under ||" {
    const source =
        \\let y = a || b && c;
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, source, false);
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    const vd_id = program.statements[0];
    const declarator = parsed.ast.node(vd_id).data.VariableDeclarator;
    try std.testing.expect(declarator.init != null);

    const or_id = declarator.init.?;
    try expectNodeTag(parsed.ast, or_id, .BinaryExpression);
    {
        const op_tok = parsed.ast.node(or_id).data.BinaryExpression.operator;
        try std.testing.expect(op_tok == .BarBar, "expected || at top level");

        // Left: identifier `a`. Right: (b && c) — binary AND whose right is an identifier.
        const or_left = parsed.ast.node(or_id).data.BinaryExpression.left;
        const or_right = parsed.ast.node(or_id).data.BinaryExpression.right;
        try expectNodeTag(parsed.ast, or_left, .Identifier);
        {
            try std.testing.expect(std.mem.eql(u8, parsed.ast.node(or_left).data.Identifier.name, "a"));

            try expectNodeTag(parsed.ast, or_right, .BinaryExpression);
            const and_id = or_right;
            const and_op_tok = parsed.ast.node(and_id).data.BinaryExpression.operator;
            try std.testing.expect(and_op_tok == .AmpersandAmpersand, "expected && at second level");

            const and_left = parsed.ast.node(and_id).data.BinaryExpression.left;
            const and_right = parsed.ast.node(and_id).data.BinaryExpression.right;
            try expectNodeTag(parsed.ast, and_left, .Identifier);
            try std.testing.expect(std.mem.eql(u8, parsed.ast.node(and_left).data.Identifier.name, "b"));

            try expectNodeTag(parsed.ast, and_right, .Identifier);
            try std.testing.expect(std.mem.eql(u8, parsed.ast.node(and_right).data.Identifier.name, "c"));
        }
    }
}

test "parser precedence: i % colors.red.length || empty string groups % inside ||" {
    const source =
        \\let z = i % colors.red.length || "";
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanner.scanAll(allocator, source, false);
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    const vd_id = program.statements[0];
    const declarator = parsed.ast.node(vd_id).data.VariableDeclarator;
    try std.testing.expect(declarator.init != null);

    const or_id = declarator.init.?;
    try expectNodeTag(parsed.ast, or_id, .BinaryExpression);
    {
        const op_tok = parsed.ast.node(or_id).data.BinaryExpression.operator;
        try std.testing.expect(op_tok == .BarBar, "expected || at top level");

        // Left: (i % colors.red.length) — binary `%` whose right is a MemberExpression.
        const or_left = parsed.ast.node(or_id).data.BinaryExpression.left;
        try expectNodeTag(parsed.ast, or_left, .BinaryExpression);

        {
            const mod_op_tok = parsed.ast.node(or_left).data.BinaryExpression.operator;
            try std.testing.expect(mod_op_tok == .Percent, "expected % at second level");

            const mod_left = parsed.ast.node(or_left).data.BinaryExpression.left;
            try expectNodeTag(parsed.ast, mod_left, .Identifier);
            try std.testing.expect(std.mem.eql(u8, parsed.ast.node(mod_left).data.Identifier.name, "i"));

            const mod_right = parsed.ast.node(or_left).data.BinaryExpression.right;
            try expectNodeTag(parsed.ast, mod_right, .MemberExpression);
            {
                // Object: MemberExpression `colors.red`. Property: "length".
                const member_obj_id = parsed.ast.node(mod_right).data.MemberExpression.object;
                try std.testing.expect(std.mem.eql(u8, parsed.ast.node(mod_right).data.MemberExpression.property, "length"));

                try expectNodeTag(parsed.ast, member_obj_id, .MemberExpression);
                // inner-most object is identifier `colors`, property "red".
                const colors_id = parsed.astnode(member_obj_id).data.MemberExpression.object;
                try std.testing.expect(std.mem.eql(u8, parsed.astnode(colors_id).data.Identifier.name, "colors"));

                const red_prop = parsed.astnode(member_obj_id).data.MemberExpression.property;
                try std.testing.expect(std.mem.eql(u8, red_prop, "red"));
            }
        }

        // Right: "" — empty string literal.
        const or_right = parsed.ast.node(or_id).data.BinaryExpression.right;
        try expectNodeTag(parsed.ast, or_right, .Literal);
    }
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

test "frontend suite: parser accepts element access non-null assertion and chains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\let art = ["a"];
        \\\\let i = 0;
        \\\\let len = art[i]!.length;
    ;
    const scanned = try scanOk(allocator, source, false);
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });

    // Goal: zero parser diagnostics on valid syntax.
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len) orelse {
        var i: usize = 0;
        while (i < parsed.diagnostics.len) : (i += 1) _ = "diag " ++ @tagName(parsed.diagnostics[i].code);
    };

    // Verify AST has ElementAccessExpression and NonNullExpression nodes.
    {
        var saw_element = false;
        var saw_nonnull = false;
        for (parsed.ast.nodes) |n| switch (n.data) {
            .ElementAccessExpression => saw_element = true,
            .NonNullExpression => saw_nonnull = true,
            else => {},
        };
        try std.testing.expect(saw_element);
        try std.testing.expect(saw_nonnull);
    }

    // Bind and resolve. Expect zero diagnostics on valid syntax.
    const binder_result = binder.bind(allocator, parsed.ast) orelse return error.BindFailed;
    const resolved = resolver.resolve(allocator, parsed.ast, binder_result);

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len) orelse {
        var i: usize = 0;
        while (i < resolved.diagnostics.len) : (i += 1) _ = "diag " ++ @tagName(resolved.diagnostics[i].code);
    };

    // Expect a read reference for 'art' and another for the inner 'i'. The member property name 'length' must not be resolved as a lexical variable.
    try std.testing.expect(countReferences(resolved, "art", .read) > 0);
    try std.testing.expect(countReferences(resolved, "i", .read) > 0);

    // Confirm element access is structured: object resolves and index expression is traversed (the 'i' reference above proves this).
    {
        const program = parsed.ast.node(parsed.ast.root).data.Program;
        var found_len_init: ?usize = null;
        for (program.statements) |stmt_id| {
            const stmt = parsed.ast.node(stmt_id);
            if (@tagName(stmt.data) != "VariableDeclaration") continue;
            const vd = stmt.data.VariableDeclaration;
            for (vd.declarations) |d_id| {
                const d = parsed.ast.node(d_id);
                const vdec = d.data.VariableDeclarator;
                if (!std.mem.eql(u8, vdec.name, "len")) continue;
                found_len_init = vdec.init;
            }
        }
        try std.testing.expect(found_len_init != null);

        // Descend into the chain: NonNull -> MemberExpression (length) -> ElementAccessExpression (art[i]).
        const nn_id = parsed.ast.node(found_len_init.?).data.VariableDeclarator.init orelse unreachable;
        try std.testing.expect(@tagName(parsed.ast.node(nn_id).data) == "NonNullExpression");
        try std.testing.expect(@tagName(parsed.ast.node(nn_id.data.NonNullExpression.expression).data) == "MemberExpression");

        const elem_id = parsed.ast.node(parsed.ast.node(nn_id).data.NonNullExpression.expression).data.MemberExpression.object;
        try std.testing.expect(@tagName(parsed.ast.node(elem_id).data) == "ElementAccessExpression");
    }
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
        const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });
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
        const invalid = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = false });
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
    const parsed = try parser.parse(allocator, scanned.tokens, .{ .recover_errors = true });

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

test "frontend suite: resolver allows console as ambient global without VZG4001" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `console` is a predeclared ambient global; should not emit VZG4001
    // for the bare read of `console`, and member `.log` skips resolution entirely.
    const parsed = try parseOk(allocator,
        \\console.log("hi");
    );
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);

    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
}

test "frontend suite: truly missing name still emits VZG4001 and ambient does not swallow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `missingName` is not in scope and is not an ambient; should still report VZG4001.
    const parsed = try parseOk(allocator,
        \\function f() {
        \\    return missingName;
        \\}
    );
    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);

    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.cannot_find_name, resolved.diagnostics[0].code);
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

test "frontend suite: parser preserves import specifier span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    //           0         1
    // 01234567890123456789012345678
    // import { x } from "./a";\n
    const source = "import { x } from \"./a\";\n";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root);
    const program = root.data.Program;
    try expectNodeTag(parsed.ast, program.statements[0], .ImportDeclaration);

    const node = parsed.ast.node(program.statements[0]);
    const decl = node.data.ImportDeclaration;

    // Source is unquoted specifier text.
    try std.testing.expectEqualStrings("./a", decl.source);

    // Source span covers the string literal token, not the full declaration.
    // String literal "\./a" starts at byte 18 ("./a" with quotes spans bytes 18..23).
    const specifier_start: usize = 18;
    const specifier_end: usize = 23;
    try std.testing.expectEqual(@as(u32, @intCast(specifier_start)), decl.source_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(specifier_end)), decl.source_span.end);

    // Full import declaration starts at byte 0 ("import" keyword). Span must not equal specifier span.
    const spans_differ = node.span.start != decl.source_span.start or node.span.end != decl.source_span.end;
    try std.testing.expect(spans_differ);

    // Source-text slicing using the preserved span must reproduce the lexeme with quotes.
    const lexeme = source[specifier_start..specifier_end];
    try std.testing.expectEqualStrings("\"./a\"", lexeme);
}

test "frontend suite: parameter annotation captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Source exercises one named parameter with an inline ': string' annotation.
    const source = "function f(x: string) { return x; }";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root).data.Program;

    const func_id = root.statements[0];
    try expectNodeTag(parsed.ast, func_id, .FunctionDeclaration);
    const func_node = parsed.ast.node(func_id);
    const params = func_node.data.FunctionDeclaration.params;
    try std.testing.expect(params.len == 1);

    const param_node = parsed.ast.node(params[0]);
    try expectNodeTag(parsed.ast, params[0], .Parameter);
    try std.testing.expect(param_node.data.Parameter.type_annotation != null);
    const ann = param_node.data.Parameter.type_annotation.?;
    try std.testing.expectEqualStrings("string", ann.name);
}

test "frontend suite: variable annotation captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "let x: string;";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root).data.Program;

    const var_decl_id = root.statements[0];
    try expectNodeTag(parsed.ast, var_decl_id, .VariableDeclaration);
    const decls_node = parsed.ast.node(var_decl_id);
    const declarators = decls_node.data.VariableDeclaration.declarations;
    try std.testing.expect(declarators.len == 1);

    const vd_id = declarators[0];
    const vd_node = parsed.ast.node(vd_id);
    try expectNodeTag(parsed.ast, vd_id, .VariableDeclarator);
    try std.testing.expect(vd_node.data.VariableDeclarator.type_annotation != null);
    const ann = vd_node.data.VariableDeclarator.type_annotation.?;
    try std.testing.expectEqualStrings("string", ann.name);
}

test "frontend suite: function return annotation captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Trailing ': boolean' is consumed as a return type annotation.
    const source = "function f(): boolean { return true; }";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root).data.Program;

    const func_id = root.statements[0];
    try expectNodeTag(parsed.ast, func_id, .FunctionDeclaration);
    const func_node = parsed.ast.node(func_id);
    try std.testing.expect(func_node.data.FunctionDeclaration.return_type != null);
    const ret_ann = func_node.data.FunctionDeclaration.return_type.?;
    try std.testing.expectEqualStrings("boolean", ret_ann.name);
}

test "frontend suite: untyped function has no return_type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No trailing ': boolean' — source parses as a bare return inside the body.
    const source = "function f() { return 0; }";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root).data.Program;

    const func_id = root.statements[0];
    try expectNodeTag(parsed.ast, func_id, .FunctionDeclaration);
    const func_node = parsed.ast.node(func_id);
    const ret_ann = func_node.data.FunctionDeclaration.return_type;
    try std.testing.expectEqual(@as(?ast_mod.TypeAnnotation, null), ret_ann);
}

test "frontend suite: simple type annotation fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Combined fixture exercising a variable annotation, a parameter
    // annotation, and a return-type annotation together.
    const source = "let x: number = 1;" ++ "\nfunction f(name: string): boolean {" ++ "\n    return true;" ++ "\n}";

    const parsed = try parseOk(allocator, source);
    const root = parsed.ast.node(parsed.ast.root).data.Program;

    // Variable annotation captured.
    const var_decl_id = root.statements[0];
    const vd_id = parsed.ast.node(var_decl_id).data.VariableDeclaration.declarations[0];
    const vd_node = parsed.ast.node(vd_id);
    try std.testing.expect(vd_node.data.VariableDeclarator.type_annotation != null);
    try std.testing.expectEqualStrings("number", vd_node.data.VariableDeclarator.type_annotation.?.name);

    // Parameter annotation captured (f's `name` parameter).
    const func_id = root.statements[1];
    const param_id = parsed.ast.node(func_id).data.FunctionDeclaration.params[0];
    const param_node = parsed.ast.node(param_id);
    try std.testing.expect(param_node.data.Parameter.type_annotation != null);
    try std.testing.expectEqualStrings("string", param_node.data.Parameter.type_annotation.?.name);

    // Return type annotation captured.
    const ret_ann = parsed.ast.node(func_id).data.FunctionDeclaration.return_type;
    try std.testing.expect(ret_ann != null);
    try std.testing.expectEqualStrings("boolean", ret_ann.?.name);
}
test "frontend suite: export default function creates named symbol and declaration wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Source parses a single 'export default function <name>() {}' statement.
    const source =
        \\export default function createColorArt() {
        \\  return [];
        \\}
    ;

    const parsed = try parseOk(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    // The parser should produce exactly one statement (the ExportDeclaration).
    const root = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expect(root.statements.len == 1);

    const stmt_id = root.statements[0];
    try expectNodeTag(parsed.ast, stmt_id, .ExportDeclaration);

    // The wrapper holds a nested FunctionDeclaration as its declaration.
    const decl_node = parsed.ast.node(stmt_id);
    const export_decl = decl_node.data.ExportDeclaration;
    try std.testing.expect(export_decl.declaration != ast_mod.invalid_node);
    try expectNodeTag(parsed.ast, export_decl.declaration, .FunctionDeclaration);

    // default_name should be the function's identifier.
    try std.testing.expectEqualStrings("createColorArt", export_decl.default_name.?);

    const func = parsed.ast.node(export_decl.declaration).data.FunctionDeclaration;
    try std.testing.expectEqualStrings("createColorArt", func.name);

    // Binder must register a 'createColorArt' symbol AND record an export.
    const bound = try binder.bind(allocator, parsed.ast);
    try std.testing.expectEqual(@as(usize, 0), bound.diagnostics.len);

    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "createColorArt")) return; // pass
    }
    try std.testing.fail("expected a 'createColorArt' symbol");

    var saw_default = false;
    for (bound.module.exports) |exp| {
        if (std.mem.eql(u8, exp.name, "default") and std.mem.eql(u8, exp.local_name, "createColorArt")) {
            saw_default = true;
            break;
        }
    }
    try std.testing.expect(saw_default);
}

test "frontend suite: export default preserves bare identifier path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Regression test — 'export default foo;' still produces default_name=foo, not the function branch.
    const source = "var x = 1; export default x;";

    const parsed = try parseOk(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    // The second statement is the default-name-only export with no declaration.
    const root = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expect(root.statements.len == 2);

    const stmt_id = root.statements[1];
    try expectNodeTag(parsed.ast, stmt_id, .ExportDeclaration);
    const decl_node = parsed.ast.node(stmt_id);
    const export_decl = decl_node.data.ExportDeclaration;
    try std.testing.expectEqualStrings("x", export_decl.default_name.?);
    try std.testing.expect(export_decl.declaration == ast_mod.invalid_node);

    const scanner = @import("scanner.zig");
    const bound = try binder.bind(allocator, parsed.ast);
    for (bound.module.exports) |exp| {
        if (std.mem.eql(u8, exp.name, "default")) return; // pass
    }
    try std.testing.fail("expected a 'default' export record");
}

test "frontend suite: existing named export is unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 'export function f() {}' still produces the existing shape.
    const source =
        \\export function main(name: string) {
        \\  return name;
        \\}
    ;

    const parsed = try parseOk(allocator, source);
    const bound = try binder.bind(allocator, parsed.ast);

    for (bound.symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "main")) return; // pass
    }
    try std.testing.fail("expected a 'main' symbol from named export");

    var saw_main = false;
    for (bound.module.exports) |exp| {
        if (std.mem.eql(u8, exp.name, "main") and std.mem.eql(u8, exp.local_name, "main")) {
            saw_main = true;
            break;
        }
    }
    try std.testing.expect(saw_main);

    // default must NOT be recorded for a named export.
    var saw_default = false;
    for (bound.module.exports) |exp| {
        if (std.mem.eql(u8, exp.name, "default")) {
            saw_default = true;
            break;
        }
    }
    try std.testing.expect(!saw_default);
}

test "frontend suite: parser accepts object literal expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const colors = { red: "#f00", green: "x2e8b1" };
    );

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expectEqual(@as(usize, 1), program.statements.len);

    const var_decl_id = program.statements[0];
    try expectNodeTag(parsed.ast, var_decl_id, .VariableDeclaration);

    const var_decl = parsed.ast.node(var_decl_id).data.VariableDeclaration;
    try std.testing.expectEqual(@as(usize, 1), var_decl.declarations.len);

    const declarator = parsed.ast.node(var_decl.declarations[0]).data.VariableDeclarator;
    try std.testing.expectEqualStrings("colors", declarator.name);
    try std.testing.expect(declarator.init != ast_mod.invalid_node);
    try expectNodeTag(parsed.ast, declarator.init.?, .ObjectExpression);

    const obj = parsed.ast.node(declarator.init.?).data.ObjectExpression;
    try std.testing.expectEqual(@as(usize, 2), obj.properties.len);

    // First property: key=red (raw lexeme from Identifier token)
    try std.testing.expectEqualStrings("red", obj.properties[0].key);
    // Second property: string-literal value includes surrounding quotes in the lexeme.
    try std.testing.expect(obj.properties[1].value != ast_mod.invalid_node);
}

test "frontend suite: parser accepts trailing comma in object literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const obj = { a: 1, b: 2, };
    );

    const var_decl = parsed.ast.node(parsed.ast.root).data.Program.statements[0];
    const decl = parsed.ast.node(var_decl).data.VariableDeclaration;
    const init_id = parsed.ast.node(decl.declarations[0]).data.VariableDeclarator.init.?;
    try expectNodeTag(parsed.ast, init_id, .ObjectExpression);
    const obj = parsed.ast.node(init_id).data.ObjectExpression;
    try std.testing.expectEqual(@as(usize, 2), obj.properties.len);
}

test "frontend suite: parser accepts string-literal and numeric literal keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const m = { "k": 1, 0: 2 };
    );

    const var_decl_id = parsed.ast.root;
    const program = parsed.ast.node(var_decl_id).data.Program;
    const init_id = parsed.ast.node(program.statements[0]).data.VariableDeclaration.declarations[0];
    try expectNodeTag(parsed.ast, init_id, .VariableDeclarator);
    const obj = parsed.ast.node(parsed.ast.node(init_id).data.VariableDeclarator.init.?).data.ObjectExpression;
    try std.testing.expectEqual(@as(usize, 2), obj.properties.len);
    // Key from a string-literal arrives with surrounding quotes stripped by the parser.
    try std.testing.expectEqualStrings("k", obj.properties[0].key);
    // Numeric key preserves its textual form.
    try std.testing.expectEqualStrings("0", obj.properties[1].key);
}

test "frontend suite: binder does not bind object literal property keys as symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const colors = { red: "#f00", green: "#2e8" };
    );

    const bound = try binder.bind(allocator, parsed.ast);

    // The only declared symbol should be "colors".
    var saw_colors = false;
    for (bound.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "colors")) {
            saw_colors = true;
            break;
        }
    }
    try std.testing.expect(saw_colors);

    // Property keys red and green must NOT appear as bound symbols.
    const red_sym = symbolByName(bound, "red");
    try std.testing.expect(red_sym == null);
    const green_sym = symbolByName(bound, "green");
    try std.testing.expect(green_sym == null);

    // And no diagnostics (e.g. cannot_find_name) should fire for the keys.
    for (parsed.diagnostics) |diag| {
        if (diag.code == .cannot_find_name or diag.code == .expected_token) {
            try std.testing.fail("unexpected diagnostic: " ++ @tagName(diag.code));
        }
    }
}

test "frontend suite: parser accepts array literal expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const art = [1, 2, "x"];
    );

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    try std.testing.expectEqual(@as(usize, 1), program.statements.len);

    const var_decl_id = program.statements[0];
    try expectNodeTag(parsed.ast, var_decl_id, .VariableDeclaration);

    const var_decl = parsed.ast.node(var_decl_id).data.VariableDeclaration;
    try std.testing.expectEqual(@as(usize, 1), var_decl.declarations.len);

    const declarator = parsed.ast.node(var_decl.declarations[0]).data.VariableDeclarator;
    try std.testing.expectEqualStrings("art", declarator.name);
    try expectNodeTag(parsed.ast, declarator.init.?, .ArrayExpression);

    const arr = parsed.ast.node(declarator.init.?).data.ArrayExpression;
    try std.testing.expectEqual(@as(usize, 3), arr.elements.len);

    // Each element is an expression node with a known tag (Identifier or Literal).
    for (arr.elements) |elem_id| {
        const elem = parsed.ast.node(elem_id);
        switch (std.meta.activeTag(elem.data)) {
            .Identifier, .Literal => {},
            else => try std.testing.expect(false),
        }
    }
}

test "frontend suite: parser accepts empty array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const empty = [];
    );

    const declarator = parsed.ast.node(parsed.ast.root).data.Program.statements[0];
    const decl = parsed.ast.node(declarator).data.VariableDeclaration;
    const init_id = parsed.ast.node(decl.declarations[0]).data.VariableDeclarator.init.?;
    try expectNodeTag(parsed.ast, init_id, .ArrayExpression);
    const arr = parsed.ast.node(init_id).data.ArrayExpression;
    try std.testing.expectEqual(@as(usize, 0), arr.elements.len);
}

test "frontend suite: parser accepts trailing comma in array literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const items = [1, 2,];
    );

    const declarator = parsed.ast.node(parsed.ast.root).data.Program.statements[0];
    const decl = parsed.ast.node(declarator).data.VariableDeclaration;
    const init_id = parsed.ast.node(decl.declarations[0]).data.VariableDeclarator.init.?;
    try expectNodeTag(parsed.ast, init_id, .ArrayExpression);
    const arr = parsed.ast.node(init_id).data.ArrayExpression;
    try std.testing.expectEqual(@as(usize, 2), arr.elements.len);
}

test "frontend suite: resolver visits array literal elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const arr = [1, 2, "x"];
        \\const items: []const f64 = arr;
    );

    const bound = try binder.bind(allocator, parsed.ast);
    // Nothing in the array itself should be declared as a symbol.
    for (bound.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "arr")) continue;
        if (std.mem.eql(u8, sym.name, "1") or std.mem.eql(u8, sym.name, "2"))
            try std.testing.fail("unexpected symbol from array literal");
    }

    const resolved = try resolver.resolve(allocator, parsed.ast, bound);
    // Only the declared names should be referenced: `arr` and `items`.
    for (resolved.references) |ref| {
        if (std.mem.eql(u8, ref.name, "1") or std.mem.eql(u8, ref.name, "2"))
            try std.testing.fail("resolver produced a reference from an array literal element");
    }

    // No diagnostics — array literals should not trigger any errors in this snippet.
    for (parsed.diagnostics) |diag| {
        if (diag.code == .cannot_find_name or diag.code == .expected_token)
            try std.testing.fail("unexpected diagnostic: " ++ @tagName(diag.code));
    }
}

test "frontend suite: array literals work with mixed element expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\const items = [1 + 2, "x", true];
    );

    const declarator = parsed.ast.node(parsed.ast.root).data.Program.statements[0];
    const decl = parsed.ast.node(declarator).data.VariableDeclaration;
    const init_id = parsed.ast.node(decl.declarations[0]).data.VariableDeclarator.init.?;
    try expectNodeTag(parsed.ast, init_id, .ArrayExpression);
    const arr = parsed.ast.node(init_id).data.ArrayExpression;
    try std.testing.expectEqual(@as(usize, 3), arr.elements.len);

    // The first element is a BinaryExpression from `1 + 2`.
    try expectNodeTag(parsed.ast, arr.elements[0], .BinaryExpression);
}

test "frontend suite: scanner emits template segments and handles escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const BT = "\x60";
    const source: []const u8 = "let line = " ++ BT ++ "${a} text ${b}" ++ BT ++ "; let raw = " ++ BT ++ "escaped \\` and \\${x}" ++ BT ++ ";";

    const scanned = try scanOk(allocator, source, false);

    try std.testing.expectEqual(@as(usize, 0), scanned.diagnostics.len);
    try expectTokenKinds(scanned.tokens, &.{
        .Keyword_let,            .Identifier,   .Equal,     .TemplateHead, .Identifier, .TemplateMiddle,
        .Identifier,             .TemplateTail, .Semicolon, .Keyword_let,  .Identifier, .Equal,
        .NoSubstitutionTemplate, .Semicolon,    .EOF,
    });
}

test "frontend suite: template AST preserves parts and resolver sees interpolations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const BT = "\x60";
    const source: []const u8 = "let name = 'x'; let obj = { value: name }; let s = " ++ BT ++ "hello ${obj.value} ${ { value: name }.value }" ++ BT ++ ";";

    const parsed = try parseOk(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);

    try std.testing.expectEqual(@as(usize, 2), countReferences(resolved, "name", .read));
    try std.testing.expectEqual(@as(usize, 1), countReferences(resolved, "obj", .read));

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    const var_decl = parsed.ast.node(program.statements[2]).data.VariableDeclaration;
    const declarator = parsed.ast.node(var_decl.declarations[0]).data.VariableDeclarator;
    try expectNodeTag(parsed.ast, declarator.init.?, .TemplateExpression);
    const template = parsed.ast.node(declarator.init.?).data.TemplateExpression;
    try std.testing.expectEqual(@as(usize, 3), template.parts.len);
    try std.testing.expectEqualStrings("hello ", template.parts[0].text);
    try std.testing.expectEqualStrings(" ", template.parts[1].text);
    try std.testing.expectEqualStrings("", template.parts[2].text);
    try std.testing.expect(template.parts[0].expression != null);
    try std.testing.expect(template.parts[1].expression != null);
    const template_span = parsed.ast.node(declarator.init.?).span;
    const template_start = std.mem.lastIndexOf(u8, source, BT).?;
    try std.testing.expectEqual(@as(u32, @intCast(template_start)), template_span.start);
    try std.testing.expectEqual(@as(u32, @intCast(source.len - 1)), template_span.end);
}

test "frontend suite: template AST supports one interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const BT = "\x60";
    const source: []const u8 = "let name = 'x'; let s = " ++ BT ++ "hello ${name}!" ++ BT ++ ";";
    const parsed = try parseOk(allocator, source);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);

    const program = parsed.ast.node(parsed.ast.root).data.Program;
    const declaration = parsed.ast.node(program.statements[1]).data.VariableDeclaration;
    const declarator = parsed.ast.node(declaration.declarations[0]).data.VariableDeclarator;
    const template = parsed.ast.node(declarator.init.?).data.TemplateExpression;
    try std.testing.expectEqual(@as(usize, 2), template.parts.len);
    try std.testing.expectEqualStrings("hello ", template.parts[0].text);
    try std.testing.expect(template.parts[0].expression != null);
    try std.testing.expectEqualStrings("!", template.parts[1].text);
    try std.testing.expect(template.parts[1].expression == null);
}

test "frontend suite: scanner reports unterminated template literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const BT = "\x60";
    const scanned = try scanner.scanAll(allocator, BT ++ "unterminated", false);
    try std.testing.expectEqual(@as(usize, 1), scanned.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_string, scanned.diagnostics[0].code);

    // Unterminated backslash inside a template also reports unterminated.
    const esc = try scanner.scanAll(allocator, BT ++ "escaped\\", false);
    try std.testing.expect(esc.diagnostics.len >= 1);

    const interpolation = try scanner.scanAll(allocator, BT ++ "hello ${name", false);
    try std.testing.expectEqual(@as(usize, 1), interpolation.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_string, interpolation.diagnostics[0].code);
}

test "frontend suite: unary expressions preserve precedence postfix assertions and resolver traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try parseOk(allocator,
        \\let value = 1;
        \\let object = { key: value };
        \\let promise = value;
        \\function fn() { return value; }
        \\let not_value = !value;
        \\let bits = ~value;
        \\let negative = -value;
        \\let positive = +value;
        \\let kind = typeof value;
        \\let ignored = void value;
        \\let removed = delete object.key;
        \\let pending = await promise;
        \\let chained = !-value;
        \\let member_kind = typeof object.key;
        \\let called = await fn();
        \\let product = -value * value;
        \\let asserted = value!;
    );

    var operators = [_]bool{false} ** 8;
    var unary_count: usize = 0;
    var saw_chained = false;
    var saw_member_operand = false;
    var saw_call_operand = false;
    var saw_nonnull = false;
    var saw_unary_product = false;

    for (parsed.ast.nodes) |node| switch (node.data) {
        .UnaryExpression => |unary| {
            unary_count += 1;
            switch (unary.operator) {
                .Exclamation => operators[0] = true,
                .Tilde => operators[1] = true,
                .Minus => operators[2] = true,
                .Plus => operators[3] = true,
                .Keyword_typeof => operators[4] = true,
                .Keyword_void => operators[5] = true,
                .Keyword_delete => operators[6] = true,
                .Keyword_await => operators[7] = true,
                else => try std.testing.fail("unexpected unary operator"),
            }
            const argument_tag = std.meta.activeTag(parsed.ast.node(unary.argument).data);
            if (unary.operator == .Exclamation and argument_tag == .UnaryExpression) saw_chained = true;
            if (unary.operator == .Keyword_typeof and argument_tag == .MemberExpression) saw_member_operand = true;
            if (unary.operator == .Keyword_await and argument_tag == .CallExpression) saw_call_operand = true;
        },
        .NonNullExpression => saw_nonnull = true,
        .BinaryExpression => |binary| {
            if (binary.operator == .Asterisk and std.meta.activeTag(parsed.ast.node(binary.left).data) == .UnaryExpression) saw_unary_product = true;
        },
        else => {},
    };

    for (operators) |seen| try std.testing.expect(seen);
    try std.testing.expect(unary_count >= 11);
    try std.testing.expect(saw_chained);
    try std.testing.expect(saw_member_operand);
    try std.testing.expect(saw_call_operand);
    try std.testing.expect(saw_unary_product);
    try std.testing.expect(saw_nonnull);

    const bound = try binder.bind(allocator, parsed.ast);
    const resolved = try resolver.resolve(allocator, parsed.ast, bound);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try std.testing.expect(countReferences(resolved, "value", .read) >= 10);
    try std.testing.expectEqual(@as(usize, 2), countReferences(resolved, "object", .read));
    try std.testing.expectEqual(@as(usize, 1), countReferences(resolved, "promise", .read));
    try std.testing.expectEqual(@as(usize, 1), countReferences(resolved, "fn", .read));
}

test "frontend suite: regexp context preserves division and recognizes expression starts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scanned = try scanOk(allocator, "a / b; x = /foo/;", false);
    try expectTokenKinds(scanned.tokens, &.{
        .Identifier, .Slash, .Identifier,    .Semicolon,
        .Identifier, .Equal, .RegExpLiteral, .Semicolon,
        .EOF,
    });

    const parsed = try parseOk(allocator, "let quotient = a / b; x = /foo/;");
    const binary_id = try findFirst(parsed.ast, .BinaryExpression);
    try std.testing.expect(binary_id != ast_mod.invalid_node);
    try std.testing.expectEqual(TokenType.Slash, parsed.ast.node(binary_id).data.BinaryExpression.operator);

    const regexp_id = try findFirst(parsed.ast, .RegExpLiteral);
    try std.testing.expect(regexp_id != ast_mod.invalid_node);
    const regexp = parsed.ast.node(regexp_id).data.RegExpLiteral;
    try std.testing.expectEqualStrings("foo", regexp.pattern);
    try std.testing.expectEqual(@as(u32, 26), parsed.ast.node(regexp_id).span.start);
    try std.testing.expectEqual(@as(u32, 31), parsed.ast.node(regexp_id).span.end);
}

test "frontend suite: regexp AST preserves patterns flags escapes and character classes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const flagged = try parseOk(allocator, "let r = /ab+c/gi;");
    const flagged_id = try findFirst(flagged.ast, .RegExpLiteral);
    const flagged_value = flagged.ast.node(flagged_id).data.RegExpLiteral;
    try std.testing.expectEqualStrings("ab+c", flagged_value.pattern);
    try std.testing.expect(flagged_value.flags.global);
    try std.testing.expect(flagged_value.flags.ignore_case);

    const escaped = try parseOk(allocator,
        \\let r = /a\/b/;
    );
    const escaped_id = try findFirst(escaped.ast, .RegExpLiteral);
    try std.testing.expectEqualStrings("a\\/b", escaped.ast.node(escaped_id).data.RegExpLiteral.pattern);

    const character_class = try parseOk(allocator, "let r = /[/]/;");
    const class_id = try findFirst(character_class.ast, .RegExpLiteral);
    try std.testing.expectEqualStrings("[/]", character_class.ast.node(class_id).data.RegExpLiteral.pattern);

    const returned = try parseOk(allocator, "function f() { return /foo/g; }");
    const returned_id = try findFirst(returned.ast, .RegExpLiteral);
    try std.testing.expectEqualStrings("foo", returned.ast.node(returned_id).data.RegExpLiteral.pattern);
    try std.testing.expect(returned.ast.node(returned_id).data.RegExpLiteral.flags.global);
}

test "frontend suite: scanner reports invalid and unterminated regexp literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const unterminated = try scanner.scanAll(allocator, "let r = /foo", false);
    try std.testing.expectEqual(@as(usize, 1), unterminated.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unterminated_regexp, unterminated.diagnostics[0].code);

    const unknown_flag = try scanner.scanAll(allocator, "let r = /foo/z;", false);
    try std.testing.expectEqual(@as(usize, 1), unknown_flag.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.invalid_regexp, unknown_flag.diagnostics[0].code);

    const duplicate_flag = try scanner.scanAll(allocator, "let r = /foo/gg;", false);
    try std.testing.expectEqual(@as(usize, 1), duplicate_flag.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.invalid_regexp, duplicate_flag.diagnostics[0].code);
}

test "frontend suite: color_art.ts fixture — 0 diagnostics smoke test" {
    // Fixture exercises: object literal, array literal, template interpolation,
    // type annotations (let i: number), non-null assertion (!.length, !.j),
    // 'as any' cast, ambient console.log. Must parse/analyze with 0 errors.
    const fixture = @embedFile("../../test/frontend/realworld/color_art.ts");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try frontend.analyze(allocator, .{ .path = "color_art.ts", .text = fixture }, .{});

    // Overall combined diagnostics (scanner + parser + binder + resolver) == 0
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    // Resolve phase specifically — catches regressions in the resolver layer.
    try std.testing.expectEqual(@as(usize, 0), result.resolve.diagnostics.len);
    // Fixture must produce a module AST with exports (exercise export default).
    try std.testing.expect(result.bind.module.exports.len > 0);
}

fn symbolByName(bind: binder.BindResult, name: []const u8) ?binder.Symbol {
    for (bind.symbols) |sym| if (std.mem.eql(u8, sym.name, name)) return sym;
    return null;
}
