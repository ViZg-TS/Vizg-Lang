# HIR v1 Final Implementation Audit

**Implementation verdict:** PASS

**Immutable freeze-reference verdict:** FROZEN

**Audit date:** 2026-07-16

**Audited implementation revision:** `6579e902129b43a9857ac07a070a33702a20df8c`

**Freeze tag:** `hir-v1.0.0`

Goals 232–237 pass. The audited implementation revision has zero known HIR P0,
P1, or P2 findings and passed the complete validation matrix before the PR was
merged. HIR v1 is frozen at the freeze commit identified by `hir-v1.0.0`; the
revision above deliberately identifies the implementation that was audited,
not this documentation commit.

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
| 237 — final implementation audit | PASS | Goals 232–236 pass; supported consumers use public APIs; the full build/test/ABI/native/Android/WASM matrix passes; unresolved P0/P1/P2 count is zero; the exact audited implementation revision is recorded above. |

## Acceptance Closure

| Acceptance item | Result | Evidence |
|---|---|---|
| ViZG ends at verified immutable HIR | PASS | Public architecture, roadmap, active HIR schema, and build graph contain no ViZG-owned post-HIR layer. |
| HIR lifetime is independent of mutable analysis state | PASS | Sealing deep-copies retained type/provenance/string state; teardown regression tests pass. |
| Consumer coverage is complete and deterministic | PASS | Checked Zig view and generic C record access cover all eight entity categories; the C consumer iterates each reported count. |
| IDs and invalid access are controlled | PASS | Result-domain checks, invalid sentinels, range checks, and version checks are exercised by tests. |
| External identity is stable and order-independent | PASS | Host symbol IDs are preserved and external declarations are sorted by those IDs; permutation tests pass. |
| External declarations are semantic, body-less, and target-independent | PASS | Declaration kind, semantic types, effects, provenance, and no-body representation are verified; backend fields do not exist. |
| Project-input ABI v1 remains frozen | PASS | Existing ABI v1 structures, constants, lifecycle entry points, and result accessors remain unchanged. The implementation is additive: two opaque-result convenience functions and three separately versioned HIR functions. |
| Native and WASM symbol surfaces are exact | PASS | Symbol tests accept exactly 23 public `vizg_` functions: one ABI-version function, 19 project/result functions, and three HIR-version functions/accessors. WASM additionally exports memory and has zero imports. |
| No unresolved HIR P0/P1/P2 findings | PASS | Source, ownership, consumer, external, ABI, portability, and validation review found none after the type-iteration correction. |
| Exact audited revision is recorded | PASS | `6579e902129b43a9857ac07a070a33702a20df8c` is the clean implementation commit on which the complete pre-merge validation matrix passed. |

## Defect Closed During This Audit

The standalone consumer exposed a mismatch between the summary type count and
type iteration. The summary includes built-in plus defined types, while the
record accessor previously interpreted an iteration ordinal as a raw `TypeId`.
`TypeStore`, `HirResult`, and both consumer APIs now expose deterministic
ordinal traversal across built-in and defined types. The Zig tests and C
consumer reject out-of-range access and traverse the complete reported set.

The one-shot `vizg_project_analyze_source` path also exposed ownership that was
not released by `vizg_project_result_destroy`. The result now records ownership
of its internal project and destroys it exactly once; streaming project results
remain owned by their explicit project.

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
Build Summary: 66/66 steps succeeded; 501/501 tests passed
```

Confirmed sub-gates include:

- source validation with zero errors and three expected `VZG2004` fixture
  warnings;
- the complete unit, safety-audit, lifecycle, allocation-failure, and ABI test
  set;
- native and seven-target portable-core/ABI cross-checks;
- C ABI layout and exact-symbol tests;
- native standalone project/HIR C consumers;
- Android AArch64/API 24 archive plus consumer compilation;
- import-free `wasm32-freestanding` build and official ABI test.

`git diff --check` is run separately as the final tree hygiene gate.

## Known Limitations

- HIR IDs and `TypeId` values are result-local. They are not stable
  serialization identifiers and cannot be mixed across results.
- HIR v1 has no binary or textual serialization contract. The printer is for
  deterministic inspection, not interchange.
- C-compatible access is intentionally kind-neutral summary/record iteration;
  borrowed strings and record data are valid only for the owning result
  lifetime.
- Unsupported or ineligible syntax produces diagnostics rather than partial
  public HIR.
- ViZG does not own MIR, optimization, representation selection, execution,
  runtime memory management, code generation, linking, or packaging.
- Any incompatible HIR consumer-contract change requires a new HIR API version;
  the frozen v1 contract must not be silently extended.

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
- Goal 237 immutable revision record: **PASS**
- Unresolved HIR P0: **0**
- Unresolved HIR P1: **0**
- Unresolved HIR P2: **0**

HIR v1 is frozen. ViZG now enters contractual maintenance; primary
post-HIR development belongs in VZed or another downstream consumer.
