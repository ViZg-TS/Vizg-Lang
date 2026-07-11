# example/result_null — Null-safe handling contract tests for `libvizg.a`

Exercises the requirement that consumers handle null/empty results from `vizg_analyze_file()` safely in both Zig and C, without dereferencing null pointers or calling `vizg_free_result` on a non-result pointer.

| Scenario                      | Input                                          | Invariant verified                                                                              |
|-------------------------------|------------------------------------------------|-------------------------------------------------------------------------------------------------|
| **valid_code_no_diagnostics** | Valid TypeScript source (`let x: i32 = 42;`)   | Analyze returns a `Vizg_Result *` (not NULL), with zero diagnostics; `vizg_free_result` works.    |
| **invalid_source**            | Invalid syntax that may trigger an error       | Whether the implementation returns null or non-null, consumers don't crash on either path.        |
| **empty_text_ptr_with_length**| Non-NULL text pointer + length 0               | Edge case of empty buffer doesn't crash (implementation-defined behavior).                        |
| **null_text_ptr_zero_length** | NULL text pointer + length 0                   | Edge case of null buffer doesn't crash (implementation-defined behavior).                         |

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

- Null safety tests are distinct from layout/format tests: this directory doesn't care about field sizes or offsets (span_check/abi_test own that) but about how consumers *survive* receiving a NULL pointer back.
- The "invalid_source" scenario is intentionally implementation-defined: some analyzers return null on failure, others return a result with error diagnostics — consumers must not assume either behavior and handle both paths.
- The empty/null text-pointer scenarios test boundary cases that would previously crash in C-style APIs if the consumer didn't check for NULL before dereferencing `text_ptr` or calling strlen() / sizeof().

## Relationship to other tests

- This directory lives under `example/`, not `test/`, because it exercises cross-language FFI contracts (null-safe handling), not syntax/parsing behavior (which belongs in `test/frontend`, `test/modules`, etc.).
- `./test/` remains reserved for `.ts` files that exercise the internal scanner/parser/binder/resolver pipeline.
