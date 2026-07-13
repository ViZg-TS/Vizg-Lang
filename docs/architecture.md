# Architecture

`vizg` is organized around a single-file frontend pipeline, a module graph, and owned single-file/project semantic results. The frontend turns one source file into tokens, an AST, binding data, resolved references, preliminary CFGs, and diagnostics. The module graph loads local static imports from an entry file and validates named imports against exports. Project semantics propagates canonical types and qualified identities across that graph. A static-library boundary exposes a subset of the single-file result through a C ABI.

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

The ABI currently exposes tokens and diagnostics from single-file analysis. It does not expose the Zig `SemanticResult`, AST nodes, symbols, references, CFGs, module graph data, type inference, execution, or compilation. `SemanticResult` additions therefore do not change C ABI v1 layouts or ownership rules. Appending a member to a public C enum is a compatible v1 extension when all existing numeric values and enum widths remain unchanged; consumers must tolerate unknown newer values. Removing or renumbering an existing member, or changing its representation, requires an ABI version change.

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
  owns one complete single-file semantic result
  hosts type annotation collection, inference, and checking passes
```

- `src/types/builtin.zig`: canonical builtin kind vocabulary and names.
- `src/types/model.zig`: `TypeId`, all primitive, literal, aggregate, callable, nominal, and type-parameter `TypeKind` variants, plus function-signature records.
- `src/types/type_store.zig`: the per-context canonical `TypeStore`, including builtins, owned structural types, function signatures, normalization, and recursive-type reservation.
- `src/types/root.zig`: public type-model re-exports.

**Important**: the type model types (`TypeId`, `Type`, `Builtins`) live in `src/types/`. They are not frontend-owned semantic types and should not be documented as such. Type annotation syntax can still be represented in `frontend/ast.zig` because it is syntax — but the semantic interpretation belongs to `types/` or `semantics/`.

### `src/semantics/root.zig` (Semantic Mapping)

The semantics layer exposes `analyzeSource`, which scans and parses its input once and returns one owned `SemanticResult`. The result owns an arena containing its copied source, frontend artifacts, type information, diagnostics, and module metadata. Callers call `SemanticResult.deinit` exactly once; all result-backed slices become invalid afterward.

`SemanticResult` contains:

- the AST, symbols, scopes, references, CFGs, and single-file import/export links through its frontend snapshot;
- expression and symbol `TypeInfo`;
- separate syntax and semantic diagnostics plus one deterministic combined view;
- stable value-based lookups for `NodeId`, `SymbolId`, `ScopeId`, `ReferenceId`, and local `ModuleId` (`0` for a single-file result);
- metadata marking recovered diagnostic output as partial.

Each `SemanticResult` owns exactly one canonical `TypeStore` containing
`any`, `unknown`, `never`, `void`, `undefined`, `null`, `boolean`, `number`,
`bigint`, `string`, `symbol`, and `object`. Type equality within that result is
constant-time `TypeId` equality. IDs are context-local, not process-global;
each primitive has one record in its registry, and `any` and `unknown` remain
distinct. Primitive literals widen directly to canonical builtins. The same
policy applies in expression and mutable-variable contexts; literal singleton
types are not represented in this milestone.

The store interns anonymous structural shapes, retains declaration identity for nominal types, and normalizes unions/intersections deterministically. Recursive types reserve an identity before their owned definition is installed, avoiding recursive allocation. Equality and semantic decisions use `TypeId`/stored structure; debug formatting is never a source of truth. Unknown IDs return `null`; a missing type entry also returns `null`. Diagnostics do not invalidate recovered AST and symbol data.

### Project semantic contract

`analyzeProject` builds the existing `ModuleGraph`, then `analyzeModuleGraph` consumes every module's existing `FrontendResult` without reparsing. One project-wide canonical `TypeStore` supplies every module `TypeInfo` and every exported/imported `TypeId`; IDs are comparable only inside that `ProjectSemanticResult`.

`SemanticIdentity` is a value-qualified identity: module ID, optional binder symbol ID, declaration node ID, namespace, and canonical type ID. `SemanticExport` covers value declarations, functions, classes, enums, interfaces, and type aliases. Aliases and named/star/default re-exports retain the target identity rather than inventing a second declaration identity.

`SemanticImport` records named, default, namespace, type-only, external, unresolved, and cyclic-partial states with its local symbol, target identity when known, runtime-binding flag, and stable source span. Namespace imports use an owned structural object made from runtime exports. External imports remain `unknown`; missing targets remain inspectable unresolved links.

Propagation uses a bounded fixed point. Cyclic graphs terminate; known declarations remain available while incomplete links keep stable `unknown` or cyclic-partial states. The final checker consumes the propagated `TypeInfo` and never duplicates inference. Diagnostics mark the result partial but do not invalidate modules, identities, types, or links.

`ProjectSemanticResult` owns the module graph and one semantic arena containing the shared store and all project semantic slices. Call `deinit` exactly once. No result-backed slice or pointer may outlive it. Rebuilds create independent ownership contexts, so old `TypeId` values must never be compared with new ones.

The contained semantic mapping uses:

- **SymbolTypeInfo**: declared and inferred type plus resolution state for a single symbol. Prefers declared over inferred when both are known.
- **NodeTypeInfo**: expression type and resolution state attached to an AST node.
- **FlowTypeInfo**: a flow-sensitive reference type keyed by function node, CFG block, symbol, and reference node.
- **TypeInfo**: container that aggregates per-symbol, per-node, and per-flow-reference type info across one analyzed file.

Declaration collection covers variables, parameters, functions, classes,
interfaces, enums, and type aliases. Identifier expressions obtain their type
only through the resolver's `SymbolId`, so lexical shadowing follows binder
scope identity and unresolved names never fabricate symbols. Recovered results
distinguish resolved, uninitialized, unresolved, and error states; nominal
declarations keep stable declaration identities inside the owning result.

This layer imports from `src/types/` (the pure model) and from the frontend (`ast.zig`, `binder.zig`) for symbol/node identity. The direction is intentional: semantics consumes types, not the other way around.

Expression inference covers identifiers, unary/binary/conditional/sequence,
assignment/update, `as`, and `satisfies` expressions. One operator table drives
result types and invalid-operand diagnostics. Plain assignment expressions
have the assigned value's type; compound assignments use their corresponding
binary operator. `as` uses the asserted type, while `satisfies` validates the
target but preserves the source type. Array literals infer a homogeneous
element type (a normalized union for heterogeneous values); a structured array
annotation may instead contextually require an array or fixed-position tuple.
Array holes remain tuple shape metadata and never synthesize `undefined` values.
Object inference covers shorthand, computed properties, methods, accessors, and
spreads. Known object spreads contribute properties; unknown/non-object spreads
contribute no known keys. Properties retain first-seen order and the last source
definition wins duplicates. Computed literal keys keep their literal name while
dynamic keys receive stable node-based synthetic names. Recursive object shells
use reserved identities. Readonly syntax is retained on arrays, tuples, and
object properties. Property and indexed access distribute across unions and
succeed only when every non-nullish branch supports the key. Optional chaining
drops nullish branches and adds `undefined`; tuple holes and optional elements
also produce `undefined`. Method access records receiver type on `NodeTypeInfo`
without changing the canonical function type. Calls use canonical signatures,
validate count and argument types, retain method receivers, and infer annotated
or body-derived returns.

Control-flow narrowing consumes each function CFG and records `FlowTypeInfo`
entries keyed by function, block, symbol, and reference node. Truthy/falsy,
`typeof`, null/undefined equality, `instanceof`, and `in` guards narrow facts;
branch joins remain conservative. Assignment and update invalidate their target,
while calls with an `any` or `unknown` callee clear facts. Terminating branches
propagate the surviving facts to following statements. Expression-bodied arrows
are normalized to one CFG body statement. This v1 pass does not model complete
reachability, discriminated unions, exception edges, or interprocedural effects.
Broader TypeScript compatibility remains incomplete.

Structural compatibility is centralized in `src/semantics/type_compat.zig`.
Its source-to-target `check` API covers primitives and literals, deterministic
unions, arrays, tuples, objects, and functions. Recursive comparisons use an
active-pair guard plus successful-pair memoization. Failures retain the first
deterministic property, tuple, union, parameter, or return path for the checker.
The v1 policy is covariant for array elements and function returns,
contravariant for function parameters, rejects readonly sources assigned to
mutable targets, and rejects optional source properties where a required target
property is expected. `any` bypasses checking, `unknown` is only a source for
`unknown` or `any`, `never` is a valid source, and the recovered error sentinel
is compatible to suppress derivative diagnostics.

Checker v2 consumes the already-built frontend result, canonical `TypeInfo`,
and its owning `TypeStore`; it does not parse again or create a competing type
table. Inference records operator, property, index, call, and `satisfies` issue
metadata on `NodeTypeInfo`. The checker uses that metadata plus the shared
compatibility engine for variable initializers, assignments, returns, calls,
and access expressions. Unresolved, unknown, and recovered-error operands
suppress derivative errors. Diagnostics carry an offending primary span, a
related declaration or operand span where available, and deterministic source
ordering.


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

`src/main.zig` is an inspection CLI around the semantic and module layers. Single-file commands read one file and create one `SemanticResult`; they reuse its frontend snapshot and never reparse for `check` or `types`. The modules command uses `graph.build` plus `linker.Linker`:

- `check`
- `tokens`
- `ast`
- `symbols`
- `references`
- `refs`
- `cfg`
- `types`: print canonical symbol and expression types through the owning `TypeStore`, including structural summaries and qualified nominal identities
- `modules`: print modules + import edges + **Links** (per-link resolved target or unresolved for external imports) + diagnostics
- `help`

The CLI is intentionally diagnostic and exploratory. It is not a compiler driver.

## Diagnostics

Diagnostics are phase-tagged records with a severity, stable code, display name, message, source span, optional label, and optional path. Current diagnostics come from scanner, parser, binder, resolver, module graph, and semantic checking phases. Future phase names already exist in the enum, but their systems are not implemented yet.

## Future Layers

Likely future layers are intentionally separate from the current frontend and module graph:

- Expanded module layer: package lookup, configuration-aware resolution, and richer import/export forms.
- Type checker expansion: add advanced TypeScript forms beyond the supported Typed Semantics v2 subset.
- HIR/lowering: lower AST or typed AST into a more compiler-friendly intermediate form.
- Runtime/compiler layers: execute, interpret, compile, or emit code from lowered forms.

## Non-Goals For Current Milestone

The current milestone does not implement:

- Package, `node_modules`, `package.json`, or `tsconfig` resolution.
- Dynamic imports or CommonJS.
- Bundling, tree shaking, or runtime module loading.
- Complete TypeScript type checking.
- JavaScript runtime behavior.
- Native compilation or code emission.
- Complete JavaScript or TypeScript grammar coverage.
- Optimization passes.
