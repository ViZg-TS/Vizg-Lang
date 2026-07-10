# C-ABI Static Library Consumer — Zig Example

Demonstrates consuming `libvizg.a` from **Zig** directly via C ABI imports.

## What it exercises

- Imports the C header and types via `@cImport`.
- Calls `vizg_analyze_file()` with inline source (no file on disk).
- Walks `Vizg_Token[]`, prints lexeme + kind, releases through `vizg_free_result()`.

## How to build

```bash
make          # builds vizg_zig_consumer via zig build-exe + -lc
```

## How to run

```bash
./vizg_zig_consumer      # runs against embedded sample_code in main.zig
```

Note: this Zig example links the static archive directly (`-lc` required under
Zig 0.16+ when C imports are used). Use whichever toolchain version you target;
older Zig releases linked libc implicitly.
