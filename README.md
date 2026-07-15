# vizg

`vizg` implements a frontend analysis pipeline for a TypeScript/JavaScript-like language subset, a minimal module graph layer, and a C-compatible static library. The same frontend is available through the development CLI, the public Zig module in `src/root.zig`, and the official C ABI v1 implemented in `Lib/abi.zig`.

## Current Status

This repository is a frontend analysis engine. It does not execute JavaScript, emit code, provide complete TypeScript type checking, resolve packages, or bundle modules.

Implemented today:

- Scanner for tokens, comments, spans, lexical diagnostics, and Unicode 17.0 ECMAScript-style identifiers.
- Parser for a focused TypeScript/JavaScript-like syntax subset.
- AST model for programs, declarations, expressions, control flow, imports, and exports.
- Binder for scopes, symbols, imports, exports, duplicate declaration diagnostics, and duplicate export diagnostics.
- Resolver for identifier references and missing-name diagnostics.
- Preliminary control-flow graphs for function bodies.
- Host-resolved module graph for static imports, re-exports, type-only edges, dynamic requests, external edges, missing modules, missing exports, and cycles. ViZG preserves raw specifiers and never applies a resolver policy.
- Cross-file import linking layer that resolves local imports to their target module's exported symbols, tracks import kind (named, default, namespace, external, unresolved), and emits `VZG5001`, `VZG5002`, and `VZG5003` diagnostics alongside link records.
- Owned Zig `SemanticResult` analysis API with stable node/symbol/scope/reference/module/type-ID lookup, split syntax/semantic diagnostics, one canonical per-result `TypeStore`, symbol/expression types, aggregate/access/function/call inference, CFG-backed flow narrowing, centralized structural compatibility and checker diagnostics, and explicit destruction.
- Owned Zig `ProjectSemanticResult` API with one shared project `TypeStore`, qualified exported identities, named/default/namespace/type-only import and re-export propagation, bounded cycle handling, partial unresolved links, and explicit destruction.
- CLI inspection commands for checks, tokens, AST, symbols, references, CFGs, canonical semantic types, and modules.
- Static library `libvizg.a` with the official memory-first, host-driven C ABI v1.
- Portable `src/root.zig` core with source-bytes analysis and a host-driven
  module request/response contract. ViZG does not implement module resolution.
- Test-only module hosts under `test/support/` validate that external runtimes
  can provide sources, failures, and external-module metadata. The filesystem
  fixture is not exported by the Zig or C API.
- CLI single-file commands read bytes once and call the source-only semantic
  API. The development-only `modules` command uses `FsValidationHost` solely to
  exercise the public host contract; it is not a ViZG resolver.

Supported syntax is enforced by `test/frontend/vizg_capabilities_test.ts` and `test/syntax/`. Current AST coverage includes modules (static attributes and dynamic imports), classes, enums, generic declarations, async/generator functions, rich parameters, labeled control flow, modern expressions, and structured TypeScript types including literal, indexed-access, `keyof`, and simple-identifier type-query nodes. Typed Semantics v2 resolves the supported named, structural, generic, and cross-module annotations while preserving canonical project identities and declaration shapes. Decorators, private fields, namespaces, JSX/TSX, mapped and conditional types, qualified or import-based type queries, `with`, and reserved pipeline syntax are intentionally unsupported and receive targeted `VZG2004`-`VZG2006` recovery. This is a stable syntax/frontend contract, not HIR, runtime, bundler, or complete TypeScript type checking.

## Build

```sh
zig build
```

The default build installs:

```txt
zig-out/bin/vizg       development CLI
zig-out/lib/libvizg.a  static library
zig-out/include/vizg.h official C ABI v1 header
```

Build the WebAssembly C ABI module with:

```sh
zig build wasm
```

This installs `zig-out/lib/vizg.wasm`, targeting
`wasm32-freestanding`. It imports nothing: there is no libc, WASI, allocator,
filesystem, or callback dependency. Its exact exports are linear `memory` and
the official ABI v1 allowlist below. The build also runs a minimal JavaScript
host through single-module, multi-module, missing-module, and external-module
flows while validating the import and export tables.

## Test

```sh
zig build test
```

The test step runs the frontend, module graph, semantic, ABI lifecycle/layout/symbol, Android-helper, and portable structural checks.

`zig build lint-portable-core` compiles every public core declaration for
`wasm32-freestanding`. It is part of `test` and `validate`, and rejects core
dependencies on filesystem, process, POSIX, WASI, environment, adapter, or ABI
facilities.

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

## Static Library And Official C ABI v1

`Lib/vizg.h` is the only public C contract. `VIZG_ABI_VERSION` is `1`, and
`vizg_abi_version()` provides the matching runtime value. The unpublished
prototype ABI was removed without aliases, wrappers, or compatibility shims.

The ABI is memory-first, host-driven, and one-shot:

1. The caller allocates one aligned workspace and creates `Vizg_Project`.
2. The caller submits each root or pre-supplied source exactly once.
3. ViZG parses source, discovers imports/exports, and returns unresolved module
   requests through `vizg_project_step`.
4. The host answers each request exactly once with source bytes, external-module
   metadata, or an explicit failure.
5. After `VIZG_PROJECT_STEP_COMPLETE`, the caller calls
   `vizg_project_finish`.
6. `finish` is terminal. It returns the same immutable result view on repeated
   calls and performs no additional allocation.
7. The result is owned by the project and remains valid until
   `vizg_project_destroy`. There is no result-destroy function.

A project does not accept source revisions. Reusing a `ModuleId` with another
source is `INVALID_STATE`. Hosts that need revisions create a new project.

Each external export declares whether it exists in the value namespace, the
type namespace, or both. C hosts set exactly one of
`VIZG_EXTERNAL_NAMESPACE_VALUE`, `VIZG_EXTERNAL_NAMESPACE_TYPE`, or
`VIZG_EXTERNAL_NAMESPACE_BOTH`; zero and unknown bits are invalid arguments.
An export marked `BOTH` may back the same imported class name in both a
constructor expression and a type annotation.

The result API exposes:

- summary flags and counts;
- modules and their host-assigned identities;
- canonical diagnostics with module identity, logical label, phase, code, span,
  severity, and message;
- discovered/resolved graph edges;
- semantic import links;
- semantic exports and re-export metadata.

`finish` retains only the module closure reachable from submitted roots through
resolved local imports. Pre-supplied modules outside that closure do not appear
in module, edge, diagnostic, import, or export result views and cannot make an
otherwise valid project fail. The summary derives its error flags from the
canonical diagnostic table: scanner/parser errors set `has_syntax_errors`,
binder/resolver/types/checker errors set `has_semantic_errors`, linking/project
errors set `has_project_errors`, and module-host errors set
`has_module_failures`. `summary.is_partial` is the OR of those four flags.

Allocation exhaustion is terminal, but every fallible project phase rolls back
its in-progress ownership before returning. No semantic result or ABI result
pointer is published until the corresponding operation commits, so callers can
safely destroy a project after any `OUT_OF_MEMORY` result.

Import and re-export rows carry explicit graph provenance. Read a module,
external-module, or edge value only when its matching `has_*` flag is set; zero
is a valid identifier/index value and is never an implicit sentinel. For
example:

```c
Vizg_ProjectImportInfo import_info;
if (vizg_project_result_import(result, index, &import_info) ==
        VIZG_PROJECT_STATUS_OK &&
    import_info.has_external_target) {
    uint64_t external = import_info.external_module_id;
    /* Use the host-assigned external identity. */
}

if (import_info.has_edge_index) {
    Vizg_ProjectEdgeInfo source_edge;
    if (vizg_project_result_edge(result, import_info.edge_index, &source_edge) ==
        VIZG_PROJECT_STATUS_OK) {
        /* source_edge identifies the exact discovered import/re-export edge. */
    }
}

Vizg_ProjectExportInfo export_info;
if (vizg_project_result_export(result, index, &export_info) ==
        VIZG_PROJECT_STATUS_OK &&
    export_info.re_export && export_info.has_edge_index) {
    /* export_info.edge_index identifies the re-export's source edge. */
}
```

The ABI performs no filesystem, URL, package, or network resolution. ViZG emits
raw specifiers and import metadata; the runtime or consumer assigns `ModuleId`
values and decides how requests are resolved. Logical names and specifiers are
labels, never graph identities. External modules use a separate identity domain.

Canonical project diagnostics use exactly the scanner, parser, binder,
resolver, types, checker, module-host, and project phases. Module-originated
rows carry an explicit host-assigned identity; the ABI never derives one from a
logical name. Host responses distinguish module-not-found (`VZG5001`), access
denied (`VZG5004`), and other host failures (`VZG5005`).

All retained input is copied into the caller-supplied workspace. Configuration
bounds per-module and cumulative source bytes, modules, requests, edges,
diagnostics, graph depth, and semantic types. Collection limits are checked
before retained input is copied or collection capacity grows. Graph depth is the
shortest resolved-edge distance from any root, independent of request and host
response order. An over-depth source response is rejected before its source,
module identity, request state, or graph edge is mutated. Every typed input and
output must have its C alignment, and
every non-empty range must be complete and overflow-safe. Project creation
rejects config/output aliasing, and host input or output may not overlap the
exclusive workspace. Pointer validation completes before any output write or
project mutation, so `INVALID_ARGUMENT` leaves both unchanged. `INVALID_STATE`
rejects lifecycle and response-order errors.
`LIMIT_EXCEEDED` and `OUT_OF_MEMORY` are terminal for that project: destroy it
and create a new one with corrected limits or capacity. After
`LIMIT_EXCEEDED`, `vizg_project_limit_kind` reports the exact stable category
for the immediately preceding project call, including
`VIZG_LIMIT_PARSE_DEPTH` for parser recursion. Every successful or non-limit
project call resets that accessor to `VIZG_LIMIT_NONE`.

`VIZG_MAX_SOURCE_LENGTH` is the representation ceiling for one source and is
equal to `UINT32_MAX`; `max_source_bytes` may not exceed it. Source byte offsets,
span endpoints, lines, and columns remain stable `uint32_t` ABI values. An
oversized `source_len` is rejected as `VIZG_LIMIT_SOURCE_BYTES` before its source
pointer is range-checked, copied, or passed to the scanner. Aggregate source-byte
accounting rejects integer overflow before project mutation. When project
creation rejects `max_source_bytes` above this ceiling, it returns a destroy-only
handle so `vizg_project_limit_kind` reports `VIZG_LIMIT_SOURCE_BYTES`; the caller
must destroy that handle.

On `wasm32`, pointers and `size_t` values are unsigned 32-bit offsets/counts in
exported linear memory. Every non-empty range, including nested strings and
typed arrays, must be in bounds and outside the exclusive project workspace
when required. The freestanding module imports no WASI, libc, filesystem,
allocator, or callback service.

The exact ABI v1 symbol allowlist is:

```txt
vizg_abi_version
vizg_project_workspace_alignment
vizg_project_workspace_overhead
vizg_project_create
vizg_project_destroy
vizg_project_limit_kind
vizg_project_add_source
vizg_project_step
vizg_project_respond_source
vizg_project_respond_external
vizg_project_respond_failure
vizg_project_finish
vizg_project_result_summary
vizg_project_result_module
vizg_project_result_diagnostic
vizg_project_result_edge
vizg_project_result_import
vizg_project_result_export
```

`test/wasm/official_abi_v1.mjs` is the minimal freestanding host. The filesystem
driver at `test/support/fs_validation_host.zig` is validation-only and is not
part of the Zig package or C ABI.

ABI v1 is frozen by the repeated Goal 207 closure recorded in
[`docs/FINAL_AUDIT.md`](docs/FINAL_AUDIT.md). Re-run its complete command matrix
before changing any public structure, constant, lifecycle rule, or symbol.

The narrow ABI gates are:

```sh
zig build abi-symbols-test
zig build abi-native-consumer-test
zig build abi-layout-test
zig build wasm-freestanding
```

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
test/support/fs_validation_host.zig Test-only filesystem host fixture
src/project/              Portable project contracts and implementation
Lib/vizg.zig              C ABI implementation and exported symbols
Lib/vizg.h                Public C ABI declarations
src/frontend/tokens.zig   Token, span, and lexical vocabulary definitions
src/frontend/scanner.zig  Scanner and comment collection
src/frontend/parser.zig   Parser and parse diagnostics
src/frontend/ast.zig      AST node model
src/frontend/binder.zig   Scope, symbol, import, and export binding
src/frontend/resolver.zig Identifier reference resolution
src/frontend/cfg.zig      Preliminary function control-flow graph builder
src/modules/root.zig      Borrowed semantic graph/link model
src/modules/graph.zig     Host-resolved module records and edges
src/modules/linker.zig    Cross-module symbol links
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
- [ABI v1 final audit and freeze record](docs/FINAL_AUDIT.md)
- [Superseded Goals 189–196 audit checklist](docs/portable-core-official-abi-v1-audit.md)
- [Changelog](CHANGELOG.md)
