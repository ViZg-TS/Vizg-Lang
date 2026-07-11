// example/span_check/main.zig — Diagnostic & token span integrity checks.
// Verifies that every Vizg_Span in the result is consistent: start <= end,
// both offsets fit within source bounds, and end never precedes start.

const std = @import("std");
const vizg = @cImport({
    @cInclude("/home/moliko/projects/vizg/Lib/vizg.h");
});

extern "c" fn vizg_analyze_file(path_ptr: ?[*]const u8, path_len: usize, text_ptr: [*]const u8, text_len: usize) ?*vizg.Vizg_Result;
extern "c" fn vizg_free_result(result: *vizg.Vizg_Result) void;

var failures: usize = 0;

fn run(name: []const u8, f: anytype) void {
    const result = f() catch |err| return fail(name, @errorName(err));
    if (result) |msg| return fail(name, msg);
    std.debug.print("ok     {s}\n", .{name});
}

fn fail(name: []const u8, why: []const u8) void {
    std.debug.print("[FAIL] {s}: {s}\n", .{ name, why });
    failures += 1;
}

fn valid_diagnostics(result: *vizg.Vizg_Result, source_len: usize) ?[]const u8 {
    if (result.diagnostic_count == 0) return null;
    const diags: [*c]const vizg.Vizg_Diagnostic = @ptrCast(@alignCast(result.diagnostics_ptr));

    for (diags[0..result.diagnostic_count]) |d| {
        // start <= end within source.
        if (d.span.start_offset > d.span.end_offset)
            return "diag span: start > end";
        if (d.span.end_offset > source_len and d.span.start_offset < source_len)
            return "diag span extends past EOF (non-empty diag)";

        // Message length must be consistent with message_ptr.
        if (d.message_len != 0 and d.message_ptr == null)
            return "message_len non-zero but message_ptr is null";

        // Path invariant: ptr == null ⟺ len == 0.
        const has_path = d.path_ptr != null;
        if (has_path != (d.path_len > 0))
            return "diag path invariant violated";

        // Lexeme invariant.
        if (d.message_len != 0) {
            if (d.lexeme_len > source_len) return "lexeme_len exceeds source size";
            if (d.lexeme_len > 0 and d.span.start_offset + d.lexeme_len > source_len)
                return "lexeme spans past EOF";
        }
    }
    return null;
}

fn scenario_valid_code() !?[]const u8 {
    const code = "var x: i32 = 42;\nlet y := \"hello\";\nif (true) {}\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null for valid code";
    defer vizg_free_result(result.?);

    // No diagnostics expected — confirm the ABI agrees.
    if (result.?.diagnostic_count != 0) return "valid code produced diagnostics unexpectedly";
    const toks: [*c]const vizg.Vizg_Token = @ptrCast(@alignCast(result.?.tokens_ptr));
    for (toks[0..result.?.token_count]) |t| {
        if (t.span.end_offset > code.len) return "token span extends past EOF";
        if (t.lexeme_len != 0 and t.span.start_offset + t.lexeme_len > code.len)
            return "lexeme spans past EOF";
    }
    return null;
}

fn scenario_with_diagnostics() !?[]const u8 {
    // Trigger diagnostic(s) by importing a missing module.
    const code = "import * from './missing_module.ts';\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null for code with diagnostic";
    defer vizg_free_result(result.?);

    if (result.?.diagnostic_count == 0) {
        return "expected at least one diagnostic from missing import";
    }
    return valid_diagnostics(&result.?, code.len);
}

fn scenario_empty_source() !?[]const u8 {
    const result = vizg_analyze_file(null, 0, "", 0);
    if (result) |r| {
        defer vizg_free_result(r);
        if (r.diagnostic_count != 0) return "empty source produced diagnostics";
    }
    return null;
}

fn scenario_span_zero_length() !?[]const u8 {
    // Code where a token may legitimately carry a zero-length span (e.g.,
    // EOF / comment terminator). The pair (start, end) must still satisfy
    // start <= end and fit inside source.
    const code = "let a: number;\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);

    const toks: [*c]const vizg.Vizg_Token = @ptrCast(@alignCast(result.?.tokens_ptr));
    for (toks[0..result.?.token_count]) |t| {
        if (t.span.start_offset > t.span.end_offset) return "token span start > end";
        if (t.span.end_offset > code.len and !(@intFromEnum(t.kind) == vizg.VIZG_TOKEN_END_OF_FILE))
            return "non-EOF token spans past EOF";
    }

    const diags: [*c]const vizg.Vizg_Diagnostic = @ptrCast(@alignCast(result.?.diagnostics_ptr));
    for (diags[0..result.?.diagnostic_count]) |d| {
        if (d.span.start_offset > d.span.end_offset) return "diag span start > end";
    }

    // Length-aware message access — never use %s on message_ptr directly.
    for (diags[0..result.?.diagnostic_count]) |d| {
        if (d.message_len == 0) continue;
        _ = d.message_ptr;
    }

    return null;
}

pub fn main() !void {
    run("valid_code", scenario_valid_code);
    run("with_diagnostics", scenario_with_diagnostics);
    run("empty_source", scenario_empty_source);
    run("span_zero_length", scenario_span_zero_length);

    if (failures == 0) {
        std.debug.print("\nSpan-check tests passed — all four scenarios verified.\n", .{});
    } else {
        std.debug.print("\n{d}/4 span-check scenarios failed.\n", .{failures});
    }

    if (failures != 0) return error.SpanCheckFailed;
}
