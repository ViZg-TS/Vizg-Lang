# Architecture

`vizg` is organized around a single-file frontend pipeline plus a small module graph layer. The frontend turns one source file into tokens, an AST, binding data, resolved references, preliminary CFGs, and diagnostics. The module graph layer loads local static imports from an entry file and validates named imports against exports.

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

`src/modules_graph/graph.zig` builds on `frontend.analyze`:

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

## Frontend Pipeline

The frontend is split into small modules:

- `tokens.zig`: token kinds, spans, token flags, and lexical error types.
- `scanner.zig`: converts source text into tokens, optional comments, and scanner diagnostics.
- `ast.zig`: defines AST node data and source spans.
- `parser.zig`: builds the AST from tokens and records parse diagnostics.
- `binder.zig`: creates scopes and symbols, records imports/exports, and reports duplicate declarations or exports.
- `resolver.zig`: resolves read/write/call/export references to bound symbols and reports missing names.
- `cfg.zig`: builds preliminary function-level control-flow graphs.

The single-file pipeline does not require file system access except for CLI input. `frontend.analyze` receives source text directly. The module graph layer is the file-system-aware wrapper.

Shared diagnostics live outside the frontend:

- `src/diagnostics/root.zig`: severity, phase, stable diagnostic codes, messages, spans, and optional paths.

The module graph layer is separate from the frontend:

- `src/modules_graph/root.zig`: public module layer API.
- `src/modules_graph/graph.zig`: graph structure, recursive traversal, import edges, export validation, and module diagnostics.
- `src/modules_graph/loader.zig`: source loading and single-file frontend analysis.
- `src/modules_graph/resolver.zig`: relative import resolution and path canonicalization.

## CLI Layer

`src/main.zig` is an inspection CLI around the frontend. It reads one file, runs `frontend.analyze` with source kind `module`, and prints one selected view:

- `check`
- `tokens`
- `ast`
- `symbols`
- `references`
- `refs`
- `cfg`
- `modules`
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
