const std = @import("std");
const Io = std.Io;

// Dev/testing imports — direct file paths so `zig build run` works without
// needing an installed vizg package (the library is only needed for C-ABI consumers).
const front = @import("frontend/frontend.zig");
const ast_mod = @import("frontend/ast.zig");
const binder = @import("frontend/binder.zig");
const cfg = @import("frontend/cfg.zig");
const diagnostics = @import("diagnostics/root.zig");
const modules = @import("modules/root.zig");
const resolver_mod = @import("frontend/resolver.zig");
const tokens_mod = @import("frontend/tokens.zig");
const semantics = @import("semantics/root.zig");
const types_pkg = @import("types/root.zig");

// Backward-compat aliases matching main.zig's existing names.
const frontend = front;
const resolver = resolver_mod;
const tokens = tokens_mod;
const Registry = modules.Registry;

const max_source_bytes = 64 * 1024 * 1024;

const Command = enum {
    check,
    tokens,
    ast,
    symbols,
    references,
    refs,
    cfg,
    modules,
    types,
    help,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const exe_name = if (args.len > 0) args[0] else "vizg";
    if (args.len < 2) {
        try printHelp(stderr, exe_name);
        try stderr.flush();
        std.process.exit(1);
    }

    const command = parseCommand(args[1]) orelse {
        try stderr.print("error: unknown command '{s}'\n\n", .{args[1]});
        try printHelp(stderr, exe_name);
        try stderr.flush();
        std.process.exit(1);
    };

    if (command == .help) {
        if (args.len != 2) {
            try stderr.print("error: help does not take a file argument\n\n", .{});
            try printHelp(stderr, exe_name);
            try stderr.flush();
            std.process.exit(1);
        }
        try printHelp(stdout, exe_name);
        return;
    }

    if (args.len < 3) {
        try stderr.print("error: expected file path for '{s}'\n\n", .{args[1]});
        try printHelp(stderr, exe_name);
        try stderr.flush();
        std.process.exit(1);
    }

    const path = args[2];

    // Parse --add-external "name=path" flags. These populate the externals
    // registry used by the module graph to validate non-relative imports.
    var externals: ?*Registry = null;
    defer if (externals) |reg| reg.deinit(arena);
    externals = parseExternalsArgs(args, arena, io) catch |err| {
        try stderr.print("external configuration error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    if (command == .modules) {
        const graph = modules.build(arena, io, path, .{
            .collect_comments = false,
            .recover_errors = true,
            .max_source_bytes = max_source_bytes,
            // Defaults from loader.BuildOptions for H4 depth limits — sufficient for real code.
            .max_parse_depth = 1024,
            .max_module_graph_depth = 10_000,
        }, externals) catch |err| {
            try stderr.print("{s}: module graph error: {s}\n", .{ path, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        try printModules(stdout, graph);
        if (hasErrors(graph.diagnostics)) {
            try stdout.flush();
            std.process.exit(1);
        }
        return;
    }

    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_source_bytes)) catch |err| {
        try stderr.print("{s}: error reading file: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    const result = frontend.analyze(arena, .{
        .path = path,
        .text = text,
        .kind = .module,
    }, .{
        .collect_comments = false,
        .recover_errors = true,
    }) catch |err| {
        try stderr.print("{s}: frontend error: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        std.process.exit(1);
    };

    switch (command) {
        .check => blk: {
            // Run the type checker and merge its diagnostics with collector ones.
            const info = semantics.analyzeFrontendResult(arena, result) catch |err| {
                try stderr.print("{s}: type error: {s}\n", .{ result.source.path, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
            const all_diags = info.diagnostics;
            // Inline printCheck using merged diagnostics so we can keep the
            // existing printCheck signature that takes a FrontendResult.
            const counts = countDiagnostics(all_diags);
            try stdout.print("checked: {s}\n", .{result.source.path});
            try stdout.print("source kind: {s}\n", .{@tagName(result.source.kind)});
            try stdout.print("diagnostics: {} errors, {} warnings\n", .{ counts.errors, counts.warnings });
            if (all_diags.len > 0) {
                try printDiagnostics(stdout, result.source.path, all_diags);
            }
            if (hasErrors(all_diags)) break :blk;
        },
        .tokens => try printTokens(stdout, result.tokens),
        .ast => try printAst(stdout, result.ast),
        .symbols => try printSymbols(stdout, result.bind, result.diagnostics),
        .references, .refs => try printReferences(stdout, result.source.path, result.bind, result.resolve, result.diagnostics),
        .cfg => try printCfg(stdout, result.ast, result.cfgs),
        .types => {
            const info = semantics.analyzeFrontendResult(arena, result) catch |err| {
                try stderr.print("{s}: types error: {s}\n", .{ path, @errorName(err) });
                std.process.exit(1);
            };
            const bind_sym = result.bind.symbols;
            try printTypes(stdout, path, info, bind_sym, result.ast);

            // Exit non-zero when semantic/type diagnostics contain errors.
            if (hasErrors(info.diagnostics)) {
                try stdout.flush();
                std.process.exit(1);
            }
        },
        .modules => unreachable, // handled earlier with early return
        .help => unreachable,
    }
}

fn parseCommand(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "check")) return .check;
    if (std.mem.eql(u8, text, "tokens")) return .tokens;
    if (std.mem.eql(u8, text, "ast")) return .ast;
    if (std.mem.eql(u8, text, "symbols")) return .symbols;
    if (std.mem.eql(u8, text, "references")) return .references;
    if (std.mem.eql(u8, text, "refs")) return .refs;
    if (std.mem.eql(u8, text, "cfg")) return .cfg;
    if (std.mem.eql(u8, text, "modules")) return .modules;
    if (std.mem.eql(u8, text, "types")) return .types;
    if (std.mem.eql(u8, text, "help")) return .help;
    if (std.mem.eql(u8, text, "--help")) return .help;
    if (std.mem.eql(u8, text, "-h")) return .help;
    return null;
}

fn printHelp(writer: *Io.Writer, exe_name: []const u8) !void {
    try writer.print(
        \\usage: {s} <command> [file]
        \\
        \\commands:
        \\  check <file>    run frontend pipeline and print diagnostics
        \\  tokens <file>   print scanner tokens
        \\  ast <file>      print readable AST tree
        \\  symbols <file>  print scopes, symbols, imports, exports, diagnostics
        \\  references <file> print resolved identifier references
        \\  refs <file>       alias for references
        \\  cfg <file>      print function control-flow graphs
        \\  modules <file>  build and print the module graph
        \\  types <file>    print declared and inferred type information
        \\  help            print this help
        \\
    , .{exe_name});
}

fn printCheck(writer: *Io.Writer, result: frontend.FrontendResult) !void {
    const counts = countDiagnostics(result.diagnostics);
    try writer.print("checked: {s}\n", .{result.source.path});
    try writer.print("source kind: {s}\n", .{@tagName(result.source.kind)});
    try writer.print("diagnostics: {} errors, {} warnings\n", .{ counts.errors, counts.warnings });
    if (result.diagnostics.len > 0) {
        try printDiagnostics(writer, result.source.path, result.diagnostics);
    }
}

fn printTokens(writer: *Io.Writer, token_list: []const tokens.Token) !void {
    for (token_list) |token| {
        try writer.print("{}:{}  ", .{ token.span.line, token.span.column });
        try printTokenKind(writer, token);
        try writer.print("  \"", .{});
        try printEscaped(writer, token.lexeme);
        try writer.print("\"  {}..{}\n", .{ token.span.start, token.span.end });
    }
}

fn printTokenKind(writer: *Io.Writer, token: tokens.Token) !void {
    if (token.contextualKeyword()) |keyword| {
        const prefix = "Contextual_";
        const name = @tagName(keyword);
        try writer.print("Identifier(contextual={s})", .{name[prefix.len..]});
        return;
    }

    try writer.print("{s}", .{@tagName(token.kind)});
}

fn printAst(writer: *Io.Writer, tree: ast_mod.Ast) !void {
    try printAstNode(writer, tree, tree.root, 0);
}

fn printTypeNode(writer: *Io.Writer, tree: ast_mod.Ast, type_id: ast_mod.TypeNodeId, depth: usize) !void {
    const node = tree.typeNode(type_id);
    try printIndent(writer, depth);
    try writer.print("Type{s} #{} {}..{}", .{ @tagName(node.data), type_id, node.span.start, node.span.end });
    switch (node.data) {
        .Named => |named| {
            try writer.print(" name=\"{s}\"\n", .{named.name});
            for (named.type_arguments) |child| try printTypeNode(writer, tree, child, depth + 1);
        },
        .Array, .Readonly, .Parenthesized => |child| {
            try writer.writeByte('\n');
            try printTypeNode(writer, tree, child, depth + 1);
        },
        .Union, .Intersection, .Tuple => |children| {
            try writer.writeByte('\n');
            for (children) |child| try printTypeNode(writer, tree, child, depth + 1);
        },
        .Object => |members| {
            try writer.writeByte('\n');
            for (members) |member| {
                try printIndent(writer, depth + 1);
                try writer.print("TypeMember name=\"{s}\" optional={} {}..{}\n", .{ member.name, member.optional, member.span.start, member.span.end });
                try printTypeNode(writer, tree, member.type_node, depth + 2);
            }
        },
        .Function => |function| {
            try writer.writeByte('\n');
            for (function.parameters) |parameter| {
                try printIndent(writer, depth + 1);
                try writer.print("TypeParameter name=\"{s}\" optional={} {}..{}\n", .{ parameter.name, parameter.optional, parameter.span.start, parameter.span.end });
                try printTypeNode(writer, tree, parameter.type_node, depth + 2);
            }
            try printTypeNode(writer, tree, function.return_type, depth + 1);
        },
    }
}

fn printGenericTypeParameters(writer: *Io.Writer, tree: ast_mod.Ast, parameters: []const ast_mod.GenericTypeParameter, depth: usize) !void {
    for (parameters) |parameter| {
        try printIndent(writer, depth);
        try writer.print("GenericTypeParameter name=\"{s}\" {}..{}\n", .{ parameter.name, parameter.span.start, parameter.span.end });
        if (parameter.constraint) |constraint| try printTypeNode(writer, tree, constraint.root, depth + 1);
        if (parameter.default_type) |default_type| try printTypeNode(writer, tree, default_type.root, depth + 1);
    }
}

fn printAstNode(writer: *Io.Writer, tree: ast_mod.Ast, node_id: ast_mod.NodeId, depth: usize) !void {
    if (node_id == ast_mod.invalid_node) return;

    const node = tree.node(node_id);
    try printIndent(writer, depth);

    switch (node.data) {
        .Program => |program| {
            try writer.print("Program #{} {}..{}\n", .{ node_id, node.span.start, node.span.end });
            for (program.statements) |statement| try printAstNode(writer, tree, statement, depth + 1);
        },
        .BlockStatement => |block| {
            try writer.print("BlockStatement #{} {}..{}\n", .{ node_id, node.span.start, node.span.end });
            for (block.statements) |statement| try printAstNode(writer, tree, statement, depth + 1);
        },
        .ExpressionStatement => |statement| {
            try writer.print("ExpressionStatement #{} expression=#{} {}..{}\n", .{ node_id, statement.expression, node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.expression, depth + 1);
        },
        .Identifier => |identifier| try writer.print("Identifier #{} name=\"{s}\" {}..{}\n", .{ node_id, identifier.name, node.span.start, node.span.end }),
        .Literal => |literal| {
            try writer.print("Literal #{} value=\"", .{node_id});
            try printEscaped(writer, literal.value);
            try writer.print("\" {}..{}\n", .{ node.span.start, node.span.end });
        },
        .RegExpLiteral => |regexp| {
            try writer.print("RegExpLiteral #{} pattern=\"", .{node_id});
            try printEscaped(writer, regexp.pattern);
            try writer.writeAll("\" flags=\"");
            if (regexp.flags.has_indices) try writer.writeByte('d');
            if (regexp.flags.global) try writer.writeByte('g');
            if (regexp.flags.ignore_case) try writer.writeByte('i');
            if (regexp.flags.multiline) try writer.writeByte('m');
            if (regexp.flags.dot_all) try writer.writeByte('s');
            if (regexp.flags.unicode) try writer.writeByte('u');
            if (regexp.flags.unicode_sets) try writer.writeByte('v');
            if (regexp.flags.sticky) try writer.writeByte('y');
            try writer.print("\" {}..{}\n", .{ node.span.start, node.span.end });
        },
        .TemplateExpression => |template| {
            try writer.print("TemplateExpression #{} parts={} {}..{}\n", .{ node_id, template.parts.len, node.span.start, node.span.end });
            for (template.parts) |part| {
                try printIndent(writer, depth + 1);
                try writer.writeAll("TemplatePart raw=\"");
                try printEscaped(writer, part.raw);
                try writer.print("\" cooked_available={} {}..{}\n", .{ part.cooked != null, part.span.start, part.span.end });
                if (part.expression) |expression| try printAstNode(writer, tree, expression, depth + 1);
            }
        },
        .TaggedTemplateExpression => |tagged| {
            try writer.print("TaggedTemplateExpression #{} tag=#{} template=#{} {}..{}\n", .{ node_id, tagged.tag, tagged.template, node.span.start, node.span.end });
            try printAstNode(writer, tree, tagged.tag, depth + 1);
            try printAstNode(writer, tree, tagged.template, depth + 1);
        },
        .ImportExpression => |import_expr| {
            try writer.print("ImportExpression #{} source=#{} options={?} {}..{}\n", .{ node_id, import_expr.source, import_expr.options, node.span.start, node.span.end });
            try printAstNode(writer, tree, import_expr.source, depth + 1);
            if (import_expr.options) |options| try printAstNode(writer, tree, options, depth + 1);
        },
        .MetaProperty => |meta| try writer.print("MetaProperty #{} kind={s} {}..{}\n", .{ node_id, @tagName(meta.kind), node.span.start, node.span.end }),
        .VariableDeclaration => |decl| {
            try writer.print("VariableDeclaration #{} kind={s} {}..{}\n", .{ node_id, @tagName(decl.kind), node.span.start, node.span.end });
            for (decl.declarations) |declarator| try printAstNode(writer, tree, declarator, depth + 1);
        },
        .TypeAliasDeclaration => |decl| {
            try writer.print("TypeAliasDeclaration #{} name=\"{s}\" type_parameters={} type=#{} {}..{}\n", .{ node_id, decl.name, decl.type_parameters.len, decl.type_annotation.root, node.span.start, node.span.end });
            try printGenericTypeParameters(writer, tree, decl.type_parameters, depth + 1);
            try printTypeNode(writer, tree, decl.type_annotation.root, depth + 1);
        },
        .InterfaceDeclaration => |decl| {
            try writer.print("InterfaceDeclaration #{} name=\"{s}\" type_parameters={} extends={} body=#{} {}..{}\n", .{ node_id, decl.name, decl.type_parameters.len, decl.extends.len, decl.body, node.span.start, node.span.end });
            try printGenericTypeParameters(writer, tree, decl.type_parameters, depth + 1);
            for (decl.extends) |heritage| try printTypeNode(writer, tree, heritage, depth + 1);
            try printTypeNode(writer, tree, decl.body, depth + 1);
        },
        .EnumDeclaration => |decl| {
            try writer.print("EnumDeclaration #{} name=\"{s}\" members={} {}..{}\n", .{ node_id, decl.name, decl.members.len, node.span.start, node.span.end });
            for (decl.members) |member| try printAstNode(writer, tree, member, depth + 1);
        },
        .EnumMember => |member| {
            try writer.print("EnumMember #{} name=\"{s}\" {}..{}\n", .{ node_id, member.name, node.span.start, node.span.end });
            if (member.computed_name) |computed| try printAstNode(writer, tree, computed, depth + 1);
            if (member.initializer) |initializer| try printAstNode(writer, tree, initializer, depth + 1);
        },
        .VariableDeclarator => |decl| {
            try writer.print("VariableDeclarator #{} name=\"{s}\"", .{ node_id, decl.name });
            if (decl.type_annotation) |annotation| try writer.print(" type=#{}", .{annotation.root});
            if (decl.init) |init| try writer.print(" init=#{}", .{init});
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            if (decl.type_annotation) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            if (decl.init) |init| try printAstNode(writer, tree, init, depth + 1);
        },
        .FunctionDeclaration => |decl| {
            try writer.print("FunctionDeclaration #{} name=\"{s}\" exported={} async={} generator={} body=#{} {}..{}\n", .{ node_id, decl.name, decl.exported, decl.flags.is_async, decl.flags.is_generator, decl.body, node.span.start, node.span.end });
            try printGenericTypeParameters(writer, tree, decl.type_parameters, depth + 1);
            for (decl.params) |param| try printAstNode(writer, tree, param, depth + 1);
            if (decl.return_type) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            try printAstNode(writer, tree, decl.body, depth + 1);
        },
        .FunctionExpression => |expr| {
            try writer.print("FunctionExpression #{}", .{node_id});
            if (expr.name) |name| try writer.print(" name=\"{s}\"", .{name});
            try writer.print(" async={} generator={} body=#{} {}..{}\n", .{ expr.flags.is_async, expr.flags.is_generator, expr.body, node.span.start, node.span.end });
            for (expr.params) |param| try printAstNode(writer, tree, param, depth + 1);
            if (expr.return_type) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            try printAstNode(writer, tree, expr.body, depth + 1);
        },
        .YieldExpression => |yield_expr| {
            try writer.print("YieldExpression #{} delegate={}", .{ node_id, yield_expr.delegate });
            if (yield_expr.argument) |argument| try writer.print(" argument=#{}", .{argument});
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            if (yield_expr.argument) |argument| try printAstNode(writer, tree, argument, depth + 1);
        },
        .ClassDeclaration => |decl| {
            try writer.print("ClassDeclaration #{} name=\"{s}\" type_parameters={} members={} {}..{}\n", .{ node_id, decl.name, decl.type_parameters.len, decl.members.len, node.span.start, node.span.end });
            try printGenericTypeParameters(writer, tree, decl.type_parameters, depth + 1);
            if (decl.super_class) |super_class| try printAstNode(writer, tree, super_class, depth + 1);
            for (decl.members) |member| try printAstNode(writer, tree, member, depth + 1);
        },
        .ClassExpression => |expr| {
            try writer.print("ClassExpression #{}", .{node_id});
            if (expr.name) |name| try writer.print(" name=\"{s}\"", .{name});
            try writer.print(" members={} {}..{}\n", .{ expr.members.len, node.span.start, node.span.end });
            if (expr.super_class) |super_class| try printAstNode(writer, tree, super_class, depth + 1);
            for (expr.members) |member| try printAstNode(writer, tree, member, depth + 1);
        },
        .ClassField => |field| {
            try writer.print("ClassField #{} name=\"{s}\" static={} access={s} {}..{}\n", .{ node_id, field.name, field.is_static, @tagName(field.access), node.span.start, node.span.end });
            if (field.type_annotation) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            if (field.initializer) |initializer| try printAstNode(writer, tree, initializer, depth + 1);
        },
        .ClassMethod => |method| {
            try writer.print("ClassMethod #{} name=\"{s}\" kind={s} static={} async={} generator={} access={s} {}..{}\n", .{ node_id, method.name, @tagName(method.kind), method.is_static, method.flags.is_async, method.flags.is_generator, @tagName(method.access), node.span.start, node.span.end });
            for (method.params) |param| try printAstNode(writer, tree, param, depth + 1);
            if (method.return_type) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            try printAstNode(writer, tree, method.body, depth + 1);
        },
        .ArrowFunctionExpression => |arrow| {
            try writer.print("ArrowFunctionExpression #{} async={} expression_body={} body=#{} {}..{}\n", .{ node_id, arrow.flags.is_async, arrow.expression_body, arrow.body, node.span.start, node.span.end });
            for (arrow.params) |param| try printAstNode(writer, tree, param, depth + 1);
            if (arrow.return_type) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            try printAstNode(writer, tree, arrow.body, depth + 1);
        },
        .Parameter => |param| {
            try writer.print("Parameter #{} name=\"{s}\" rest={} optional={}", .{ node_id, param.name, param.rest, param.optional });
            if (param.type_annotation) |annotation| try writer.print(" type=#{}", .{annotation.root});
            if (param.initializer) |initializer| try writer.print(" initializer=#{}", .{initializer});
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            if (param.type_annotation) |annotation| try printTypeNode(writer, tree, annotation.root, depth + 1);
            if (param.initializer) |initializer| try printAstNode(writer, tree, initializer, depth + 1);
        },
        .SpreadElement => |spread| {
            try writer.print("SpreadElement #{} argument=#{} {}..{}\n", .{ node_id, spread.argument, node.span.start, node.span.end });
            try printAstNode(writer, tree, spread.argument, depth + 1);
        },
        .ReturnStatement => |statement| {
            try writer.print("ReturnStatement #{}", .{node_id});
            if (statement.argument) |arg| try writer.print(" argument=#{}", .{arg});
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            if (statement.argument) |arg| try printAstNode(writer, tree, arg, depth + 1);
        },
        .ThrowStatement => |statement| {
            try writer.print("ThrowStatement #{} argument=#{} {}..{}\n", .{ node_id, statement.argument, node.span.start, node.span.end });
            if (statement.argument != ast_mod.invalid_node) try printAstNode(writer, tree, statement.argument, depth + 1);
        },
        .DebuggerStatement => try writer.print("DebuggerStatement #{} {}..{}\n", .{ node_id, node.span.start, node.span.end }),
        .TryStatement => |statement| {
            try writer.print("TryStatement #{} block=#{}", .{ node_id, statement.block });
            if (statement.handler) |handler| try writer.print(" handler=#{}", .{handler}) else try writer.writeAll(" handler=null");
            if (statement.finalizer) |finalizer| try writer.print(" finalizer=#{}", .{finalizer}) else try writer.writeAll(" finalizer=null");
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.block, depth + 1);
            if (statement.handler) |handler| try printAstNode(writer, tree, handler, depth + 1);
            if (statement.finalizer) |finalizer| try printAstNode(writer, tree, finalizer, depth + 1);
        },
        .CatchClause => |clause| {
            try writer.print("CatchClause #{}", .{node_id});
            if (clause.parameter) |parameter| try writer.print(" parameter=#{}", .{parameter}) else try writer.writeAll(" parameter=null");
            try writer.print(" body=#{} {}..{}\n", .{ clause.body, node.span.start, node.span.end });
            if (clause.parameter) |parameter| try printAstNode(writer, tree, parameter, depth + 1);
            try printAstNode(writer, tree, clause.body, depth + 1);
        },
        .FinallyClause => |clause| {
            try writer.print("FinallyClause #{} body=#{} {}..{}\n", .{ node_id, clause.body, node.span.start, node.span.end });
            try printAstNode(writer, tree, clause.body, depth + 1);
        },
        .BreakStatement => |statement| try writer.print("BreakStatement #{} label={s} {}..{}\n", .{ node_id, statement.label orelse "-", node.span.start, node.span.end }),
        .ContinueStatement => |statement| try writer.print("ContinueStatement #{} label={s} {}..{}\n", .{ node_id, statement.label orelse "-", node.span.start, node.span.end }),
        .LabeledStatement => |statement| {
            try writer.print("LabeledStatement #{} label={s} {}..{}\n", .{ node_id, statement.label, node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.body, depth + 1);
        },
        .ThisExpression => try writer.print("ThisExpression #{} {}..{}\n", .{ node_id, node.span.start, node.span.end }),
        .SuperExpression => try writer.print("SuperExpression #{} {}..{}\n", .{ node_id, node.span.start, node.span.end }),
        .NewExpression => |new_expr| {
            try writer.print("NewExpression #{} callee=#{} {}..{}\n", .{ node_id, new_expr.callee, node.span.start, node.span.end });
            try printAstNode(writer, tree, new_expr.callee, depth + 1);
            for (new_expr.arguments) |arg| try printAstNode(writer, tree, arg, depth + 1);
        },
        .CallExpression => |call| {
            try writer.print("CallExpression #{} callee=#{} optional={} {}..{}\n", .{ node_id, call.callee, call.optional, node.span.start, node.span.end });
            try printAstNode(writer, tree, call.callee, depth + 1);
            for (call.arguments) |arg| try printAstNode(writer, tree, arg, depth + 1);
        },
        .ElementAccessExpression => |elem_access| {
            try writer.print("ElementAccessExpression #{} object=#{} index=#{} optional={} {}..{}\n", .{ node_id, elem_access.object, elem_access.index, elem_access.optional, node.span.start, node.span.end });
            try printAstNode(writer, tree, elem_access.object, depth + 1);
            try printAstNode(writer, tree, elem_access.index, depth + 1);
        },
        .NonNullExpression => |nonnull| {
            try writer.print("NonNullExpression #{} expression=#{} {}..{}\n", .{ node_id, nonnull.expression, node.span.start, node.span.end });
            try printAstNode(writer, tree, nonnull.expression, depth + 1);
        },
        .UnaryExpression => |unary| {
            try writer.print("UnaryExpression #{} operator={s} argument=#{} {}..{}\n", .{ node_id, @tagName(unary.operator), unary.argument, node.span.start, node.span.end });
            try printAstNode(writer, tree, unary.argument, depth + 1);
        },
        .AsExpression => |as_expr| {
            try writer.print("AsExpression #{} expr=#{} type=#{} {}..{}\n", .{ node_id, as_expr.expression, as_expr.type_annotation.root, node.span.start, node.span.end });
            try printTypeNode(writer, tree, as_expr.type_annotation.root, depth + 1);
        },
        .SatisfiesExpression => |satisfies_expr| {
            try writer.print("SatisfiesExpression #{} expr=#{} type=#{} {}..{}\n", .{ node_id, satisfies_expr.expression, satisfies_expr.type_annotation.root, node.span.start, node.span.end });
            try printTypeNode(writer, tree, satisfies_expr.type_annotation.root, depth + 1);
        },
        .MemberExpression => |member| {
            try writer.print("MemberExpression #{} object=#{} property=\"{s}\" optional={} {}..{}\n", .{ node_id, member.object, member.property, member.optional, node.span.start, node.span.end });
            try printAstNode(writer, tree, member.object, depth + 1);
        },
        .BinaryExpression => |expr| {
            try writer.print("BinaryExpression #{} operator={s} left=#{} right=#{} {}..{}\n", .{ node_id, @tagName(expr.operator), expr.left, expr.right, node.span.start, node.span.end });
            try printAstNode(writer, tree, expr.left, depth + 1);
            try printAstNode(writer, tree, expr.right, depth + 1);
        },
        .SequenceExpression => |expr| {
            try writer.print("SequenceExpression #{} expressions={} {}..{}\n", .{ node_id, expr.expressions.len, node.span.start, node.span.end });
            for (expr.expressions) |expression| try printAstNode(writer, tree, expression, depth + 1);
        },
        .ConditionalExpression => |expr| {
            try writer.print("ConditionalExpression #{} condition=#{} consequent=#{} alternate=#{} {}..{}\n", .{ node_id, expr.condition, expr.consequent, expr.alternate, node.span.start, node.span.end });
            try printAstNode(writer, tree, expr.condition, depth + 1);
            try printAstNode(writer, tree, expr.consequent, depth + 1);
            try printAstNode(writer, tree, expr.alternate, depth + 1);
        },
        .UpdateExpression => |expr| {
            const prefix_tag: []const u8 = if (expr.prefix) "Prefix" else "Postfix";
            try writer.print("UpdateExpression #{} {s} operator={s} argument=#{} {}..{}\n", .{ node_id, prefix_tag, @tagName(expr.operator), expr.argument, node.span.start, node.span.end });
            try printAstNode(writer, tree, expr.argument, depth + 1);
        },
        .AssignmentExpression => |expr| {
            try writer.print("AssignmentExpression #{} operator={s} left=#{} right=#{} {}..{}\n", .{ node_id, @tagName(expr.operator), expr.left, expr.right, node.span.start, node.span.end });
            try printAstNode(writer, tree, expr.left, depth + 1);
            try printAstNode(writer, tree, expr.right, depth + 1);
        },
        .IfStatement => |statement| {
            try writer.print("IfStatement #{} condition=#{} consequent=#{}", .{ node_id, statement.condition, statement.consequent });
            if (statement.alternate) |alternate| try writer.print(" alternate=#{}", .{alternate});
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.condition, depth + 1);
            try printAstNode(writer, tree, statement.consequent, depth + 1);
            if (statement.alternate) |alternate| try printAstNode(writer, tree, alternate, depth + 1);
        },
        .WhileStatement => |statement| {
            try writer.print("WhileStatement #{} condition=#{} body=#{} {}..{}\n", .{ node_id, statement.condition, statement.body, node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.condition, depth + 1);
            try printAstNode(writer, tree, statement.body, depth + 1);
        },
        .DoWhileStatement => |statement| {
            try writer.print("DoWhileStatement #{} body=#{} condition=#{} {}..{}\n", .{ node_id, statement.body, statement.condition, node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.body, depth + 1);
            if (statement.condition != ast_mod.invalid_node) try printAstNode(writer, tree, statement.condition, depth + 1);
        },
        .ForStatement => |statement| {
            try writer.print("ForStatement #{} kind={s} await={}", .{ node_id, @tagName(statement.kind), statement.await });
            if (statement.init) |init| try writer.print(" init=#{}", .{init}) else try writer.print(" init=null", .{});
            if (statement.condition) |condition| try writer.print(" test=#{}", .{condition}) else try writer.print(" test=null", .{});
            if (statement.update) |update| try writer.print(" update=#{}", .{update}) else try writer.print(" update=null", .{});
            if (statement.right) |right| try writer.print(" right=#{}", .{right}) else try writer.print(" right=null", .{});
            try writer.print(" body=#{} {}..{}\n", .{ statement.body, node.span.start, node.span.end });
            if (statement.init) |init| try printAstNode(writer, tree, init, depth + 1);
            if (statement.condition) |condition| try printAstNode(writer, tree, condition, depth + 1);
            if (statement.update) |update| try printAstNode(writer, tree, update, depth + 1);
            if (statement.right) |right| try printAstNode(writer, tree, right, depth + 1);
            try printAstNode(writer, tree, statement.body, depth + 1);
        },
        .SwitchStatement => |statement| {
            try writer.print("SwitchStatement #{} discriminant=#{} cases={} {}..{}\n", .{ node_id, statement.discriminant, statement.cases.len, node.span.start, node.span.end });
            try printAstNode(writer, tree, statement.discriminant, depth + 1);
            for (statement.cases) |case| try printAstNode(writer, tree, case, depth + 1);
        },
        .SwitchCase => |switch_case| {
            try writer.print("SwitchCase #{}", .{node_id});
            if (switch_case.condition) |condition| try writer.print(" test=#{}", .{condition}) else try writer.print(" default", .{});
            try writer.print(" consequent={} {}..{}\n", .{ switch_case.consequent.len, node.span.start, node.span.end });
            if (switch_case.condition) |condition| try printAstNode(writer, tree, condition, depth + 1);
            for (switch_case.consequent) |statement| try printAstNode(writer, tree, statement, depth + 1);
        },
        .ImportDeclaration => |decl| {
            try writer.print("ImportDeclaration #{} source=\"{s}\" kind={s} type_only={} names=[", .{ node_id, decl.source, @tagName(decl.kind), decl.type_only });
            try printStringList(writer, decl.names);
            try writer.print("]", .{});
            if (decl.specifiers.len > 0) {
                try writer.print(" specifiers=[", .{});
                try printImportSpecifiers(writer, decl.specifiers);
                try writer.print("]", .{});
            }
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
        },
        .ExportDeclaration => |decl| {
            try writer.print("ExportDeclaration #{} kind={s} type_only={}", .{ node_id, @tagName(decl.kind), decl.type_only });
            if (decl.declaration != ast_mod.invalid_node) try writer.print(" declaration=#{}", .{decl.declaration});
            if (decl.expression != ast_mod.invalid_node) try writer.print(" expression=#{}", .{decl.expression});
            if (decl.default_name) |name| try writer.print(" default=\"{s}\"", .{name});
            if (decl.source.len > 0) try writer.print(" source=\"{s}\"", .{decl.source});
            if (decl.specifiers.len > 0) {
                try writer.print(" specifiers=[", .{});
                try printExportSpecifiers(writer, decl.specifiers);
                try writer.print("]", .{});
            }
            try writer.print(" {}..{}\n", .{ node.span.start, node.span.end });
            if (decl.declaration != ast_mod.invalid_node) try printAstNode(writer, tree, decl.declaration, depth + 1);
            if (decl.expression != ast_mod.invalid_node) try printAstNode(writer, tree, decl.expression, depth + 1);
        },
        .ObjectExpression => |obj_expr| {
            try writer.print("ObjectExpression #{} props=[", .{node_id});
            for (obj_expr.properties, 0..) |prop, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("{s}:", .{@tagName(prop.kind)});
                if (prop.computed_key) |key| try writer.print("#{}", .{key}) else if (prop.kind == .spread) try writer.writeAll("...") else try writer.print("{s}", .{prop.key});
            }
            try writer.print("] {}..{}\n", .{ node.span.start, node.span.end });
            for (obj_expr.properties) |prop| {
                if (prop.computed_key) |key| try printAstNode(writer, tree, key, depth + 1);
                try printAstNode(writer, tree, prop.value, depth + 1);
            }
        },
        .ArrayExpression => |arr_expr| {
            try writer.print("ArrayExpression #{} elements=[", .{node_id});
            for (arr_expr.elements, 0..) |maybe_elem, i| {
                if (i > 0) try writer.print(", ", .{});
                if (maybe_elem) |elem| try writer.print("#{}", .{elem}) else try writer.writeAll("<hole>");
            }
            try writer.print("] {}..{}\n", .{ node.span.start, node.span.end });
            for (arr_expr.elements) |maybe_elem| if (maybe_elem) |elem| try printAstNode(writer, tree, elem, depth + 1);
        },
    }
}

fn printSymbols(writer: *Io.Writer, bind: binder.BindResult, diags: []const diagnostics.Diagnostic) !void {
    try writer.print("Scopes\n", .{});
    for (bind.scopes) |scope| {
        try writer.print("  scope {} kind={s}", .{ scope.id, @tagName(scope.kind) });
        if (scope.parent) |parent| {
            try writer.print(" parent={}", .{parent});
        } else {
            try writer.print(" parent=null", .{});
        }
        try writer.print(" symbols=[", .{});
        for (scope.symbols, 0..) |symbol_id, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{s}", .{symbolName(bind, symbol_id)});
        }
        try writer.print("]\n", .{});
    }

    try writer.print("\nSymbols\n", .{});
    for (bind.symbols) |symbol| {
        try writer.print(
            "  symbol {} name=\"{s}\" kind={s} namespace={s} scope={} node={} span={}..{}\n",
            .{ symbol.id, symbol.name, @tagName(symbol.kind), @tagName(symbol.namespace), symbol.scope, symbol.declaration, symbol.span.start, symbol.span.end },
        );
    }

    try writer.print("\nImports\n", .{});
    for (bind.module.imports) |import| {
        try writer.print("  {s} from \"{s}\" kind={s} type_only={}\n", .{ import.local_name, import.source, @tagName(import.kind), import.type_only });
    }

    try writer.print("\nExports\n", .{});
    for (bind.module.exports) |export_record| {
        if (std.mem.eql(u8, export_record.name, export_record.local_name)) {
            try writer.print("  {s} node={}\n", .{ export_record.name, export_record.node });
        } else {
            try writer.print("  {s} from {s} node={}\n", .{ export_record.name, export_record.local_name, export_record.node });
        }
    }

    try writer.print("\nDiagnostics\n", .{});
    if (diags.len == 0) {
        try writer.print("  none\n", .{});
    } else {
        try printDiagnostics(writer, "", diags);
    }
}

fn printReferences(writer: *Io.Writer, path: []const u8, bind: binder.BindResult, resolved: resolver.ResolveResult, diags: []const diagnostics.Diagnostic) !void {
    try writer.print("References\n", .{});
    for (resolved.references, 0..) |reference, id| {
        try writer.print(
            "  ref {} node={} name=\"{s}\" kind={s} scope={} symbol=",
            .{ id, reference.node, reference.name, @tagName(reference.kind), reference.scope },
        );
        if (reference.symbol) |symbol_id| {
            try writer.print("{}({s})", .{ symbol_id, symbolName(bind, symbol_id) });
        } else {
            try writer.print("null", .{});
        }
        try writer.print(" span={}..{}\n", .{ reference.span.start, reference.span.end });
    }

    try writer.print("\nDiagnostics\n", .{});
    if (diags.len == 0) {
        try writer.print("  none\n", .{});
    } else {
        try printDiagnostics(writer, path, diags);
    }
}

fn printCfg(writer: *Io.Writer, tree: ast_mod.Ast, cfgs: []const cfg.FunctionCfg) !void {
    for (cfgs, 0..) |function_cfg, index| {
        if (index > 0) try writer.print("\n", .{});
        try writer.print("Function {s} #{}\n", .{ function_cfg.name, function_cfg.function });
        try writer.print("  entry: {}\n", .{function_cfg.graph.entry});
        try writer.print("  exit: {}\n\n", .{function_cfg.graph.exit});

        for (function_cfg.graph.blocks) |block| {
            try writer.print("  block {}\n", .{block.id});
            try writer.print("    kind: {s}\n", .{@tagName(block.kind)});
            try writer.print("    statements: [", .{});
            for (block.statements, 0..) |statement, i| {
                if (i > 0) try writer.print(", ", .{});
                const node = tree.node(statement);
                try writer.print("#{}/{s}", .{ statement, @tagName(node.data) });
            }
            try writer.print("]\n", .{});
            try writer.print("    successors: [", .{});
            try printIdList(writer, block.successors);
            try writer.print("]\n", .{});
            try writer.print("    predecessors: [", .{});
            try printIdList(writer, block.predecessors);
            try writer.print("]\n", .{});
        }
    }
}

fn printModules(writer: *Io.Writer, graph: modules.ModuleGraph) !void {
    try writer.print("Modules\n", .{});
    for (graph.modules) |module| {
        try writer.print(
            "  module {} path=\"{s}\"\n",
            .{ module.id, module.display_path },
        );
    }

    try writer.print("\nImports\n", .{});
    if (graph.imports.len == 0) {
        try writer.print("  none\n", .{});
    } else {
        for (graph.imports) |edge| {
            const from = graph.modules[@intCast(edge.from)];
            try writer.print("  module {} -> ", .{from.id});
            if (edge.to) |to| {
                const target = graph.modules[@intCast(to)];
                try writer.print("module {}", .{target.id});
            } else switch (edge.status) {
                .external => try writer.print("external", .{}),
                .missing => try writer.print("missing", .{}),
                .local => unreachable,
            }
            try writer.print(
                " specifier=\"{s}\" kind={s} type_only={} status={s}\n",
                .{ edge.specifier, @tagName(edge.kind), edge.type_only, @tagName(edge.status) },
            );
        }
    }

    if (graph.linked_imports.len > 0) {
        try writer.print("\nLinks\n", .{});
        for (graph.linked_imports) |link| {
            // Find the matching import edge so we can display specifier and status.
            var edge_for_link: ?modules.ImportEdge = null;
            for (graph.imports) |e| {
                if (@as(u32, e.id) == link.import_edge) {
                    edge_for_link = e;
                    break;
                }
            }

            // Resolve the target symbol name from the target module when available.
            var target_name: ?[]const u8 = null;
            if (link.target_module) |tm_id| {
                const tm = graph.modules[@intCast(tm_id)];
                if (link.target_symbol) |ts_id| {
                    for (tm.result.bind.symbols) |sym| {
                        if (sym.id == ts_id) {
                            target_name = sym.name;
                            break;
                        }
                    }
                }
            }

            if (edge_for_link) |edge| {
                const status_tag = @tagName(edge.status);
                if (target_name) |tname| {
                    const target_id: u32 = blk: {
                        if (link.target_module) |id| break :blk id;
                        @panic("target_module must be set when we reach target_name");
                    };
                    try writer.print(
                        "  link {} local=\"{s}\" imported=\"{s}\" from=\"{s}\" status={s} -> module {} name=\"{s}\"\n",
                        .{ link.id, link.local_name, link.imported_name, edge.specifier, @tagName(edge.status), target_id, tname },
                    );
                } else {
                    try writer.print(
                        "  link {} local=\"{s}\" imported=\"{s}\" from=\"{s}\" status={s} -> unresolved\n",
                        .{ link.id, link.local_name, link.imported_name, edge.specifier, status_tag },
                    );
                }
            } else {
                try writer.print(
                    "  link {} local=\"{s}\" imported=\"{s}\" kind={s}\n",
                    .{ link.id, link.local_name, link.imported_name, @tagName(link.kind) },
                );
            }
        }
    }

    try writer.print("\nDiagnostics\n", .{});
    if (graph.diagnostics.len == 0) {
        try writer.print("  none\n", .{});
    } else {
        const entry_path = graph.modules[graph.entry].display_path;
        try printDiagnostics(writer, entry_path, graph.diagnostics);
    }
}

fn printDiagnostics(writer: *Io.Writer, path: []const u8, diags: []const diagnostics.Diagnostic) !void {
    for (diags) |diag| {
        const diag_path = diag.path orelse path;
        if (diag_path.len > 0) {
            try writer.print("{s}:", .{diag_path});
        }
        if (diag.label) |l| {
            try writer.print("{}:{} {s} {s} {s}: {s} \'{s}\'\n", .{
                diag.span.line,
                diag.span.column,
                severityName(diag.severity),
                diagnostics.diagnosticCodeId(diag.code),
                diagnostics.diagnosticCodeName(diag.code),
                diag.message,
                l,
            });
        } else {
            try writer.print("{}:{} {s} {s} {s}: {s}\n", .{
                diag.span.line,
                diag.span.column,
                severityName(diag.severity),
                diagnostics.diagnosticCodeId(diag.code),
                diagnostics.diagnosticCodeName(diag.code),
                diag.message,
            });
        }
    }
}

fn severityName(severity: diagnostics.Severity) []const u8 {
    return switch (severity) {
        .@"error" => "error",
        .warning => "warning",
        .info => "info",
        .hint => "hint",
    };
}

fn countDiagnostics(diags: []const diagnostics.Diagnostic) struct { errors: usize, warnings: usize } {
    var errors: usize = 0;
    var warnings: usize = 0;
    for (diags) |diag| {
        switch (diag.severity) {
            .@"error" => errors += 1,
            .warning => warnings += 1,
            .info, .hint => {},
        }
    }
    return .{ .errors = errors, .warnings = warnings };
}

fn hasErrors(diags: []const diagnostics.Diagnostic) bool {
    return countDiagnostics(diags).errors > 0;
}

fn printIndent(writer: *Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try writer.print("  ", .{});
    }
}

fn printEscaped(writer: *Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

fn printStringList(writer: *Io.Writer, values: []const []const u8) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("\"{s}\"", .{value});
    }
}

fn printExportSpecifiers(writer: *Io.Writer, values: []const ast_mod.ExportSpecifier) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print(
            "{{local=\"{s}\", exported=\"{s}\"}}",
            .{ value.local_name, value.exported_name },
        );
    }
}

fn printImportSpecifiers(writer: *Io.Writer, values: []const ast_mod.ImportSpecifier) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print(
            "{{kind={s}, imported=\"{s}\", local=\"{s}\"}}",
            .{ @tagName(value.kind), value.imported_name, value.local_name },
        );
    }
}

/// Parse extra CLI flags for externals registry. Returns an owned Registry when
/// any --add-external or --externals-dir flag is present; otherwise returns null.
fn parseExternalsArgs(args: []const []const u8, allocator: std.mem.Allocator, io: Io) !?*Registry {
    var seen = false;
    for (args[2..]) |arg| {
        if (arg.len < 2 or arg[0] != '-') continue;
        const rest = arg[2..];
        if (std.mem.startsWith(u8, rest, "add-external") or std.mem.startsWith(u8, rest, "externals-dir")) {
            seen = true;
            break;
        }
    }
    if (!seen) return null;

    const reg = try allocator.create(Registry);
    reg.* = Registry.init();

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) continue;
        if (std.mem.eql(u8, arg, "--add-external")) {
            if (i + 1 >= args.len) {
                reg.deinit(allocator);
                return null;
            }
            i += 1;
            try parseExternalEntry(args[i], allocator, reg);
        } else if (std.mem.eql(u8, arg, "--externals-dir")) {
            if (i + 1 >= args.len) {
                reg.deinit(allocator);
                return null;
            }
            i += 1;
            try loadExternalsDir(io, args[i], allocator, reg);
        }
    }

    // Return non-owning pointer. The caller keeps `reg` alive via the deferred deinit below.
    return @ptrCast(reg);
}

/// Parse "name=path"; bare name also accepted (decl_path becomes null).
fn parseExternalEntry(entry: []const u8, allocator: std.mem.Allocator, reg: *Registry) !void {
    const eq = std.mem.indexOfScalar(u8, entry, '=');
    if (eq != null) {
        const name = entry[0..eq.?];
        const decl_path = entry[(eq.? + 1)..];
        try reg.add(allocator, name, decl_path);
        return;
    }
    // bare name — register without declaration file
    try reg.add(allocator, entry, null);
}

fn loadExternalsDir(io: Io, dir_path: []const u8, allocator: std.mem.Allocator, reg: *Registry) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = Io.Dir.iterate(dir);
    while (true) {
        const maybe_entry = iter.next(io) catch break;
        if (maybe_entry == null) continue;
        const entry = maybe_entry.?;
        // C2 fix: accept any file with an extension — no longer hardcoded to .ts only. Using
        // std.fs.path.extension() keeps separator handling correct on Windows too.
        const ext = std.fs.path.extension(entry.name);
        if (ext.len == 0) continue;
        const name = entry.name[0..(entry.name.len - ext.len)];
        try reg.add(allocator, name, null);
    }
}

test "printExportSpecifiers shows local and exported names" {
    var buffer: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    const specifiers = [_]ast_mod.ExportSpecifier{
        .{ .local_name = "x", .exported_name = "x" },
        .{ .local_name = "x", .exported_name = "y" },
    };

    try printExportSpecifiers(&writer, &specifiers);

    try std.testing.expectEqualStrings(
        "{local=\"x\", exported=\"x\"}, {local=\"x\", exported=\"y\"}",
        writer.buffered(),
    );
}

test "printAst shows import declaration and specifier metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\import type main, { value as localValue } from "./dep";
        \\import "./side-effect";
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var buffer: [2048]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try printAst(&writer, result.ast);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "kind=mixed type_only=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{kind=default, imported=\"default\", local=\"main\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{kind=named, imported=\"value\", local=\"localValue\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "kind=side_effect type_only=false") != null);
}

test "printAst shows extended object property kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\const value = 1;
        \\const key = "k";
        \\const other = {};
        \\const object = { value, [key]: value, ...other, method() {}, async load() {}, get item() {}, set item(next) {} };
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var buffer: [8192]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try printAst(&writer, result.ast);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "shorthand:value") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "computed:#") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "spread:...") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "method:method") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "async_method:load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "getter:item") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "setter:item") != null);
}

test "printAst shows array holes and spread elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try frontend.analyze(arena.allocator(), .{ .text =
        \\const items = [];
        \\const array = [1, , ...items];
    }, .{});
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);

    var buffer: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);
    try printAst(&writer, result.ast);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "elements=[#") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, ", <hole>, #") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SpreadElement #") != null);
}

fn printIdList(writer: *Io.Writer, values: []const u32) !void {
    for (values, 0..) |value, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("{}", .{value});
    }
}

fn symbolName(bind: binder.BindResult, id: binder.SymbolId) []const u8 {
    for (bind.symbols) |symbol| {
        if (symbol.id == id) return symbol.name;
    }
    return "<missing>";
}

test "parseCommand accepts required commands" {
    try std.testing.expectEqual(Command.check, parseCommand("check").?);
    try std.testing.expectEqual(Command.tokens, parseCommand("tokens").?);
    try std.testing.expectEqual(Command.ast, parseCommand("ast").?);
    try std.testing.expectEqual(Command.symbols, parseCommand("symbols").?);
    try std.testing.expectEqual(Command.references, parseCommand("references").?);
    try std.testing.expectEqual(Command.refs, parseCommand("refs").?);
    try std.testing.expectEqual(Command.cfg, parseCommand("cfg").?);
    try std.testing.expectEqual(Command.modules, parseCommand("modules").?);
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
    try std.testing.expectEqual(Command.help, parseCommand("--help").?);
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
    try std.testing.expect(parseCommand("missing") == null);
}

test "diagnostic error count controls check status" {
    const diags = [_]diagnostics.Diagnostic{
        .{
            .severity = .warning,
            .code = .unexpected_token,
            .phase = .parser,
            .message = "warn",
            .span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
        },
        .{
            .severity = .@"error",
            .code = .unexpected_token,
            .phase = .parser,
            .message = "err",
            .span = .{ .start = 0, .end = 0, .line = 1, .column = 1 },
        },
    };

    try std.testing.expect(hasErrors(&diags));
    const counts = countDiagnostics(&diags);
    try std.testing.expectEqual(@as(usize, 1), counts.errors);
    try std.testing.expectEqual(@as(usize, 1), counts.warnings);
}

test "printModules emits deterministic shape with module ids and status labels" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // arena kept alive; no direct allocations needed in this test path

    // Construct minimal modules using zeroes on the complex FrontendResult sub-struct;
    // printModules only reads id and display_path, so any valid value works here.
    var mods = [_]modules.Module{
        .{
            .id = 0,
            .path = "/abs/main.ts",
            .display_path = "main.ts",
            .source_path = "./main.ts",
            .text = "",
            .result = std.mem.zeroes(frontend.FrontendResult),
        },
        .{
            .id = 1,
            .path = "/abs/a.ts",
            .display_path = "a.ts",
            .source_path = "./a.ts",
            .text = "",
            .result = std.mem.zeroes(frontend.FrontendResult),
        },
    };

    var edges = [_]modules.ImportEdge{
        .{
            .id = @as(u32, 0),
            .from = 0,
            .to = 1,
            .specifier = "./a",
            .kind = .named,
            .type_only = false,
            .status = .local,
            .span = tokens.Span{ .start = 0, .end = 3, .line = 1, .column = 1 },
        },
        .{
            .id = @as(u32, 1),
            .from = 0,
            .to = null,
            .specifier = "console",
            .kind = .side_effect,
            .type_only = false,
            .status = .external,
            .span = tokens.Span{ .start = 0, .end = 8, .line = 2, .column = 1 },
        },
        .{
            .id = @as(u32, 2),
            .from = 0,
            .to = null,
            .specifier = "./nonexistent",
            .kind = .named,
            .type_only = true,
            .status = .missing,
            .span = tokens.Span{ .start = 0, .end = 13, .line = 3, .column = 1 },
        },
    };

    const diags: []const diagnostics.Diagnostic = &.{};
    const empty_linked_imports: []const modules.linker.LinkedImport = &.{};

    const graph = modules.ModuleGraph{
        .arena = arena,
        .entry = 0,
        .modules = mods[0..],
        .imports = edges[0..],
        .linked_imports = empty_linked_imports,
        .diagnostics = diags,
    };

    var buf: [4096]u8 = undefined;
    var writer = Io.Writer.fixed(&buf);

    try printModules(&writer, graph);

    const out = std.mem.sliceTo(writer.buffered(), 0);

    // Module lines use "module <id> path=" form (not display_path=).
    try std.testing.expect(std.mem.indexOf(u8, out, "module 0 path=\"main.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module 1 path=\"a.ts\"") != null);

    // Import edges show target, declaration metadata, and resolution status.
    try std.testing.expect(std.mem.indexOf(u8, out, "module 0 -> module 1 specifier=\"./a\" kind=named type_only=false status=local") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module 0 -> external specifier=\"console\" kind=side_effect type_only=false status=external") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module 0 -> missing specifier=\"./nonexistent\" kind=named type_only=true status=missing") != null);

    // Diagnostics section still present.
    try std.testing.expect(std.mem.indexOf(u8, out, "\nDiagnostics\n") != null);
}

/// Returns the canonical type name for a TypeId drawn from
/// `types_pkg.builtinKinds_static`. Falls back to "<unknown>".
fn builtinNameFromId(type_id: types_pkg.TypeId) []const u8 {
    const kinds = types_pkg.builtinKinds_static;
    inline for (kinds) |kind| {
        if (types_pkg.builtinKindTypeId(kind) == type_id) {
            return switch (kind) {
                .number => "number",
                .string => "string",
                .boolean => "boolean",
                .null_ => "null",
                .undefined => "undefined",
                .void => "void",
                .unknown => "unknown",
                .any => "any",
            };
        }
    }
    return "<unknown>";
}

fn printTypes(
    writer: *Io.Writer,
    path: []const u8,
    info: semantics.TypeInfo,
    bind_symbols: []const binder.Symbol,
    tree: ast_mod.Ast,
) !void {
    try writer.print("Types\n", .{});

    // Symbols — declared / inferred types per symbol.
    for (info.symbols, 0..) |sym, i| {
        const name = symbolNameFromSlice(bind_symbols, sym.symbol_id);
        const decl_str = if (sym.declared_type) |t| builtinNameFromId(t) else "null";
        const infer_str = if (sym.inferred_type) |t| builtinNameFromId(t) else "null";
        const i_u32: u32 = @intCast(i);
        try writer.print(
            "  symbol {d} name=\"{s}\" declared={s} inferred={s}\n",
            .{ i_u32, name, decl_str, infer_str },
        );
    }

    // Node types — inferred primitive type per literal/keyword node.
    try writer.print("\nNodes\n", .{});
    if (info.nodes.len == 0) {
        try writer.writeAll("  none\n");
    } else {
        for (info.nodes, 0..) |entry, i| {
            _ = i; // node_id field is the primary key.
            const kind_name = nodeKindName(tree, entry.node_id);
            const type_str = builtinNameFromId(entry.type_id);
            try writer.print("  node {d} {s} type={s}\n", .{
                entry.node_id, kind_name, type_str,
            });
        }
    }

    if (info.diagnostics.len > 0) {
        try writer.writeAll("\nDiagnostics\n");
        try printDiagnostics(writer, path, info.diagnostics);
    } else {
        try writer.writeAll("\nDiagnostics\n  none\n");
    }
}

/// Return the AST variant tag name for a node — used to label each inferred
/// literal/keyword in the CLI output (e.g. "Literal", "Identifier"). Stored as
/// an owned slice in the TypeInfo would require allocator plumbing; the cheaper
/// path is computing it on demand from the tree, which `printTypes` already
/// receives alongside the TypeInfo for exactly this purpose.
fn nodeKindName(tree: ast_mod.Ast, id: ast_mod.NodeId) []const u8 {
    if (id >= tree.nodes.len) return "<unknown>";
    switch (tree.node(id).data) {
        .Program => return "Program",
        .BlockStatement => return "BlockStatement",
        .ExpressionStatement => return "ExpressionStatement",
        .Identifier => return "Identifier",
        .Literal => return "Literal",
        .RegExpLiteral => return "RegExpLiteral",
        .TemplateExpression => return "TemplateExpression",
        .TaggedTemplateExpression => return "TaggedTemplateExpression",
        .ImportExpression => return "ImportExpression",
        .MetaProperty => return "MetaProperty",
        .VariableDeclaration => return "VariableDeclaration",
        .TypeAliasDeclaration => return "TypeAliasDeclaration",
        .InterfaceDeclaration => return "InterfaceDeclaration",
        .EnumDeclaration => return "EnumDeclaration",
        .EnumMember => return "EnumMember",
        .VariableDeclarator => return "VariableDeclarator",
        .FunctionDeclaration => return "FunctionDeclaration",
        .FunctionExpression => return "FunctionExpression",
        .YieldExpression => return "YieldExpression",
        .ArrowFunctionExpression => return "ArrowFunctionExpression",
        .ClassDeclaration => return "ClassDeclaration",
        .ClassExpression => return "ClassExpression",
        .ClassField => return "ClassField",
        .ClassMethod => return "ClassMethod",
        .Parameter => return "Parameter",
        .SpreadElement => return "SpreadElement",
        .ReturnStatement => return "ReturnStatement",
        .ThrowStatement => return "ThrowStatement",
        .DebuggerStatement => return "DebuggerStatement",
        .TryStatement => return "TryStatement",
        .CatchClause => return "CatchClause",
        .FinallyClause => return "FinallyClause",
        .BreakStatement => return "BreakStatement",
        .ContinueStatement => return "ContinueStatement",
        .LabeledStatement => return "LabeledStatement",
        .ThisExpression => return "ThisExpression",
        .SuperExpression => return "SuperExpression",
        .NewExpression => return "NewExpression",
        .CallExpression => return "CallExpression",
        .ElementAccessExpression => return "ElementAccessExpression",
        .NonNullExpression => return "NonNullExpression",
        .UnaryExpression => return "UnaryExpression",
        .AsExpression => return "AsExpression",
        .SatisfiesExpression => return "SatisfiesExpression",
        .MemberExpression => return "MemberExpression",
        .BinaryExpression => return "BinaryExpression",
        .SequenceExpression => return "SequenceExpression",
        .ConditionalExpression => return "ConditionalExpression",
        .UpdateExpression => return "UpdateExpression",
        .AssignmentExpression => return "AssignmentExpression",
        .IfStatement => return "IfStatement",
        .WhileStatement => return "WhileStatement",
        .DoWhileStatement => return "DoWhileStatement",
        .ForStatement => return "ForStatement",
        .SwitchStatement => return "SwitchStatement",
        .SwitchCase => return "SwitchCase",
        .ImportDeclaration => return "ImportDeclaration",
        .ExportDeclaration => return "ExportDeclaration",
        .ObjectExpression => return "ObjectExpression",
        .ArrayExpression => return "ArrayExpression",
    }
}

fn symbolNameFromSlice(symbols: []const binder.Symbol, id: binder.SymbolId) []const u8 {
    for (symbols) |s| if (s.id == id) return s.name;
    return "<missing>";
}
