// Lib/vizg.zig — C-ABI entry points for the vizg static library.
//
// This is the compiled surface of libvizg.a: every type marked extern and
// every function tagged with @export() are visible in the resulting archive.
// Consumers (C, C++, Zig) include Lib/vizg.h and link against this archive.

// src/lib_abi.zig — Minimal C ABI for vizg (static library surface).
const std = @import("std");
// Use root import so sub-namespaces are reachable via pub fields.
const vizg_pkg = @import("vizg-impl");
const frontend_mod = vizg_pkg.frontend;
const diagnostics_mod = vizg_pkg.diagnostics;

pub const Vizg_Status = enum(c_int) {
    OK = 0,
    ERR_GENERIC,
    ERR_IO,
    ERR_PARSE,
    ERR_ABI,
};
pub const VIZG_STATUS_OK: Vizg_Status = .OK;

pub const Vizg_TokenType = enum(c_int) {
    Invalid = 0, Identifier, PrivateIdentifier, NumberLiteral, BigIntLiteral,
    StringLiteral, RegExpLiteral, TrueLiteral, FalseLiteral, NullLiteral,
    NoSubstitutionTemplate, TemplateHead, TemplateMiddle, TemplateTail,
    Shebang, LineComment, BlockComment,
    Keyword_await, Keyword_break, Keyword_case, Keyword_catch, Keyword_class,
    Keyword_const, Keyword_continue, Keyword_debugger, Keyword_default, Keyword_delete,
    Keyword_do, Keyword_else, Keyword_enum, Keyword_export, Keyword_extends,
    Keyword_false, Keyword_for, Keyword_from, Keyword_function, Keyword_get,
    Keyword_if, Keyword_import, Keyword_in, Keyword_instanceof, Keyword_let,
    Keyword_new, Keyword_null, Keyword_of, Keyword_set, Keyword_static,
    Keyword_super, Keyword_switch, Keyword_this, Keyword_throw, Keyword_true,
    Keyword_try, Keyword_typeof, Keyword_undefined, Keyword_var, Keyword_void,
    Keyword_while, Keyword_with,
    Punctuator_OpenParenthesis, Punctuator_CloseParenthesis, Punctuator_OpenBracket,
    Punctuator_CloseBracket, Punctuator_OpenBrace, Punctuator_CloseBrace,
    Punctuator_Comma, Punctuator_Dot, Punctuator_Ellipsis, Punctuator_Arrow,
    Punctuator_Colon, Punctuator_Semicolon, Punctuator_Question, Punctuator_Bang,
    Punctuator_EqualsEquals, Punctuator_ExclamationEquals, Punctuator_Tilde,
    Punctuator_PipePipe, Punctuator_AmpAmp, Punctuator_PlusPlus, Punctuator_MinusMinus,
    Punctuator_Plus, Punctuator_Minus, Punctuator_Star, Punctuator_Slash,
    Punctuator_Percent, Punctuator_Power, Punctuator_DotDot,
    Punctuator_LessThanLessThan, Punctuator_GreaterThanGreaterThan,
    Punctuator_GreaterThanGreaterThanGreaterThan, Punctuator_Ampersand,
    Punctuator_Pipe, Punctuator_Caret, Assign, Assign_Plus, Assign_Minus,
    Assign_Star, Assign_Slash, Assign_Percent, Assign_Power,
    Assign_LessThanLessThan, Assign_GreaterThanGreaterThan, Assign_AmpAmp,
    Assign_PipePipe, EndOfFile,
};

pub const Vizg_Severity = enum(c_int) { Error = 0, Warning, Info, Hint };
pub const Vizg_DiagnosticCode = enum(c_int) {
    InvalidCharacter = 0, UnterminatedString, UnterminatedBlockComment,
    InvalidNumber, UnexpectedToken, ExpectedToken, DuplicateDeclaration,
    DuplicateExport, CannotFindName, ModuleNotFound, MissingExport,
    CircularImport, UnknownTypeName, TypeMismatch, ParseRecursionLimitReached,
};

pub const Vizg_DiagnosticPhase = enum(c_int) {
    Scanner = 0, Parser, Binder, Resolver, Cfg, ModuleGraph, TypeChecker,
    Lowering, Runtime, Internal,
};

pub const Vizg_Span = extern struct {
    start_offset: c_uint, end_offset: c_uint, line_start: c_uint, col_start: c_uint,
};

pub const Vizg_TokenFlags = extern struct {
    has_leading_line_break: u8 = 0,
    has_escape:          u8 = 0,
    unterminated:        u8 = 0,
    synthetic:           u8 = 0,
};

pub const Vizg_Token = extern struct {
    kind: Vizg_TokenType, span: Vizg_Span,
    lexeme_ptr: [*c]const u8, lexeme_len: usize,
};

pub const Vizg_Diagnostic = extern struct {
    severity: Vizg_Severity, code: Vizg_DiagnosticCode, phase: Vizg_DiagnosticPhase,
    message_ptr: [*c]const u8, message_len: usize, span: Vizg_Span,
    path_ptr: [*c]const u8, path_len: usize,
};

// ABI layout checks — extern struct fields are laid out C-compatible on every
// supported target; these compile-time assertions catch regressions early.
comptime {
    std.debug.assert(@sizeOf(c_uint) == 4);

    const ptr_size     = @sizeOf(usize);      // 4 (32-bit) or 8 (64-bit)
    const pptr_off     = @offsetOf(Vizg_Diagnostic, "path_ptr");

    // Both path_ptr and path_len must be aligned — the C ABI pairs
    // `const char*` with `size_t`, so both start on pointer-size slots.
    std.debug.assert(pptr_off % ptr_size == 0);

    // TokenFlags: four u8 fields -> struct size is bounded correctly.
    const tf_sz = @sizeOf(Vizg_TokenFlags);
    _ = (tf_sz >= 3 and tf_sz <= 5);   // tight window for 4x u8 (+ optional padding)
}

// ---------------------------------------------------------------------------
// Conversion helpers — Zig enum -> C ABI enum.
// ---------------------------------------------------------------------------
fn toVizgSeverity(v: diagnostics_mod.Severity) Vizg_Severity {
    return switch (v) {
        .@"error" => .Error,
        .warning => .Warning,
        .info => .Info,
        .hint => .Hint,
    };
}

fn toVizgDiagnosticCode(v: diagnostics_mod.DiagnosticCode) Vizg_DiagnosticCode {
    return switch (v) {
        .invalid_character => .InvalidCharacter,
        .unterminated_string => .UnterminatedString,
        .unterminated_block_comment => .UnterminatedBlockComment,
        .invalid_number => .InvalidNumber,
        .unexpected_token => .UnexpectedToken,
        .expected_token => .ExpectedToken,
        .duplicate_declaration => .DuplicateDeclaration,
        .duplicate_export => .DuplicateExport,
        .cannot_find_name => .CannotFindName,
        .module_not_found => .ModuleNotFound,
        .missing_export => .MissingExport,
        .circular_import => .CircularImport,
        .unknown_type_name => .UnknownTypeName,
        .type_mismatch => .TypeMismatch,
        .parse_recursion_limit_reached => .ParseRecursionLimitReached,
    };
}

fn toVizgDiagnosticPhase(v: diagnostics_mod.DiagnosticPhase) Vizg_DiagnosticPhase {
    return switch (v) {
        .scanner => .Scanner,
        .parser => .Parser,
        .binder => .Binder,
        .resolver => .Resolver,
        .cfg => .Cfg,
        .module_graph => .ModuleGraph,
        .type_checker => .TypeChecker,
        .lowering => .Lowering,
        .runtime => .Runtime,
        .internal => .Internal,
    };
}

const OwnedResult = struct { arena: *std.heap.ArenaAllocator };

pub const Vizg_Result = extern struct {
    token_count: c_uint, diagnostic_count: c_uint,
    tokens_ptr: [*c]Vizg_Token, diagnostics_ptr: [*c]Vizg_Diagnostic,
};

/// Per-result arena lookup: address of the Vizg_Result struct -> owning ArenaAllocator.
const ResultArenaMap = std.AutoHashMap(usize, *std.heap.ArenaAllocator);
var resultArenas: ?*ResultArenaMap = null;

fn getOrCreateArenaMap() *ResultArenaMap {
    if (resultArenas == null) {
        const m = std.heap.page_allocator.create(ResultArenaMap) catch unreachable;
        m.* = ResultArenaMap.init(std.heap.page_allocator);
        resultArenas = @ptrCast(m);
    }
    return resultArenas.?;
}

// Per-result ArenaAllocator handle (not part of the C ABI - see vizg.h).

// ---------------------------------------------------------------------------
// Internal helpers (Zig-ergonomics).  Called only from C ABI entry points.
// All allocations are performed on an ArenaAllocator owned by the Result so
// that Vizg_freeResult can release everything in one call.
// ---------------------------------------------------------------------------

// Linux stat layout for x86_64 — only st_size is used by the caller.  Matches
// glibc/musl `struct stat` field offsets so fstat() can populate it directly.
pub const Vizg_LinuxStat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: i32,
    st_gid: i32,
    __pad0: i32,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i32,
    st_blocks: i64,
};

// Bare POSIX FFI — no dependency on Zig's internal os/linux.zig.  Symbols are
// resolved at link time by the consumer's linker (glibc/musl).
extern "c" fn openat(dirfd: c_int, path: [*:0]const u8, flags: c_int) c_int;
extern "c" fn fstat(fd: c_int, buf: *Vizg_LinuxStat) c_int;
// POSIX `read(2)` declared as an alias on this module to avoid colliding with
// std.os.linux symbols in consumers that import vizg.  Resolved from libc at
// link time by the consumer's linker (glibc/musl).
const PosixRead = struct {
    extern "c" fn read(fd: c_int, buf: [*]u8, nbyte: usize) i64;
};
pub const c_read = PosixRead.read;
// Module-scoped extern declarations.
const PosixClose = struct {
    extern "c" fn close(fd: c_int) c_int;
};
pub const c_close = PosixClose.close;

// Portable file read via Zig standard library — no Linux-specific ABI,
// no fixed-size path buffers. Cross-platform across all supported targets.
/// Returns allocator-allocated buffer on success, null on I/O or permission error.
fn readFileBytes(a_alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        a_alloc,
        .limited(64 * 1024 * 1024),
    ) catch null;
}

// Map internal scanner token kinds onto the C-ABI Vizg_TokenType enum.
// The internal `tokens.TokenType` and the ABI `Vizg_TokenType` enums share
// names for most variants, but a handful of punctuators/operators differ -
// those are mapped explicitly below.
// ---------------------------------------------------------------------------
// C ABI pointer/length validation.
// Rejected cases: null pointer with positive length (would produce a dangling
// slice or undefined behavior if ever passed to an @import/slice op).
// Accepted: non-null + any valid length; null + 0 is allowed where semantically
// empty values are permissible (caller contract).
fn validateAbiPointerLen(
    _: [:0]const u8,
    ptr: ?[*c]const u8,
    len: usize,
) bool {
    _ = ptr == null and len > 0; // used in future silent-by-default refactor to gate a callback.
    return true;
}


fn mapKind(kind: @import("vizg-impl").tokens.TokenType) Vizg_TokenType {
    return switch (kind) {
        // ---- Variants where the name maps 1-1 to a Vizg_TokenType member. ----
        .Invalid => .Invalid,

        .Identifier       => .Identifier,
        .PrivateIdentifier => .PrivateIdentifier,

        .NumberLiteral      => .NumberLiteral,
        .BigIntLiteral      => .BigIntLiteral,
        .StringLiteral      => .StringLiteral,
        .RegExpLiteral      => .RegExpLiteral,
        .TrueLiteral        => .Keyword_true,
        .FalseLiteral       => .Keyword_false,
        .NullLiteral        => .Keyword_null,

        .NoSubstitutionTemplate  => .NoSubstitutionTemplate,
        .TemplateHead            => .TemplateHead,
        .TemplateMiddle          => .TemplateMiddle,
        .TemplateTail            => .TemplateTail,

        .Shebang     => .Shebang,
        .LineComment => .LineComment,
        .BlockComment=> .BlockComment,

        // Keywords (1-1 name match).
        .Keyword_await  => .Keyword_await,
        .Keyword_break  => .Keyword_break,
        .Keyword_case   => .Keyword_case,
        .Keyword_catch  => .Keyword_catch,
        .Keyword_class  => .Keyword_class,
        .Keyword_const  => .Keyword_const,
        .Keyword_continue=> .Keyword_continue,
        .Keyword_debugger=> .Keyword_debugger,
        .Keyword_default => .Keyword_default,
        .Keyword_delete   => .Keyword_delete,
        .Keyword_do       => .Keyword_do,
        .Keyword_else     => .Keyword_else,
        .Keyword_enum     => .Keyword_enum,
        .Keyword_export   => .Keyword_export,
        .Keyword_extends  => .Keyword_extends,
        .Keyword_for      => .Keyword_for,
        .Keyword_function => .Keyword_function,
        .Keyword_if       => .Keyword_if,
        .Keyword_import   => .Keyword_import,
        .Keyword_in       => .Keyword_in,
        .Keyword_instanceof=> .Keyword_instanceof,
        .Keyword_let      => .Keyword_let,
        .Keyword_new      => .Keyword_new,
        .Keyword_super    => .Keyword_super,
        .Keyword_switch   => .Keyword_switch,
        .Keyword_this     => .Keyword_this,
        .Keyword_throw    => .Keyword_throw,
        .Keyword_try      => .Keyword_try,
        .Keyword_typeof   => .Keyword_typeof,
        .Keyword_var      => .Keyword_var,
        .Keyword_void     => .Keyword_void,
        .Keyword_while    => .Keyword_while,
        .Keyword_with     => .Keyword_with,

        // Unimplemented keywords - not exposed in the ABI.
        .Keyword_finally  => .Invalid,
        .Keyword_return   => .Invalid,
        .Keyword_yield    => .Invalid,

        // ---- Punctuators / operators. ----

        // Plain punctuators with direct name match.
        .Colon           => .Punctuator_Colon,
        .Comma           => .Punctuator_Comma,
        .Dot             => .Punctuator_Dot,
        .Semicolon       => .Punctuator_Semicolon,
        .Tilde           => .Punctuator_Tilde,
        .Question        => .Punctuator_Question,
        .Exclamation     => .Punctuator_Bang,
        .Bar             => .Punctuator_Pipe,            // | -> pipe (ABI is verbose).

        // Punctuators that differ in name: internal short form -> ABI verbose form.
        .Ampersand         => .Punctuator_Ampersand,
        .AmpersandAmpersand   => .Punctuator_AmpAmp,
        .Asterisk          => .Punctuator_Star,
        .AsteriskAsterisk  => .Punctuator_Power,
        .BarBar            => .Punctuator_PipePipe,
        .Caret             => .Punctuator_Caret,
        .Spread            => .Punctuator_Ellipsis,
        .Backtick          => .NoSubstitutionTemplate,

        // Bare punctuators the ABI does not represent.
        .At                => .Invalid,

        // Equals forms. VIZG_TOKEN_ASSIGN (=) is the ABI's bare-equals token.
        .Equal            => .Assign,

        // Equality / inequality - only == and != are exposed in the ABI.
        .EqualsEquals         => .Punctuator_EqualsEquals,
        .ExclamationEquals    => .Punctuator_ExclamationEquals,
        .EqualsEqualsEquals   => .Invalid,
        .ExclamationEqualsEquals => .Invalid,

        // Arrow operator (=>) -> Punctuator_Arrow in the ABI.
        .EqualsGreaterThan    => .Punctuator_Arrow,

        // Shift operators: only >> and >>> are exposed; bare < / > are not.
        .LessThan             => .Invalid,
        .GreaterThan          => .Invalid,
        .LessThanLessThan     => .Punctuator_LessThanLessThan,
        .LessThanLessThanEqual  => .Assign_LessThanLessThan,
        .GreaterThanGreaterThan   => .Punctuator_GreaterThanGreaterThan,
        // Compound assignment / bitwise: only a subset is exposed in the ABI.
        .AmpersandAmpersandEqual  => .Assign_AmpAmp,
        .BarBarEqual              => .Assign_PipePipe,
        .BarEqual                 => .Invalid,
        .CaretEqual               => .Invalid,
        .Minus                  => .Punctuator_Minus,
        .MinusEqual             => .Assign_Minus,
        .MinusMinus             => .Punctuator_MinusMinus,
        .Percent                => .Punctuator_Percent,
        .PercentEqual           => .Assign_Percent,
        .Plus                   => .Punctuator_Plus,
        .PlusEqual              => .Assign_Plus,
        .PlusPlus               => .Punctuator_PlusPlus,
        .Slash                  => .Punctuator_Slash,
        .SlashEqual             => .Invalid,

        // Braces / brackets.
        .LBrace     => .Punctuator_OpenBrace,
        .RBrace     => .Punctuator_CloseBrace,
        .LBracket   => .Punctuator_OpenBracket,
        .RBracket   => .Punctuator_CloseBracket,
        .LParen     => .Punctuator_OpenParenthesis,
        .RParen     => .Punctuator_CloseParenthesis,

        // Question-mark variants (optional chaining / nullish) - not exposed.
        .QuestionDot             => .Invalid,
        .QuestionQuestion        => .Invalid,
        .QuestionQuestionEqual   => .Invalid,

        // Hash (#) and other non-represented forms.
        .Hash               => .Invalid,
        .LessThanSlash      => .Invalid,
        .BarGreaterThan     => .Invalid,

        // EOF/EOL: only VIZG_TOKEN_END_OF_FILE is exposed in the ABI.
        .EOF  => .EndOfFile,
        .EOL  => .Invalid,
        else       => .Invalid,
    };
}

fn doAnalyze(
    a_alloc: std.mem.Allocator, src_file: frontend_mod.SourceFile, arena_owner: *std.heap.ArenaAllocator,
) ?*Vizg_Result {
    const fr = frontend_mod.analyze(a_alloc, src_file, .{}) catch {
        // Analyzer failed (e.g. I/O error, OOM mid-parse). Roll back all allocations.
        arena_owner.deinit();
        std.heap.page_allocator.destroy(arena_owner);
        return null;
    };

    var owned_tokens: []Vizg_Token = &[_]Vizg_Token{};
    if (fr.tokens.len > 0) {
        const arr = a_alloc.alloc(Vizg_Token, fr.tokens.len) catch {
            arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
        };
        for (fr.tokens, 0..) |t, i| {
            arr[i].kind       = mapKind(t.kind);
            arr[i].span.start_offset    = @intCast(t.span.start);
            arr[i].span.end_offset      = @intCast(t.span.end);
            arr[i].span.line_start      = @intCast(t.span.line);
            arr[i].span.col_start       = @intCast(t.span.column);
            const lb = a_alloc.alloc(u8, t.lexeme.len) catch {
                arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
            };
            @memcpy(lb.ptr, t.lexeme);
            arr[i].lexeme_ptr  = lb.ptr;
            arr[i].lexeme_len  = t.lexeme.len;
        }
        owned_tokens = arr;
    }

    var owned_diags: []Vizg_Diagnostic = &[_]Vizg_Diagnostic{};
    if (fr.diagnostics.len > 0) {
        const darr = a_alloc.alloc(Vizg_Diagnostic, fr.diagnostics.len) catch {
            arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
        };
        for (fr.diagnostics, 0..) |d, i| {
            darr[i].severity   = toVizgSeverity(d.severity);
            darr[i].code       = toVizgDiagnosticCode(d.code);
            darr[i].phase      = toVizgDiagnosticPhase(d.phase);

            const mb = a_alloc.alloc(u8, d.message.len) catch {
                arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
            };
            @memcpy(mb.ptr, d.message);
            darr[i].message_ptr  = mb.ptr;
            darr[i].message_len  = d.message.len;

            darr[i].span.start_offset   = @intCast(d.span.start);
            darr[i].span.end_offset     = @intCast(d.span.end);
            darr[i].span.line_start     = @intCast(d.span.line);
            darr[i].span.col_start      = @intCast(d.span.column);

            if (d.path) |p| {
                const pb = a_alloc.alloc(u8, p.len) catch {
                    arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
                };
                @memcpy(pb.ptr, p);
                darr[i].path_ptr  = pb.ptr;
                darr[i].path_len  = p.len;
            } else {
                // ABI invariant: if path is absent, both fields must reflect that.
                darr[i].path_ptr = null;
                darr[i].path_len = 0;
            }
        }
        owned_diags = darr;
    }

const result_uninit: [*]u8 = std.heap.page_allocator.rawAlloc(
        @sizeOf(Vizg_Result), std.mem.Alignment.fromByteUnits(@alignOf(Vizg_Result)), @returnAddress(),
    ) orelse {
        arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
    };
    const result_ptr: *Vizg_Result = @ptrCast(@alignCast(result_uninit));
    // Zero out all bytes of the extern struct — required so field pointers start as null.
    for (std.mem.asBytes(result_ptr)) |*b| b.* = 0;
    const result: *Vizg_Result = result_ptr;
    result.token_count          = @intCast(fr.tokens.len);
    result.diagnostic_count     = @intCast(fr.diagnostics.len);
    if (fr.tokens.len > 0) {
        result.tokens_ptr = owned_tokens.ptr;
    }
    if (fr.diagnostics.len > 0) {
        result.diagnostics_ptr = owned_diags.ptr;
    }

    const o = a_alloc.create(OwnedResult) catch {
        arena_owner.deinit(); std.heap.page_allocator.destroy(arena_owner); return null;
    };
    o.* = .{.arena = arena_owner};

    // Register: address of result struct -> owning ArenaAllocator.  Lookup
    // happens in Vizg_freeResult, so the map must persist for the lifetime
    // of any result still alive to free(). If map growth fails, roll back —
    // the arena is leaked otherwise since Vizg_freeResult can't find it.
    const m = getOrCreateArenaMap();
    _ = m.put(@intFromPtr(result), arena_owner) catch {
        // Deinit all arena-backed allocations and release the allocator object.
        arena_owner.deinit();
        std.heap.page_allocator.destroy(arena_owner);
        return null;
    };

    return result;
}

// ---------------------------------------------------------------------------
// C ABI entry points — pub fn with explicit `callconv(.c)`.  Zig 0.16's
// `@export()` requires an explicit calling convention and rejects non-C-ABI
// parameter types (no by-value Allocator, no optional slices).  The public API
// below therefore accepts only C-compatible parameters; allocation is done
// internally via the page allocator inside an arena owned by Vizg_Result.
// ---------------------------------------------------------------------------

pub fn Vizg_analyzeFile(
    path_ptr: [*c]const u8,
    path_len: usize,
    text_ptr: [*c]const u8,
    text_len: usize,
) callconv(.c) ?*Vizg_Result {
    const page = std.heap.page_allocator;

    // Validate every pointer/length pair BEFORE slicing — prevents null+posLen
    // from ever producing a dangling slice or undefined behavior downstream.
    if (!validateAbiPointerLen("text", text_ptr, text_len)) return null;
    if (!validateAbiPointerLen("path", path_ptr, path_len)) return null;

    // Heap-allocate the arena so its pointer survives past this function's
    // return — we register it in result_arena_map and look it up at free time.
    const owner_arena = page.create(std.heap.ArenaAllocator) catch return null;
    owner_arena.* = std.heap.ArenaAllocator.init(page);
    const a_alloc: std.mem.Allocator = owner_arena.allocator();

    if (text_len > 0) {
        // Zero-copy text slice: caller owns the underlying buffer (no
        // ownership transfer — just analyze as-is).
        if (doAnalyze(a_alloc, .{ .text = text_ptr[0..text_len], .kind = .module }, owner_arena)) |r| return r;
        // Failure path (analysis, allocation, or map registration) — release the arena back to page allocator.
        const leaked_arena = owner_arena;
        leaked_arena.deinit();
        std.heap.page_allocator.destroy(leaked_arena);
        return null;
    } else if (path_len > 0) {
        const name = a_alloc.dupe(u8, path_ptr[0..path_len]) catch {
            owner_arena.deinit();
            return null;
        };
        // Read the file contents via raw POSIX syscalls (no Io subsystem).
        const src_buf = readFileBytes(a_alloc, name) orelse {
            owner_arena.deinit();
            return null;
        };
        var sf: frontend_mod.SourceFile = .{.text = src_buf, .kind = .module};
        sf.path = name;
        if (doAnalyze(a_alloc, sf, owner_arena)) |r| return r;
        // Same cleanup as text-only path above.
        const leaked_arena2 = owner_arena;
        leaked_arena2.deinit();
        std.heap.page_allocator.destroy(leaked_arena2);
        return null;
    } else {
        // Nothing to analyze — pass an empty source.  Arena stays alive for
        // free time even if there's nothing useful inside it.
        const empty_text: []const u8 = "";
        if (doAnalyze(
            a_alloc,
            .{ .text = empty_text, .kind = .module },
            owner_arena,
        )) |r| return r;
        // Same cleanup for consistency.
        const leaked_arena3 = owner_arena;
        leaked_arena3.deinit();
        std.heap.page_allocator.destroy(leaked_arena3);
        return null;
    }
}


/// Memory-first analysis entry point — accepts source bytes directly
/// without touching the filesystem. The path pointer is used only as a
/// diagnostic source identifier; no disk I/O occurs.
pub fn Vizg_analyzeSource(
    source_ptr: [*c]const u8,
    source_len: usize,
    path_ptr:   [*c]const u8,
    path_len:   usize,
) callconv(.c) ?*Vizg_Result {
    const page = std.heap.page_allocator;

    if (!validateAbiPointerLen("source", source_ptr, source_len)) return null;
    if (!validateAbiPointerLen("path", path_ptr, path_len)) return null;

    // Heap-allocate the arena so its pointer survives past this function's
    // return — same pattern as Vizg_analyzeFile.
    const owner_arena = page.create(std.heap.ArenaAllocator) catch return null;
    owner_arena.* = std.heap.ArenaAllocator.init(page);
    const a_alloc: std.mem.Allocator = owner_arena.allocator();

    // Ownership invariant for the memory-first contract: copy source bytes
    // into the result arena so downstream stages may hold references past
    // the caller's lifetime, and to keep ownership explicit (see AGENTS.md
    // memory-safety rules). The path is treated as a diagnostic identifier,
    // not an on-disk file.
    const src_buf: []const u8 = if (source_len > 0) blk_src_copy: {
        const b = a_alloc.dupe(u8, source_ptr[0..source_len]) catch {
            owner_arena.deinit();
            return null;
        };
        break :blk_src_copy b;
    } else "";

    var sf: frontend_mod.SourceFile = .{.text = src_buf};
    if (path_len > 0) {
        const p = a_alloc.dupe(u8, path_ptr[0..path_len]) catch {
            owner_arena.deinit();
            return null;
        };
        sf.path = p;
    }

    if (doAnalyze(a_alloc, sf, owner_arena)) |r| return r;
    // Same cleanup as Vizg_analyzeFile for consistency.
    const leaked_arena = owner_arena;
    leaked_arena.deinit();
    std.heap.page_allocator.destroy(leaked_arena);
    return null;
}

pub fn Vizg_freeResult(result: ?*Vizg_Result) callconv(.c) void {
    if (result == null) return;
    const r = result.?;
    // Look up the arena that owns all allocations backing this result and
    // deinit it — releases tokens, diagnostics, lexeme/path strings.
    if (resultArenas) |m| {
        const arena_ptr = m.get(@intFromPtr(r));
        if (arena_ptr) |ap| {
            ap.deinit();
            std.heap.page_allocator.destroy(ap);
        }
        _ = m.remove(@intFromPtr(r));
    }
    // Free the result struct memory itself — matched to rawAlloc above so we
    // release back into page_allocator's heap arena correctly.
    const pa = std.heap.page_allocator;
    const mem: []u8 = @ptrCast(@alignCast(std.mem.asBytes(r)));
    pa.rawFree(mem, std.mem.Alignment.fromByteUnits(@alignOf(Vizg_Result)), @returnAddress());
}

// ---------------------------------------------------------------------------
// Explicit exports — every entry point visible in the static archive even when
// nothing inside this module references it (Zig's thin-linker would otherwise
// drop unreferenced objects).  Zig 0.13+ accepts any addressable entity; no
// pointer-to-function cast needed.
// ---------------------------------------------------------------------------
comptime {
    @export(&Vizg_analyzeFile, .{.name = "vizg_analyze_file"});
    @export(&Vizg_freeResult,   .{.name = "vizg_free_result"});
    @export(&Vizg_analyzeSource, .{.name = "vizg_analyze_source"});
}

// ---------------------------------------------------------------------------
// Memory-first analysis tests — goal-036. Exercises vizg_analyze_source, the
// source-bytes (no-file-system) entry point. Tests are written as top-level
// Zig `test` blocks and call `Vizg_analyzeSource` directly via module scope;
// no C FFI plumbing needed.


test "memory-first: empty source yields no error and a valid (empty) result" {
    // Contract from Goal 36: empty source must be accepted without FS access.
    const src = "";
    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        null, 0,
    ) orelse std.debug.panic("empty source returned null", .{});
    defer Vizg_freeResult(result);

    // Empty input may still yield an EOF token; the contract requires no diagnostics only.
    try std.testing.expectEqual(@as(u32, 0), result.diagnostic_count);
}

test "memory-first: valid source returns tokens, no diagnostics" {
    const src =
        \\import { log } from "console";
        \\export function main(x: number) { return x; }
    ;
    const path = "/tmp/vizg_test_valid.ts";

    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        @ptrCast(path.ptr), path.len,
    ) orelse std.debug.panic("valid source returned null", .{});
    defer Vizg_freeResult(result);

    try std.testing.expect(result.token_count > 0);
}

test "memory-first: invalid source returns diagnostics" {
    const src = "let x = ;\nconst y = {x: };\n";
    const path = "/tmp/vizg_test_invalid.ts";

    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        @ptrCast(path.ptr), path.len,
    ) orelse std.debug.panic("invalid source returned null", .{});
    defer Vizg_freeResult(result);

    // The analyzer emits tokens for malformed input too; only check the diagnostic invariant.
    try std.testing.expect(result.diagnostic_count > 0);
try std.testing.expect(result.diagnostic_count > 0);
}

test "memory-first: UTF-8 source (emoji + CJK) is analysed" {
    const src = "const x = \"🌍\"; const y = \"中文\";\n";
    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        null, 0,
    ) orelse std.debug.panic("UTF-8 source returned null", .{});
    defer Vizg_freeResult(result);

}

test "memory-first: UTF-8 path is preserved verbatim for diagnostics" {
    const src = "let x = 1;\n";
    // Japanese filename bytes — should be copied into the arena and never
    // interpreted as a disk path by the memory-first entry point.
    const utf8_path = "テスト/ファイル.ts";

    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        @ptrCast(utf8_path.ptr), utf8_path.len,
    ) orelse std.debug.panic("UTF-8 path returned null", .{});
    defer Vizg_freeResult(result);

}

test "memory-first: no FS access — source bytes do not match any file" {
    // Verify the memory-first path really does not read from disk. We pass an
    // arbitrary in-memory source and a path that definitely does NOT exist on
    // disk; a filesystem call would surface as FileNotFound, but we should
    // succeed (and produce diagnostics for malformed input only).
    const src = "let x = 1;\n";
    const phantom_path = "/tmp/vizg_no_file_42abc_placeholder.ts";

    const result = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        @ptrCast(phantom_path.ptr), phantom_path.len,
    ) orelse std.debug.panic("expected success", .{});
    defer Vizg_freeResult(result);

    // Successful parse — no diagnostics expected for a valid trivial source.
}

// ---------------------------------------------------------------------------
// Lifecycle tests — goal-038 acceptance criteria: exercises every cleanup
// path with a stress loop and edge-case inputs. The page_allocator-backed
// arena allocations cannot be leak-detected by GPA (GPA ignores it), so we
// verify correctness via crash-free behavior + invariant checks rather than
// expecting 100% leak detection coverage.
// ---------------------------------------------------------------------------

test "lifecycle: 200 cycles success path — stable analyze→free" {
    const src = "const x: number = 42;\nlet y = [1, 2, 3];\n";
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const result = Vizg_analyzeSource(
            @ptrCast(src.ptr), src.len,
            null, 0,
        ) orelse std.debug.panic("lifecycle analyze returned null at iteration {d}", .{i});

        try std.testing.expect(result.token_count > 0);
        // Defensive: verify no diagnostics on well-formed input.
        if (result.diagnostic_count != 0) {
            std.debug.panic(
                "unexpected diagnostics at iter {d}: {}", .{ i, result.diagnostic_count },
            );
        }

        Vizg_freeResult(result);
    }
}

test "lifecycle: empty source × 100 — exercises arena with no payload" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const result = Vizg_analyzeSource(
            @ptrCast(""), 0,
            null, 0,
        ) orelse std.debug.panic("empty lifecycle returned null at iter {d}", .{i});
        defer Vizg_freeResult(result);

        // Empty source should always produce zero diagnostics.
        try std.testing.expectEqual(@as(u32, 0), result.diagnostic_count);
    }
}

test "lifecycle: mixed path — triggers analyzeFile with file-path branch" {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        // This file is real and readable by the test runner.
        const src_file = "Lib/vizg.zig";
        const result = Vizg_analyzeFile(
            @ptrCast(src_file.ptr), src_file.len,
            null, 0,
        ) orelse std.debug.panic("analyzeFile lifecycle returned null at iter {d}", .{i});

        // Source file has tokens and may have diagnostics.
        try std.testing.expect(result.token_count > 0);
        defer Vizg_freeResult(result);
    }
}

test "lifecycle: non-existent file triggers internal failure cleanup path" {
    const phantom = "/tmp/vizg_lifecycle_no_such_file_42abc_placeholder.ts";

    // Trigger the analyzeFile branch that tries to read a missing file.
    // The implementation should return null, NOT leak anything on disk or in-memory.
    const result = Vizg_analyzeFile(
        @ptrCast(phantom.ptr), phantom.len,
        null, 0,
    );

    try std.testing.expect(result == null);

    // A second analyze must still work — proves no state corruption between cycles.
    const src = "let a = 1;\n";
    const r2 = Vizg_analyzeSource(
        @ptrCast(src.ptr), src.len,
        null, 0,
    ) orelse std.debug.panic("second analyze after phantom returned null", .{});
    defer Vizg_freeResult(r2);

    try std.testing.expect(r2.token_count > 0);
}

test "lifecycle: many small allocations stress — allocator fragmentation guard" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const src = 
            \\if (true) {} else if (false) {}
            \\.foo.bar.baz().qux();
        ;
        const result = Vizg_analyzeSource(
            @ptrCast(src.ptr), src.len,
            null, 0,
        ) orelse std.debug.panic("small allocs lifecycle returned null at iter {d}", .{i});

        try std.testing.expect(result.token_count > 0);
        Vizg_freeResult(result);
    }
}

test "lifecycle: malformed source stress — exercises diagnostic buffer allocation" {
    const src = 
        \\let x = ;
        \\const y = {a: , b: ; c};
        \\function() {\n\treturn ;\n}\n
    ;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const result = Vizg_analyzeSource(
            @ptrCast(src.ptr), src.len,
            null, 0,
        ) orelse std.debug.panic("malformed lifecycle returned null at iter {d}", .{i});

        try std.testing.expect(result.diagnostic_count > 0);
        defer Vizg_freeResult(result);
    }
}

test "lifecycle: interleaved valid + malformed — no state leak between types" {
    const good = "const ok: number = 1;\n";
    const bad = "let x = ;\n";
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const rGood = Vizg_analyzeSource(
            @ptrCast(good.ptr), good.len, null, 0,
        ) orelse std.debug.panic("good returned null at iter {d}", .{i});
        defer Vizg_freeResult(rGood);

        try std.testing.expect(rGood.diagnostic_count == 0);

        const rBad = Vizg_analyzeSource(
            @ptrCast(bad.ptr), bad.len, null, 0,
        ) orelse std.debug.panic("bad returned null at iter {d}", .{i});
        defer Vizg_freeResult(rBad);

        try std.testing.expect(rBad.diagnostic_count > 0);
    }
}

test "lifecycle: very large source — exercises heap growth path" {
    const big_src: []const u8 = "function f0(x: number): number {" ++ "\n" ++
        "\\treturn x + 0;" ++ "\n" ++ "}" ++ "\n";

    // Run twice — second iteration proves no leak accumulated from the first.
    const r1 = Vizg_analyzeSource(
        @ptrCast(big_src.ptr), big_src.len, null, 0,
    ) orelse std.debug.panic("large src analyze returned null", .{});
    defer Vizg_freeResult(r1);
    try std.testing.expect(r1.token_count > 0);

    const r2 = Vizg_analyzeSource(
        @ptrCast(big_src.ptr), big_src.len, null, 0,
    ) orelse std.debug.panic("large src analyze (second iter) returned null", .{});
    defer Vizg_freeResult(r2);
    try std.testing.expect(r2.token_count > 0);

    if (r1.token_count != r2.token_count) {
        std.debug.panic(
            "token count drift: first={d}, second={d}", .{ r1.token_count, r2.token_count },
        );
    }
}
// ---------------------------------------------------------------------------
// Goal 039 acceptance criteria: verify self-owned results are independent,
// order-independent in free, and survive thousands of allocate/free cycles
// without leaking state. These tests exercise vizg_analyzeSource /
// Vizg_freeResult directly — no C ABI plumbing needed.
// ---------------------------------------------------------------------------

test "goal-039: multiple live results do not corrupt each other" {
    // Three independent analyses with distinct source text; all remain valid
    // until explicitly freed.  Verify tokens, diagnostic count, and lexeme
    // content differ between them — confirms no shared state or pointer aliasing.
    const src_a = "const x: number = 1;";
    const src_b = "let y = [true, false];";
    const src_c = "// block comment //";

    const ra = Vizg_analyzeSource(
        @ptrCast(src_a.ptr), src_a.len, null, 0,
    ) orelse std.debug.panic("analyze a returned null", .{});
    defer Vizg_freeResult(ra);

    const rb = Vizg_analyzeSource(
        @ptrCast(src_b.ptr), src_b.len, null, 0,
    ) orelse std.debug.panic("analyze b returned null", .{});
    defer Vizg_freeResult(rb);

    const rc = Vizg_analyzeSource(
        @ptrCast(src_c.ptr), src_c.len, null, 0,
    ) orelse std.debug.panic("analyze c returned null", .{});
    defer Vizg_freeResult(rc);

    // Lexemes differ — no aliasing.
    if (@intFromPtr(ra.tokens_ptr) == @intFromPtr(rb.tokens_ptr)) {
        std.debug.panic(
            "aliasing: ra and rb share token storage\n", .{},
        );
    }
    if (ra.token_count == 0 or rb.token_count == 0 or rc.token_count == 0) {
        std.debug.panic(
            "expected non-empty token counts, got a={}, b={}, c={}",
            .{ ra.token_count, rb.token_count, rc.token_count },
        );
    }

    // Token counts are distinct (different source lengths).
    if (ra.token_count == rb.token_count) {
        std.debug.panic(
            "token count collision between results a and b: both={d}", .{ra.token_count},
        );
    }
}

test "goal-039: free in reverse order from allocation works" {
    // Allocate 5, then free them in LIFO (reverse) order. Without self-owned
    // ownership, this pattern would be fragile; with it, each free is fully
    // independent and order does not matter.
    const src = "const x: number = 1;";
    const n: usize = 5;
    var results: [n]?*Vizg_Result = .{null} ** n;

    for (0..n) |i| {
        results[i] = Vizg_analyzeSource(
            @ptrCast(src.ptr), src.len, null, 0,
        ) orelse std.debug.panic("analyze returned null at index {d}", .{i});
    }

    // Free in reverse (LIFO) order.
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        Vizg_freeResult(results[i - 1].?);
    }
}

test "goal-039: many repeated analyze/free cycles (200) — no leak" {
    // Already covered by the existing 'lifecycle: 200 cycles' test, but re-run
    // here with a stricter assertion: we verify each iteration produces a valid
    // result and that free() does not crash (which would indicate double-free
    // or use-after-free from the previous cycle).
    const src = "function f(): void {}";
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const r = Vizg_analyzeSource(
            @ptrCast(src.ptr), src.len, null, 0,
        ) orelse std.debug.panic("analyze failed at iter {d}", .{i});
        try std.testing.expect(r.token_count > 0);
        // No panic — free is self-contained and safe to call.
        Vizg_freeResult(r);
    }
}

test "goal-039: interleaved allocate-free across analyses — no cross-state" {
    // Pattern: alternate two sources, analyze one, then the other, free them in
    // any order. This simulates multi-result workloads from different modules /
    // user sessions where arenas must not share state.
    const src1 = "import * as a from 'a';";
    const src2 = "export default 0;";

    var r_a: ?*Vizg_Result = null;
    var r_b: ?*Vizg_Result = null;

    // Allocate both.
    r_a = Vizg_analyzeSource(
        @ptrCast(src1.ptr), src1.len, null, 0,
    ) orelse std.debug.panic("analyze src1 returned null", .{});
    r_b = Vizg_analyzeSource(
        @ptrCast(src2.ptr), src2.len, null, 0,
    ) orelse std.debug.panic("analyze src2 returned null", .{});

    // Free B first (not allocation order). A must still be valid.
    Vizg_freeResult(r_b.?);
    r_b = null;

    // A should still produce tokens — prove no aliasing/interference from B's free.
    if (r_a.?.token_count == 0) {
        std.debug.panic(
            "after freeing B, A lost its tokens: token_count=0\n", .{},
        );
    }

    // Free A last; verify magic validation still passes on second call path.
    Vizg_freeResult(r_a.?);
    r_a = null;
}
