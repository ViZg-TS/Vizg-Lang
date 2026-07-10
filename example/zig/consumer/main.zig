// example/zig/consumer/main.zig - Zig consumer of libvizg.a via C ABI.
// Links against the public header at repo root and libvizg.a produced by
// `zig build` in the project root.

const std = @import("std");
const vizg = @cImport({
    // Absolute path — Zig 0.16's @cInclude does not traverse ".." across
    // source file boundaries reliably. Absolute paths work on any host.
    @cInclude("/home/moliko/projects/vizg/Lib/vizg.h");
});

// Ergonomic re-exports from the C enum base values for use in Zig code.
pub const Vizg_Severity       = vizg.VIZG_SEVERITY_ERROR;
pub const Vizg_DiagnosticCode = vizg.VIZG_DIAG_INVALID_CHAR;
pub const Vizg_DiagnosticPhase = vizg.VIZG_PHASE_SCANNER;
pub const Vizg_TokenType      = vizg.VIZG_TOKEN_INVALID;

// Direct extern declaration for the ABI functions so Zig sees them as nullable.
extern "c" fn vizg_analyze_file(
    path_ptr: ?[*]const u8, path_len: usize,
    text_ptr: [*]const u8, text_len: usize) ?*vizg.Vizg_Result;
extern "c" fn vizg_free_result(result: *vizg.Vizg_Result) void;

const sample_code: []const u8 = "var x: i32 = 42;\n" ++
    "let y := \"hello\";\n" ++
    "if (true) {} else { }\n";

pub fn main() !void {
    const result = vizg_analyze_file(
        null, 0, sample_code.ptr, sample_code.len);
    defer if (result) |r| vizg_free_result(r);

    std.debug.print("=== vizg Zig consumer (C-ABI link) ===\n", .{});
    std.debug.print("input: {d} bytes\n", .{sample_code.len});
    if (result == null) {
        std.debug.print("vizg_analyze_file returned null\n", .{});
        return;
    }

    const r = result.?;
    std.debug.print(
        "tokens:   {d}\n" ++
        "diags:    {d}\n",
        .{ r.token_count, r.diagnostic_count });

    // Vizg_Result.tokens_ptr is declared as `const void *` in the header.
    // Cast to the actual element type before indexing it.
    if (r.tokens_ptr) |toks_raw| {
        const toks: [*c]const vizg.Vizg_Token = @alignCast(@ptrCast(toks_raw));
        const shown = @min(r.token_count, 5);
        std.debug.print("\nFirst {d} token(s):\n", .{shown});
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            const t = toks[i];
            if (t.lexeme_len == 0 or t.span.start_offset > sample_code.len) continue;
            const end_off = @min(t.span.start_offset + t.lexeme_len, sample_code.len);
            const lex = sample_code[t.span.start_offset .. end_off];
            std.debug.print(
                "  [{d}] {s:<36} kind={d}\n", .{ i, lex, @as(i16, @intCast(t.kind)) });
        }
    }

    // Same cast dance for diagnostics (const void * in the C struct).
    if (r.diagnostics_ptr) |diags_raw| {
        const diags: [*c]const vizg.Vizg_Diagnostic = @alignCast(@ptrCast(diags_raw));
        const n = r.diagnostic_count;
        std.debug.print("\nDiagnostics:\n", .{});
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const d = diags[i];

            // Length-aware message — never use %s on a raw pointer.
            std.debug.print(
                "  [{d}] sev={d} code={d:<5} phase={d} msg_len={d}\n", .{
                    i, @as(i8, @intCast(d.severity)), d.code, d.phase,
                    d.message_len });

            // path_ptr == null implies path_len == 0 (ABI invariant).
            if (d.path_len > 0) {
                const path = d.path_ptr[0..d.path_len];
                std.debug.print("              path={s}\n", .{path});
            } else {
                std.debug.print("              path=<none>\n", .{});
            }
        }
    }

    std.debug.print("\ndone\n", .{});
}
