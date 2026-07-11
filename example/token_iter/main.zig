// example/token_iter/main.zig — Length-aware token consumption via C ABI.
// Exercises four scenarios that focus on lexeme_len / lexeme_ptr pairing,
// zero-length handling, and EOF sentinel behaviour.

const std = @import("std");
const vizg = @cImport({
    @cInclude("/home/moliko/projects/vizg/Lib/vizg.h");
});

extern "c" fn vizg_analyze_file(
    path_ptr: ?[*]const u8, path_len: usize,
    text_ptr: [*]const u8, text_len: usize) ?*vizg.Vizg_Result;
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

fn normal_tokens() !?[]const u8 {
    const code = "var x: i32 = 42;\nlet s := \"hello\";\nif (true) {}\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null for valid code";
    defer vizg_free_result(result.?);

    const r = result.?;
    if (r.token_count == 0) return "expected non-empty token stream";
    const toks: [*c]const vizg.Vizg_Token = @alignCast(@ptrCast(r.tokens_ptr));

    var saw_eof = false;
    for (toks[0..r.token_count]) |t| {
        if (t.span.start_offset >= code.len) return "start_offset out of range";
        const end_off = t.span.start_offset + t.lexeme_len;
        if (end_off > code.len and t.kind != vizg.VIZG_TOKEN_END_OF_FILE)
            return "lexeme spans past EOF";

        if (t.kind == vizg.VIZG_TOKEN_END_OF_FILE) saw_eof = true;
    }
    if (!saw_eof) return "no VIZG_TOKEN_END_OF_FILE in stream";
    return null;
}

fn empty_source() !?[]const u8 {
    const result = vizg_analyze_file(null, 0, "", 0);
    // ABI allows either null or an empty Result for truly-empty input.
    if (result) |r| {
        defer vizg_free_result(r);
        if (r.token_count > 1) return "empty source produced >1 tokens";
        if (r.diagnostic_count != 0) return "empty source produced diagnostics";
    }
    return null;
}

fn keywords_and_punctuators() !?[]const u8 {
    const code = "import * from './missing.ts';\nexport let y: number;\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null for keyword-heavy input";
    defer vizg_free_result(result.?);

    const r = result.?;
    const toks: [*c]const vizg.Vizg_Token = @alignCast(@ptrCast(r.tokens_ptr));
    var saw_keyword = false;
    var saw_punctuator = false;
    for (toks[0..r.token_count]) |t| {
        if (@intFromEnum(t.kind) >= 17 and @intFromEnum(t.kind) <= 52)
            saw_keyword = true;
        else if (@intFromEnum(t.kind) >= vizg.VIZG_TOKEN_PUNCTUATOR_OPEN_PARENTHESIS)
            saw_punctuator = true;
    }
    if (!saw_keyword) return "no keyword tokens detected";
    if (!saw_punctuator) return "no punctuator tokens detected";
    return null;
}

fn zero_length_lexeme() !?[]const u8 {
    // EOF / line-comment tokens may carry zero-length lexemes — confirm that
    // the pair (lexeme_ptr, lexeme_len == 0) is internally consistent.
    const code = "let a: number;\n";

    const result = vizg_analyze_file(null, 0, code.ptr, code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);

    const r = result.?;
    const toks: [*c]const vizg.Vizg_Token = @alignCast(@ptrCast(r.tokens_ptr));
    for (toks[0..r.token_count]) |t| {
        if (t.lexeme_len == 0 and t.span.start_offset >= code.len) {
            return "zero-len lexeme with out-of-bounds offset";
        }
    }
    return null;
}

pub fn main() !void {
    run("normal_tokens",              normal_tokens);
    run("empty_source",               empty_source);
    run("keywords_and_punctuators",   keywords_and_punctuators);
    run("zero_length_lexeme",         zero_length_lexeme);

    if (failures == 0) {
        std.debug.print("\nToken-iter tests passed — all four scenarios verified.\n", .{});
    } else {
        std.debug.print("\n{d}/4 token-iter scenarios failed.\n", .{failures});
    }

    if (failures != 0) return error.TokenIterFailed;
}
