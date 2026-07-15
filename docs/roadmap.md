# Roadmap

This roadmap separates implemented frontend work from planned layers. It is not a release promise.

## Closed Foundation: Portable Core And Official ABI v1

Goals 189–207 are closed. The memory-first host-driven API uses
`VIZG_ABI_VERSION = 1`; earlier unpublished surfaces were deleted without
compatibility shims. The final repeated audit and exact command evidence are in
[`FINAL_AUDIT.md`](FINAL_AUDIT.md).

The responsibility split is fixed:

- ViZG discovers and links modules but does not resolve specifiers.
- A runtime/consumer assigns `ModuleId` values and supplies source/external data.
- Concrete filesystem hosts in this repository are validation fixtures only.
- The project ABI is one-shot; changed source requires a new project.

ABI v1 is frozen. Goal 207 passed the repeated complete local validation matrix with no
unresolved in-scope finding, so HIR planning is authorized. HIR remains
unimplemented and cannot retroactively change the frozen ABI v1 contract.

## Current Implementation Snapshot: Frontend And Host-Resolved Module Graph

Implemented:

- scanner, parser, AST, binder, resolver, CFG, typed semantics, and checker for
  the documented language subset;
- opaque host-assigned module identities and project-local request identities;
- source-derived imports, exports, re-exports, type-only metadata, and dynamic
  requests;
- deterministic pull-based request/response scheduling and cycle-safe graph
  construction;
- external-module descriptors with a distinct identity domain;
- one-shot project lifecycle with project-owned immutable result views;
- result ABI accessors for summary, modules, diagnostics, edges, imports, and
  exports;
- native, Android, and import-free `wasm32-freestanding` ABI targets;
- in-memory project tests plus optional test-only host fixtures;
- exact ABI symbol/layout gates and portable-core/module-boundary lints.

## Runtime-Owned Module Resolution — Explicit Non-Goal

ViZG will not implement package lookup, `node_modules`, `package.json`,
`tsconfig` path mapping, URL fetching, filesystem canonicalization, import maps,
or CommonJS resolution. Those policies belong to the future runtime or another
consumer of the module-provider API.

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

### HIR Entry Gate — Opened By Goal 207

Goal 207 closed the gate only after Goals 203–206 corrected external semantic
propagation, pre-growth limits, summary/limit consistency, and oversized-source
safety, and the resulting tree passed the repeated complete local command
matrix. HIR planning may begin from the frozen portable project and ABI v1
contracts. The verified conditions and limitations are recorded in
[`FINAL_AUDIT.md`](FINAL_AUDIT.md).

### Superseded portable-core closure records

The earlier Goal 187/188 closure records and the Goals 189–196 pre-validation
checklist and the premature Goal 202 freeze claim are superseded by Goal 207's
[`FINAL_AUDIT.md`](FINAL_AUDIT.md). They must not be used as current freeze
evidence.

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
