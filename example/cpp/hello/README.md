# C-ABI Static Library Consumer — C++ Example

Demonstrates consuming `libvizg.a` from **C++** using the public header `Lib/vizg.h`.

## What it exercises

- Same ABI surface as the C example (tokenization + diagnostics).
- Verifies that C structs and arenas interoperate with `std::string`, RAII, etc.

## How to build

```bash
make          # builds analyze_hello against libvizg.a + vizg.h
```

## How to run

```bash
./analyze_hello <file>
