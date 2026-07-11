# example/token_iter — Length-aware token consumption via C ABI

Exercises four scenarios focused on `Vizg_Token.lexeme_len` / `lexeme_ptr`
pairing, zero-length handling, and EOF sentinel behaviour:

| Scenario                    | Focus                                                |
|-----------------------------|------------------------------------------------------|
| **normal_tokens**           | Token stream from valid code contains VIZG_TOKEN_END_OF_FILE; every lexeme spans fit within source. |
| **empty_source**            | Empty input yields ≤1 token and zero diagnostics (ABI permits null result too). |
| **keywords_and_punctuators**| Keyword-token range `[17,52]` and punctuator-token range `[≥open_paren, …]` are reachable from the C ABI. |
| **zero_length_lexeme**      | Zero-length lexemes (EOF / line-comment) carry `span.start_offset < source_len`. |

Each driver exits non-zero if any invariant is violated; otherwise prints `ok   <name>` and a final summary, then returns 0.

## Run

```sh
make run-zig
make run-c
make              # both, exit nonzero on failure
```

Both drivers link against the actual `libvizg.a` from `zig build`.

## Design notes

- Demonstrates the **only safe consumption pattern** for `lexeme_ptr`: never `%s`, always index via `span.start_offset .. span.start_offset + lexeme_len`. This is the same principle that drives `path_ptr` / `path_len` and `message_ptr` / `message_len` in `Vizg_Diagnostic`.
- Pairs with `example/abi_test` — that directory covers path/invariant scenarios for diagnostics; this one covers token-level consumption. Together they give a first-class contract test over the whole `Vizg_Result` payload.
