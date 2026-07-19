# Architecture

`vizg` has one portable core, one official memory-first C ABI v1, optional host
adapters, and executable composition roots. The frontend produces tokens, AST,
bindings, references, CFGs, canonical types, links, and diagnostics. Project
analysis owns a host-driven module graph and its semantic results.

## Frozen Portable Target Architecture

ViZG is an environment-independent frontend and semantic engine. It does not
resolve module specifiers.

Responsibilities are fixed:

- ViZG parses host-supplied source, discovers imports/exports/re-exports, emits
  unresolved module requests, owns the graph, and performs semantic analysis.
- The runtime or consumer resolves raw specifiers, assigns opaque `ModuleId`
  values, and supplies source bytes, external metadata, or failure responses.
- Filesystem, URL, package, database, memory, and virtual-module policies remain
  outside ViZG.
- Concrete hosts in this repository are tests or development examples only.

Paths, URLs, logical names, and raw specifiers are labels. Only host-assigned
`ModuleId` values identify source modules. `ExternalModuleId` is a separate
identity domain.

## Portable Roots And ABI Boundary

`src/root.zig` is the portable Zig package root. It exports frontend, project,
semantic, and type APIs and imports neither ABI nor host fixtures.

### Portable project contracts

`src/project/contracts.zig` defines fixed-width module/request identities,
source descriptors, request attributes, external descriptors, and orthogonal
request metadata:

```txt
operation = static_import | re_export | dynamic_import
type_only = false | true
```

This represents `export type ... from` without treating type-only as a resolver
kind. Requests preserve the raw source specifier, attributes, and source span.
ViZG does not normalize or interpret the specifier.

Each external export independently declares its namespace availability as
`value`, `type`, or `both`. The zero flag set is invalid. Linking filters the
descriptor against the namespace requested by the import; `both` therefore
supports one imported class name in both `new ExternalClass()` and an
`ExternalClass` type annotation. The C ABI represents the same contract with
`VIZG_EXTERNAL_NAMESPACE_VALUE`, `VIZG_EXTERNAL_NAMESPACE_TYPE`, and
`VIZG_EXTERNAL_NAMESPACE_BOTH`.

The additive external-module API v2 carries the rest of the origin-neutral
publication contract needed by HIR: a stable external symbol identity,
declaration kind, portable function signature, and effect flags. Hosts discover
the extension through `vizg_external_module_api_version()` and answer with
`vizg_project_respond_external_v2()`. The original external response remains
available unchanged; neither form accepts filesystem, header, library, linker,
or other origin policy.

`Project` is one-shot. A source identity is supplied once, `step()` analyzes
reachable modules and returns one pending request at a time, every request is
answered once, and `finish()` is terminal. There are no source revisions or
stale-request states. A host needing a new source revision creates a new project.

After `finish()`, `Project` owns one deterministic canonical diagnostic table.
Every module-originated row carries its host-assigned `ModuleId` directly;
logical names remain labels and are never identity lookup keys. The table maps
single-file diagnostics to scanner, parser, binder, resolver, types, or checker,
host request failures to module-host, and graph/link failures to project. The
Zig and C result accessors read this same table without a late merge.

All submitted slices are borrowed for the call and copied when retained.
Project state and semantic output live until project destruction.

### Official C ABI v1

`Lib/vizg.zig` roots the static library and `Lib/abi.zig` implements
`Lib/vizg.h`. The ABI uses opaque `Vizg_Project` and `Vizg_ProjectResult`
handles over one caller-owned aligned workspace.

Lifecycle:

```txt
create
  -> optionally register ambient globals
  -> optionally add one source-backed global root
  -> add source(s)
  -> step / respond exactly once per request
  -> step complete
  -> finish
  -> read immutable result views
  -> destroy project
```

Ambient globals must be registered before any source is added. ViZG copies the
borrowed descriptors into project-owned storage. The base registration call
carries coarse type metadata; the V2 call adds structural member descriptors.
Host-assigned identities flow through HIR detail API v2, and descriptor-declared
readonly self references preserve identity during HIR lowering without adding
general property or runtime semantics.

A source-backed global root is submitted before ordinary project roots and is
analyzed as source rather than converted into host-owned ambient descriptors.
Its source identity is retained in semantic and HIR dependency records. The
additive `vizg_project_add_global_root` entry point exposes the same operation
through the C lifecycle; ViZG does not assign runtime or platform meaning to
the declarations.

`finish()` returns a project-owned immutable view. Repeated calls return the
same view without allocation. The view becomes invalid when the project is
destroyed. There is no independent result owner, result destructor, convenience
file function, or convenience single-source ABI.

The result surface provides summary, modules, canonical diagnostics, graph
edges, semantic imports, and semantic exports. Strings and spans returned from a
result remain borrowed from the project until destruction.

The official ABI layout remains v1, while the read-only HIR record projection
is independently versioned. HIR record API v2 preserves the v1 struct and
lifecycle but reports an instruction's optional result `ValueId` in
`secondary_id`; v1 requests remain accepted and retain the original parent
function interpretation. The parent function is derivable from the instruction
parent block, so v2 exposes the otherwise unavailable definition identity.
The separately versioned HIR detail projection preserves wrapped public
function return types and also exposes each function body's completion type.
For async functions and generators this lets downstream consumers validate
`return` instructions without depending on ViZg's private type-store layout.

Finalization computes the closure reachable from submitted roots through
resolved local import edges. Only that closure is validated and retained in the
final module, edge, diagnostic, import, and export views; unreachable
pre-supplied source is excluded. Summary flags are computed from canonical
error diagnostics by phase: scanner/parser, binder/resolver/types/checker,
project, and module-host errors populate the syntax, semantic, project, and
module-failure groups respectively. The summary is partial when any group is
set, so every public error diagnostic is represented.

Semantic import and re-export rows retain their exact graph edge index. Local
and external identities occupy separate fields, and every optional module,
external-module, and edge value has an explicit `has_*` flag. Consumers must not
interpret numeric zero as an absent identity or edge.

Every public typed pointer is checked for C alignment and its complete range is
validated before dereference or output initialization. Nested strings and typed
arrays are validated before slices are formed. WASM offsets are checked against
current linear memory; host input and output must not overlap the exclusive
project workspace, and project creation also rejects config/output aliasing.
Range overflow, invalid tags, non-zero reserved bytes, invalid booleans, and
invalid response order return a controlled status. Pointer-validation failures
return `INVALID_ARGUMENT` before project state or host output is mutated.

Configured project-owned limits cover per-module and aggregate source bytes,
modules, requests, edges, diagnostics, graph depth, and semantic types. Each
owner checks its bound before copying retained data or growing a collection.
The single-source representation ceiling is `VIZG_MAX_SOURCE_LENGTH`
(`UINT32_MAX`) because source offsets, span endpoints, lines, and columns are
stable `uint32_t` values. Configuration cannot raise the per-source limit above
that ceiling; the rejected create returns a destroy-only handle whose limit kind
is `SOURCE_BYTES`. Source descriptors over it are rejected before nested pointer
range access, copying, or scanner entry; aggregate byte addition is
overflow-checked before mutation.
Graph depth is computed after resolution as the shortest resolved-edge distance
from any root; relaxation makes cycles converge and removes discovery-order and
host-response-order dependence. The source-response path preflights that
prospective shortest depth and rejects an over-depth response without consuming
the request or mutating source/module/edge state. Limit or allocation exhaustion
is terminal for that project. Immediately after `LIMIT_EXCEEDED`,
`vizg_project_limit_kind` identifies the exact non-`NONE` limit category,
including parser recursion; successful and non-limit project calls reset it to
`NONE`.

Fallible project mutations are ownership-transactional even though allocation
exhaustion remains terminal for the caller. Source copying, the frontend and
semantic pipeline, derived metadata, requests and edges, external descriptors,
project semantics, canonical diagnostics, and ABI snapshot preparation remove
all partially retained allocations on failure. Semantic and ABI result pointers
are published only after their complete commit. Exhaustive fault-injection tests
run each scenario once successfully and then fail every allocation index,
checking teardown and publication invariants at every boundary.

The official export table is:

```txt
vizg_abi_version
vizg_external_module_api_version
vizg_project_workspace_alignment
vizg_project_workspace_overhead
vizg_project_create
vizg_project_destroy
vizg_project_limit_kind
vizg_project_add_source
vizg_project_step
vizg_project_respond_source
vizg_project_respond_external
vizg_project_respond_external_v2
vizg_project_respond_failure
vizg_project_finish
vizg_project_result_summary
vizg_project_result_module
vizg_project_result_diagnostic
vizg_project_result_edge
vizg_project_result_import
vizg_project_result_export
```

Native, Android, and `wasm32-freestanding` builds use the same header and ABI.
The WASM build exports linear memory and the allowlist above and imports no host
service.

This ABI v1 surface is frozen. Goal 207's repeated source, lifecycle, hostile
input, fault-injection, limit-boundary, native-symbol, and WASM-export audit is
recorded in [`FINAL_AUDIT.md`](FINAL_AUDIT.md). Future incompatible contract
changes require a new ABI version; HIR may consume this contract but must not
silently change it.

### Module-host validation fixtures

`test/support/fs_validation_host.zig` proves that an external host can drive the
contract from files. It is not a resolver supplied by ViZG and is not exported
through `src/root.zig` or `Lib/vizg.h`.

The development CLI may compose this fixture to validate multi-file behavior.
Production runtimes implement their own resolution policy. In-memory project
tests are the primary core validation mechanism.

Build dependency direction:

```txt
consumer -> Lib/vizg.h -> libvizg.a
libvizg.a: Lib/vizg.zig -> Lib/abi.zig -> src/root.zig
validation CLI: src/main.zig -> src/root.zig + test/support fixture
src/root.zig -/-> ABI, filesystem, or host fixtures
```

`zig build lint-portable-core` compiles all public declarations for
`wasm32-freestanding`. `zig build lint-module-host-boundary` additionally scans
public core/ABI roots and rejects concrete resolver-policy dependencies.

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

The portable `Project` layer supplies analyzed frontend results to the borrowed
semantic graph records in `src/modules/`. No file loading or specifier
resolution occurs there.

```txt
host-supplied source + ModuleId
  -> frontend.analyze
  -> discover raw imports/exports/re-exports
  -> emit ModuleRequest
  -> host responds with source/external/failure
  -> record host-resolved edge
  -> build semantic graph and linked imports
```

### Cross-file Linking

`src/modules/linker.zig` links binder import records against the target modules
selected by host-resolved edges. Links classify named, default, namespace,
external, and unresolved bindings. The linker does not open files, interpret
specifiers, call a host, or apply package policy.

### Module Layer Files

- `src/project/`: owned request/response session and source-derived graph.
- `src/modules/root.zig`: borrowed graph/link structures used by project
  semantics.
- `src/modules/graph.zig`: modules, host-resolved edges, linked imports, and
  module diagnostics.
- `src/modules/linker.zig`: cross-module symbol link construction.
- `src/modules/externals.zig`: legacy-neutral external metadata helpers; no
  loading or resolution.

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

`analyzeProject` builds the existing `ModuleGraph`, including descriptor-backed
external modules, then `analyzeModuleGraph` consumes every source module's
existing `FrontendResult` without reparsing. External descriptors are lowered
to canonical value/type identities in the shared store before import and
re-export propagation begins. One project-wide canonical `TypeStore` supplies
every module `TypeInfo` and every exported/imported `TypeId`; IDs are comparable
only inside that `ProjectSemanticResult`.

`SemanticIdentity` contains a source or external-module identity, optional
binder symbol ID, declaration identity, namespace, and canonical type ID.
`SemanticExport` covers value declarations, functions, classes, enums,
interfaces, type aliases, and descriptor-backed external declarations. Aliases
and named/star/default re-exports retain the target identity rather than
inventing a second declaration identity.

`SemanticImport` records named, default, namespace, type-only, external, unresolved, and cyclic-partial states with its local symbol, target identity when known, runtime-binding flag, and stable source span. Namespace imports use an owned structural object made from runtime exports. Descriptor-backed external imports retain external provenance, declared portable types, and value/type namespace availability; missing external members remain inspectable unresolved links and emit a stable graph diagnostic.

Propagation uses one bounded project fixed point over source and external
identities. Cyclic graphs terminate; known declarations remain available while
incomplete links keep stable `unknown` or cyclic-partial states. The final
checker consumes the propagated `TypeInfo` and canonical `TypeId`s directly;
semantic types are not patched after checking. Diagnostics mark the result
partial but do not invalidate modules, identities, types, or links.

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

The single-file pipeline receives source text directly. The project and module layers are host-resolved and contain no filesystem-aware wrapper.

## Platform Boundary

`cross_check.zig` references the public declarations in the frontend, types, and semantics layers. `zig build cross-check` compiles that generic probe as an object for representative Linux, Windows, macOS, WASI, and Android targets. `zig build abi-cross-check` separately compiles target static archives using the consumer dependency graph (`src/root.zig` and `Lib/vizg.zig`) and compiles the official C ABI v1 header probe. Neither step runs foreign code.

Generic layers must not branch on the target OS. Platform-dependent work stays in adapters such as `src/main.zig` for CLI interaction, `test/support/fs_validation_host.zig` for test-only filesystem-backed loading, `Lib/vizg.zig` for the official C ABI v1, and build/packaging helpers. The ABI matrix proves that its adapter compiles for the listed targets; it does not claim runtime validation there.

Shared diagnostics live outside the frontend:

- `src/diagnostics/root.zig`: severity, phase, stable diagnostic codes, messages, spans, and optional paths.

## CLI Layer

`src/main.zig` is an inspection CLI around the source-only semantic API and the
portable project API. Single-file commands read one file into memory and create
one `SemanticResult`; they reuse its frontend snapshot and never reparse for
`check` or `types`. The `modules` command drives `Project.step()` through the
test-only `FsValidationHost` fixture:

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

## Future Layers

Likely future layers are intentionally separate from the current frontend and module graph:

- Module contract expansion: richer source-derived import/export metadata without adding resolver policy.
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
