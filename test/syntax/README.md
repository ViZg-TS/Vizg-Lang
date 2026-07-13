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

`unsupported/` covers intentionally deferred syntax. Fixtures declare ordered
diagnostic codes with `// expect:` and matching comma-separated token spans with
`// span:`. Reserved pipeline syntax (`|>`) is intentionally unsupported.
