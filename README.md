# vizg

`vizg` currently implements a frontend analysis pipeline for a TypeScript/JavaScript-like language subset plus a minimal module graph layer. It scans source text, parses files into ASTs, binds declarations, resolves identifier references, builds preliminary function control-flow graphs, resolves local static imports, and exposes inspection output through a Zig CLI.

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
- CLI inspection commands for checks, tokens, AST, symbols, references, CFGs, and modules.

Supported syntax is best described by `test/frontend/vizg_capabilities_test.ts`: comments, named/default imports, `let`/`const`/`var`, exported variables and functions, typed parameters, primitive literals, binary expressions, assignments, calls, member expressions, `if`/`else`, `while`, `for`, `return`, named exports, and aliased exports.

## Build

```sh
zig build
```

The default build installs the `vizg` executable under `zig-out/bin/vizg`.

## Test

```sh
zig build test
```

The test step runs both the library module tests and the CLI module tests.

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
src/root.zig              Public module exports
src/frontend/tokens.zig   Token, span, and lexical vocabulary definitions
src/frontend/scanner.zig  Scanner and comment collection
src/frontend/parser.zig   Parser and parse diagnostics
src/frontend/ast.zig      AST node model
src/frontend/binder.zig   Scope, symbol, import, and export binding
src/frontend/resolver.zig Identifier reference resolution
src/frontend/cfg.zig      Preliminary function control-flow graph builder
src/modules_graph/root.zig      Module graph public API
src/modules_graph/graph.zig     Minimal multi-file module graph
src/modules_graph/loader.zig    Source file loading and frontend analysis wrapper
src/modules_graph/resolver.zig  Relative module path resolution
src/diagnostic/root.zig   Shared diagnostic model and stable codes
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
