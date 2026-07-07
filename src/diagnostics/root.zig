const tokens = @import("../frontend/tokens.zig");

pub const Severity = enum {
    @"error",
    warning,
    info,
    hint,
};

pub const DiagnosticCode = enum {
    invalid_character,
    unterminated_string,
    unterminated_block_comment,
    invalid_number,
    unexpected_token,
    expected_token,
    duplicate_declaration,
    duplicate_export,
    cannot_find_name,
    module_not_found,
    missing_export,
    circular_import,
    unknown_type_name,
    internal_error,
};

pub const DiagnosticPhase = enum {
    scanner,
    parser,
    binder,
    resolver,
    cfg,
    module_graph,
    type_checker,
    lowering,
    runtime,
    internal,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: DiagnosticCode,
    phase: DiagnosticPhase,
    message: []const u8,
    span: tokens.Span,
    label: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub fn lexicalErrorCode(err: tokens.LexicalError) DiagnosticCode {
    return switch (err) {
        error.UnknownCharacter => .invalid_character,
        error.UnterminatedComment => .unterminated_block_comment,
        error.UnterminatedString, error.UnterminatedTemplateString => .unterminated_string,
        error.InvalidNumberFormat,
        error.InvalidExponent,
        error.InvalidNumericSeparator,
        => .invalid_number,
        else => .unexpected_token,
    };
}

pub fn lexicalErrorMessage(err: tokens.LexicalError) []const u8 {
    return switch (err) {
        error.UnknownCharacter => "unknown character",
        error.UnterminatedComment => "unterminated comment",
        error.UnterminatedString, error.UnterminatedTemplateString => "unterminated string",
        error.InvalidNumberFormat => "invalid number",
        error.InvalidExponent => "invalid exponent",
        error.InvalidNumericSeparator => "invalid numeric separator",
        else => "lexical error",
    };
}

pub fn diagnosticCodeId(code: DiagnosticCode) []const u8 {
    return switch (code) {
        .invalid_character => "VZG1001",
        .unterminated_string => "VZG1002",
        .unterminated_block_comment => "VZG1003",
        .invalid_number => "VZG1004",
        .unexpected_token => "VZG2001",
        .expected_token => "VZG2002",
        .duplicate_declaration => "VZG3001",
        .duplicate_export => "VZG3002",
        .cannot_find_name => "VZG4001",
        .module_not_found => "VZG5001",
        .missing_export => "VZG5002",
        .circular_import => "VZG5003",
        .unknown_type_name => "VZG6004",
        .internal_error => "VZG9001",
    };
}

pub fn diagnosticCodeName(code: DiagnosticCode) []const u8 {
    return switch (code) {
        .invalid_character => "invalid_character",
        .unterminated_string => "unterminated_string",
        .unterminated_block_comment => "unterminated_block_comment",
        .invalid_number => "invalid_number",
        .unexpected_token => "unexpected_token",
        .expected_token => "expected_token",
        .duplicate_declaration => "duplicate_declaration",
        .duplicate_export => "duplicate_export",
        .cannot_find_name => "cannot_find_name",
        .module_not_found => "module_not_found",
        .missing_export => "missing_export",
        .circular_import => "circular_import",
        .unknown_type_name => "unknown_type_name",
        .internal_error => "internal_error",
    };
}
