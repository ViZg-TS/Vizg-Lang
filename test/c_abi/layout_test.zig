const std = @import("std");
const abi = @import("vizg-abi");

extern fn vizg_c_sizeof_Vizg_Result() usize;
extern fn vizg_c_alignof_Vizg_Result() usize;
extern fn vizg_c_offsetof_Vizg_Result_token_count() usize;
extern fn vizg_c_offsetof_Vizg_Result_diagnostic_count() usize;
extern fn vizg_c_offsetof_Vizg_Result_tokens_ptr() usize;
extern fn vizg_c_offsetof_Vizg_Result_diagnostics_ptr() usize;

extern fn vizg_c_sizeof_Vizg_Span() usize;
extern fn vizg_c_alignof_Vizg_Span() usize;
extern fn vizg_c_offsetof_Vizg_Span_start_offset() usize;
extern fn vizg_c_offsetof_Vizg_Span_end_offset() usize;
extern fn vizg_c_offsetof_Vizg_Span_line_start() usize;
extern fn vizg_c_offsetof_Vizg_Span_col_start() usize;

extern fn vizg_c_sizeof_Vizg_Diagnostic() usize;
extern fn vizg_c_alignof_Vizg_Diagnostic() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_severity() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_code() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_phase() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_message_ptr() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_message_len() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_span() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_path_ptr() usize;
extern fn vizg_c_offsetof_Vizg_Diagnostic_path_len() usize;

extern fn vizg_c_sizeof_Vizg_Token() usize;
extern fn vizg_c_alignof_Vizg_Token() usize;
extern fn vizg_c_offsetof_Vizg_Token_kind() usize;
extern fn vizg_c_offsetof_Vizg_Token_span() usize;
extern fn vizg_c_offsetof_Vizg_Token_lexeme_ptr() usize;
extern fn vizg_c_offsetof_Vizg_Token_lexeme_len() usize;
extern fn vizg_c_offsetof_Vizg_Token_contextual_kind() usize;

extern fn vizg_c_sizeof_Vizg_SourceInput() usize;
extern fn vizg_c_alignof_Vizg_SourceInput() usize;
extern fn vizg_c_offsetof_Vizg_SourceInput_text_ptr() usize;
extern fn vizg_c_offsetof_Vizg_SourceInput_text_len() usize;
extern fn vizg_c_offsetof_Vizg_SourceInput_path_ptr() usize;
extern fn vizg_c_offsetof_Vizg_SourceInput_path_len() usize;

extern fn vizg_c_sizeof_Vizg_Severity() usize;
extern fn vizg_c_alignof_Vizg_Severity() usize;
extern fn vizg_c_sizeof_Vizg_DiagnosticCode() usize;
extern fn vizg_c_alignof_Vizg_DiagnosticCode() usize;
extern fn vizg_c_sizeof_Vizg_DiagnosticPhase() usize;
extern fn vizg_c_alignof_Vizg_DiagnosticPhase() usize;
extern fn vizg_c_sizeof_Vizg_TokenType() usize;
extern fn vizg_c_alignof_Vizg_TokenType() usize;
extern fn vizg_c_sizeof_Vizg_ContextualKeyword() usize;
extern fn vizg_c_alignof_Vizg_ContextualKeyword() usize;
extern fn vizg_c_sizeof_Vizg_Status() usize;
extern fn vizg_c_alignof_Vizg_Status() usize;

extern fn vizg_c_value_severity_hint() c_int;
extern fn vizg_c_value_diag_invalid_escape() c_int;
extern fn vizg_c_value_phase_internal() c_int;
extern fn vizg_c_value_token_invalid() c_int;
extern fn vizg_c_value_token_identifier() c_int;
extern fn vizg_c_value_token_finally() c_int;
extern fn vizg_c_value_token_eof() c_int;
extern fn vizg_c_value_contextual_none() c_int;
extern fn vizg_c_value_contextual_as() c_int;
extern fn vizg_c_value_contextual_get() c_int;
extern fn vizg_c_value_status_ok() c_int;
extern fn vizg_c_value_status_file_too_large() c_int;

fn expectLayout(comptime T: type, c_size: usize, c_align: usize) !void {
    try std.testing.expectEqual(@sizeOf(T), c_size);
    try std.testing.expectEqual(@alignOf(T), c_align);
}

test "C and Zig public struct layouts match" {
    try expectLayout(abi.Vizg_Result, vizg_c_sizeof_Vizg_Result(), vizg_c_alignof_Vizg_Result());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Result, "token_count"), vizg_c_offsetof_Vizg_Result_token_count());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Result, "diagnostic_count"), vizg_c_offsetof_Vizg_Result_diagnostic_count());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Result, "tokens_ptr"), vizg_c_offsetof_Vizg_Result_tokens_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Result, "diagnostics_ptr"), vizg_c_offsetof_Vizg_Result_diagnostics_ptr());

    try expectLayout(abi.Vizg_Span, vizg_c_sizeof_Vizg_Span(), vizg_c_alignof_Vizg_Span());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Span, "start_offset"), vizg_c_offsetof_Vizg_Span_start_offset());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Span, "end_offset"), vizg_c_offsetof_Vizg_Span_end_offset());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Span, "line_start"), vizg_c_offsetof_Vizg_Span_line_start());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Span, "col_start"), vizg_c_offsetof_Vizg_Span_col_start());

    try expectLayout(abi.Vizg_Diagnostic, vizg_c_sizeof_Vizg_Diagnostic(), vizg_c_alignof_Vizg_Diagnostic());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "severity"), vizg_c_offsetof_Vizg_Diagnostic_severity());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "code"), vizg_c_offsetof_Vizg_Diagnostic_code());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "phase"), vizg_c_offsetof_Vizg_Diagnostic_phase());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "message_ptr"), vizg_c_offsetof_Vizg_Diagnostic_message_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "message_len"), vizg_c_offsetof_Vizg_Diagnostic_message_len());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "span"), vizg_c_offsetof_Vizg_Diagnostic_span());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "path_ptr"), vizg_c_offsetof_Vizg_Diagnostic_path_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Diagnostic, "path_len"), vizg_c_offsetof_Vizg_Diagnostic_path_len());

    try expectLayout(abi.Vizg_Token, vizg_c_sizeof_Vizg_Token(), vizg_c_alignof_Vizg_Token());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Token, "kind"), vizg_c_offsetof_Vizg_Token_kind());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Token, "span"), vizg_c_offsetof_Vizg_Token_span());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Token, "lexeme_ptr"), vizg_c_offsetof_Vizg_Token_lexeme_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Token, "lexeme_len"), vizg_c_offsetof_Vizg_Token_lexeme_len());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_Token, "contextual_kind"), vizg_c_offsetof_Vizg_Token_contextual_kind());

    try expectLayout(abi.Vizg_SourceInput, vizg_c_sizeof_Vizg_SourceInput(), vizg_c_alignof_Vizg_SourceInput());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_SourceInput, "text_ptr"), vizg_c_offsetof_Vizg_SourceInput_text_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_SourceInput, "text_len"), vizg_c_offsetof_Vizg_SourceInput_text_len());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_SourceInput, "path_ptr"), vizg_c_offsetof_Vizg_SourceInput_path_ptr());
    try std.testing.expectEqual(@offsetOf(abi.Vizg_SourceInput, "path_len"), vizg_c_offsetof_Vizg_SourceInput_path_len());
}

test "C and Zig public enum representations and values match" {
    try expectLayout(abi.Vizg_Severity, vizg_c_sizeof_Vizg_Severity(), vizg_c_alignof_Vizg_Severity());
    try expectLayout(abi.Vizg_DiagnosticCode, vizg_c_sizeof_Vizg_DiagnosticCode(), vizg_c_alignof_Vizg_DiagnosticCode());
    try expectLayout(abi.Vizg_DiagnosticPhase, vizg_c_sizeof_Vizg_DiagnosticPhase(), vizg_c_alignof_Vizg_DiagnosticPhase());
    try expectLayout(abi.Vizg_TokenType, vizg_c_sizeof_Vizg_TokenType(), vizg_c_alignof_Vizg_TokenType());
    try expectLayout(c_int, vizg_c_sizeof_Vizg_ContextualKeyword(), vizg_c_alignof_Vizg_ContextualKeyword());
    try expectLayout(abi.Vizg_Status, vizg_c_sizeof_Vizg_Status(), vizg_c_alignof_Vizg_Status());

    try std.testing.expectEqual(@intFromEnum(abi.Vizg_Severity.Hint), vizg_c_value_severity_hint());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_DiagnosticCode.InvalidEscapeSequence), vizg_c_value_diag_invalid_escape());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_DiagnosticPhase.Internal), vizg_c_value_phase_internal());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_TokenType.Invalid), vizg_c_value_token_invalid());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_TokenType.Identifier), vizg_c_value_token_identifier());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_TokenType.Keyword_finally), vizg_c_value_token_finally());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_TokenType.EndOfFile), vizg_c_value_token_eof());
    try std.testing.expectEqual(@as(c_int, 0), vizg_c_value_contextual_none());
    try std.testing.expectEqual(@as(c_int, 1), vizg_c_value_contextual_as());
    try std.testing.expectEqual(@as(c_int, 43), vizg_c_value_contextual_get());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_Status.OK), vizg_c_value_status_ok());
    try std.testing.expectEqual(@intFromEnum(abi.Vizg_Status.FILE_TOO_LARGE), vizg_c_value_status_file_too_large());
}
