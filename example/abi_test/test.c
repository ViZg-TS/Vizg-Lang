/* example/abi_test/test.c — Equivalent of main.zig, exercising the same four
 * ABI scenarios from C to confirm cross-language consistency. */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "/home/moliko/projects/vizg/Lib/vizg.h"

static int failures = 0;

static void check_pair(const char *step, const char *msg_ptr, size_t msg_len,
                       const char *path_ptr, size_t path_len) {
    if ((path_ptr == NULL) != (path_len == 0)) {
        fprintf(stderr, "[FAIL] %s: invariant violated (ptr/len mismatch)\n", step);
        failures++;
    } else if (msg_ptr != NULL && msg_len == 0) {
        fprintf(stderr, "[FAIL] %s: non-null message with zero length\n", step);
        failures++;
    } else {
        printf("ok     %s\n", step);
    }
}

static int scenario_normal_path(void) {
    const char *code = "import * from './missing_module.ts';\n";
    const char *src  = "/tmp/main.ts";
    Vizg_Result *r = vizg_analyze_file(src, (size_t)strlen(src), code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] normal_path: analyze returned null\n"); failures++; return 1; }

    int saw_any = 0;
    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        check_pair("normal_path", d->message_ptr, d->message_len,
                   (const char *)d->path_ptr, d->path_len);
        if (d->path_len > 0) saw_any = 1;
    }
    vizg_free_result(r);
    if (!saw_any) { fprintf(stderr, "[FAIL] normal_path: no diag carried a path field\n"); failures++; return 1; }
    printf("ok     normal_path\n");
    return 0;
}

static int scenario_empty_path(void) {
    const char *code = "let x: number = 1;\n";
    Vizg_Result *r = vizg_analyze_file("", 0, code, (size_t)strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] empty_path: analyze returned null\n"); failures++; return 1; }

    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        if (d->path_len != 0 || d->path_ptr != NULL) {
            fprintf(stderr, "[FAIL] empty_path: diag has path field despite empty src_path\n");
            failures++;
        } else {
            printf("ok     empty_path\n");
        }
    }
    vizg_free_result(r);
    return 0;
}

static int scenario_utf8_path(void) {
    /* UTF-8 encoded path — 16 bytes for "/tmp/日本語.ts". */
    const char *utf8 = "\343\202\203\343\203\207\343\201\205.ts";
    size_t utf8_len  = (size_t)(strlen("/tmp/") + 9);  /* 6 + 9 multi-byte chars */

    const char *code = "const x = 42;\n";
    Vizg_Result *r = vizg_analyze_file(utf8, utf8_len, code, strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] utf8_path: analyze returned null\n"); failures++; return 1; }

    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        check_pair("utf8_path", d->message_ptr, d->message_len,
                   (const char *)d->path_ptr, d->path_len);
    }
    vizg_free_result(r);
    return 0;
}

static int scenario_null_path(void) {
    const char *code = "let z: boolean = false;\n";
    Vizg_Result *r = vizg_analyze_file(NULL, 0, code, (size_t)strlen(code));
    if (!r) { fprintf(stderr, "[FAIL] null_path: analyze returned null\n"); failures++; return 1; }

    for (unsigned i = 0; i < r->diagnostic_count; ++i) {
        const Vizg_Diagnostic *d = &((const Vizg_Diagnostic *)r->diagnostics_ptr)[i];
        if (d->path_len != 0 || d->path_ptr != NULL) {
            fprintf(stderr, "[FAIL] null_path: diag has path field despite null src_path\n");
            failures++;
        } else {
            printf("ok     null_path\n");
        }
    }
    vizg_free_result(r);
    return 0;
}

int main(void) {
    scenario_normal_path();
    scenario_empty_path();
    scenario_utf8_path();
    scenario_null_path();

    if (failures == 0) {
        printf("\nABI tests passed — all four scenarios verified.\n");
    } else {
        printf("\n%d/4 ABI test scenarios failed.\n", failures);
    }
    return failures != 0 ? 1 : 0;
}
