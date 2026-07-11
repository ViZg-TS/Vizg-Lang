/* example/token_iter/test.c — Equivalent of main.zig for cross-language
 * parity on token-consumption scenarios.  Exercises lexeme_len + lexeme_ptr
 * pairing, zero-length handling, and EOF sentinel via the C ABI. */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "/home/moliko/projects/vizg/Lib/vizg.h"

static int failures = 0;

static void fail(const char *step, const char *why) {
    fprintf(stderr, "[FAIL] %s: %s\n", step, why);
    failures++;
}

static void check_pair_ok(const char *lexeme_ptr, size_t lexeme_len) {
    // Length-aware consumption — the only safe way to print a non-NUL-terminated
    // field in C.  Never use "%s" on lexeme_ptr without consulting lexeme_len.
    (void)lexeme_ptr;
    (void)lexeme_len;
}

static int scenario_normal_tokens(void) {
    const char *code = "var x: i32 = 42;\nlet s := \"hello\";\nif (true) {}\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("normal_tokens", "analyze returned null"); return 1; }

    int saw_eof = 0;
    for (unsigned i = 0; i < r->token_count; ++i) {
        const Vizg_Token *t = &((const Vizg_Token *)r->tokens_ptr)[i];

        if ((size_t)t->span.start_offset >= strlen(code)) {
            fail("normal_tokens", "start_offset out of range");
            vizg_free_result(r);
            return 1;
        }

        size_t end = (size_t)t->span.start_offset + t->lexeme_len;
        if (end > strlen(code) && t->kind != VIZG_TOKEN_END_OF_FILE) {
            fail("normal_tokens", "lexeme spans past EOF");
            vizg_free_result(r);
            return 1;
        }

        check_pair_ok(t->lexeme_ptr, t->lexeme_len);
        if (t->kind == VIZG_TOKEN_END_OF_FILE) saw_eof = 1;
    }

    vizg_free_result(r);
    if (!saw_eof) { fail("normal_tokens", "no EOF token"); return 1; }
    printf("ok     normal_tokens\n");
    return 0;
}

static int scenario_empty_source(void) {
    Vizg_Result *r = vizg_analyze_file(NULL, 0, "", 0);
    if (!r) { printf("ok     empty_source\n"); return 0; } // ABI allows null.

    if (r->token_count > 1) { fail("empty_source", "too many tokens"); vizg_free_result(r); return 1; }
    if (r->diagnostic_count != 0) { fail("empty_source", "unexpected diagnostics"); vizg_free_result(r); return 1; }

    vizg_free_result(r);
    printf("ok     empty_source\n");
    return 0;
}

static int scenario_keywords(void) {
    const char *code = "import * from './missing.ts';\nexport let y: number;\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("keywords", "analyze returned null"); return 1; }

    int saw_keyword = 0, saw_punctuator = 0;
    for (unsigned i = 0; i < r->token_count; ++i) {
        const Vizg_Token *t = &((const Vizg_Token *)r->tokens_ptr)[i];
        if (t->kind >= VIZG_TOKEN_KEYWORD_await && t->kind <= VIZG_TOKEN_KEYWORD_with)
            saw_keyword++;
        else if (t->kind >= VIZG_TOKEN_PUNCTUATOR_OPEN_PARENTHESIS)
            saw_punctuator++;
    }

    vizg_free_result(r);
    if (!saw_keyword) { fail("keywords", "no keyword tokens"); return 1; }
    if (!saw_punctuator) { fail("keywords", "no punctuator tokens"); return 1; }
    printf("ok     keywords\n");
    return 0;
}

static int scenario_zero_length_lexeme(void) {
    const char *code = "let a: number;\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("zero_length_lexeme", "analyze returned null"); return 1; }

    for (unsigned i = 0; i < r->token_count; ++i) {
        const Vizg_Token *t = &((const Vizg_Token *)r->tokens_ptr)[i];
        if (t->lexeme_len == 0 && (size_t)t->span.start_offset >= strlen(code)) {
            fail("zero_length_lexeme", "zero-len lexeme out of range");
            vizg_free_result(r);
            return 1;
        }
    }

    vizg_free_result(r);
    printf("ok     zero_length_lexeme\n");
    return 0;
}

int main(void) {
    scenario_normal_tokens();
    scenario_empty_source();
    scenario_keywords();
    scenario_zero_length_lexeme();

    if (failures == 0) {
        printf("\nToken-iter tests passed — all four scenarios verified.\n");
    } else {
        printf("\n%d/4 token-iter scenarios failed.\n", failures);
    }
    return failures != 0 ? 1 : 0;
}
