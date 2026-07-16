# Architecture

`vizg` has one portable core, one official memory-first C ABI v1, optional host
adapters, and executable composition roots. The frontend produces tokens, AST,
bindings, references, CFGs, canonical types, links, and diagnostics. Project
analysis owns a host-driven module graph and its semantic results.

## Frozen Portable Target Architecture

The first official public ABI is identified by `VIZG_ABI_VERSION = 1`.
All earlier ABI surfaces were internal and unpublished. They were deleted
without a compatibility shim, deprecated aliases, a legacy library, or a
parallel versioned library.

Responsibilities are fixed:

- Core parses host-supplied source, derives imports and exports, owns graph and
  semantic analysis, and returns owned data through memory-first APIs.
- Hosts resolve import specifiers, assign opaque `ModuleId` values, and provide
  source bytes or external-module metadata. Paths and URLs are labels, never
  implicit identities.
- Executables compose core and host adapters and own arguments, output,
  environment access, and lifecycle.

Core never calls host code. Requests and responses cross the API boundary, and
the host drives progress by calling the core again. Native filesystem support
is an optional host adapter, not a core dependency. Goal 188 closed the final
portable-core audit on 2026-07-14. HIR implementation is now governed by the
strict Goals 208–237 chain. The project-input ABI v1 remains frozen; public HIR
access is additive and independently versioned.

## Portable Roots And ABI Boundary

`src/root.zig` is the portable Zig package root. It exports frontend, project,
semantics, and type APIs and imports neither ABI nor adapter code.

### Portable project contracts

`src/project/` defines the project boundary. Hosts assign opaque 64-bit
`ModuleId` values and supply `ModuleSource` descriptors. A logical name is
diagnostic text only: it is never an identity, cache key, resolved path, or URL.
Equal names may identify different modules, and one identity may be shown under
different names.

The core assigns opaque 64-bit `RequestId` values to unresolved
`ModuleRequest` records. Each request preserves importer identity, raw
specifier, source span, borrowed attributes, and one explicit kind: static,
type-only, dynamic, or re-export. Resolution remains host-owned.

Descriptor slices are borrowed for the receiving call. Any retained data is
copied into core-owned storage. IDs and enums have fixed widths. The C ABI uses
pointer/length spans and never embeds Zig slice layout.

`project.Project` owns the session, copied source, module state, analysis, and
result arenas. Revisions, duplicate/conflict handling, partial failure, request
deduplication, FIFO stepping, stale response rejection, cycles, external
modules, export tables, and hard limits are explicit and deterministic.
`finish()` performs no hidden analysis.

### Official C ABI v1

`Lib/abi.zig` adapts the portable project engine to the declarations in
`Lib/vizg.h`. `Lib/vizg.zig` is the library root. `Vizg_Project` and
`Vizg_ProjectResult` are opaque handles. Hosts create a project, add root
source, repeatedly pull one request, answer with source, external metadata, or
failure, and finish only after completion. `vizg_project_analyze_source`
drives the same engine and resolves derived imports as not found.

The ABI performs no filesystem operation or callback. Strings are exact
pointer/length spans. Submitted bytes are borrowed for one call and copied when
retained. Step output is borrowed until the next project call. A finished
result is immutable, survives project destruction, and has explicit cleanup.

Ownership and recovery are exact:

- The caller owns the workspace and every submitted span. Retained descriptors
  are copied; request output remains borrowed until the next project call.
- One project handle is single-threaded. Independent workspaces and immutable
  result reads may run in parallel. Destruction must be externally synchronized.
- Destroy a non-null project and result exactly once. Result data survives
  project destruction, but the workspace remains reserved and immutable until
  result destruction.
- `INVALID_ARGUMENT` and `INVALID_STATE` identify rejected input or sequencing.
  `LIMIT_EXCEEDED` and `OUT_OF_MEMORY` identify configured-bound and workspace
  exhaustion. `INTERNAL_ERROR` is terminal.
- Non-OK operations are not a general rollback boundary once analysis or
  allocation starts. After exhaustion, limit failure, or internal failure,
  destroy and restart. A successful `finish` may return a partial result:
  completed modules and links remain inspectable and `has_failures` records
  terminal source/external resolution failures.

All tags use `uint32_t`, identities use `uint64_t`, booleans use `uint8_t`,
and lengths use `size_t`; public structures contain no C `enum` or `bool`.
Reserved bytes must be zero and boolean bytes accept only 0 or 1.

Project storage is one aligned caller-owned workspace. All state, retained
source, semantic state, and result storage comes from that bounded region.
Limits cover cumulative source bytes, modules, diagnostics, graph depth, and
canonical semantic types. Inputs must not overlap the workspace. Separate
workspaces isolate independent analyses.

The same header and exact official symbol set are used for native, Android,
and freestanding WebAssembly builds. `zig build abi-symbols-test` enforces the
native tables. `zig build wasm-freestanding` additionally inspects
the WebAssembly tables: there are zero imports and the only exports are linear
`memory` plus those official functions.

The project-input ABI v1 function table is:

```txt
vizg_project_add_source
vizg_project_analyze_source
vizg_project_create
vizg_project_destroy
vizg_project_finish
vizg_project_respond_external
vizg_project_respond_failure
vizg_project_respond_source
vizg_project_result_destroy
vizg_project_result_summary
vizg_project_step
vizg_project_workspace_alignment
vizg_project_workspace_overhead
```

HIR access is additive and separately versioned by
`VIZG_HIR_API_VERSION = 1`:

```txt
vizg_hir_api_version
vizg_hir_record_at
vizg_hir_summary
```

These functions inspect only verified immutable HIR owned by an opaque finished
result. `Vizg_HirSummary` gives deterministic entity counts and
`Vizg_HirRecord` iterates modules, external declarations, functions, blocks,
instructions, bindings, types, and origins. Record strings are borrowed until
`vizg_project_result_destroy`. Unsupported versions, invalid kinds, and
out-of-range indices return controlled status values.

On `x86_64-linux`, the exact undefined native archive table depends on the
selected optimization mode:

| Mode | Imports |
| --- | --- |
| Debug | `_DYNAMIC`, `__divti3`, `__modti3`, `__tls_get_addr`, `getauxval`, `memcpy`, `memmove` |
| ReleaseSafe | `_DYNAMIC`, `__divti3`, `__tls_get_addr`, `__zig_probe_stack`, `getauxval`, `memcpy`, `memmove`, `memset` |
| ReleaseFast / ReleaseSmall | `memcpy`, `memmove`, `memset` |

These are native compiler/runtime support symbols. They do not represent
filesystem, process, POSIX, WASI, allocator, or host-callback use by core. The
`wasm32-freestanding` import table is exactly empty; its export table is
`memory` followed by the 16 functions above.

For `wasm32`, every pointer and `size_t` is a 32-bit byte offset/count in the
exported linear memory. The host grows memory, chooses a workspace satisfying
`vizg_project_workspace_alignment`, and keeps config/input descriptors and
their byte spans outside that exclusive workspace. Non-empty spans must be
in-bounds. The module never allocates through a host import. Because
`memory.grow` replaces the JavaScript `ArrayBuffer`, a host must rebuild its
typed views after growth. Request/step pointers are borrowed until the next
project call, while a finished result continues to occupy the workspace until
result destruction.

The reference glue in `test/wasm/official_abi_v1.mjs` remains outside
`src/root.zig`. It writes the fixed ABI records into linear memory and drives
source, missing, and external responses; native and WebAssembly execution use
the same `Lib/abi.zig` engine.

### Reference native filesystem host

`src/adapters/fs_module_host.zig` is an optional driver for the portable
project API. It loads a root file, repeatedly calls `Project.step()`, and maps
filesystem outcomes to source, not-found, denied, or failed responses. Core has
no filesystem branch or policy.

Within one host session, canonical real paths key stable module identities.
Only relative specifiers are accepted. Extension-less requests try TypeScript
and JavaScript extensions and matching index files. The canonical root
directory confines traversal and symlinks. File metadata is checked before
source allocation, and configured source/module limits are enforced.

`src/main.zig` owns command-line file reads. Single-file commands call the
source-only semantic API. The `modules` command composes the portable project
with `FsModuleHost`. Alternate hosts replace only this driver.

Build dependency direction:

```txt
consumer -> Lib/vizg.h -> libvizg.a
libvizg.a root: Lib/vizg.zig -> Lib/abi.zig -> src/root.zig
native executable: src/main.zig -> src/root.zig + src/adapters/
filesystem adapter -> src/root.zig
src/root.zig -/-> ABI or adapters
```

`zig build lint-portable-core` references every public declaration while
compiling `src/root.zig` for `wasm32-freestanding`. It rejects filesystem,
process, POSIX, WASI, environment, adapter, and ABI dependencies and is required
by both `test` and `validate`.

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

`src/adapters/native_fs/graph.zig` builds on `frontend.analyze` and the portable
records in `src/modules/graph.zig`:

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

`SemanticImport` records named, default, namespace, type-only, external, unresolved, and cyclic-partial states with its local symbol, target identity when known, runtime-binding flag, and stable source span. Namespace imports use an owned structural object made from runtime exports. Descriptor-backed external imports retain external provenance and declared portable types; missing external members remain inspectable unresolved links and emit a stable graph diagnostic.

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

`cross_check.zig` references the public declarations in the frontend, types, and semantics layers. `zig build cross-check` compiles that generic probe as an object for representative Linux, Windows, macOS, WASI, and Android targets. `zig build abi-cross-check` separately compiles target static archives using the consumer dependency graph (`src/root.zig` and `Lib/vizg.zig`) and compiles the official C ABI v1 header probe. Neither step runs foreign code.

Generic layers must not branch on the target OS. Platform-dependent work stays in adapters such as `src/main.zig` for CLI interaction, `src/adapters/native_fs/` for filesystem-backed loading, `Lib/vizg.zig` for the official C ABI v1, and build/packaging helpers. The ABI matrix proves that its adapter compiles for the listed targets; it does not claim runtime validation there.

Shared diagnostics live outside the frontend:

- `src/diagnostics/root.zig`: severity, phase, stable diagnostic codes, messages, spans, and optional paths.
## CLI Layer

`src/main.zig` is an inspection CLI around the source-only semantic API and the
portable project API. Single-file commands read one file into memory and create
one `SemanticResult`; they reuse its frontend snapshot and never reparse for
`check` or `types`. The `modules` command drives `Project.step()` through the
optional `FsModuleHost` adapter:

- `check`
- `tokens`
- `ast`
- `symbols`
- `references`
- `refs`
- `cfg`
- `types`: print canonical symbol and expression types through the owning `TypeStore`, including structural summaries and qualified nominal identities
- `modules`: print portable module states, request/import kinds, preserved
  specifier spans, semantic links, and diagnostics
- `help`

The CLI is intentionally diagnostic and exploratory. It is not a compiler driver.

## Diagnostics

Diagnostics are phase-tagged records with a severity, stable code, display name, message, source span, optional label, and optional path. Current diagnostics come from scanner, parser, binder, resolver, module graph, and semantic checking phases. Future phase names already exist in the enum, but their systems are not implemented yet.

## Frozen HIR v1 Final Product

HIR v1 is ViZG's final product layer and remains separate from the frontend and
module graph. Its normative contract is
[`hir-v1-design.md`](hir-v1-design.md), its exhaustive source mapping is
[`hir-v1-lowering-matrix.md`](hir-v1-lowering-matrix.md), and its strict
implementation and freeze order is Goals 208–237 in [`VIZG_PLAN.md`](../VIZG_PLAN.md).
HIR uses typed ANF-like values, explicit mutable bindings, blocks and
terminators; it is neither SSA-lite nor MIR. Structured `if`, ternary and loop
syntax lowers to control-flow blocks, never final syntax-shaped HIR nodes.
The portable Zig root exports `hir`; each sealed `HirResult` owns its HIR
allocations, immutable type snapshot, provenance and strings, and scopes every
HIR ID to one result-local identity domain. Semantic/project teardown cannot
invalidate an owned result. The core schema exposes modules, external
declarations, entities,
canonical functions, bindings, captures, semantic places, regions, blocks,
instructions and terminators. Its closed operation union validates immediate
payload shape, derives conservative effects, and contains no AST fallback,
mutable-binding phi, machine type, or memory-management metadata.
An eligibility gate runs before HIR allocation: it requires complete local
semantics, rejects blocking or recovered unsupported syntax, validates linked
module/symbol/type identities, and applies canonical input and output budgets.
Failures use stable `VZG7xxx` diagnostics and expose no partial `HirResult`;
linked external identities remain body-less typed declarations without
fabricated bodies. Host-supplied `ExternalSymbolId` values are stable across
descriptor order; declaration kind, complete function types, conservative
effects, and provenance survive lowering without target or backend metadata.
Eligible projects lower deterministically to one shell per reachable source
module. Shell identity is the exact host-supplied `ModuleId`; logical names are
descriptive only. Each shell owns one module-initialization function and records
initialization dependencies from resolved static and re-export graph edges.
Import and export descriptors retain their linked semantic declarations and
types. Graph cycles are traversed iteratively and never duplicate shells, and
lowering performs no specifier resolution or filesystem access.
Module and block declaration lowering resolves every declaration and identifier
through binder/resolver `SymbolId`s; spelling is never an identity lookup key.
Bindings record `var` hoisting, function hoisting, live imports, and `let`/`const`
temporal-dead-zone initialization explicitly. Literals become typed HIR values,
while type aliases, interfaces, type nodes, `as`, `satisfies`, and non-null
wrappers emit no executable operation; transparent wrappers reuse the operand
value and retain semantic type identity. Function declarations create canonical
function/entity shells, with body lowering deferred to its ordered phase.
Expression lowering is block-aware ANF: callees and arguments evaluate in
left-to-right source order, sequence expressions retain every effect and yield
their last value, and conditional expression results cross control-flow edges
only as typed block arguments and parameters. The ANF builder assigns each
temporary once and rejects instruction or terminator operands that have not
already been defined in the same result identity domain.
Assignments and updates lower through semantic `PlaceId` references for
bindings, static properties, computed elements, and super properties. A place
captures its already-evaluated base and key, never a physical address or
storage layout. Simple and non-logical compound assignments, prefix/postfix
updates, and `delete` become explicit make/load/store/delete sequences; target
evaluation precedes the right-hand side and occurs exactly once. Logical
assignments use nullish or boolean branches and store only on the selected arm.
Unary and binary operations retain their typed semantic modes. Logical,
conditional, and optional-chain expressions lower to explicit branches and
typed block-parameter merges, so unselected computed keys and arguments do not
evaluate.
Property reads use places plus `load_place`. Ordinary calls, receiver-preserving
method and super calls, super-constructor calls, and construction remain
distinct operations. Callees, bases, computed keys, and arguments preserve
source order and single evaluation, including optional method calls whose
property value is tested before their arguments. `import.meta` and `new.target`
remain explicit meta loads. Dynamic import retains its runtime source, options,
and attributes in HIR; HIR performs no specifier resolution.
Aggregate lowering preserves object member and array element source order,
distinguishes array holes from values and iterable spread, and keeps call spread
context-specific. Untagged templates perform ordered string conversion; tagged
templates retain receiver semantics, raw/optional-cooked segments, and stable
source-site identity. Regexp creation retains canonical flags and stable
source-site identity while creating a fresh value for every evaluation.
Function declarations, expressions, arrows, object methods/accessors, and
async/generator variants lower through one canonical function-body path.
Parameter plans explicitly read arguments, branch for ordered per-call default
initializers, and collect rest values from their ordinary argument index.
Optional syntax erases, while parameter-property metadata remains available for
class initialization. Closure captures use already resolved semantic identities
and distinguish live bindings from lexical receiver state without choosing an
environment layout.
Conditional statements and synchronous loops lower to explicit blocks and
terminators. Classic `for` retains a distinct update block, `do...while` enters
its body before testing, and `for...in` uses semantic property-enumeration
operations rather than a library-call approximation. `for...of` uses explicit
iterator next/done/value operations; normal exhaustion reaches the exit
directly, while abrupt completion crosses an iterator-close cleanup region.
`switch` evaluates its discriminant once, tests non-default cases lazily in
source order with strict equality, and represents case fallthrough only with
block edges. Break and continue targets are resolved to exact block identities;
label spellings do not survive in executable HIR, including across nested loops,
switches, and iterator-close regions.
Exception control flow uses target-independent catch and cleanup regions.
`finally` has one shared handler and resumes an explicit pending normal, return,
throw, break, or continue completion; an abrupt completion created by the
handler replaces that pending completion. Catch parameters initialize only on
handler entry. Region ownership, nesting, protected-entry edges, cleanup exits,
and resume sites are structurally validated without selecting an exception ABI.
Async and generator functions retain their semantic flags. `await`, `yield`,
and delegated `yield*` lower to typed suspension operations with owned source
origins. `for await...of` explicitly acquires an async iterator, awaits each
next result, and reuses the iterator-close cleanup-region contract for abrupt
completion. HIR does not synthesize state-machine blocks, resume dispatch,
runtime frame layout, or promise machinery.
Class declarations and expressions lower to one runtime class entity with one
canonical constructor, method/accessor functions, and source-ordered instance
and static field-initialization plans. `extends` evaluates once; explicit
derived-constructor `super()` calls remain distinct operations, and parameter
properties initialize after that call. Class bindings retain temporal-dead-zone
state. Enums lower to ordered runtime objects: numeric members add reverse
mappings while string members do not. Module initialization preserves source
order, deterministic cyclic dependencies, live import/export bindings, named
and star re-export identity, without choosing prototype, object-layout, or
constructor ABI policy.
Every eligible lowering then runs the same mandatory HIR canonicalization,
independent of optimization mode. Its deterministic fixed-order worklist folds
safe primitive literals, replaces literal branches, eliminates trivial copies,
collapses identical merge values, removes unreachable blocks and unused
proven-pure instructions, merges legal empty jump blocks, and normalizes
`return undefined` to an empty return. Rewrites retain surviving instruction
origins, never discard observable effects or identity creation, and consume the
bounded `rewrites` budget; exhaustion fails lowering with `VZG7009` and no
partial result. This stage only establishes canonical HIR shape and performs no
MIR or target-dependent optimization.
HIR debug metadata is result-owned side-table data selected independently from
executable lowering. `none` leaves every executable origin invalid and records
no trace; `minimal` gives every instruction and block terminator a valid origin
(the block origin is the terminator origin) with the exact opaque host
`ModuleId`, primary span, AST contributors, syntax kind, semantic declaration,
type, parent, lowering rule, and synthetic reason where applicable. `full`
retains the same origins and adds transformation events for source lowering,
erased syntax, and canonical rewrites. Trace events may therefore describe an
interface or type alias with no executable output. Paths and logical module
names are never used to reconstruct module identity, and selecting a debug
level cannot change executable HIR shape.
HIR also has a deterministic text printer for debugging and tests. Canonical
output walks only stable project-owned slices and renders checked numeric IDs,
never pointer values or hash-table order. Brief, typed, provenance, and full
trace views are projections of the same immutable HIR; type and origin
annotations can be selected independently. Invalid or foreign IDs produce
controlled markers instead of indexing project storage. Reference snapshot
tests exercise every supported lowering family.

The Zig project/session layer is the canonical HIR construction entry point. Once
`Project.finish` has produced complete project semantics, `hir.deriveProject`
performs eligibility checking, lowering, canonicalization, verification, and
result sealing. Repeated calls are idempotent and return the same immutable
result. Public Zig `ConsumerView` lookup/iteration covers every HIR entity,
type, effect, and origin with controlled invalid/foreign-ID errors. The
project-input C ABI v1 remains unchanged; the separately versioned HIR ABI
exposes deterministic summary/record iteration through the opaque result.

HIR construction is bounded under adversarial input. Every generic arena,
nesting, provenance, and project-growth limit is checked before mutating the
owned result and reports `VZG7010`; this includes active cleanup-region nesting.
Canonical rewrite convergence is the deliberate exception: exhausting that
stage's dedicated rewrite budget reports `VZG7009`. Deep and wide control flow,
cyclic modules, abrupt iterator cleanup, large traces, deterministic mutation
corpora, and corrupted-HIR verifier fixtures exercise these contracts in every
optimization mode without introducing target-dependent behavior.

Outside-product concerns remain intentionally unassigned:

- Expanded module layer: package lookup, configuration-aware resolution, and richer import/export forms.
- Type checker expansion: add advanced TypeScript forms beyond the supported Typed Semantics v2 subset.
- Global optimization, representation, memory management, execution,
  interpretation, compilation, code emission, linking, and packaging are not
  ViZG layers. Independent consumers may implement them.

## Non-Goals For Current Milestone

The current milestone does not implement:

- Package, `node_modules`, `package.json`, or `tsconfig` resolution.
- Dynamic-import runtime loading or CommonJS execution.
- Bundling, tree shaking, or runtime module loading.
- Complete TypeScript type checking.
- JavaScript runtime behavior.
- Native compilation or code emission.
- Complete JavaScript or TypeScript grammar coverage.
- Optimization passes.
