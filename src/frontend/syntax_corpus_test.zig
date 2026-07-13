const std = @import("std");
const diagnostics = @import("../diagnostics/root.zig");
const parser = @import("parser.zig");
const scanner = @import("scanner.zig");
const tokens = @import("tokens.zig");

const valid_dirs = [_][]const u8{
    "test/syntax/expressions", "test/syntax/statements", "test/syntax/modules",
    "test/syntax/types",       "test/syntax/classes",    "test/syntax/mixed",
};

test "syntax corpus: valid fixtures parse without scanner or parser diagnostics" {
    var count: usize = 0;
    for (valid_dirs) |path| count += try runDirectory(path, true);
    try std.testing.expect(count > 0);
}

test "syntax corpus: invalid fixtures emit declared diagnostic codes and make progress" {
    try std.testing.expect((try runDirectory("test/syntax/invalid", false)) > 0);
}

test "syntax corpus: unsupported fixtures emit one targeted diagnostic and make progress" {
    try std.testing.expect((try runDirectory("test/syntax/unsupported", false)) > 0);
}

fn runDirectory(path: []const u8, valid: bool) !usize {
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".js") or std.mem.endsWith(u8, entry.name, ".ts") or std.mem.endsWith(u8, entry.name, ".tsx"))) continue;
        const source = try directory.readFileAlloc(io, entry.name, std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(source);
        try checkFixture(source, valid);
        count += 1;
    }
    return count;
}

fn checkFixture(source: []const u8, valid: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scanned = try scanner.scanAll(allocator, source, true);
    const parsed = try parser.parse(allocator, scanned.tokens, .{});

    try std.testing.expect(scanned.tokens.len > 0);
    try std.testing.expectEqual(tokens.TokenType.EOF, scanned.tokens[scanned.tokens.len - 1].kind);
    try std.testing.expectEqual(scanned.tokens.len - 1, parsed.consumed_tokens);

    if (valid) {
        try std.testing.expectEqual(@as(usize, 0), scanned.diagnostics.len);
        try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
        return;
    }

    try std.testing.expectEqual(@as(usize, 0), scanned.diagnostics.len);
    const expected = try expectedCodes(allocator, source);
    try std.testing.expect(expected.len > 0);
    try std.testing.expectEqual(expected.len, parsed.diagnostics.len);
    for (expected, parsed.diagnostics) |code, diagnostic| {
        try std.testing.expectEqual(code, diagnostic.code);
        try std.testing.expectEqual(diagnostics.DiagnosticPhase.parser, diagnostic.phase);
        if (code == .unsupported_syntax or code == .unsupported_ts_syntax or code == .unsupported_jsx) {
            try std.testing.expect(diagnostic.span.end > diagnostic.span.start);
            try std.testing.expect(diagnostic.span.end <= source.len);
            const expected_span = expectedSpan(source) orelse return error.MissingExpectedSpan;
            try std.testing.expectEqualStrings(expected_span, source[diagnostic.span.start..diagnostic.span.end]);
        }
    }
}

fn expectedSpan(source: []const u8) ?[]const u8 {
    const prefix = "// span:";
    const first_end = std.mem.indexOfScalar(u8, source, '\n') orelse return null;
    const second_start = first_end + 1;
    const second_end = std.mem.indexOfScalarPos(u8, source, second_start, '\n') orelse source.len;
    const line = std.mem.trim(u8, source[second_start..second_end], " \t\r");
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return std.mem.trim(u8, line[prefix.len..], " \t");
}

fn expectedCodes(allocator: std.mem.Allocator, source: []const u8) ![]const diagnostics.DiagnosticCode {
    const prefix = "// expect:";
    const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
    const first_line = std.mem.trim(u8, source[0..line_end], " \t\r");
    if (!std.mem.startsWith(u8, first_line, prefix)) return &.{};

    var result: std.ArrayList(diagnostics.DiagnosticCode) = .empty;
    var values = std.mem.tokenizeAny(u8, first_line[prefix.len..], " ,\t");
    while (values.next()) |value| {
        const code = if (std.mem.eql(u8, value, "VZG2001"))
            diagnostics.DiagnosticCode.unexpected_token
        else if (std.mem.eql(u8, value, "VZG2002"))
            diagnostics.DiagnosticCode.expected_token
        else if (std.mem.eql(u8, value, "VZG2003"))
            diagnostics.DiagnosticCode.parse_recursion_limit_reached
        else if (std.mem.eql(u8, value, "VZG2004"))
            diagnostics.DiagnosticCode.unsupported_syntax
        else if (std.mem.eql(u8, value, "VZG2005"))
            diagnostics.DiagnosticCode.unsupported_ts_syntax
        else if (std.mem.eql(u8, value, "VZG2006"))
            diagnostics.DiagnosticCode.unsupported_jsx
        else
            return error.UnknownExpectedDiagnosticCode;
        try result.append(allocator, code);
    }
    return result.toOwnedSlice(allocator);
}
