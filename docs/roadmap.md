# Roadmap

This roadmap separates implemented frontend work from planned layers. It is not a release promise.

## Closed Foundation: Portable Core And Official ABI v1

Goals 189–207 are closed. The memory-first host-driven API uses
`VIZG_ABI_VERSION = 1`; earlier unpublished surfaces were deleted without
compatibility shims. The final repeated audit and exact command evidence are in
[`FINAL_AUDIT.md`](FINAL_AUDIT.md).

The responsibility split is fixed:

- ViZG discovers and links modules but does not resolve specifiers.
- A host/consumer assigns `ModuleId` values and supplies source/external data.
- Concrete filesystem hosts in this repository are validation fixtures only.
- The project ABI is one-shot; changed source requires a new project.

The project-input ABI v1 remains frozen. Goal 207 passed its validation matrix.
HIR is now implemented as ViZG's final product and adds a separately versioned
read-only HIR access contract without changing project input structures.

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

## Host-Owned Module Resolution — Explicit Non-Goal

ViZG will not implement package lookup, `node_modules`, `package.json`,
`tsconfig` path mapping, URL fetching, filesystem canonicalization, import maps,
or CommonJS resolution. Those policies belong to the host or another consumer
of the module-provider API.

## Type Checker Milestone

Implemented for the supported syntax subset:

- Owned single-file and project semantic results with explicit teardown.
- One canonical `TypeStore` per result/project and context-local `TypeId` equality.
- Declared, expression, aggregate, access, function, call, and CFG-narrowed types.
- Central compatibility and Checker v2 diagnostics for initializers, assignments, returns, calls, access, operators, and `satisfies`.
- Cross-module identities and type propagation for values, functions, classes, enums, interfaces, type aliases, aliases, default/namespace imports, re-exports, and type-only imports.
- Bounded cyclic propagation and partially inspectable missing/external links.

Complete TypeScript compatibility and advanced annotation forms remain out of scope.

## Completed Final Product: Canonical Typed HIR v1

Goals 208–237 are implementation-complete. Final validation evidence is
recorded in
[`HIR_V1_AUDIT.md`](HIR_V1_AUDIT.md). The normative contracts are:

- [`hir-v1-design.md`](hir-v1-design.md) — typed ANF-like, block-based HIR,
  ownership, invariants, examples and the HIR/MIR boundary;
- [`hir-v1-lowering-matrix.md`](hir-v1-lowering-matrix.md) — exhaustive
  TypeScript/AST/operator/module equivalence and coverage table;
- [`../VIZG_PLAN.md`](../VIZG_PLAN.md) — ordered Goals 208–237 and acceptance
  gates.

HIR v1:

- consumes the immutable complete project semantic result;
- erase type-only and syntax-only forms;
- make evaluation order explicit through immutable temporary values;
- keep mutable source bindings explicit rather than converting them to full SSA;
- lower structured control flow into blocks and terminators;
- preserve language-semantic operations, types and source provenance;
- apply only mandatory local canonicalization;
- expose only a verified immutable owned result;
- remain readable after semantic/project teardown through sealed owned type and
  provenance storage;
- expose deterministic checked Zig lookup/iteration plus a separately
  versioned non-Zig summary/record API;
- preserve stable host-supplied external declaration identities, complete
  function types, conservative effects, and body-less canonical declarations.

ViZG ends at verified immutable HIR. MIR, global optimization, object/closure
layout, async state machines, exception ABI, memory management, GC, bytecode,
native code, object files, linking, and executable/library packaging are not
ViZG roadmap items. Independent consumers may implement such concerns without
becoming ViZG phases.

### HIR Entry Gate — Opened By Goal 207

Goal 207 closed the gate after the repeated complete local command matrix and
froze official ABI v1. Goal 208 begins from that exact baseline and must not
retroactively change it. The verified foundation is recorded in
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
