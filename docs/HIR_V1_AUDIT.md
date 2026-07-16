# HIR v1 Final Implementation Audit

**Implementation verdict:** PASS  
**Immutable freeze-reference verdict:** PENDING COMMIT  
**Audit date:** 2026-07-16  
**Base revision:** `42e2de84717fa28091d9cfa675a2b1752303f222`  
**Candidate:** current `HIR` working tree

Goals 232–236 and the implementation/validation portion of Goal 237 pass.
The candidate has zero known HIR P0, P1, or P2 findings. An exact immutable
post-audit revision cannot be recorded until these changes are committed; the
base revision above predates this candidate.

## Scope

This audit covers:

- Goals 232–237 in `VIZG_PLAN.md`;
- `goals/hir_v1-design.md` and `goals/hir_v1-lowering-matrix.md`;
- the normative `docs/hir-v1-design.md` and
  `docs/hir-v1-lowering-matrix.md`;
- `docs/roadmap.md`;
- active HIR, semantic-result, project-host, C ABI, build, test, native,
  Android, and WebAssembly surfaces.

MIR, runtime, execution, representation selection, memory management, code
generation, object production, linking, and package resolution are outside
this audit and remain outside ViZG.

## Goal Findings

| Goal | Result | Confirmed evidence |
|---|---|---|
| 232 — verified immutable HIR | PASS | `HirResult` seals owned modules, strings, provenance, and a read-only `TypeStore` snapshot. Teardown tests read types and HIR after semantic/project teardown. HIR contains no MIR, runtime, backend, GC, allocator, target, object, or linker policy. |
| 233 — immutable consumer contract | PASS | `hir.ConsumerView` provides deterministic checked count, iteration, and lookup for modules, external declarations, functions, blocks, instructions, bindings, types, signatures/effects, and origins. Invalid, out-of-range, version-mismatched, and foreign result-local IDs return controlled errors. The standalone C consumer traverses every public entity kind without frontend state. |
| 234 — stable external declarations | PASS | The Zig host contract accepts host-supplied `ExternalSymbolId`, declaration kind, complete function metadata, conservative effects, and type/provenance metadata. External module, external symbol, semantic, and HIR ID domains remain distinct. External declaration ordering is canonicalized by stable symbol ID, independent of descriptor order. No backend metadata is admitted. |
| 235 — canonical external lowering | PASS | Imported bindings, aliases, re-exports, and ordinary call/binding operations retain canonical external identity. External functions lower as body-less declarations. Missing, duplicate, inconsistent, or malformed publication metadata is rejected before HIR publication. |
| 236 — official versioned HIR access | PASS | Zig exposes immutable checked views. C exposes additive `VIZG_HIR_API_VERSION == 1`, `vizg_hir_summary`, and `vizg_hir_record_at` through opaque result ownership. Result-owned borrowed strings remain valid for the result lifetime. `example/hir_consumer.c` builds, links, runs, and traverses all entity categories. Serialization remains absent. |
| 237 — final implementation audit | PARTIAL | Goals 232–236 pass; supported consumers use public APIs; the full build/test/ABI/native/Android/WASM matrix passes; unresolved P0/P1/P2 count is zero. Recording the exact immutable audited revision remains pending a commit. |

## Acceptance Closure

| Acceptance item | Result | Evidence |
|---|---|---|
| ViZG ends at verified immutable HIR | PASS | Public architecture, roadmap, active HIR schema, and build graph contain no ViZG-owned post-HIR layer. |
| HIR lifetime is independent of mutable analysis state | PASS | Sealing deep-copies retained type/provenance/string state; teardown regression tests pass. |
| Consumer coverage is complete and deterministic | PASS | Checked Zig view and generic C record access cover all eight entity categories; the C consumer iterates each reported count. |
| IDs and invalid access are controlled | PASS | Result-domain checks, invalid sentinels, range checks, and version checks are exercised by tests. |
| External identity is stable and order-independent | PASS | Host symbol IDs are preserved and external declarations are sorted by those IDs; permutation tests pass. |
| External declarations are semantic, body-less, and target-independent | PASS | Declaration kind, semantic types, effects, provenance, and no-body representation are verified; backend fields do not exist. |
| Project-input ABI v1 remains frozen | PASS | Existing project-input structures and 13 project functions are unchanged. HIR access adds three separately versioned functions. |
| Native and WASM symbol surfaces are exact | PASS | Symbol tests accept exactly the 13 project functions plus the three additive HIR functions; WASM also exports memory and has zero imports. |
| No unresolved HIR P0/P1/P2 findings | PASS | Source, ownership, consumer, external, ABI, portability, and validation review found none after the type-iteration correction. |
| Exact audited revision is recorded | PARTIAL | The base SHA is recorded, but it is not the dirty post-audit candidate. A commit is required for an immutable freeze SHA. |

## Defect Closed During This Audit

The standalone consumer exposed a mismatch between the summary type count and
type iteration. The summary includes built-in plus defined types, while the
record accessor previously interpreted an iteration ordinal as a raw `TypeId`.
`TypeStore`, `HirResult`, and both consumer APIs now expose deterministic
ordinal traversal across built-in and defined types. The Zig tests and C
consumer reject out-of-range access and traverse the complete reported set.

## Fresh Validation

Executed with:

```sh
HOME=/tmp
ZIG_GLOBAL_CACHE_DIR=/tmp/vizg-zig-global
ZIG_LOCAL_CACHE_DIR=/tmp/vizg-zig-local
```

Command:

```sh
zig build test validate audit-safety cross-check abi-cross-check \
  abi-layout-test abi-symbols-test abi-native-consumer-test \
  android-aarch64-lib wasm --summary all
```

Observed result:

```txt
Build Summary: 68/68 steps succeeded; 529/529 tests passed
```

Confirmed sub-gates include:

- source validation with zero errors and three expected `VZG2004` fixture
  warnings;
- 440 safety-audit tests and 57 supporting tests;
- native and seven-target portable-core/ABI cross-checks;
- C ABI layout and exact-symbol tests;
- native standalone project/HIR C consumers;
- Android AArch64/API 24 archive plus consumer compilation;
- import-free `wasm32-freestanding` build and official ABI test.

`git diff --check` is run separately as the final tree hygiene gate.

## Supported Public Interface Verdict

The supported downstream surfaces are:

- Zig: `hir.ConsumerView` over an owned sealed `HirResult`;
- C and other C-compatible consumers: opaque `Vizg_ProjectResult` ownership
  plus the versioned HIR summary/record functions.

`example/hir_consumer.c` uses only the installed public header and library. It
does not access AST, binder, checker, semantic session, mutable project state,
private HIR storage, or repository-internal headers. This supplies the required
VZed-style downstream-consumer proof without making VZed or any other consumer
part of ViZG.

## Verdict

- Goals 232–236: **PASS**
- Goal 237 implementation and validation: **PASS**
- Goal 237 immutable revision record: **PENDING COMMIT**
- Unresolved HIR P0: **0**
- Unresolved HIR P1: **0**
- Unresolved HIR P2: **0**

The current candidate finishes the HIR implementation and is ready for an
intentional freeze commit. Until that commit exists, documentation must not
present the base revision as the exact immutable HIR v1 freeze reference.
