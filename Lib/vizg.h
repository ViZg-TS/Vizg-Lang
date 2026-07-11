#ifndef VIZG_H
#define VIZG_H

/* vizg — C ABI for the static library.  Include this from any C/C++ consumer
 * and link against libvizg.a (or platform equivalent). */

#include <stddef.h>
#include <stdint.h>

typedef struct Vizg_Result {
    uint32_t        token_count;
    uint32_t        diagnostic_count;
    const void     *tokens_ptr;
    const void     *diagnostics_ptr;
} Vizg_Result;

typedef struct Vizg_Span {
    uint32_t start_offset;
    uint32_t end_offset;
    uint32_t line_start;
    uint32_t col_start;
} Vizg_Span;

typedef enum {
    VIZG_SEVERITY_ERROR   = 0,
    VIZG_SEVERITY_WARNING = 1,
    VIZG_SEVERITY_INFO    = 2,
    VIZG_SEVERITY_HINT    = 3,
} Vizg_Severity;

typedef enum {
    VIZG_DIAG_INVALID_CHAR             = 0,
    VIZG_DIAG_UNTERMINATED_STRING      = 1,
    VIZG_DIAG_UNTERMINATED_BLOCK_COMMENT = 2,
    VIZG_DIAG_INVALID_NUMBER           = 3,
    VIZG_DIAG_UNEXPECTED_TOKEN         = 4,
    VIZG_DIAG_EXPECTED_TOKEN           = 5,
    VIZG_DIAG_DUPLICATE_DECLARATION    = 6,
    VIZG_DIAG_DUPLICATE_EXPORT         = 7,
    VIZG_DIAG_CANNOT_FIND_NAME         = 8,
    VIZG_DIAG_MODULE_NOT_FOUND         = 9,
    VIZG_DIAG_MISSING_EXPORT           = 10,
    VIZG_DIAG_CIRCULAR_IMPORT          = 11,
    VIZG_DIAG_UNKNOWN_TYPE_NAME        = 12,
    VIZG_DIAG_TYPE_MISMATCH            = 13,
    VIZG_DIAG_PARSE_RECURSION_LIMIT    = 14,
} Vizg_DiagnosticCode;

typedef enum {
    VIZG_PHASE_SCANNER      = 0,
    VIZG_PHASE_PARSER       = 1,
    VIZG_PHASE_BINDER       = 2,
    VIZG_PHASE_RESOLVER     = 3,
    VIZG_PHASE_CFG          = 4,
    VIZG_PHASE_MODULE_GRAPH = 5,
    VIZG_PHASE_TYPE_CHECKER = 6,
    VIZG_PHASE_LOWERING     = 7,
    VIZG_PHASE_RUNTIME      = 8,
    VIZG_PHASE_INTERNAL     = 9,
} Vizg_DiagnosticPhase;

typedef struct Vizg_Diagnostic {
    Vizg_Severity        severity;
    Vizg_DiagnosticCode  code;
    Vizg_DiagnosticPhase phase;
    const char          *message_ptr;
    size_t               message_len;
    Vizg_Span            span;
    const char          *path_ptr;
    size_t               path_len;
} Vizg_Diagnostic;

typedef enum {
    VIZG_TOKEN_INVALID = 0,
    VIZG_TOKEN_IDENTIFIER,
    VIZG_TOKEN_PRIVATE_IDENTIFIER,
    VIZG_TOKEN_NUMBER_LITERAL,
    VIZG_TOKEN_BIGINT_LITERAL,
    VIZG_TOKEN_STRING_LITERAL,
    VIZG_TOKEN_REGEX_LITERAL,
    VIZG_TOKEN_TRUE_LITERAL,
    VIZG_TOKEN_FALSE_LITERAL,
    VIZG_TOKEN_NULL_LITERAL,
    VIZG_TOKEN_NO_SUBSTITUTION_TEMPLATE,
    VIZG_TOKEN_TEMPLATE_HEAD,
    VIZG_TOKEN_TEMPLATE_MIDDLE,
    VIZG_TOKEN_TEMPLATE_TAIL,
    VIZG_TOKEN_SHEBANG,
    VIZG_TOKEN_LINE_COMMENT,
    VIZG_TOKEN_BLOCK_COMMENT,

    VIZG_TOKEN_KEYWORD_await = 17, VIZG_TOKEN_KEYWORD_break, VIZG_TOKEN_KEYWORD_case,
    VIZG_TOKEN_KEYWORD_catch, VIZG_TOKEN_KEYWORD_class, VIZG_TOKEN_KEYWORD_const,
    VIZG_TOKEN_KEYWORD_continue, VIZG_TOKEN_KEYWORD_debugger, VIZG_TOKEN_KEYWORD_default,
    VIZG_TOKEN_KEYWORD_delete, VIZG_TOKEN_KEYWORD_do, VIZG_TOKEN_KEYWORD_else,
    VIZG_TOKEN_KEYWORD_enum, VIZG_TOKEN_KEYWORD_export, VIZG_TOKEN_KEYWORD_extends,
    VIZG_TOKEN_KEYWORD_false, VIZG_TOKEN_KEYWORD_for, VIZG_TOKEN_KEYWORD_from,
    VIZG_TOKEN_KEYWORD_function, VIZG_TOKEN_KEYWORD_get, VIZG_TOKEN_KEYWORD_if,
    VIZG_TOKEN_KEYWORD_import, VIZG_TOKEN_KEYWORD_in, VIZG_TOKEN_KEYWORD_instanceof,
    VIZG_TOKEN_KEYWORD_let, VIZG_TOKEN_KEYWORD_new, VIZG_TOKEN_KEYWORD_null,
    VIZG_TOKEN_KEYWORD_of, VIZG_TOKEN_KEYWORD_set, VIZG_TOKEN_KEYWORD_static,
    VIZG_TOKEN_KEYWORD_super, VIZG_TOKEN_KEYWORD_switch, VIZG_TOKEN_KEYWORD_this,
    VIZG_TOKEN_KEYWORD_throw, VIZG_TOKEN_KEYWORD_true, VIZG_TOKEN_KEYWORD_try,
    VIZG_TOKEN_KEYWORD_typeof, VIZG_TOKEN_KEYWORD_undefined, VIZG_TOKEN_KEYWORD_var,
    VIZG_TOKEN_KEYWORD_void, VIZG_TOKEN_KEYWORD_while, VIZG_TOKEN_KEYWORD_with,

    VIZG_TOKEN_PUNCTUATOR_OPEN_PARENTHESIS = 53, VIZG_TOKEN_PUNCTUATOR_CLOSE_PARENTHESIS,
    VIZG_TOKEN_PUNCTUATOR_OPEN_BRACKET, VIZG_TOKEN_PUNCTUATOR_CLOSE_BRACKET,
    VIZG_TOKEN_PUNCTUATOR_OPEN_BRACE, VIZG_TOKEN_PUNCTUATOR_CLOSE_BRACE,
    VIZG_TOKEN_PUNCTUATOR_COMMA, VIZG_TOKEN_PUNCTUATOR_DOT,
    VIZG_TOKEN_PUNCTUATOR_ELLIPSIS, VIZG_TOKEN_PUNCTUATOR_ARROW,
    VIZG_TOKEN_PUNCTUATOR_COLON, VIZG_TOKEN_PUNCTUATOR_SEMICOLON,
    VIZG_TOKEN_PUNCTUATOR_QUESTION, VIZG_TOKEN_PUNCTUATOR_BANG,
    VIZG_TOKEN_PUNCTUATOR_EQUALS_EQUALS, VIZG_TOKEN_PUNCTUATOR_EXCLAMATION_EQUALS,
    VIZG_TOKEN_PUNCTUATOR_TILDE, VIZG_TOKEN_PUNCTUATOR_PIPE_PIPE,
    VIZG_TOKEN_PUNCTUATOR_AMP_AMP, VIZG_TOKEN_PUNCTUATOR_PLUS_PLUS,
    VIZG_TOKEN_PUNCTUATOR_MINUS_MINUS, VIZG_TOKEN_PUNCTUATOR_PLUS,
    VIZG_TOKEN_PUNCTUATOR_MINUS, VIZG_TOKEN_PUNCTUATOR_STAR,
    VIZG_TOKEN_PUNCTUATOR_SLASH, VIZG_TOKEN_PUNCTUATOR_PERCENT,
    VIZG_TOKEN_PUNCTUATOR_POWER, VIZG_TOKEN_PUNCTUATOR_DOT_DOT,
    VIZG_TOKEN_PUNCTUATOR_LESS_THAN_LESS_THAN,
    VIZG_TOKEN_PUNCTUATOR_GREATER_THAN_GREATER_THAN,
    VIZG_TOKEN_PUNCTUATOR_GREATER_THAN_GREATER_THAN_GREATER_THAN,
    VIZG_TOKEN_PUNCTUATOR_AMPERSAND, VIZG_TOKEN_PUNCTUATOR_PIPE,
    VIZG_TOKEN_PUNCTUATOR_CARET,

    VIZG_TOKEN_ASSIGN = 87, VIZG_TOKEN_ASSIGN_PLUS, VIZG_TOKEN_ASSIGN_MINUS,
    VIZG_TOKEN_ASSIGN_STAR, VIZG_TOKEN_ASSIGN_SLASH, VIZG_TOKEN_ASSIGN_PERCENT,
    VIZG_TOKEN_ASSIGN_POWER, VIZG_TOKEN_ASSIGN_LESS_THAN_LESS_THAN,
    VIZG_TOKEN_ASSIGN_GREATER_THAN_GREATER_THAN,
    VIZG_TOKEN_ASSIGN_AMP_AMP, VIZG_TOKEN_ASSIGN_PIPE_PIPE,

    VIZG_TOKEN_END_OF_FILE,
} Vizg_TokenType;

typedef struct Vizg_Token {
    Vizg_TokenType kind;
    Vizg_Span      span;
    const char    *lexeme_ptr;
    size_t         lexeme_len;
} Vizg_Token;

typedef enum {
    VIZG_STATUS_OK = 0,
    VIZG_STATUS_ERR_GENERIC,
    VIZG_STATUS_ERR_IO,
    VIZG_STATUS_ERR_PARSE,
    VIZG_STATUS_ERR_ABI,
} Vizg_Status;

#ifdef __cplusplus
extern "C" {
#endif

Vizg_Result *vizg_analyze_file(
    const char     *path_ptr, size_t path_len,
    const char     *text_ptr, size_t text_len);

void vizg_free_result(Vizg_Result *result);
Vizg_Result *vizg_analyze_source(
    const char     *source_ptr, size_t source_len,
    const char     *path_ptr,   size_t path_len);


#ifdef __cplusplus
}
#endif

#endif  /* VIZG_H */
