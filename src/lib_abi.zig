// src/lib_abi.zig — Minimal C ABI for vizg (static library surface).

pub const Vizg_Status = enum(c_int) {
    OK = 0,
    INVALID_ARGUMENT,
    IO_ERROR,
    OUT_OF_MEMORY,
    INTERNAL_ERROR,
    FILE_TOO_LARGE,
};
pub const VIZG_STATUS_OK: Vizg_Status = .OK;

pub const Vizg_Severity = enum(c_int) { Error = 0, Warning, Info, Hint };
pub const Vizg_DiagnosticCode = enum(c_int) {
    InvalidCharacter = 0, UnterminatedString, UnterminatedBlockComment,
    InvalidNumber, UnexpectedToken, ExpectedToken, DuplicateDeclaration,
    DuplicateExport, CannotFindName, ModuleNotFound, MissingExport,
    CircularImport, UnknownTypeName, TypeMismatch, ParseRecursionLimitReached,
    InvalidEscapeSequence = 15,
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
    has_escape:             u8 = 0,
    unterminated:           u8 = 0,
    synthetic:              u8 = 0,
};

pub const Vizg_Diagnostic = extern struct {
    severity:        Vizg_Severity,
    code:            Vizg_DiagnosticCode,
    phase:           Vizg_DiagnosticPhase,
    span:            Vizg_Span,
    lexeme_ptr:      [*c]const u8,
    message_ptr:     [*c]const u8,
};

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
    Punctuator_Plus, Punctuator_Minus, Punctuator_Star, Punctuator_Slash,
    Punctuator_Percent, Punctuator_Power, Punctuator_DotDot,
    Punctuator_LessThanLessThan, Punctuator_GreaterThanGreaterThan,
    Punctuator_GreaterThanGreaterThanGreaterThan, Punctuator_Ampersand,
    Punctuator_Pipe, Punctuator_Caret, Assign, Assign_Plus, Assign_Minus,
    Assign_Star, Assign_Slash, Assign_Percent, Assign_Power,
    Assign_LessThanLessThan, Assign_GreaterThanGreaterThan, Assign_AmpAmp,
    Assign_PipePipe, EndOfFile,
};

pub const Vizg_Token = extern struct {
    kind:   Vizg_TokenType,
    span:   Vizg_Span,
    lexeme_ptr: [*c]const u8,
    lexeme_len: usize,
};

pub const Vizg_Result = extern struct {
    token_count:        c_uint,
    diagnostic_count:   c_uint,
    tokens_ptr:         [*c]Vizg_Token,
    diagnostics_ptr:    [*c]Vizg_Diagnostic,
    source_path_len:    usize,
};

pub const Vizg_SourceInput = extern struct {
    text_ptr: [*c]const u8,
    text_len: usize,
    path_ptr: [*c]const u8,
    path_len: usize,
};
