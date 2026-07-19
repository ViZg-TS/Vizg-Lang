const std = @import("std");
const ast_mod = @import("ast.zig");
const binder = @import("binder.zig");
const cfg = @import("cfg.zig");
const diagnostics = @import("../diagnostics/root.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const scanner = @import("scanner.zig");
const tokens = @import("tokens.zig");

pub const SourceKind = enum {
    script,
    module,
};

pub const SourceFile = struct {
    path: []const u8 = "",
    text: []const u8,
    kind: SourceKind = .module,
};

pub const FrontendOptions = struct {
    collect_comments: bool = true,
    recover_errors: bool = true,
    // Maximum recursive depth during parse descent. Exceeded parses are rejected with a diagnostic (H4).
    max_parse_depth: usize = 1024,
    max_diagnostics: usize = std.math.maxInt(usize),
    /// Ambient globals (e.g. a host clock) registered by the host
    /// before analysis so they resolve without synthetic source declarations.
    /// Borrowed for the duration of `analyze`.
    ambient_globals: []const @import("../project/contracts.zig").AmbientGlobal = &.{},
    /// Source-backed globals derived from a designated project module.
    /// Borrowed for the duration of `analyze`.
    source_globals: []const binder.SourceGlobal = &.{},
    /// Stable host identities attached to matching top-level source value
    /// declarations. Borrowed for the duration of `analyze`.
    source_host_bindings: []const @import("../project/contracts.zig").SourceHostBinding = &.{},
};

pub const FrontendResult = struct {
    source: SourceFile,
    tokens: []const tokens.Token,
    comments: []const scanner.Comment,
    ast: ast_mod.Ast,
    bind: binder.BindResult,
    resolve: resolver.ResolveResult,
    cfgs: []const cfg.FunctionCfg,
    diagnostics: []const diagnostics.Diagnostic,
};

pub fn analyze(allocator: std.mem.Allocator, source: SourceFile, options: FrontendOptions) !FrontendResult {
    const scanned = try scanner.scanAllWithLimit(allocator, source.text, options.collect_comments, options.max_diagnostics);
    const parsed = try parser.parse(allocator, scanned.tokens, .{
        .recover_errors = options.recover_errors,
        .max_parse_depth = options.max_parse_depth,
        .max_diagnostics = try remainingDiagnostics(options.max_diagnostics, scanned.diagnostics.len),
    });
    const scanner_parser_count = try diagnosticCount(&.{ scanned.diagnostics, parsed.diagnostics }, options.max_diagnostics);
    const bound = try binder.bindWithLimit(
        allocator,
        parsed.ast,
        options.ambient_globals,
        options.source_globals,
        options.source_host_bindings,
        try remainingDiagnostics(options.max_diagnostics, scanner_parser_count),
    );
    const resolved = try resolver.resolveWithLimit(
        allocator,
        parsed.ast,
        bound,
        try remainingDiagnostics(
            options.max_diagnostics,
            try diagnosticCount(&.{ scanned.diagnostics, parsed.diagnostics, bound.diagnostics }, options.max_diagnostics),
        ),
    );
    const cfgs = try cfg.build(allocator, parsed.ast);
    const all_diagnostics = try combineDiagnosticsWithLimit(allocator, &.{
        scanned.diagnostics,
        parsed.diagnostics,
        bound.diagnostics,
        resolved.diagnostics,
    }, options.max_diagnostics);

    return .{
        .source = source,
        .tokens = scanned.tokens,
        .comments = scanned.comments,
        .ast = parsed.ast,
        .bind = bound,
        .resolve = resolved,
        .cfgs = cfgs,
        .diagnostics = all_diagnostics,
    };
}

fn remainingDiagnostics(max_diagnostics: usize, used: usize) !usize {
    if (used > max_diagnostics) return error.DiagnosticLimitExceeded;
    return max_diagnostics - used;
}

fn diagnosticCount(lists: []const []const diagnostics.Diagnostic, max_diagnostics: usize) !usize {
    var total: usize = 0;
    for (lists) |list| {
        total = std.math.add(usize, total, list.len) catch return error.DiagnosticLimitExceeded;
        if (total > max_diagnostics) return error.DiagnosticLimitExceeded;
    }
    return total;
}

fn combineDiagnostics(allocator: std.mem.Allocator, lists: []const []const diagnostics.Diagnostic) ![]const diagnostics.Diagnostic {
    return combineDiagnosticsWithLimit(allocator, lists, std.math.maxInt(usize));
}

fn combineDiagnosticsWithLimit(
    allocator: std.mem.Allocator,
    lists: []const []const diagnostics.Diagnostic,
    max_diagnostics: usize,
) ![]const diagnostics.Diagnostic {
    var total: usize = 0;
    for (lists) |list| {
        total = std.math.add(usize, total, list.len) catch return error.DiagnosticLimitExceeded;
        if (total > max_diagnostics) return error.DiagnosticLimitExceeded;
    }

    if (total == 0) return &[_]diagnostics.Diagnostic{};

    const combined = try allocator.alloc(diagnostics.Diagnostic, total);
    var index: usize = 0;
    for (lists) |list| {
        @memcpy(combined[index .. index + list.len], list);
        index += list.len;
    }

    // Sort by source position (span.start), then diagnostic code as tiebreak. This
    // clusters duplicates of `(code, span)` so a linear scan drops them. We use an inline
    // stable insertion sort to avoid the Zig 0.16 std.sort.block context-parameter issue
    // with unused `void` callbacks in Debug builds (unused params are errors).
    for (combined[1..], 0..) |item, i| {
        var j = i;
        while (j > 0) : (j -= 1) {
            const prev = combined[j - 1];
            if (prev.span.start < item.span.start) break;
            if (prev.span.start == item.span.start and
                @intFromEnum(prev.code) <= @intFromEnum(item.code)) break;
            // Move current forward one slot.
            const tmp = combined[j - 1];
            combined[j - 1] = combined[j];
            combined[j] = tmp;
        }
    }

    // Dedup: keep only the first entry per unique `(DiagnosticCode, span.start)`.
    var write: usize = 0;
    for (combined) |entry| {
        if (write == 0 or combined[write - 1].code != entry.code or combined[write - 1].span.start != entry.span.start) {
            // First occurrence of `(code, span.start)` — keep.
            if (write != @as(usize, @intCast(combined.len)))
                combined[write] = entry;
            write += 1;
        }
    }

    return combined[0..write];
}

test "frontend analyze runs scanner parser binder and cfg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\import { log } from "host-service";
        \\
        \\export function main(name: string) {
        \\    let message = "hi " + name;
        \\    log(message);
        \\    return message;
        \\}
    ;

    const result = try analyze(allocator, .{ .text = source }, .{});

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.tokens.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.bind.module.imports.len);
    try std.testing.expectEqual(@as(usize, 1), result.bind.module.exports.len);
    try std.testing.expect(result.resolve.references.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.cfgs.len);
}

test "frontend analyze keeps lexical diagnostics and EOF token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try analyze(allocator, .{ .text = "\"unterminated" }, .{});

    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(tokens.TokenType.EOF, result.tokens[result.tokens.len - 1].kind);
}
