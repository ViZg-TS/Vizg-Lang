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

ABI v1 is frozen. Goal 207 passed the repeated complete local validation matrix
with no unresolved in-scope finding. HIR v1 was then implemented additively
without changing existing ABI v1 layouts or entry points.

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

## Closed Milestone: Canonical HIR v1

Goals 208–237 are complete. The audited implementation is
`6579e902129b43a9857ac07a070a33702a20df8c`, and the immutable freeze point is
identified by tag `hir-v1.0.0`.

Implemented:

- immutable, owned, typed and target-independent project HIR;
- canonical lowering with explicit evaluation order and control flow;
- eligibility, limits, diagnostics, canonicalization and verification;
- stable external declarations and identity-preserving external lowering;
- deterministic Zig consumer views and versioned C-compatible summary/record
  access;
- native, Android and import-free WebAssembly validation.

The normative contract and lowering table are
[`hir-v1-design.md`](hir-v1-design.md) and
[`hir-v1-lowering-matrix.md`](hir-v1-lowering-matrix.md). Exact audit evidence
and known limitations are in [`HIR_V1_AUDIT.md`](HIR_V1_AUDIT.md).

## Current Product Boundary: Contractual Maintenance

ViZG ends at verified immutable HIR v1 and now enters contractual maintenance.
Changes must preserve the frozen project ABI v1 and version public HIR
projection changes deliberately. Primary development may move to VZed, which
consumes public HIR instead of private frontend state.

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

## Downstream Work: VZed

Post-HIR work is not a ViZG milestone. Downstream consumers such as VZed may
implement:

- Interpreter.
- Native compiler backend.
- JavaScript emitter.
- Bytecode VM.

No runtime or compiler backend exists in ViZG.

## Non-Goals Until Explicitly Revisited

- Claiming full JavaScript or TypeScript support.
- Running npm packages.
- Acting as a browser or Node.js replacement.
- Bundling packages.
- Emitting optimized native code from the current AST.
- Treating external package imports as resolved module semantics.
