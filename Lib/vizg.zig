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

pub const Vizg_Status = enum(c_int) { OK = 0, ERR_GENERIC, ERR_IO, ERR_PARSE };
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

/// Read a file into an arena-allocated buffer using raw POSIX syscalls.  We
/// cannot use `std.Io.Dir` without an Io instance (only available at startup),
/// and passing one through the C ABI would force users to also pass a Zig IO
/// handle, defeating the purpose of a minimal C interface.
fn readFileBytes(a_alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const AT_FDCWD: c_int = -100;
    const O_RDONLY: c_int = 0;

    var pbuf: [4096]u8 = undefined;
    if (path.len + 1 > pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;

    // pbuf is zero-terminated at index path.len; pass as [:0]u8 slice which coerces to [*:0]const u8.
    const c_path_slice: [:0]const u8 = pbuf[0 .. path.len + 1 : 0];
    const fd: c_int = openat(AT_FDCWD, @ptrCast(@alignCast(c_path_slice.ptr)), O_RDONLY);

    var st: Vizg_LinuxStat = undefined;
    if (fstat(fd, @ptrCast(@alignCast(&st))) != 0) { _ = c_close(fd); return null; }
    // File sizes are always non-negative; guard negative fstat output and
    // fall back on overflow beyond usize range (extremely unlikely in practice).
    if (st.st_size < 0) {
        _ = c_close(fd);
        return null;
    }
    const file_size: usize = @intCast(st.st_size);
    if (file_size > 64 * 1024 * 1024) { _ = c_close(fd); return null; } // 64 MiB hard cap.

    // Use catch to handle allocation failure inline.
    const alloc_result = (a_alloc.alloc(u8, file_size) catch |err| {
        _ = c_close(fd);
        if (err == error.OutOfMemory) return null;
        unreachable; // align is hard-coded so only OutOfMemory can arise.
    });
    var total_read: usize = 0;
    while (true) {
        const n = c_read(fd, alloc_result.ptr + total_read, file_size - total_read);
        if (n <= 0) { _ = c_close(fd); return null; }
        total_read += @intCast(n);
        if (total_read >= file_size) break;
    }
    _ = c_close(fd);
    return alloc_result;
}

// Map internal scanner token kinds onto the C-ABI Vizg_TokenType enum.
// The internal `tokens.TokenType` and the ABI `Vizg_TokenType` enums share
// names for most variants, but a handful of punctuators/operators differ -
// those are mapped explicitly below.
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
    const fr = frontend_mod.analyze(a_alloc, src_file, .{}) catch return null;

    var owned_tokens: []Vizg_Token = &[_]Vizg_Token{};
    if (fr.tokens.len > 0) {
        const arr = a_alloc.alloc(Vizg_Token, fr.tokens.len) catch return null;
        for (fr.tokens, 0..) |t, i| {
            arr[i].kind       = mapKind(t.kind);
            arr[i].span.start_offset    = @intCast(t.span.start);
            arr[i].span.end_offset      = @intCast(t.span.end);
            arr[i].span.line_start      = @intCast(t.span.line);
            arr[i].span.col_start       = @intCast(t.span.column);
            const lb = a_alloc.alloc(u8, t.lexeme.len) catch return null;
            @memcpy(lb.ptr, t.lexeme);
            arr[i].lexeme_ptr  = lb.ptr;
            arr[i].lexeme_len  = t.lexeme.len;
        }
        owned_tokens = arr;
    }

    var owned_diags: []Vizg_Diagnostic = &[_]Vizg_Diagnostic{};
    if (fr.diagnostics.len > 0) {
        const darr = a_alloc.alloc(Vizg_Diagnostic, fr.diagnostics.len) catch return null;
        for (fr.diagnostics, 0..) |d, i| {
            darr[i].severity   = toVizgSeverity(d.severity);
            darr[i].code       = toVizgDiagnosticCode(d.code);
            darr[i].phase      = toVizgDiagnosticPhase(d.phase);

            const mb = a_alloc.alloc(u8, d.message.len) catch return null;
            @memcpy(mb.ptr, d.message);
            darr[i].message_ptr  = mb.ptr;
            darr[i].message_len  = d.message.len;

            darr[i].span.start_offset   = @intCast(d.span.start);
            darr[i].span.end_offset     = @intCast(d.span.end);
            darr[i].span.line_start     = @intCast(d.span.line);
            darr[i].span.col_start      = @intCast(d.span.column);

            if (d.path) |p| {
                const pb = a_alloc.alloc(u8, p.len) catch return null;
                @memcpy(pb.ptr, p);
                darr[i].path_ptr  = pb.ptr;
                darr[i].path_len  = p.len;
            } else {
                // path_ptr == null implies path_len == 0 (ABI invariant).
                darr[i].path_ptr = null;
            }
        }
        owned_diags = darr;
    }

const result_uninit: [*]u8 = std.heap.page_allocator.rawAlloc(
        @sizeOf(Vizg_Result), std.mem.Alignment.fromByteUnits(@alignOf(Vizg_Result)), @returnAddress(),
    ) orelse return null;
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

    const o = a_alloc.create(OwnedResult) catch return null;
    o.* = .{.arena = arena_owner};

    // Register: address of result struct -> owning ArenaAllocator.  Lookup
    // happens in Vizg_freeResult, so the map must persist for the lifetime
    // of any result still alive to free().
    const m = getOrCreateArenaMap();
    _ = m.put(@intFromPtr(result), arena_owner) catch {};

    std.debug.print("registered result=0x{x} -> arena=0x{x}\n", .{@intFromPtr(result), @intFromPtr(arena_owner)});

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

    // Heap-allocate the arena so its pointer survives past this function's
    // return — we register it in result_arena_map and look it up at free time.
    const owner_arena = page.create(std.heap.ArenaAllocator) catch return null;
    owner_arena.* = std.heap.ArenaAllocator.init(page);
    const a_alloc: std.mem.Allocator = owner_arena.allocator();

    if (text_len > 0) {
        // Zero-copy text slice: caller owns the underlying buffer (no
        // ownership transfer — just analyze as-is).
        return doAnalyze(a_alloc, .{ .text = text_ptr[0..text_len], .kind = .module }, owner_arena);
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
        return doAnalyze(a_alloc, sf, owner_arena);
    } else {
        // Nothing to analyze — pass an empty source.  Arena stays alive for
        // free time even if there's nothing useful inside it.
        const empty_text: []const u8 = "";
        return doAnalyze(
            a_alloc,
            .{ .text = empty_text, .kind = .module },
            owner_arena,
        );
    }
}

pub fn Vizg_freeResult(result: ?*Vizg_Result) callconv(.c) void {
    if (result == null) return;
    const r = result.?;
    std.debug.print("freeResult called with r=0x{x}\n", .{@intFromPtr(r)});
    // Look up the arena that owns all allocations backing this result and
    // deinit it — releases tokens, diagnostics, lexeme/path strings.
    if (resultArenas) |m| {
        std.debug.print("  map has {} entries; lookup=0x{x}\n", .{ m.count(), @intFromPtr(r) });
        const arena_ptr = m.get(@intFromPtr(r));
        if (arena_ptr) |ap| {
            std.debug.print("  found arena at 0x{x}, deiniting\n", .{@intFromPtr(ap)});
            ap.deinit();
            std.debug.print("  deinit done\n", .{});
        } else {
            std.debug.print("  NO ENTRY for this result pointer!\n", .{});
        }
        _ = m.remove(@intFromPtr(r));
    } else {
        std.debug.print("  no map at all?!\n", .{});
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
}
