# example/diag_format — Length-aware diagnostic formatting contract tests for `libvizg.a`

Exercises the requirement that consumers never use `%s` directly on `message_ptr`, `path_ptr`, or `lexeme_ptr`. Instead, all output must go through length-aware formatting (`%.*s`) to safely handle embedded null bytes and partial messages.

| Scenario              | Input                                                  | Invariant verified                                                              |
|-----------------------|--------------------------------------------------------|---------------------------------------------------------------------------------|
| **trigger_diagnostic** | Real file path + code triggering a `VZG5001` diagnostic with an associated module specifier path. | At least one diagnostic message can be printed using only length-aware formatting without relying on `%s`. |
| **no_message**         | Valid TypeScript source (`let x: i32 = 42;`)           | No diagnostics emitted, confirming no format code runs for empty messages — trivially passing the invariant. |
| **unicode_message**    | Source with UTF-8 characters in a string literal       | Any diagnostic message survives length-aware formatting intact (no truncated byte sequences or embedded-null corruption). |

Each scenario exits nonzero if it detects a violation; drivers print `ok <name>` for passing scenarios and `[FAIL] <name>: ...` otherwise, then exit with status equal to the number of failures.

## Run

From this directory:
```sh
make run-zig      # runs the Zig driver
make run-c        # runs the C driver
make              # runs both, exiting nonzero on any failure
```

Both drivers link against `zig-out/lib/libvizg.a` so they validate the actual build output, not an ad-hoc compile.

## Design notes

- Format contract tests are distinct from layout tests: this directory doesn't care about field sizes or offsets (span_check/abi_test own that) but about how consumers actually *use* the fields when building strings for humans (or logs).
- `%.*s` is a C format verb — length-aware formatting only. It's the idiomatic safe way to print `char *` buffers when you don't trust them to be null terminated.
- The "trigger_diagnostic" scenario reuses the same trick as `abi_test`: import a non-existent module specifier (VZG5001) which carries an associated path field, giving us a controlled diagnostic with non-empty message and path lengths.

## Relationship to other tests

- This directory lives under `example/`, not `test/`, because it exercises cross-language FFI contracts (length-aware usage of the ABI), not syntax/parsing behavior (which belongs in `test/frontend`, `test/modules`, etc.).
- `./test/` remains reserved for `.ts` files that exercise the internal scanner/parser/binder/resolver pipeline.
