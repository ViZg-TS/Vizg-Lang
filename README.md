# vizg

`vizg` implements a frontend analysis pipeline for a TypeScript/JavaScript-like language subset, a minimal module graph layer, and a C-compatible static library. The same frontend is available through the development CLI, the public Zig module in `src/root.zig`, and the ABI implemented in `Lib/vizg.zig`.

## Current Status

This repository is a frontend engine prototype. It does not execute JavaScript, emit code, provide complete TypeScript type checking, resolve packages, or bundle modules.

Implemented today:

- Scanner for tokens, comments, spans, lexical diagnostics, and Unicode 17.0 ECMAScript-style identifiers.
- Parser for a focused TypeScript/JavaScript-like syntax subset.
- AST model for programs, declarations, expressions, control flow, imports, and exports.
- Binder for scopes, symbols, imports, exports, duplicate declaration diagnostics, and duplicate export diagnostics.
- Resolver for identifier references and missing-name diagnostics.
- Preliminary control-flow graphs for function bodies.
- Module graph v1 for relative static imports and re-exports, canonical-path caching, named import validation, external edges, missing modules, missing exports, and simple cycles.
- Cross-file import linking layer that resolves local imports to their target module's exported symbols, tracks import kind (named, default, namespace, external, unresolved), and emits `VZG5001`, `VZG5002`, and `VZG5003` diagnostics alongside link records.
- Owned Zig `SemanticResult` analysis API with stable node/symbol/scope/reference/module/type-ID lookup, split syntax/semantic diagnostics, one canonical per-result `TypeStore`, symbol/expression types, aggregate/access/function/call inference, CFG-backed flow narrowing, centralized structural compatibility and checker diagnostics, and explicit destruction.
- Owned Zig `ProjectSemanticResult` API with one shared project `TypeStore`, qualified exported identities, named/default/namespace/type-only import and re-export propagation, bounded cycle handling, partial unresolved links, and explicit destruction.
- CLI inspection commands for checks, tokens, AST, symbols, references, CFGs, canonical semantic types, and modules.
- Static library `libvizg.a` with a public C header and file/in-memory analysis entry points.

Supported syntax is enforced by `test/frontend/vizg_capabilities_test.ts` and `test/syntax/`. Current AST coverage includes modules (static attributes and dynamic imports), classes, enums, generic declarations, async/generator functions, rich parameters, labeled control flow, modern expressions, and structured TypeScript types including literal, indexed-access, `keyof`, and simple-identifier type-query nodes. Typed Semantics v2 resolves the supported named, structural, generic, and cross-module annotations while preserving canonical project identities and declaration shapes. Decorators, private fields, namespaces, JSX/TSX, mapped and conditional types, qualified or import-based type queries, `with`, and reserved pipeline syntax are intentionally unsupported and receive targeted `VZG2004`-`VZG2006` recovery. This is a stable syntax/frontend contract, not HIR, runtime, bundler, or complete TypeScript type checking.

## Build

```sh
zig build
```

The default build installs:

```txt
zig-out/bin/vizg       development CLI
zig-out/lib/libvizg.a  static library
zig-out/include/vizg.h public C header
```

Build the WebAssembly C ABI module with:

```sh
zig build wasm
```

This installs `zig-out/wasm/vizg.wasm`, targeting `wasm32-wasi`. The reactor
exports the C ABI functions from `Lib/vizg.h` and `_initialize`, not `_start`.
It requires a WASI host because `vizg_analyze_file` uses filesystem APIs;
`wasm32-freestanding` and browser-only runtimes are not currently supported.
The in-memory `vizg_analyze_source_ex` path itself does not read files.

## Test

```sh
zig build test
```

The test step runs the frontend, module graph, semantic, ABI, Android-helper, and portable structural checks. C and Zig consumer contract tests remain available under `example/`.

Run the C/Zig public ABI layout comparison independently with:

```sh
zig build abi-layout-test
```

## Cross-target compile checks

```sh
zig build cross-check
zig build abi-cross-check
```

`cross-check` builds the generic frontend, types, and semantics layers as objects. `abi-cross-check` builds the same static-library graph used by consumers, rooted at `src/root.zig` with the C ABI implementation in `Lib/vizg.zig`, and compiles a C translation unit against `Lib/vizg.h` for every target. The ABI archives are compile probes and are not installed as packages.

Both steps cover `x86_64-linux`, `aarch64-linux`, `x86_64-windows`, `x86_64-macos`, `aarch64-macos`, `wasm32-wasi`, and `aarch64-linux-android.24`. They compile only and never run foreign code. Passing proves compile portability and header neutrality, not runtime behavior. The CLI and packaging remain outside the matrix. Android compilation uses Zig's target query and does not require an NDK; Android runtime validation remains separate work.

Build the packaged Android AArch64/API 24 static library with:

```sh
zig build android-aarch64-lib
```

This installs `zig-out/android-aarch64/lib/libvizg.a` and `zig-out/android-aarch64/include/vizg.h`. The step also compiles a minimal C consumer for `aarch64-linux-android.24`. It does not link or run an Android executable: final linkage needs the consuming Android build's API-24-compatible NDK sysroot and CRT.

## Static Library And C ABI

The supported exported functions are:

```c
#define VIZG_ABI_VERSION 1u

uint32_t vizg_abi_version(void);

Vizg_Status vizg_analyze_source_ex(
    const Vizg_SourceInput *input,
    Vizg_Result **out_result);

Vizg_Result *vizg_analyze_file(
    const char *path_ptr, size_t path_len,
    const char *text_ptr, size_t text_len);

Vizg_Result *vizg_analyze_source(
    const char *source_ptr, size_t source_len,
    const char *path_ptr, size_t path_len);

void vizg_free_result(Vizg_Result *result);
```

Compare `VIZG_ABI_VERSION` with `vizg_abi_version()` to detect a
header/library mismatch.

Use `vizg_analyze_source_ex` for new integrations. It reports `VIZG_STATUS_OUT_OF_MEMORY` and other failures explicitly and leaves `*out_result == NULL` on failure. `vizg_analyze_source` is the deprecated null-on-failure compatibility wrapper. Both analyze caller-provided bytes without filesystem access; the optional path is only a diagnostic identifier. `vizg_analyze_file` reads `path_ptr` when no source text is supplied.

Returned tokens, diagnostics, messages, paths, and lexemes remain owned by the result. Treat every pointer as a pointer/length pair and call `vizg_free_result` exactly once when finished. A missing diagnostic path is represented by `path_ptr == NULL` and `path_len == 0`.

Independent calls and results may be used concurrently; never access the same
result while or after it is freed. See the
[C ABI v1 contract](docs/architecture.md#c-abi-v1-contract) for exact ownership,
status, size, thread-safety, and platform-validation rules.

Minimal C build:

```sh
zig build
cc -I Lib consumer.c -L zig-out/lib -lvizg -o consumer
```

See `example/c/hello/` and `example/zig/consumer/` for complete consumers. The ABI exposes the current single-file frontend result; the owned `SemanticResult` and `ProjectSemanticResult` are Zig-only and do not alter C ABI v1. The ABI does not expose the module graph, linker, or a runtime.

New enum members appended to public C ABI enums are compatible extensions: existing numeric values and layouts remain unchanged. Consumers must tolerate enum values added by a newer v1 library; removing, renumbering, or changing the width of existing members requires an ABI version change.

## Validation

A portable build step installs all public artifacts, runs the registered tests, and exercises the CLI:

```sh
zig build validate
```

`tools/validate.sh` remains a convenience wrapper around that build step.

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
zig build run -- types test/frontend/vizg_capabilities_test.ts
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
- No runtime module loading, CommonJS, or bundling. Dynamic imports are represented syntactically.
- No complete TypeScript semantic type checker.
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
