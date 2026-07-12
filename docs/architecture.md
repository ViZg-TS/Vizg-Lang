# Architecture

`vizg` is organized around a single-file frontend pipeline plus a small module graph layer. The frontend turns one source file into tokens, an AST, binding data, resolved references, preliminary CFGs, and diagnostics. The module graph layer loads local static imports from an entry file and validates named imports against exports. A static-library boundary exposes a subset of the single-file result through a C ABI.

## Public Roots And ABI Boundary

`src/root.zig` has two roles: it is the public Zig package root and the root module used to build `libvizg.a`. It re-exports the implemented project layers and imports the ABI module so exported C symbols are retained in the archive.

`Lib/vizg.zig` owns the C-compatible structs, internal-to-ABI conversion, result allocation, and these exported functions:

- `vizg_abi_version`
- `vizg_analyze_file`
- `vizg_analyze_source`
- `vizg_analyze_source_ex`
- `vizg_free_result`

`Lib/vizg.h` is the consumer contract. The ABI is pointer/length based: returned strings are not required to be NUL-terminated, and result-backed memory remains valid only until `vizg_free_result`. Each result owns an independent arena, so multiple results may be alive and freed in any order. New consumers use `vizg_analyze_source_ex`, whose status distinguishes invalid arguments, I/O, file-size, OOM, and internal failures; the older source function remains a null-on-failure compatibility wrapper.

`zig build android-aarch64-lib` compiles this same ABI graph for `aarch64-linux-android.24` and installs a static archive plus header under `zig-out/android-aarch64/`. The in-memory analysis entry points have no filesystem, host-path, threading, or direct syscall dependency. `vizg_analyze_file` is the platform adapter and uses the target's filesystem through Zig's standard library. The build requires no hardcoded SDK or NDK path; final Android application linkage supplies an API-24-compatible NDK sysroot and CRT. This is compile validation only, not an Android runtime claim.

### C ABI v1 contract

`Lib/vizg.h` defines `VIZG_ABI_VERSION` as `1`.
`vizg_abi_version()` returns the linked runtime library version. Consumers may
compare both values before analysis to detect a header/library mismatch.

Every string-like field is an exact pointer/length byte span, not a
NUL-terminated string. Zero length permits a null pointer; non-zero length
requires a non-null pointer. Source and path inputs are borrowed only for the
duration of the call.

On `VIZG_STATUS_OK`, `vizg_analyze_source_ex` writes one non-null owned result.
It clears `out_result` before work and leaves it null on failure. That result
owns its token and diagnostic arrays plus all message, path, and lexeme spans.
They remain valid until `vizg_free_result()` is called exactly once. Callers
must not modify or separately free nested storage. `vizg_free_result(NULL)` is
valid. Compatibility wrappers return null when they cannot produce a result.

Independent analysis calls are thread-safe. Separately owned results may be
read or freed concurrently and in any order. The same result must not be read
while another thread frees it, or after it has been freed.

Status meanings:

- `VIZG_STATUS_OK`: analysis completed. Syntax problems are diagnostics in the
  returned result, not API failures.
- `VIZG_STATUS_INVALID_ARGUMENT`: a required output pointer, input descriptor,
  or non-empty span pointer is null.
- `VIZG_STATUS_IO_ERROR`: file input could not be opened or read.
- `VIZG_STATUS_OUT_OF_MEMORY`: allocation failed.
- `VIZG_STATUS_INTERNAL_ERROR`: an otherwise unmapped internal failure.
- `VIZG_STATUS_FILE_TOO_LARGE`: file input cannot be represented or read at
  the required size.

In-memory source has no fixed ABI size limit beyond the target address space
and available memory. File input may report `VIZG_STATUS_FILE_TOO_LARGE`.

The default host-target static library is produced by `zig build`, and the host
is the only target with runtime ABI validation through `zig build test`.
`zig build abi-cross-check` compiles the same consumer library graph as a static
archive for each listed Linux, Windows, macOS, and Android target. It also
compiles a C translation unit against `Lib/vizg.h` for each target. These are
compile and header-neutrality probes, not foreign-target runtime claims.

The ABI currently exposes tokens and diagnostics from single-file analysis. It does not expose AST nodes, symbols, references, CFGs, module graph data, type inference, execution, or compilation.

Build dependency direction:

```txt
consumer -> Lib/vizg.h -> libvizg.a
libvizg.a root: src/root.zig <-> imported ABI module: Lib/vizg.zig
Lib/vizg.zig -> public frontend exports from src/root.zig
```

## Current Implemented Layer

The current engine lives under `src/frontend/` and is re-exported from `src/root.zig`.

Current data flow:

```txt
source text
  -> scanner
  -> tokens/comments/lexical diagnostics
  -> parser
  -> AST/parse diagnostics
  -> binder
  -> scopes/symbols/imports/exports/bind diagnostics
  -> resolver
  -> references/resolve diagnostics
  -> CFG builder
  -> FrontendResult
```

`src/frontend/frontend.zig` owns this orchestration through `frontend.analyze`.

`src/modules/graph.zig` builds on `frontend.analyze`:

```txt
entry path
  -> read source
  -> frontend.analyze
  -> collect static imports
  -> resolve relative imports
  -> recursively analyze local modules
  -> cache by canonical path
  -> build import edges
  -> validate named imports
  -> module diagnostics
```

### Cross-file Linking (Linker)

Above the loader/resolver, `src/modules/linker.zig` builds per-build cross-file import links. Each link records a local name in one file and the symbol it resolves to (or will resolve to after further passes) inside another module:

```txt
entry path
  -> read source
  -> frontend.analyze
  -> build linked imports
    for each static named/default/namespace import:
      classify kind as .named, .default, .namespace, or .external
    record unresolved imports when no target is resolved yet
  -> graph.zig exposes linked_imports to the CLI
  -> `vizg modules` prints Links section in output
```

The linker lives strictly inside the module layer. It owns no filesystem work and produces immutable snapshots for one `Linker` instance. It does not bundle, execute, or resolve packages — it is a structural analysis pass.

### Module Layer Files

- `src/modules/root.zig`: public API re-export.
- `src/modules/graph.zig`: graph structure, recursive traversal, import edges, export validation, module diagnostics (`VZG5xxx`).
- `src/modules/loader.zig`: source loading and single-file frontend analysis.
- `src/modules/resolver.zig`: relative import resolution and path canonicalization.
- `src/modules/linker.zig`: per-build cross-file import link construction (named/default/namespace imports resolve to exported symbols; external imports preserved as `.external`).



## Types And Semantics Layers

Two dedicated layers above the frontend own type model and semantic mapping. They do not sit inside `src/frontend/`.

```txt
frontend/
  lexical/syntax single-file structural analysis
  owns AST syntax for type annotations (e.g. parameter types, interface shapes)
  does not own semantic type model

types/
  pure type model
  builtin primitive types
  function signature model
  no dependency on frontend

semantics/
  maps frontend symbols/nodes to types
  future location for type annotation resolver, type collector, inference, and checker
```

- `src/types/builtin.zig`: builtin kind enum, name-to-id mappings.
- `src/types/model.zig`: TypeId, TypeKind, FunctionSignature, Builtins.
- `src/types/root.zig`: public re-export with precomputed builtins instance.

**Important**: the type model types (`TypeId`, `Type`, `Builtins`) live in `src/types/`. They are not frontend-owned semantic types and should not be documented as such. Type annotation syntax can still be represented in `frontend/ast.zig` because it is syntax — but the semantic interpretation belongs to `types/` or `semantics/`.

### `src/semantics/root.zig` (Semantic Mapping)

The semantics layer maps frontend symbols and AST nodes to their associated types:

- **SymbolTypeInfo**: declared and inferred type for a single symbol. Prefers declared over inferred when both are known.
- **NodeTypeInfo**: type information attached to an AST node.
- **TypeInfo**: container that aggregates per-symbol and per-node type info across one analyzed file.

This layer imports from `src/types/` (the pure model) and from the frontend (`ast.zig`, `binder.zig`) for symbol/node identity. The direction is intentional: semantics consumes types, not the other way around.

These are NOT a working type checker yet. The actual inference, annotation resolution, and semantic checking passes still belong to a future milestone; this layer provides the data structures to hold per-symbol / per-node mappings once that work lands.


The frontend is split into small modules:

- `tokens.zig`: token kinds, spans, token flags, and lexical error types.
- `scanner.zig`: converts source text into tokens, optional comments, and scanner diagnostics.
- `ast.zig`: defines AST node data and source spans.
- `parser.zig`: builds the AST from tokens and records parse diagnostics.
- `binder.zig`: creates scopes and symbols, records imports/exports, and reports duplicate declarations or exports.
- `resolver.zig`: resolves read/write/call/export references to bound symbols and reports missing names.
- `cfg.zig`: builds preliminary function-level control-flow graphs.

The single-file pipeline does not require file system access except for CLI input. `frontend.analyze` receives source text directly. The module graph layer is the file-system-aware wrapper.

## Platform Boundary

`cross_check.zig` references the public declarations in the frontend, types, and semantics layers. `zig build cross-check` compiles that generic probe as an object for representative Linux, Windows, macOS, and Android targets. `zig build abi-cross-check` separately compiles target static archives using the consumer dependency graph (`src/root.zig` and `Lib/vizg.zig`) and compiles the public C header probe. Neither step runs foreign code.

Generic layers must not branch on the target OS. Platform-dependent work stays in adapters such as `src/main.zig` for CLI interaction, `src/modules/loader.zig` for filesystem-backed loading, `Lib/vizg.zig` for the C ABI, and build/packaging helpers. The ABI matrix proves that its adapter compiles for the listed targets; it does not claim runtime validation there.

Shared diagnostics live outside the frontend:

- `src/diagnostics/root.zig`: severity, phase, stable diagnostic codes, messages, spans, and optional paths.
## CLI Layer

`src/main.zig` is an inspection CLI around the frontend and module layer. It reads one file, runs `frontend.analyze`, optionally loads imports via `graph.build` plus `linker.Linker` to resolve them, and prints one selected view:

- `check`
- `tokens`
- `ast`
- `symbols`
- `references`
- `refs`
- `cfg`
- `modules`: print modules + import edges + **Links** (per-link resolved target or unresolved for external imports) + diagnostics
- `help`

The CLI is intentionally diagnostic and exploratory. It is not a compiler driver.

## Diagnostics

Diagnostics are phase-tagged records with a severity, stable code, display name, message, source span, optional label, and optional path. Current diagnostics come from scanner, parser, binder, resolver, and module graph phases. Future phase names already exist in the enum, but their systems are not implemented yet.

## Future Layers

Likely future layers are intentionally separate from the current frontend and module graph:

- Expanded module layer: package lookup, configuration-aware resolution, and richer import/export forms.
- Type checker: infer/check types, validate calls and assignments, and produce semantic diagnostics.
- HIR/lowering: lower AST or typed AST into a more compiler-friendly intermediate form.
- Runtime/compiler layers: execute, interpret, compile, or emit code from lowered forms.

## Non-Goals For Current Milestone

The current milestone does not implement:

- Package, `node_modules`, `package.json`, or `tsconfig` resolution.
- Dynamic imports or CommonJS.
- Bundling, tree shaking, or runtime module loading.
- TypeScript type checking.
- JavaScript runtime behavior.
- Native compilation or code emission.
- Complete JavaScript or TypeScript grammar coverage.
- Optimization passes.
