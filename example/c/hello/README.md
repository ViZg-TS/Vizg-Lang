# C-ABI Static Library Consumer — C Example

Demonstrates consuming `libvizg.a` from **C** via the public header `Lib/vizg.h`.

## What it exercises

- Checks `VIZG_ABI_VERSION` against `vizg_abi_version()`.
- Calls `vizg_analyze_source_ex()` and handles its explicit status.
- Iterates over `Vizg_Token[]` and `Vizg_Diagnostic[]` produced by the analyzer.
- Calls `vizg_free_result()` to release the arena-owned result (verifies zero leak).

## How to build

```bash
make          # builds analyze_hello against libvizg.a + vizg.h
```

## How to run

```bash
./analyze_hello <file>        # tokenize a file on disk
echo 'var x = 42;' | ./a.out  # or pipe inline code via /dev/stdin (if supported)
```
