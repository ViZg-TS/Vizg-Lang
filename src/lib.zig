// src/lib.zig — Entry point for the vizg static library (libvizg.a).
//
// For Zig callers this re-exports types with un-prefixed names; the same types are
// also available under `abi.Vizg_*` when you @import("lib_abi").
//
// C ABI entry points: `Vizg_analyzeFile`, `Vizg_freeResult`, plus `Vizg_SymbolExports`.

const abi = @import("lib_abi.zig");
const std = @import("std");

// -----------------------------------------------------------------------------
// Re-exported type aliases — un-prefixed for ergonomics from other Zig code.
// All types share their ABI layout with the Vizg_* names below (extern struct).
// -----------------------------------------------------------------------------
pub const Status     = abi.Vizg_Status;
pub const STATUS_OK  = abi.VIZG_STATUS_OK;
pub const TokenType  = abi.Vizg_TokenType;
pub const Severity   = abi.Vizg_Severity;
pub const DiagnosticCode = abi.Vizg_DiagnosticCode;
pub const DiagnosticPhase = abi.Vizg_DiagnosticPhase;
pub const Span       = abi.Vizg_Span;

// Aliases for types used as Result fields / struct members.
pub const TokenFlags = abi.Vizg_TokenFlags;

/// A token produced by the scanner — layout is `Vizg_Token` (extern).
pub const Token      = abi.Vizg_Token;

/// Structured diagnostic emitted during parsing, binding, resolution etc.
pub const Diagnostic = abi.Vizg_Diagnostic;

/// Result handle returned by analyzeFile; must be passed to freeResult when done.
pub const Result     = abi.Vizg_Result;

// -----------------------------------------------------------------------------
// C ABI functions — thin wrappers that forward to the Vizg_* extern "C" symbols.
// Signatures match so a Zig caller gets the same ABI as a C caller would.
// -----------------------------------------------------------------------------

/// Analyze source text or a file and return a result handle.
/// Caller must call freeResult() on success to release all allocations.
/// Returns null on failure (out-of-memory, I/O error).
pub fn analyzeFile(text_ptr: [*c]const u8, text_len: usize) ?*Result {
    // Forward to the C ABI entry point with zero-copy text.  The library owns
    // the returned Result's allocations; call freeResult() when done.
    return abi.Vizg_analyzeFile(null, 0, text_ptr, text_len);
}

/// Analyze a source file on disk by path.  Allocates path bytes in an arena so
/// readFileBytes can safely copy it into the fixed-length POSIX buf.
pub fn analyzeFileFromPath(a_alloc: std.mem.Allocator, dir_path: ?[]const u8) ?*Result {
    if (dir_path == null or dir_path.?.len == 0) return null;
    const name = a_alloc.dupe(u8, dir_path.?) catch return null;
    // Forward to the C ABI — it will read the file via raw syscalls internally.
    return abi.Vizg_analyzeFile(name.ptr, name.len, null, 0);
}

/// Release all memory associated with a Result. Safe to call with null (no-op).
pub fn freeResult(result: ?*Result) void {
    abi.Vizg_freeResult(result);
}
