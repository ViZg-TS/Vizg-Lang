#ifndef VIZG_H
#define VIZG_H

/* vizg — C ABI for the static library.  Include this from any C/C++ consumer
 * and link against libvizg.a (or platform equivalent). */

#include <stddef.h>
#include <stdint.h>

#define VIZG_ABI_VERSION 1u

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
    VIZG_DIAG_INVALID_ESCAPE_SEQUENCE  = 15,
    VIZG_DIAG_UNTERMINATED_REGEXP      = 16,
    VIZG_DIAG_INVALID_REGEXP           = 17,
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
    VIZG_TOKEN_REGEXP_LITERAL,
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
    VIZG_TOKEN_KEYWORD_AWAIT,
    VIZG_TOKEN_KEYWORD_BREAK,
    VIZG_TOKEN_KEYWORD_CASE,
    VIZG_TOKEN_KEYWORD_CATCH,
    VIZG_TOKEN_KEYWORD_CLASS,
    VIZG_TOKEN_KEYWORD_CONST,
    VIZG_TOKEN_KEYWORD_CONTINUE,
    VIZG_TOKEN_KEYWORD_DEBUGGER,
    VIZG_TOKEN_KEYWORD_DEFAULT,
    VIZG_TOKEN_KEYWORD_DELETE,
    VIZG_TOKEN_KEYWORD_DO,
    VIZG_TOKEN_KEYWORD_ELSE,
    VIZG_TOKEN_KEYWORD_ENUM,
    VIZG_TOKEN_KEYWORD_EXPORT,
    VIZG_TOKEN_KEYWORD_EXTENDS,
    VIZG_TOKEN_KEYWORD_FINALLY,
    VIZG_TOKEN_KEYWORD_FOR,
    VIZG_TOKEN_KEYWORD_FUNCTION,
    VIZG_TOKEN_KEYWORD_IF,
    VIZG_TOKEN_KEYWORD_IMPORT,
    VIZG_TOKEN_KEYWORD_IN,
    VIZG_TOKEN_KEYWORD_INSTANCEOF,
    VIZG_TOKEN_KEYWORD_LET,
    VIZG_TOKEN_KEYWORD_NEW,
    VIZG_TOKEN_KEYWORD_RETURN,
    VIZG_TOKEN_KEYWORD_SUPER,
    VIZG_TOKEN_KEYWORD_SWITCH,
    VIZG_TOKEN_KEYWORD_THIS,
    VIZG_TOKEN_KEYWORD_THROW,
    VIZG_TOKEN_KEYWORD_TRY,
    VIZG_TOKEN_KEYWORD_TYPEOF,
    VIZG_TOKEN_KEYWORD_VAR,
    VIZG_TOKEN_KEYWORD_VOID,
    VIZG_TOKEN_KEYWORD_WHILE,
    VIZG_TOKEN_KEYWORD_WITH,
    VIZG_TOKEN_KEYWORD_YIELD,
    VIZG_TOKEN_AMPERSAND,
    VIZG_TOKEN_AMPERSAND_AMPERSAND,
    VIZG_TOKEN_AMPERSAND_AMPERSAND_EQUAL,
    VIZG_TOKEN_AMPERSAND_EQUAL,
    VIZG_TOKEN_STAR,
    VIZG_TOKEN_STAR_STAR,
    VIZG_TOKEN_STAR_STAR_EQUAL,
    VIZG_TOKEN_STAR_EQUAL,
    VIZG_TOKEN_AT,
    VIZG_TOKEN_BACKTICK,
    VIZG_TOKEN_BAR,
    VIZG_TOKEN_BAR_BAR,
    VIZG_TOKEN_BAR_BAR_EQUAL,
    VIZG_TOKEN_BAR_EQUAL,
    VIZG_TOKEN_BAR_GREATER_THAN,
    VIZG_TOKEN_CARET,
    VIZG_TOKEN_CARET_EQUAL,
    VIZG_TOKEN_COLON,
    VIZG_TOKEN_COMMA,
    VIZG_TOKEN_DOT,
    VIZG_TOKEN_ELLIPSIS,
    VIZG_TOKEN_SEMICOLON,
    VIZG_TOKEN_EQUALS,
    VIZG_TOKEN_EQUALS_EQUALS,
    VIZG_TOKEN_EQUALS_EQUALS_EQUALS,
    VIZG_TOKEN_EQUALS_GREATER_THAN,
    VIZG_TOKEN_BANG,
    VIZG_TOKEN_BANG_EQUAL,
    VIZG_TOKEN_BANG_EQUAL_EQUAL,
    VIZG_TOKEN_GREATER_THAN,
    VIZG_TOKEN_GREATER_THAN_EQUALS,
    VIZG_TOKEN_GREATER_THAN_GREATER_THAN,
    VIZG_TOKEN_GREATER_THAN_GREATER_THAN_EQUAL,
    VIZG_TOKEN_GREATER_THAN_GREATER_THAN_GREATER_THAN,
    VIZG_TOKEN_GREATER_THAN_GREATER_THAN_GREATER_THAN_EQUAL,
    VIZG_TOKEN_HASH,
    VIZG_TOKEN_LESS_THAN,
    VIZG_TOKEN_LESS_THAN_EQUALS,
    VIZG_TOKEN_LESS_THAN_LESS_THAN,
    VIZG_TOKEN_LESS_THAN_LESS_THAN_EQUAL,
    VIZG_TOKEN_LESS_THAN_SLASH,
    VIZG_TOKEN_OPEN_BRACE,
    VIZG_TOKEN_OPEN_BRACKET,
    VIZG_TOKEN_OPEN_PARENTHESIS,
    VIZG_TOKEN_MINUS,
    VIZG_TOKEN_MINUS_EQUAL,
    VIZG_TOKEN_MINUS_MINUS,
    VIZG_TOKEN_PERCENT,
    VIZG_TOKEN_PERCENT_EQUAL,
    VIZG_TOKEN_PLUS,
    VIZG_TOKEN_PLUS_EQUAL,
    VIZG_TOKEN_PLUS_PLUS,
    VIZG_TOKEN_QUESTION_MARK,
    VIZG_TOKEN_QUESTION_DOT,
    VIZG_TOKEN_NULLISH_COALESCING,
    VIZG_TOKEN_NULLISH_COALESCING_EQUAL,
    VIZG_TOKEN_CLOSE_BRACE,
    VIZG_TOKEN_CLOSE_BRACKET,
    VIZG_TOKEN_CLOSE_PARENTHESIS,
    VIZG_TOKEN_SLASH,
    VIZG_TOKEN_SLASH_EQUAL,
    VIZG_TOKEN_TILDE,
    VIZG_TOKEN_END_OF_LINE,
    VIZG_TOKEN_END_OF_FILE
} Vizg_TokenType;

/* Contextual keyword classification companion to Vizg_TokenType.Identifier. */
typedef enum Vizg_ContextualKeyword {
    VIZG_CONTEXTUAL_KEYWORD_NONE           = 0,
    VIZG_CONTEXTUAL_KEYWORD_AS             = 1,
    VIZG_CONTEXTUAL_KEYWORD_FROM           = 2,
    VIZG_CONTEXTUAL_KEYWORD_OF             = 3,
    VIZG_CONTEXTUAL_KEYWORD_READONLY       = 4,
    VIZG_CONTEXTUAL_KEYWORD_ABSTRACT       = 5,
    VIZG_CONTEXTUAL_KEYWORD_DECLARE        = 6,
    VIZG_CONTEXTUAL_KEYWORD_SATISFIES      = 7,
    VIZG_CONTEXTUAL_KEYWORD_INFER          = 8,
    VIZG_CONTEXTUAL_KEYWORD_KEYOF          = 9,

    /* Extended contextual keywords (all supported by the scanner). */
    VIZG_CONTEXTUAL_KEYWORD_ACCESSOR       = 10,
    VIZG_CONTEXTUAL_KEYWORD_ANY            = 11,
    VIZG_CONTEXTUAL_KEYWORD_ASSERT         = 12,
    VIZG_CONTEXTUAL_KEYWORD_ASSERTS        = 13,
    VIZG_CONTEXTUAL_KEYWORD_ASYNC          = 14,
    VIZG_CONTEXTUAL_KEYWORD_BIGINT         = 15,
    VIZG_CONTEXTUAL_KEYWORD_BOOLEAN        = 16,
    VIZG_CONTEXTUAL_KEYWORD_CONSTRUCTOR    = 17,
    VIZG_CONTEXTUAL_KEYWORD_GLOBAL         = 18,
    VIZG_CONTEXTUAL_KEYWORD_IMPLEMENTS     = 19,
    VIZG_CONTEXTUAL_KEYWORD_INTERFACE      = 20,
    VIZG_CONTEXTUAL_KEYWORD_INTRINSIC      = 21,
    VIZG_CONTEXTUAL_KEYWORD_IS             = 22,
    VIZG_CONTEXTUAL_KEYWORD_MODULE         = 23,
    VIZG_CONTEXTUAL_KEYWORD_NAMESPACE      = 24,
    VIZG_CONTEXTUAL_KEYWORD_NEVER          = 25,
    VIZG_CONTEXTUAL_KEYWORD_NUMBER         = 26,
    VIZG_CONTEXTUAL_KEYWORD_OBJECT         = 27,
    VIZG_CONTEXTUAL_KEYWORD_OUT            = 28,
    VIZG_CONTEXTUAL_KEYWORD_OVERRIDE       = 29,
    VIZG_CONTEXTUAL_KEYWORD_PACKAGE        = 30,
    VIZG_CONTEXTUAL_KEYWORD_PRIVATE        = 31,
    VIZG_CONTEXTUAL_KEYWORD_PROTECTED      = 32,
    VIZG_CONTEXTUAL_KEYWORD_PUBLIC         = 33,
    VIZG_CONTEXTUAL_KEYWORD_SET            = 34,
    VIZG_CONTEXTUAL_KEYWORD_STATIC         = 35,
    VIZG_CONTEXTUAL_KEYWORD_STRING         = 36,
    VIZG_CONTEXTUAL_KEYWORD_SYMBOL         = 37,
    VIZG_CONTEXTUAL_KEYWORD_TYPE           = 38,
    VIZG_CONTEXTUAL_KEYWORD_UNDEFINED      = 39,
    VIZG_CONTEXTUAL_KEYWORD_UNIQUE         = 40,
    VIZG_CONTEXTUAL_KEYWORD_UNKNOWN        = 41,
    VIZG_CONTEXTUAL_KEYWORD_USING          = 42,
    VIZG_CONTEXTUAL_KEYWORD_GET            = 43,
} Vizg_ContextualKeyword;




typedef struct Vizg_Token {
    Vizg_TokenType  kind;
    Vizg_Span       span;
    const char     *lexeme_ptr;
    size_t          lexeme_len;
    int32_t         contextual_kind; /* VIZG_CONTEXTUAL_KEYWORD_*. */
} Vizg_Token;

typedef enum {
    VIZG_STATUS_OK                    = 0,
    VIZG_STATUS_INVALID_ARGUMENT      = 1,
    VIZG_STATUS_IO_ERROR              = 2,
    VIZG_STATUS_OUT_OF_MEMORY         = 3,
    VIZG_STATUS_INTERNAL_ERROR        = 4,
    VIZG_STATUS_FILE_TOO_LARGE        = 5,
} Vizg_Status;

typedef struct Vizg_SourceInput {
    const char     *text_ptr;
    size_t          text_len;
    const char     *path_ptr;
    size_t          path_len;
} Vizg_SourceInput;

/*
 * C ABI v1 contract:
 * - Pointer/length pairs are exact byte spans, not NUL-terminated strings.
 *   Zero length permits NULL; non-zero length requires non-NULL. Inputs are
 *   borrowed only for the duration of the call.
 * - A successful result owns all nested spans until vizg_free_result() is
 *   called exactly once. Callers must not modify or separately free them.
 * - Separate calls and results may be used concurrently. Do not read a result
 *   while or after another thread frees that same result.
 * - VIZG_STATUS_OK may include syntax diagnostics. Other statuses return no
 *   result. In-memory source has no fixed cap beyond address space and memory;
 *   file input may return VIZG_STATUS_FILE_TOO_LARGE.
 * See docs/architecture.md for platform validation scope and the full contract.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the runtime library's C ABI version. */
uint32_t vizg_abi_version(void);

Vizg_Status vizg_analyze_source_ex(
    const Vizg_SourceInput *input,
    Vizg_Result **out_result);

/* Deprecated: use vizg_analyze_source_ex(). Kept for back-compat. */

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
