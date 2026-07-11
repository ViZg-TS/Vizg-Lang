// Goal-041 runtime smoke test in C — exercises the C ABI and asserts silence.

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include "vizg.h"

static int failures = 0;

int main(void) {
    const char *code = "let x: number = 42;\n";

    /* Open a temp capture file, dup it onto fd 2 (stderr), then restore. */
    int saved_stderr = dup(2);
    if (saved_stderr < 0) { perror("dup"); return 1; }

    int cap_fd = open("/tmp/vizg-silent-capture.txt",
                      O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (cap_fd < 0) { perror("open"); close(saved_stderr); return 1; }

    dup2(cap_fd, 2);        /* stderr now goes to our file */

    /* Exercise the API under capture. */
    Vizg_Result *r = vizg_analyze_source("", 0, code, (size_t)strlen(code));
    if (!r) { fprintf(stderr, "FAIL: analyze returned null\n"); failures++; }
    else      vizg_free_result(r);

    /* Restore stderr and inspect what was captured. */
    dup2(saved_stderr, 2);
    close(cap_fd);
    close(saved_stderr);

    FILE *f = fopen("/tmp/vizg-silent-capture.txt", "r");
    if (!f) { perror("fopen"); return 1; }
    char buf[65536];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);

    if (n > 0) {
        fprintf(stderr, "FAIL: Goal-041 silent test detected %zu bytes on stderr:\n%s\n",
                (unsigned long)n, buf);
        failures++;
    } else {
        printf("ok     silent_test\n");
    }

    return failures == 0 ? 0 : 1;
}
