# ViZG ABI v1 Final Audit

## Audited revision

`1dec758704510c52a82bf751945aecb36574a1d4`

- Date: 2026-07-15
- Zig: `0.16.0`
- Scope: the Goals 203–207 working-tree series applied to the revision above
- Unresolved in-scope P0/P1/P2 findings: **0**

This is the repeated Goal 207 audit. It supersedes the earlier Goal 202 freeze
claim because Goals 203–206 found and corrected material semantic, resource,
summary, and source-representation gaps after that claim.

The audit restarted from `build.zig`, `src/root.zig`, `Lib/vizg.zig`, and the
public C header; traced the active frontend, semantic, project, native ABI, and
WASM paths; inspected the registered assertions; ran the complete fresh command
matrix below; fixed the new finding; added a regression; and repeated the
affected validation. Generated and cached output was not treated as source
evidence.

## Closure of Goals 203–207

| Goal | Result | Confirmed closure |
|---|---|---|
| 203 | PASS | External descriptors participate in the bounded semantic propagation before final checking. Value/type/both namespaces, downstream re-exports, `SymbolTypeInfo`, `NodeTypeInfo`, `SemanticImport`, and checker-visible `TypeId` identity are covered together. |
| 204 | PASS | Semantic-type, diagnostic, module, request, edge, source, and graph-depth limits are checked at their owning growth points. Over-depth source responses roll back without consuming the request or mutating source/module/edge state. Exact N/N+1 cases pass. |
| 205 | PASS | Canonical diagnostic phases drive syntax, semantic, project, and module-host summary flags; `is_partial` is their OR. Every `LIMIT_EXCEEDED` path has a stable non-`NONE` kind, including parser recursion. Native, Zig, and WASM layouts agree. |
| 206 | PASS | One-source representation is capped at `UINT32_MAX`; configuration and descriptors above it return `SOURCE_BYTES` before nested pointer access, copying, or scanner entry. Aggregate accounting is overflow-safe and source-index casts have a preceding invariant. |
| 207 | PASS | The complete static and executable audit was repeated, the new finding below was fixed and regressed, the native/WASM surface matches the exact allowlist, and no in-scope P0/P1/P2 remains. |

## New Goal 207 finding

| ID | Severity | Reproduction | Root cause | Fix | Regression |
|---|---|---|---|---|---|
| G207-01 | P1 | On a native target, create with `max_source_bytes = UINT32_MAX + 1`, receive `LIMIT_EXCEEDED`, then query `vizg_project_limit_kind`. | Creation rejected the configuration without publishing a handle, so the required `SOURCE_BYTES` category could not be observed. | Create a limit-inspection-and-destroy-only handle, record `SOURCE_BYTES`, reject operational calls with `INVALID_STATE`, and retain normal validation/output behavior for other create failures. | The official ABI lifecycle test checks the status, non-null handle, exact kind, rejected operational use without clearing the kind, and destruction. |

No regression weakens an existing assertion or special-cases a fixture.

## Active contract and evidence

`src/root.zig` is the portable Zig composition root. It exposes source-byte
frontend, semantic, type, and host-driven project APIs without filesystem,
package, URL, or runtime resolution. `Lib/vizg.zig` composes that root with
`Lib/abi.zig`; `Lib/vizg.h` is the public C contract. The only concrete
filesystem host is the repository validation fixture in
`test/support/fs_validation_host.zig`, reached by development/test composition
and not exported by the portable root or ABI. The active
`lint-module-host-boundary` gate enforces this boundary.

The ABI is caller-workspace-owned and one-shot:

```txt
create -> add roots/sources -> step/respond -> complete -> finish
       -> immutable project-owned result views -> destroy
```

Input is borrowed only for a call and copied before retention. `finish` is
terminal and idempotently returns the same immutable project-owned view without
allocating. Pointer/range/alignment, nested input, alias, and workspace overlap
validation precedes output mutation or access. Limit and allocation exhaustion
do not publish incomplete semantic or ABI results.

The registered suite covers:

- external checker mismatch, value/type/both namespaces, combined class
  constructor/instance identity, and transitive external re-export consumers;
- exact N/N+1 limits for individual/aggregate source bytes, modules, requests,
  edges, diagnostics, graph depth, and semantic types;
- graph-depth rollback, later shorter paths, order independence, and cycles;
- every public summary group and stable limit-kind mapping;
- exact `UINT32_MAX` configuration plus fake native `UINT32_MAX + 1` source
  length without a giant allocation or pointer access;
- hostile null, alignment, overflow, near-end, nested, aliased, and
  workspace-overlap native/WASM inputs;
- allocation-failure injection through frontend, project graph, semantic
  metadata, external linking, result construction, and ABI publication;
- one-shot lifecycle and repeated create/add/step/respond/finish/destroy flows;
- exact native symbols, import-free WASM, C/Zig layouts, and Android/C consumer
  compilation.

## Commands executed

All commands were run from the repository root on the audited working tree.

```text
zig build test --summary all
zig build validate
zig build cross-check
zig build abi-cross-check
zig build abi-layout-test
zig build android-aarch64-lib
zig build wasm-freestanding
git diff --check
nm -g --defined-only zig-out/lib/libvizg.a
wasm-objdump -x zig-out/lib/vizg.wasm
```

Additional registered safety and freeze gates were also run:

```text
git diff --name-only -- '*.zig' | xargs -r zig fmt --check
zig build audit-safety
zig build lint-portable-core
zig build lint-module-host-boundary
zig build abi-symbols-test
zig build abi-native-consumer-test
```

The optional whole-tree `zig fmt --check .` was also run. It reports
`src/modules/linker.zig`, an unmodified baseline file outside Goals 203–207;
the changed-file formatter command above passes.

## Observed results

| Command | Observed result |
|---|---|
| `zig build test --summary all` | PASS — 30/30 build steps, 448/448 tests |
| `zig build validate` | PASS — install, aggregate tests, portable/boundary lints, and CLI fixture validation |
| `zig build audit-safety` | PASS |
| `zig build lint-portable-core` | PASS |
| `zig build lint-module-host-boundary` | PASS |
| `zig build cross-check` | PASS |
| `zig build abi-cross-check` | PASS |
| `zig build abi-layout-test` | PASS |
| `zig build abi-symbols-test` | PASS — exact native allowlist |
| `zig build abi-native-consumer-test` | PASS — official C consumer and hostile-pointer probe |
| `zig build android-aarch64-lib` | PASS |
| `zig build wasm-freestanding` | PASS — JavaScript host matrix and exact import/export assertions |
| changed Zig files, `zig fmt --check` | PASS |
| `git diff --check` | PASS |
| `nm -g --defined-only zig-out/lib/libvizg.a` | PASS — the official 18 functions below are the only `vizg_` globals |
| `wasm-objdump -x zig-out/lib/vizg.wasm` | PASS — no import section; `memory` plus exactly the same 18 functions |

Native and WASM function allowlist:

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

## Remaining limitations

- ViZG remains a frontend and semantic-analysis engine for its documented
  TypeScript/JavaScript-like subset, not a complete TypeScript checker.
- It has no HIR, lowering, runtime, emitter, backend, bundler, package resolver,
  or production filesystem/URL/network module host.
- Source revision requires a new one-shot project.
- Native C cannot portably prove that an arbitrary non-null integer address is
  mapped before dereference. The contract validates null, alignment, overflow,
  complete ranges, and forbidden overlap; WASM additionally validates complete
  linear-memory bounds.
- Cross-target and Android gates are compile/layout/consumer checks, not foreign
  runtime execution.
- The optional whole-tree formatter check still reports the unmodified baseline
  file `src/modules/linker.zig`; every Zig file changed by Goals 203–207 passes
  `zig fmt --check`.

## Final decision

- Goals 203–207: **PASS**
- Unresolved P0: **0**
- Unresolved P1: **0**
- Unresolved P2: **0**
- ABI v1 frozen: **yes**
- HIR planning authorized: **yes**

The public layouts, enum values, ownership/lifecycle rules, and 18-function
symbol allowlist are the ABI v1 compatibility contract. Incompatible changes
require a new ABI version. HIR work may consume this frozen foundation but may
not mutate it.
