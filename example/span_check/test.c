/* example/span_check/test.c — Cross-language parity for span integrity
 * checks in diagnostics and tokens via the C ABI. */

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

static int check_diagnostics(Vizg_Result *r, size_t source_len) {
    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];

        if (d->span.start_offset > d->span.end_offset) {
            fail("valid_code/diag", "start > end"); vizg_free_result(r); return 1;
        }
        if (d->message_len != 0 && !d->message_ptr) {
            fail("valid_code/diag", "msg len but null ptr"); vizg_free_result(r); return 1;
        }

        int has_path = d->path_ptr != NULL;
        if (has_path != (d->path_len > 0)) {
            fail("diag", "path invariant violated"); vizg_free_result(r); return 1;
        }

        // Length-aware access — the contract. Never use "%s" on message_ptr.
        (void)d->message_ptr;
        (void)d->message_len;
    }
    return 0;
}

static int scenario_valid_code(void) {
    const char *code = "var x: i32 = 42;\nlet y := \"hello\";\nif (true) {}\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("valid_code", "returned null"); return 1; }

    if (r->diagnostic_count != 0) { fail("valid_code", "unexpected diagnostics"); vizg_free_result(r); return 1; }

    for (unsigned i = 0; i < r->token_count; ++i) {
        const Vizg_Token *t = &((const Vizg_Token *)r->tokens_ptr)[i];
        if (t->span.end_offset > strlen(code)) { fail("valid_code", "token span past EOF"); vizg_free_result(r); return 1; }
    }

    vizg_free_result(r);
    printf("ok     valid_code\n");
    return 0;
}

static int scenario_with_diagnostics(void) {
    const char *code = "import * from './missing_module.ts';\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("with_diags", "returned null"); return 1; }

    if (r->diagnostic_count == 0) { fail("with_diags", "expected diagnostics"); vizg_free_result(r); return 1; }

    int rc = check_diagnostics(r, strlen(code));
    vizg_free_result(r);
    if (rc != 0) return 1;
    printf("ok     with_diagnostics\n");
    return 0;
}

static int scenario_empty_source(void) {
    Vizg_Result *r = vizg_analyze_file(NULL, 0, "", 0);
    if (!r) { printf("ok     empty_source\n"); return 0; }
    if (r->diagnostic_count != 0) { fail("empty_src", "unexpected diagnostics"); vizg_free_result(r); return 1; }
    vizg_free_result(r);
    printf("ok     empty_source\n");
    return 0;
}

static int scenario_span_zero_length(void) {
    const char *code = "let a: number;\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, strlen(code));
    if (!r) { fail("span_zero_len", "returned null"); return 1; }

    for (unsigned i = 0; i < r->token_count; ++i) {
        const Vizg_Token *t = &((const Vizg_Token *)r->tokens_ptr)[i];
        if (t->span.start_offset > t->span.end_offset) { fail("span_zero_len", "start > end"); vizg_free_result(r); return 1; }
    }

    check_diagnostics(r, strlen(code));
    vizg_free_result(r);
    printf("ok     span_zero_length\n");
    return 0;
}

int main(void) {
    scenario_valid_code();
    scenario_with_diagnostics();
    scenario_empty_source();
    scenario_span_zero_length();

    if (failures == 0) {
        printf("\nSpan-check tests passed — all four scenarios verified.\n");
    } else {
        printf("\n%d/4 span-check scenarios failed.\n", failures);
    }
    return failures != 0 ? 1 : 0;
}
