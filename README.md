# vizg

`vizg` implements a frontend analysis pipeline for a TypeScript/JavaScript-like language subset, a minimal module graph layer, and a C-compatible static library. The same frontend is available through the development CLI, the public Zig module in `src/root.zig`, and the ABI implemented in `Lib/vizg.zig`.

## Current Status

This repository is a frontend engine prototype. It does not execute JavaScript, emit code, type-check programs, resolve packages, or bundle modules.

Implemented today:

- Scanner for tokens, comments, spans, and lexical diagnostics.
- Parser for a focused TypeScript/JavaScript-like syntax subset.
- AST model for programs, declarations, expressions, control flow, imports, and exports.
- Binder for scopes, symbols, imports, exports, duplicate declaration diagnostics, and duplicate export diagnostics.
- Resolver for identifier references and missing-name diagnostics.
- Preliminary control-flow graphs for function bodies.
- Module graph v1 for relative static imports, canonical-path caching, named import validation, external import edges, missing modules, missing exports, and simple cycles.
- Cross-file import linking layer that resolves local imports to their target module's exported symbols, tracks import kind (named, default, namespace, external, unresolved), and emits `VZG5001`, `VZG5002`, and `VZG5003` diagnostics alongside link records.
- CLI inspection commands for checks, tokens, AST, symbols, references, CFGs, and modules.
- Static library `libvizg.a` with a public C header and file/in-memory analysis entry points.

Supported syntax is best described by `test/frontend/vizg_capabilities_test.ts`: comments, named/default imports, `let`/`const`/`var`, exported variables and functions, typed parameters, primitive literals, binary expressions, assignments, calls, member expressions, `if`/`else`, `while`, `for`, `return`, named exports, and aliased exports.

## Build

```sh
zig build
```

The default build installs:

```txt
zig-out/bin/vizg       development CLI
zig-out/lib/libvizg.a  static library
```

The public header is installed by the test dependency chain at `zig-out/include/vizg.h`. Consumers may also include the source header directly from `Lib/vizg.h`.

## Test

```sh
zig build test
```

The test step runs the frontend, module graph, semantic, and ABI unit-test tree. It also rejects unconditional debug output in `Lib/`, compiles a C consumer against the installed header/archive, and runs that consumer as a smoke test.

## Static Library And C ABI

The supported exported functions are:

```c
Vizg_Result *vizg_analyze_file(
    const char *path_ptr, size_t path_len,
    const char *text_ptr, size_t text_len);

Vizg_Result *vizg_analyze_source(
    const char *source_ptr, size_t source_len,
    const char *path_ptr, size_t path_len);

void vizg_free_result(Vizg_Result *result);
```

`vizg_analyze_source` analyzes caller-provided bytes without filesystem access. Its optional path is only a diagnostic identifier. `vizg_analyze_file` reads `path_ptr` when no source text is supplied; caller-provided text can be used instead.

Returned tokens, diagnostics, messages, paths, and lexemes remain owned by the result. Treat every pointer as a pointer/length pair and call `vizg_free_result` exactly once when finished. A missing diagnostic path is represented by `path_ptr == NULL` and `path_len == 0`.

Minimal C build:

```sh
zig build
cc -I Lib consumer.c -L zig-out/lib -lvizg -o consumer
```

See `example/c/hello/` and `example/zig/consumer/` for complete consumers. The ABI exposes the current single-file frontend result; it does not expose the module graph, linker, or a runtime.

## Android

```sh
zig build android
```

This cross-compiles the C ABI static library for Android `aarch64`, `armv7`,
and `x86_64`, installing the archives under `zig-out/android/<abi>/libvizg.a`.

## Validation

A repeatable validation script builds, runs tests, and exercises the CLI on a handful of fixtures. All output goes to `logs/validate-YYYYMMDD-HHMMSS.log`.

```sh
sh tools/validate.sh
ls -lh logs/
tail -n 80 logs/validate-*.log
```

The script exits non-zero if the build or tests fail.

## CLI Examples

Run through Zig:

```sh
zig build run -- help
zig build run -- check test/frontend/vizg_capabilities_test.ts
zig build run -- tokens test/frontend/basic-module.ts
zig build run -- ast test/frontend/basic-module.ts
zig build run -- symbols test/frontend/vizg_capabilities_test.ts
zig build run -- references test/frontend/resolver_missing_name.ts
zig build run -- cfg test/frontend/control-flow.ts
zig build run -- modules test/frontend/modules/manual/success.ts
```

Or use the installed binary after `zig build`:

```sh
./zig-out/bin/vizg check test/frontend/vizg_capabilities_test.ts
```

Successful `check` output looks like:

```txt
checked: test/frontend/vizg_capabilities_test.ts
source kind: module
diagnostics: 0 errors, 0 warnings
```

See [docs/cli.md](docs/cli.md) for command details.

## Repository Layout

```txt
build.zig                 Zig build configuration
src/main.zig              CLI entry point and output formatting
src/root.zig              Public Zig exports and static-library root module
Lib/vizg.zig              C ABI implementation and exported symbols
Lib/vizg.h                Public C ABI declarations
src/frontend/tokens.zig   Token, span, and lexical vocabulary definitions
src/frontend/scanner.zig  Scanner and comment collection
src/frontend/parser.zig   Parser and parse diagnostics
src/frontend/ast.zig      AST node model
src/frontend/binder.zig   Scope, symbol, import, and export binding
src/frontend/resolver.zig Identifier reference resolution
src/frontend/cfg.zig      Preliminary function control-flow graph builder
src/modules/root.zig      Module graph public API
src/modules/graph.zig     Minimal multi-file module graph
src/modules/loader.zig    Source file loading and frontend analysis wrapper
src/modules/resolver.zig  Relative module path resolution
src/diagnostics/root.zig   Shared diagnostic model and stable codes
src/types/root.zig                Type model (primitives, function signatures)
src/semantics/root.zig            Semantic type info mapping symbols/nodes to types
src/frontend/tests.zig    Frontend integration tests
test/frontend/            TypeScript fixture files
docs/                     Contributor and architecture documentation
```

## Non-Goals For Current Milestone

- No package, `node_modules`, `package.json`, or `tsconfig` resolution.
- No dynamic imports or CommonJS.
- No semantic type checker.
- No HIR/lowering layer.
- No code generation or native compilation.
- No JavaScript runtime or execution engine.
- No package manager, bundler, or runtime module loader.
- No claim of full TypeScript or JavaScript language coverage.

## More Documentation

- [Architecture](docs/architecture.md)
- [Frontend pipeline](docs/frontend-pipeline.md)
- [Diagnostics](docs/diagnostics.md)
- [CLI](docs/cli.md)
- [Roadmap](docs/roadmap.md)
- [Changelog](CHANGELOG.md)
