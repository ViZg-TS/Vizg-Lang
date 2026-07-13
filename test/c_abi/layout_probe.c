#include "vizg.h"

#include <stddef.h>

#define VIZG_LAYOUT_TYPE(type)                       \
    size_t vizg_c_sizeof_##type(void) { return sizeof(type); } \
    size_t vizg_c_alignof_##type(void) { return _Alignof(type); }

#define VIZG_LAYOUT_FIELD(type, field) \
    size_t vizg_c_offsetof_##type##_##field(void) { return offsetof(type, field); }

VIZG_LAYOUT_TYPE(Vizg_Result)
VIZG_LAYOUT_FIELD(Vizg_Result, token_count)
VIZG_LAYOUT_FIELD(Vizg_Result, diagnostic_count)
VIZG_LAYOUT_FIELD(Vizg_Result, tokens_ptr)
VIZG_LAYOUT_FIELD(Vizg_Result, diagnostics_ptr)

VIZG_LAYOUT_TYPE(Vizg_Span)
VIZG_LAYOUT_FIELD(Vizg_Span, start_offset)
VIZG_LAYOUT_FIELD(Vizg_Span, end_offset)
VIZG_LAYOUT_FIELD(Vizg_Span, line_start)
VIZG_LAYOUT_FIELD(Vizg_Span, col_start)

VIZG_LAYOUT_TYPE(Vizg_Diagnostic)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, severity)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, code)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, phase)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, message_ptr)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, message_len)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, span)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, path_ptr)
VIZG_LAYOUT_FIELD(Vizg_Diagnostic, path_len)

VIZG_LAYOUT_TYPE(Vizg_Token)
VIZG_LAYOUT_FIELD(Vizg_Token, kind)
VIZG_LAYOUT_FIELD(Vizg_Token, span)
VIZG_LAYOUT_FIELD(Vizg_Token, lexeme_ptr)
VIZG_LAYOUT_FIELD(Vizg_Token, lexeme_len)
VIZG_LAYOUT_FIELD(Vizg_Token, contextual_kind)

VIZG_LAYOUT_TYPE(Vizg_SourceInput)
VIZG_LAYOUT_FIELD(Vizg_SourceInput, text_ptr)
VIZG_LAYOUT_FIELD(Vizg_SourceInput, text_len)
VIZG_LAYOUT_FIELD(Vizg_SourceInput, path_ptr)
VIZG_LAYOUT_FIELD(Vizg_SourceInput, path_len)

VIZG_LAYOUT_TYPE(Vizg_Severity)
VIZG_LAYOUT_TYPE(Vizg_DiagnosticCode)
VIZG_LAYOUT_TYPE(Vizg_DiagnosticPhase)
VIZG_LAYOUT_TYPE(Vizg_TokenType)
VIZG_LAYOUT_TYPE(Vizg_ContextualKeyword)
VIZG_LAYOUT_TYPE(Vizg_Status)

int vizg_c_value_severity_hint(void) { return VIZG_SEVERITY_HINT; }
int vizg_c_value_diag_invalid_escape(void) { return VIZG_DIAG_INVALID_ESCAPE_SEQUENCE; }
int vizg_c_value_diag_invalid_utf8(void) { return VIZG_DIAG_INVALID_UTF8; }
int vizg_c_value_diag_unsupported_syntax(void) { return VIZG_DIAG_UNSUPPORTED_SYNTAX; }
int vizg_c_value_diag_unsupported_ts_syntax(void) { return VIZG_DIAG_UNSUPPORTED_TS_SYNTAX; }
int vizg_c_value_diag_unsupported_jsx(void) { return VIZG_DIAG_UNSUPPORTED_JSX; }
int vizg_c_value_phase_internal(void) { return VIZG_PHASE_INTERNAL; }
int vizg_c_value_token_invalid(void) { return VIZG_TOKEN_INVALID; }
int vizg_c_value_token_identifier(void) { return VIZG_TOKEN_IDENTIFIER; }
int vizg_c_value_token_finally(void) { return VIZG_TOKEN_KEYWORD_FINALLY; }
int vizg_c_value_token_eof(void) { return VIZG_TOKEN_END_OF_FILE; }
int vizg_c_value_contextual_none(void) { return VIZG_CONTEXTUAL_KEYWORD_NONE; }
int vizg_c_value_contextual_as(void) { return VIZG_CONTEXTUAL_KEYWORD_AS; }
int vizg_c_value_contextual_get(void) { return VIZG_CONTEXTUAL_KEYWORD_GET; }
int vizg_c_value_status_ok(void) { return VIZG_STATUS_OK; }
int vizg_c_value_status_file_too_large(void) { return VIZG_STATUS_FILE_TOO_LARGE; }
