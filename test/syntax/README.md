# Syntax fixture corpus

Small JS/TS fixtures grouped by syntax family. `zig build test` scans every
`.js`, `.ts`, and `.tsx` file in valid category directories and requires zero scanner
and parser diagnostics. Files under `invalid/` declare ordered parser codes on
their first line:

```ts
// expect: VZG2001 VZG2002
```

Runner also requires EOF emission and full non-EOF token consumption. Fixtures
assert syntax behavior and diagnostic codes; they intentionally avoid AST node
IDs. `mixed/` holds representative real-world combinations.

`unsupported/` covers intentionally deferred syntax. Each fixture must emit one
targeted parser diagnostic (`VZG2004`-`VZG2006`) with a non-empty in-bounds span,
then consume the remaining token stream without scanner errors.
