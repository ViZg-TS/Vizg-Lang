const std = @import("std");
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
    invalid_escape_sequence,
    unterminated_regexp,
    invalid_regexp,
    invalid_utf8,
    unexpected_token,
    expected_token,
    unsupported_syntax,
    unsupported_ts_syntax,
    unsupported_jsx,
    duplicate_declaration,
    duplicate_export,
    cannot_find_name,
    module_not_found,
    module_access_denied,
    module_host_failed,
    missing_export,
    circular_import,
    unknown_type_name,
    type_mismatch,
    unknown_property,
    invalid_index,
    invalid_argument_count,
    invalid_argument_type,
    parse_recursion_limit_reached,
    global_ambient_collision,
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
    related: []const RelatedSpan = &.{},
};

pub const RelatedSpan = struct {
    span: tokens.Span,
    message: []const u8,
};

/// A diagnostic collector that rejects the next entry before growing beyond
/// its configured logical limit. Callers can therefore propagate the stable
/// `DiagnosticLimitExceeded` error without first allocating the diagnostic or
/// any diagnostic-owned metadata.
pub const LimitedList = struct {
    values: std.ArrayList(Diagnostic) = .empty,
    max_items: usize = std.math.maxInt(usize),

    pub fn init(max_items: usize) LimitedList {
        return .{ .max_items = max_items };
    }

    pub fn len(self: *const LimitedList) usize {
        return self.values.items.len;
    }

    pub fn items(self: *const LimitedList) []const Diagnostic {
        return self.values.items;
    }

    pub fn mutableItems(self: *LimitedList) []Diagnostic {
        return self.values.items;
    }

    pub fn ensureUnusedCapacity(self: *const LimitedList, additions: usize) !void {
        const next = std.math.add(usize, self.values.items.len, additions) catch
            return error.DiagnosticLimitExceeded;
        if (next > self.max_items) return error.DiagnosticLimitExceeded;
    }

    pub fn append(self: *LimitedList, allocator: std.mem.Allocator, diagnostic: Diagnostic) !void {
        try self.ensureUnusedCapacity(1);
        try self.values.append(allocator, diagnostic);
    }

    pub fn appendSlice(self: *LimitedList, allocator: std.mem.Allocator, new_items: []const Diagnostic) !void {
        try self.ensureUnusedCapacity(new_items.len);
        try self.values.appendSlice(allocator, new_items);
    }

    pub fn toOwnedSlice(self: *LimitedList, allocator: std.mem.Allocator) ![]Diagnostic {
        return self.values.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *LimitedList, allocator: std.mem.Allocator) void {
        self.values.deinit(allocator);
        self.* = .{};
    }
};

pub fn lexicalErrorCode(err: tokens.LexicalError) DiagnosticCode {
    return switch (err) {
        error.UnknownCharacter => .invalid_character,
        error.InvalidUtf8 => .invalid_utf8,
        error.UnterminatedComment => .unterminated_block_comment,
        error.UnterminatedString, error.UnterminatedTemplateString => .unterminated_string,
        error.InvalidNumberFormat,
        error.InvalidExponent,
        error.InvalidNumericSeparator,
        => .invalid_number,
        error.InvalidEscapeSequence => .invalid_escape_sequence,
        error.UnterminatedRegExp => .unterminated_regexp,
        error.InvalidRegExp => .invalid_regexp,
        else => .unexpected_token,
    };
}

pub fn lexicalErrorMessage(err: tokens.LexicalError) []const u8 {
    return switch (err) {
        error.UnknownCharacter => "unknown character",
        error.InvalidUtf8 => "invalid UTF-8 source text",
        error.UnterminatedComment => "unterminated comment",
        error.UnterminatedString, error.UnterminatedTemplateString => "unterminated string",
        error.InvalidNumberFormat => "invalid number",
        error.InvalidExponent => "invalid exponent",
        error.InvalidNumericSeparator => "invalid numeric separator",
        error.InvalidEscapeSequence => "invalid escape sequence",
        error.UnterminatedRegExp => "unterminated regular expression literal",
        error.InvalidRegExp => "invalid regular expression flags",
        else => "lexical error",
    };
}

pub fn diagnosticCodeId(code: DiagnosticCode) []const u8 {
    return switch (code) {
        .invalid_character => "VZG1001",
        .unterminated_string => "VZG1002",
        .unterminated_block_comment => "VZG1003",
        .invalid_number => "VZG1004",
        .invalid_escape_sequence => "VZG1005",
        .unterminated_regexp => "VZG1006",
        .invalid_regexp => "VZG1007",
        .invalid_utf8 => "VZG1008",
        .unexpected_token => "VZG2001",
        .expected_token => "VZG2002",
        .unsupported_syntax => "VZG2004",
        .unsupported_ts_syntax => "VZG2005",
        .unsupported_jsx => "VZG2006",
        .duplicate_declaration => "VZG3001",
        .duplicate_export => "VZG3002",
        .cannot_find_name => "VZG4001",
        .module_not_found => "VZG5001",
        .module_access_denied => "VZG5004",
        .module_host_failed => "VZG5005",
        .missing_export => "VZG5002",
        .circular_import => "VZG5003",
        .unknown_type_name => "VZG6004",
        .type_mismatch => "VZG6005",
        .unknown_property => "VZG6006",
        .invalid_index => "VZG6007",
        .invalid_argument_count => "VZG6008",
        .invalid_argument_type => "VZG6009",
        .parse_recursion_limit_reached => "VZG2003",
        .global_ambient_collision => "VZG8001",
    };
}

pub fn diagnosticCodeName(code: DiagnosticCode) []const u8 {
    return switch (code) {
        .invalid_character => "invalid_character",
        .unterminated_string => "unterminated_string",
        .unterminated_block_comment => "unterminated_block_comment",
        .invalid_number => "invalid_number",
        .invalid_escape_sequence => "invalid_escape_sequence",
        .unterminated_regexp => "unterminated_regexp",
        .invalid_regexp => "invalid_regexp",
        .invalid_utf8 => "invalid_utf8",
        .unexpected_token => "unexpected_token",
        .expected_token => "expected_token",
        .unsupported_syntax => "unsupported_syntax",
        .unsupported_ts_syntax => "unsupported_ts_syntax",
        .unsupported_jsx => "unsupported_jsx",
        .duplicate_declaration => "duplicate_declaration",
        .duplicate_export => "duplicate_export",
        .cannot_find_name => "cannot_find_name",
        .module_not_found => "module_not_found",
        .module_access_denied => "module_access_denied",
        .module_host_failed => "module_host_failed",
        .missing_export => "missing_export",
        .circular_import => "circular_import",
        .unknown_type_name => "unknown_type_name",
        .type_mismatch => "type_mismatch",
        .unknown_property => "unknown_property",
        .invalid_index => "invalid_index",
        .invalid_argument_count => "invalid_argument_count",
        .invalid_argument_type => "invalid_argument_type",
        .parse_recursion_limit_reached => "parse_recursion_limit_reached",
        .global_ambient_collision => "global_ambient_collision",
    };
}
