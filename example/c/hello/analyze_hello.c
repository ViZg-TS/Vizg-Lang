// example/c/hello/analyze_hello.c - Minimal consumer of libvizg.a via C ABI.
// Link against zig-out/lib/libvizg.a produced by `zig build` in repo root.

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../../Lib/vizg.h"      // public C ABI header at repo root.

static int run(const char *text, size_t text_len, const char *label);
static int analyze_stdin(void);
static int analyze_path(const char *path);

int main(int argc, char **argv) {
    if (vizg_abi_version() != VIZG_ABI_VERSION) {
        fprintf(stderr, "vizg C ABI version mismatch\n");
        return 1;
    }

    if (argc > 1 && strcmp(argv[1], "-") != 0) return analyze_path(argv[1]);
    return analyze_stdin();
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    buf[got] = '\0';
    fclose(f);
    if (out_len) *out_len = got;
    return buf;
}

static int analyze_stdin(void) {
    size_t cap = 4096, used = 0;
    char *text = (char *)malloc(cap);
    if (!text) return 1;
    int ch;
    while ((ch = getchar()) != EOF) {
        if (used + 1 >= cap) { cap *= 2; text = (char *)realloc(text, cap); }
        text[used++] = (char)ch;
    }
    text[used] = '\0';

    return run(text, used, "stdin");
}

static int analyze_path(const char *path) {
    size_t len = 0;
    char *text = read_file(path, &len);
    if (!text) { perror("open file"); return 1; }
    int rc = run(text, len, path);
    free(text);
    return rc;
}

static int run(const char *text, size_t text_len, const char *label) {
    Vizg_SourceInput input = {
        .text_ptr = text,
        .text_len = text_len,
        .path_ptr = label,
        .path_len = strlen(label),
    };
    Vizg_Result *result = NULL;
    Vizg_Status status = vizg_analyze_source_ex(&input, &result);
    if (status != VIZG_STATUS_OK) {
        fprintf(stderr, "vizg_analyze_source_ex failed with status %d\n", (int)status);
        return 1;
    }

    printf("=== vizg C-ABI example ===\n");
    if (*label) printf("Source   : %s\n", label);
    printf("Bytes in : %zu\n"
           "Tokens   : %u\n"
           "Diags    : %u\n", text_len, result->token_count, result->diagnostic_count);

    if (result->tokens_ptr && result->token_count > 0) {
        const Vizg_Token *toks = (const Vizg_Token *)result->tokens_ptr;
        size_t shown = result->token_count < 5 ? result->token_count : 5;
        printf("\nFirst %zu token(s):\n", shown);
        for (size_t i = 0; i < shown; ++i) {
            const char *lex = toks[i].lexeme_ptr;
            size_t len = toks[i].lexeme_len;
            if (len > 40) len = 40;
            printf("  [%zu] %-*.*s  kind=%d\n", i, (int)len, (int)len, lex, (int)toks[i].kind);
        }
    }

    if (result->diagnostics_ptr && result->diagnostic_count > 0) {
        const Vizg_Diagnostic *diags = (const Vizg_Diagnostic *)result->diagnostics_ptr;
        printf("\nDiagnostics:\n");
        for (unsigned i = 0; i < result->diagnostic_count; ++i) {
            printf("  [%u] sev=%d code=%d phase=%d msg=\"", 
                i, diags[i].severity, (int)diags[i].code, (int)diags[i].phase);
            fwrite(diags[i].message_ptr, 1, diags[i].message_len, stdout);
            printf("\" span=+%u..%u\n", diags[i].span.start_offset, diags[i].span.end_offset);
        }
    }

    vizg_free_result(result);
    return 0;
}
