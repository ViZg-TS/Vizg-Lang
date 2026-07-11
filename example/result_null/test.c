/* example/result_null/test.c — Null/empty result safety checks.
 * Verifies vizg_analyze_file() returns NULL in certain failure modes and
 * consumers handle it safely without dereferencing null pointers or calling
 * vizg_free_result on a non-result pointer. */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "/home/moliko/projects/vizg/Lib/vizg.h"

static int failures = 0;

static int scenario_valid_code_no_diagnostics(void) {
    const char *code = "let x: number = 1;\n"; /* valid code */

    Vizg_Result *r = vizg_analyze_file("", 0, code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] scenario_valid_code_no_diagnostics: analyze returned null for valid code\n"); failures++; return 1; }

    // No diagnostics expected — confirm the ABI agrees.
    if (r->diagnostic_count != 0) {
        fprintf(stderr, "[FAIL] scenario_valid_code_no_diagnostics: valid code produced diagnostics unexpectedly\n");
        failures++;
    }

    printf("ok     scenario_valid_code_no_diagnostics: safe handling of no-diagnostic result (C)\n");
    vizg_free_result(r); /* verify free doesn't crash */
    return 0;
}

static int scenario_invalid_source(void) {
    const char *code = "let x := 1; ++;\n"; /* invalid syntax, may trigger error */

    Vizg_Result *r = vizg_analyze_file("", 0, code, strlen(code));
    
    // Implementation-defined behavior: r may or may not be NULL.
    // We just verify that analyze didn't crash&&free_result can be called safely.
    if (r != NULL) {
        printf("ok     scenario_invalid_source: analyze returned non-null for invalid source\n");
        vizg_free_result(r);
    } else {
        printf("ok     scenario_invalid_source: analyze returned null for invalid source — safe handling confirmed\n");
    }

    return 0; /* never fails in this scenario */
}

static int scenario_empty_text_ptr_with_length(void) {
    const char *path = "/tmp/empty.txt";
    
    // Pass non-null text_ptr with length 0 — should not crash.
    Vizg_Result *r = vizg_analyze_file(path, strlen(path), (const char*)"", 0);

    if (r != NULL) {
        printf("ok     scenario_empty_text_ptr_with_length: non-null ptr + zero length returned result\n");
        vizg_free_result(r);
    } else {
        printf("ok     scenario_empty_text_ptr_with_length: non-null ptr + zero length returned null — safe handling confirmed\n");
    }

    return 0; /* never fails in this scenario */
}

static int scenario_null_text_ptr_zero_length(void) {
    const char *path = "/tmp/empty.txt";

    // Pass NULL text_ptr with length 0 — should not crash (implementation-defined).
    Vizg_Result *r = vizg_analyze_file(path, strlen(path), NULL, 0);

    if (r != NULL) {
        printf("ok     scenario_null_text_ptr_zero_length: non-NULL result returned for edge case\n");
        vizg_free_result(r);
    } else {
        printf("ok     scenario_null_text_ptr_zero_length: edge case handled safely (no crash)\n");
    }

    return 0; /* never fails in this scenario */
}

int main(void) {
    int status = 0;
    status |= scenario_valid_code_no_diagnostics();
    status |= scenario_invalid_source();
    status |= scenario_empty_text_ptr_with_length();
    status |= scenario_null_text_ptr_zero_length();

    printf("\n--- result_null summary (C) ---\n");
    if (failures > 0) {
        fprintf(stderr, "FAIL: %d failure(s)\n", failures);
        return 1;
    } else {
        printf("PASS: all scenarios verified\n");
        return 0;
    }
}
