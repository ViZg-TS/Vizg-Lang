# Roadmap

This roadmap separates implemented frontend work from planned layers. It is not a release promise.

## Completed Program: Portable Core And First Official ABI v1

Goals 174–188 are the only executable portability and ABI plan. They strictly
replace Goals 159–173, which are superseded and non-executable. Each goal is a
serial hard gate.

The memory-first, host-driven API is the first official public ABI and uses
`VIZG_ABI_VERSION = 1`. Earlier unpublished internal surfaces were deleted.
No compatibility shim, deprecated alias, old library, or parallel versioned
ABI remains.

The target responsibility split is fixed:

- ViZG core parses source, derives imports and exports, and owns graph and
  semantic state.
- Hosts resolve specifiers, assign opaque module identities, and provide source
  bytes or external metadata.
- Optional adapters provide platform services such as native filesystem access.
- Executables compose core and adapters and own process I/O and lifecycle.

Paths and URLs are labels, not module identities. Core never calls host code.
Goal 188 closed the final portability and security audit on 2026-07-14. HIR
planning is now authorized; implementation requires a separate executable goal.

## Current Implementation Snapshot: Frontend And Module Graph

Implemented:

- Scanner with tokens, comments, spans, and lexical diagnostics.
- Parser for the current TypeScript/JavaScript-like subset.
- AST model for supported declarations, statements, and expressions.
- Binder with scopes, symbols, imports, exports, and duplicate diagnostics.
- Resolver with read/write/call/export references and missing-name diagnostics.
- Preliminary function CFGs.
- Minimal multi-file module graph for static local imports.
- Relative import resolution by `.ts` and `/index.ts`.
- Module cache keyed by canonical file path.
- Named import validation against target value-space exports.
- Cross-file import linking via `src/modules/linker.zig`: each named/default/namespace or external import becomes a `LinkedImport` carrying local name, imported name, kind (`named`, `default`, `namespace`, `external`, or `unresolved`), and the resolved target module/symbol when available.
- Linker output surfaced in CLI as the "Links" section on `vizg modules <file>`.
- Module graph diagnostics `VZG5001`, `VZG5002`, and `VZG5003`.
- CLI inspection commands.
- Portable `src/root.zig` core with a freestanding dependency lint and a
  separate native filesystem adapter under `src/adapters/native_fs/`.
- Portable host/core contracts for opaque module and request identities,
  borrowed source and request metadata, and all four request kinds. Logical
  names are diagnostic-only and never imply filesystem identity.
- Owned portable project sessions that copy host buffers, track explicit module
  lifecycle states and revisions, retain partial results, and release all
  sources and semantic arenas on teardown.
- Deterministic pull-based module request scheduling with project-local IDs,
  FIFO dispatch, equivalent-request deduplication, explicit terminal response
  kinds, stale/foreign/duplicate rejection, cycle-safe source responses, and
  guarded finish states.
- Copied external-module descriptors with identities distinct from source
  modules; named, default, namespace-valued, and type-only exports; validated
  export tables; portable type metadata; and explicit unknown/any policy.
- Official memory-first C ABI v1 with opaque project/result handles,
  explicit source/external/failure host responses, pull-based stepping,
  source-only convenience through the same engine, platform-identical layouts,
  caller-owned bounded storage, and independent result ownership.
- Optional reference native `FsModuleHost` that drives project step/respond,
  assigns canonical per-session identities, resolves relative extension/index
  candidates, confines traversal and symlinks to the root directory, bounds
  source/module growth, and maps I/O outcomes to portable responses.
- CLI migration to memory-first APIs: single-file commands call source-only
  semantics after executable-owned reads, while multi-module inspection drives
  the portable project through `FsModuleHost`, including missing, cyclic, and
  registered external outcomes with original paths and spans.
- Zig build and test wiring.
- Static library `libvizg.a` rooted at the official ABI v1 in `Lib/vizg.zig`,
  with its implementation in `Lib/abi.zig` over `src/root.zig`.
- Public C header for host-driven project analysis and explicit ownership.
- Exact exported-symbol allowlist in `zig build abi-symbols-test`.
- Scanner diagnostic `VZG1005` for invalid or incomplete escape sequences.

Deferred backlog, not executable before the active portable-core gates allow it:

- Add more parser recovery tests.
- Expand fixture coverage for unsupported syntax errors.
- Improve CLI formatting consistency.
- Add snapshot-style tests for CLI output (including `modules` Links section).
- Document each AST node in source comments or generated docs.
- Add module graph snapshot tests.

## Next Milestone: Module Layer Expansion

Planned, not implemented:

- Package or `node_modules` lookup.
- `package.json` or `tsconfig` path resolution.
- Dynamic import resolution.
- CommonJS interop.
- Default import export validation.
- Code emission, bundling, or tree shaking.

## Type Checker Milestone

Implemented for the supported syntax subset:

- Owned single-file and project semantic results with explicit teardown.
- One canonical `TypeStore` per result/project and context-local `TypeId` equality.
- Declared, expression, aggregate, access, function, call, and CFG-narrowed types.
- Central compatibility and Checker v2 diagnostics for initializers, assignments, returns, calls, access, operators, and `satisfies`.
- Cross-module identities and type propagation for values, functions, classes, enums, interfaces, type aliases, aliases, default/namespace imports, re-exports, and type-only imports.
- Bounded cyclic propagation and partially inspectable missing/external links.

Complete TypeScript compatibility and advanced annotation forms remain out of scope.

## Future Milestone: HIR And Lowering

Planned, not implemented:

- Lower AST or typed AST into a compact intermediate representation.
- Normalize control flow and expression forms.
- Prepare for interpretation, analysis, or code generation.
- Reserve `VZG7xxx` diagnostics for lowering errors.

### HIR Entry Gate — Open After Goal 188

Typed Semantics v2 and the portable-core audit are closed. HIR planning is
authorized. Implementation remains pending a separate executable goal.

- [x] The owned `SemanticResult` and `ProjectSemanticResult` contracts are stable, including teardown and partial-result behavior.
- [x] One canonical `TypeStore` per result/project and context-local ID rules remain enforced.
- [x] Tests cover value/function/class/enum/interface/type-alias exports; aliases, default/namespace/re-export/type-only imports; missing/external links; cycles; and repeated rebuild/teardown.
- [x] Checker diagnostics retain stable source and related spans while recovered semantic data stays inspectable.
- [x] Full test, validation, cross-target, Android, and ABI gates are green.
- [x] Future HIR must consume semantic results. It must not parse, bind, infer again, or create a competing `TypeStore`.
- [x] Portable core and official ABI v1 release candidate closed through Goal 187.
- [x] Final bug, vulnerability, portability, and correctness audit closed through Goal 188.
- [x] Official ABI allocation is caller-owned and bounded: workspace, source,
  module, diagnostic, graph-depth, and semantic-type exhaustion have explicit
  portable statuses with no hidden allocator or WASM allocation import.
- [x] Goal 186 provides an import-free `wasm32-freestanding` module exporting
  only linear memory and official ABI v1, with JS-host coverage for single,
  multi, missing, and external module flows.

### Portable core and official ABI v1 RC closure — 2026-07-14

Goal 187 audited the public Zig and C surfaces, removed the last metadata-free
external response, and made orchestration helpers private. Native archives are
PIC and link into a default PIE C consumer. Exact export and undefined-import
tables are enforced for Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall;
freestanding WASM has no imports. Full native, cross-target, Android, WASM,
safety, layout, lifecycle, and consumer gates pass. At RC closure, Goal 188 was
still the final mandatory adversarial audit before HIR work could begin.

### Portable core and official ABI v1 final audit — 2026-07-14

Goal 188 remediated ABI workspace aliasing and stale handles, reclaimable
external-response scratch, native filesystem path-replacement races, and Linux
executable-stack inference. Mutation, malformed-input, repeated lifecycle, and
parallel independent-project regressions pass. The repeated dependency, state,
identity, resource, filesystem, pointer, layout, and symbol audit has no known
unresolved in-scope finding. Full evidence and residual contract limits are in
[`portable-core-official-abi-v1-audit.md`](portable-core-official-abi-v1-audit.md).
HIR planning is authorized; HIR implementation is not part of this program.

### Typed Semantics v2 closure verification — 2026-07-13

The complete release-candidate contract matrices, ownership rules, lookup API
inventory, current CLI format, and exact gate output live in
[`typed-semantics-v2-rc.md`](typed-semantics-v2-rc.md). This replaces stale
intermediate test counts and inspection-output examples.

The mandatory post-RC bug, security, and correctness audit is closed with all
confirmed findings remediated. Its attack classes, finding severity, fixes,
limits, and final gate evidence live in
[`typed-semantics-v2-audit.md`](typed-semantics-v2-audit.md).

## Future Milestone: Runtime Or Compiler Backend

Possible future directions, not implemented:

- Interpreter.
- Native compiler backend.
- JavaScript emitter.
- Bytecode VM.

No runtime or compiler backend exists today. Reserve `VZG8xxx` diagnostics for runtime-facing errors if that layer is added.

## Non-Goals Until Explicitly Revisited

- Claiming full JavaScript or TypeScript support.
- Running npm packages.
- Acting as a browser or Node.js replacement.
- Bundling packages.
- Emitting optimized native code from the current AST.
- Treating external package imports as resolved module semantics.
