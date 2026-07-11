# example/abi_test — C ABI layout contract tests for `libvizg.a`

Exercises the four scenarios required by the project's "explicit path length" goal:

| Scenario          | Input                                       | Invariant verified                                              |
|-------------------|---------------------------------------------|-----------------------------------------------------------------|
| **normal_path**   | real file path + code that triggers a diagnostic with an associated module specifier (VZG5001) | At least one `Vizg_Diagnostic` carries a non-null, length-matched `(path_ptr, path_len)` pair. |
| **empty_path**    | empty source-path string                    | Every diagnostic has `(null, 0)` — no leaked file association.  |
| **utf8_path**     | UTF-8 encoded source path (`/tmp/日本語.ts`) | Any diagnostic that carries a path has `path_len` equal to the byte length of its content (not character count). The pair is consistent: non-null pointer ⟺ nonzero length. |
| **null_path**     | `NULL` source-path with zero length         | Every diagnostic has `(null, 0)` — no leaked file association.  |

Each scenario exits the process non-zero if it detects a violation; the test drivers print `ok   <name>` for passing scenarios and `[FAIL] <name>: ...` otherwise, then exit with status equal to the number of failed scenarios (or zero if all passed).

## Run

From this directory:
```sh
make run-zig      # runs the Zig driver
make run-c        # runs the C driver
make              # runs both, exiting nonzero on any failure
```

Both drivers link against `zig-out/lib/libvizg.a` so they validate the actual build output, not an ad-hoc compile.

## Design notes

- The four scenarios are expressed in **two languages** (Zig and C) so that a layout bug that corrupts Zig ABI but leaves C layout intact would still be caught by at least one of them — confirming cross-language parity is a first-class invariant we want to enforce, not just trust.
- `path_len` / `lexeme_len` are the actual data carrier: consumers must *never* use `%s` on `message_ptr`, `path_ptr`, or `lexeme_ptr` without consulting its corresponding length field. This matches how the C ABI treats every pointer in `Vizg_Diagnostic`.
- The "normal_path" scenario triggers `module_not_found` (VZG5001) by importing a non-existent specifier; that diagnostic carries its module specifier as a `path`. It is the cleanest way to get a controlled non-empty path into the result.

## Relationship to other tests

- This directory lives under `example/`, not `test/`, because it exercises cross-language FFI contracts, not syntax/parsing behavior (which belongs in `test/frontend`, `test/modules`, etc.).
- `./test/` remains reserved for `.ts` files that exercise the internal scanner/parser/binder/resolver pipeline.
