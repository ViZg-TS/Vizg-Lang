# example/span_check — Diagnostic & token span integrity checks via C ABI

Exercises four scenarios that verify `Vizg_Span` invariants: every valid
diagnostic and token carries a consistent `(start_offset, end_offset)` pair
that fits within the source bounds.

| Scenario                | Focus                                              |
|-------------------------|----------------------------------------------------|
| **valid_code**          | Code with no diagnostics — zero diags produced; all tokens' spans fit inside source. |
| **with_diagnostics**    | Trigger a diagnostic (missing import) and confirm each diag carries consistent path/length, lexeme bounds, and span fields. |
| **empty_source**        | Truly empty input produces no diagnostics.         |
| **span_zero_length**    | Zero-length spans (EOF / comment terminators) still satisfy `start <= end` and stay inside source. |

Each driver exits non-zero if any invariant is violated; otherwise prints `ok   <name>` and a summary, returning 0.

## Run

```sh
make run-zig
make run-c
make              # both, exit nonzero on failure
```

Both drivers link against the actual `libvizg.a` from `zig build`.

## Design notes

- Validates **both** diagnostic-level and token-level span fields in one pass — catching regressions where an internal phase starts emitting spans that drift outside source bounds.
- Confirms the ABI's path/message invariant (`path_ptr == null ⟺ path_len == 0`) alongside span integrity, giving this example a contract scope wider than `abi_test`'s focused path-only checks.
- The zero-length-span scenario is critical: many ABIs silently allow out-of-range offsets for "sentinel" tokens; we enforce that even sentinels stay within bounds so consumers can trust the entire stream without branch-heavy guards.
