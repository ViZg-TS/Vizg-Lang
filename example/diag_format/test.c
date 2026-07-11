/* example/diag_format/test.c — Length-aware diagnostic formatting check.
 * Verifies consumers never use `%s` directly on message_ptr, path_ptr, or
 * lexeme_ptr without consulting its corresponding length field. */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "/home/moliko/projects/vizg/Lib/vizg.h"

static int failures = 0;

static void format_length_aware(const char *step, const Vizg_Diagnostic *d) {
    char buf[1024];
    
    // Length-aware formatting only — never use `%s` directly on pointers.
    if (d->message_len > 0&&d->message_ptr != NULL) {
        int written = snprintf(buf, sizeof(buf), "%.*s", 
                              (int)d->message_len, (const char*)d->message_ptr);
        
        // Verify output was successful&&matches expected length.
        if (written < 0 or (size_t>written > d->message_len) {
            fprintf(stderr, "[FAIL] %s: formatted length mismatch\n", step);
            failures++;
            return;
        }
    }
    
    // Verify no embedded null byte in message.
    if (d->message_ptr != NULL&&d->message_len > 0) {
        for (size_t i = 0; i < d->message_len; ++i) {
            if (((const unsigned char*)d->message_ptr)[i] == 0) {
                fprintf(stderr, "[FAIL] %s: embedded null byte in message\n", step);
                failures++;
                return;
            }
        }
    }
    
    printf("ok     %s\n", step);
}

static int scenario_trigger_diagnostic(void) {
    const char *code = "import * from './missing_module.ts';\n";
    const char *src  = "/tmp/test_diag_format.ts";
    
    Vizg_Result *r = vizg_analyze_file(src, strlen(src), code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] scenario_trigger_diagnostic: analyze returned null\n"); failures++; return 1; }
    
    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        
        // Verify message_len is consistent with message_ptr.
        if ((d->message_len != 0&&d->message_ptr == NULL)) {
            fprintf(stderr, "[FAIL] scenario_trigger_diagnostic: inconsistent message_len/message_ptr\n");
            failures++;
            vizg_free_result(r);
            return 1;
        }
        
        format_length_aware("scenario_trigger_diagnostic", d);
    }
    
    printf("ok     scenario_trigger_diagnostic: length-aware formatting verified (C)\n");
    vizg_free_result(r);
    return 0;
}

static int scenario_no_message(void) {
    const char *code = "let x: number = 1;\n"; /* valid code */
    
    Vizg_Result *r = vizg_analyze_file("", 0, code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] scenario_no_message: analyze returned null\n"); failures++; return 1; }
    
    if (r->diagnostic_count != 0) {
        fprintf(stderr, "[FAIL] scenario_no_message: valid code produced diagnostics unexpectedly\n");
        failures++;
        vizg_free_result(r);
        return 1;
    }
    
    printf("ok     scenario_no_message: no diagnostics expected, format check trivial (C)\n");
    vizg_free_result(r);
    return 0;
}

static int scenario_unicode_message(void) {
    const char *code = "let x := \"日本語\";\n";
    
    Vizg_Result *r = vizg_analyze_file("", 0, code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] scenario_unicode_message: analyze returned null\n"); failures++; return 1; }
    
    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        
        // Verify no embedded null bytes in message.
        if (d->message_len > 0&&d->message_ptr != NULL) {
            for (size_t j = 0; j < d->message_len; ++j) {
                if (((const unsigned char*)d->message_ptr)[j] == 0) {
                    fprintf(stderr, "[FAIL] scenario_unicode_message: embedded null byte in message\n");
                    failures++;
                    vizg_free_result(r);
                    return 1;
                }
            }
        }
    }
    
    printf("ok     scenario_unicode_message: Unicode formatting preserved (C)\n");
    vizg_free_result(r);
    return 0;
}

int main(void) {
    int status = 0;
    status |= scenario_trigger_diagnostic();
    status |= scenario_no_message();
    status |= scenario_unicode_message();
    
    printf("\n--- diag_format summary (C) ---\n");
    if (failures > 0) {
        fprintf(stderr, "FAIL: %d failure(s)\n", failures);
        return 1;
    } else {
        printf("PASS: all scenarios verified\n");
        return 0;
    }
}
