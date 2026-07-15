# ViZG ABI v1 Final Audit

## Commit audited

`38b336391158aa2730e953a723bf3999ed4982c6`

- Date: 2026-07-15
- Zig: `0.16.0`
- Scope: Goal 202, including the current applied Goals 189–201 working-tree
  series based on the commit above
- Unresolved in-scope findings: **0**

The audit restarted at the active build and composition roots, traced every
relevant frontend, semantic, project, graph, native ABI, and WASM path, fixed
each confirmed finding, added a regression, and repeated the required gates.
Generated or cached output was not treated as source evidence.

## ABI surface

- Version: 1
- Symbols: the 18-function native/WASM allowlist recorded below
- Result ownership: project-owned immutable view
- Lifecycle: one-shot

`src/root.zig` is the portable Zig root. It exposes source-byte frontend,
semantic, type, and host-driven project APIs without a filesystem/package/URL
resolver. `Lib/vizg.zig` composes that root with `Lib/abi.zig`; `Lib/vizg.h` is
the only public C contract. The only concrete filesystem host is the
repository-only fixture in `test/support/fs_validation_host.zig`, composed by
the development CLI and tests rather than exported by the core or ABI.

The ABI is caller-workspace-owned and one-shot:

```txt
create -> add roots/sources -> step/respond -> complete -> finish
       -> immutable project-owned result views -> destroy
```

Input is borrowed only for each call and copied before retention. `finish` is
terminal and idempotently returns the same immutable view without allocating.
The result and all nested strings remain valid until project destruction; there
is no separate result owner or destructor. Pointer/range/alignment and workspace
overlap validation completes before output writes or mutation. Limit and
allocation exhaustion are terminal, but in-progress ownership rolls back and
no incomplete semantic or ABI result is published.

The final result retains only the root-reachable local-module closure. Module
identity is always the host-assigned `ModuleId`, never a logical label. External
modules use a separate identity domain. Import and re-export rows use explicit
presence flags and exact graph-edge provenance. Graph depth is the shortest
resolved path from any root and is independent of discovery/response order.

## Findings

| ID | Severity | Reproduction | Root cause | Fix | Regression test |
|---|---|---|---|---|---|
| G202-01 | Medium | Scan string `"\\0"` and template `` `\\01` ``. | String/template escape paths enforced different legacy-free null rules. | Unified the complete null-escape rule. | Valid and invalid scanner escape cases. |
| G202-02 | High | Parse nested assignment, unary, exponentiation, or recursive type syntax at the configured depth boundary. | Depth guards did not wrap the actual recursive entry paths. | Moved guards to every recursive expression/type entry. | Exact boundary tests for each path. |
| G202-03 | Medium | Parse multiple invalid constructs with `recover_errors = false`. | Reporting an error did not request parser termination. | Stop immediately after the first parser error when recovery is disabled. | First-error-only parser regression. |
| G202-04 | High | Call the public parser with empty, missing-EOF, embedded-EOF, or duplicate-EOF token slices. | The parser trusted scanner-only token-stream invariants. | Require exactly one terminal EOF before parsing. | Four hostile caller token-stream cases. |
| G202-05 | High | Resolve named/star re-exports from an external module across value/type namespaces. | External re-exports bypassed the semantic fixed point and lost identity, edge, or namespace data. | Link named/star external re-exports with exact provenance and namespace filtering. | Project and ABI named/star, value/type/both, type-only, and default-exclusion cases. |
| G202-06 | Medium | Pass hostile native pointers/WASM offsets to `vizg_project_limit_kind`. | This public accessor was absent from the direct hostile-pointer matrix. | Added native C and JavaScript WASM probes with controlled returns. | Misaligned/range/near-end no-trap cases. |
| G202-07 | Medium | Run the required object dump after `zig build wasm-freestanding`. | The WASM artifact installed outside the required documented path. | Install it as `zig-out/lib/vizg.wasm` and align documentation. | The exact object-dump and WASM host gates consume that path. |
| G202-08 | Low | Compare `Lib/vizg.zig` with the public C namespace/limit declarations. | Zig binding comments/re-exports lagged the stable C surface. | Exported limit and namespace types/constants and corrected the ABI version description. | Native/WASM symbol, layout, and cross-check gates. |

No regression weakens an existing assertion or special-cases a fixture.

## Boundary and adversarial coverage

The registered suite covers:

- malformed syntax through the official ABI;
- duplicate logical names with distinct `ModuleId` values and duplicate
  identities with conflicting source;
- null, misaligned, overflowed, past-end, nested, aliased, and
  config/output/workspace-overlapping host ranges;
- unreachable pre-supplied modules and reachable side-effect unresolved edges;
- local and external named/star re-export provenance;
- external value, type, and combined namespaces;
- shortest-depth order independence and cycles;
- exact N/N+1 boundaries for per-module/total source bytes, modules, requests,
  edges, diagnostics, graph depth, and semantic types;
- exhaustive allocation-failure injection through project and ABI publication;
- repeated create/add/step/respond/finish/destroy stress across module, request,
  edge, diagnostic, and external-metadata flows.

Focused source inspection and boundary linting also confirmed that public roots
contain no `vizg_analyze_file`, no production module resolver policy, and no
concrete host implementation outside test/development fixtures.

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

## Observed results

| Command | Observed result |
|---|---|
| `zig build test --summary all` | PASS — 30/30 build steps, 439/439 tests |
| `zig build validate` | PASS — installed artifacts, tests, portable/boundary lints, CLI fixture check |
| `zig build cross-check` | PASS |
| `zig build abi-cross-check` | PASS |
| `zig build abi-layout-test` | PASS |
| `zig build android-aarch64-lib` | PASS |
| `zig build wasm-freestanding` | PASS — JavaScript host and exact import/export assertions passed |
| `git diff --check` | PASS |
| `nm -g --defined-only zig-out/lib/libvizg.a` | PASS — exactly the 18 ABI v1 functions listed below |
| `wasm-objdump -x zig-out/lib/vizg.wasm` | PASS — no import section; `memory` plus exactly the same 18 functions |

`wasm-objdump` came from WABT 1.0.34 extracted under `/tmp` and selected through
`PATH`; no repository or system package artifact was added.

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

- ViZG remains a frontend and semantic analysis engine for its documented
  TypeScript/JavaScript-like subset, not a complete TypeScript checker.
- It has no HIR, lowering, runtime, emitter, backend, bundler, package resolver,
  or production filesystem/URL/network module host.
- The project lifecycle is intentionally one-shot; source revision requires a
  new project.
- Native C cannot portably prove whether an arbitrary non-null integer address
  is mapped before dereference. The contract validates null, alignment,
  overflow, complete ranges, and forbidden overlap; callers must supply mapped
  memory. WASM offsets additionally receive complete linear-memory bounds
  validation.
- Cross-target and Android gates are compile/layout/consumer checks, not foreign
  runtime execution.

## Decision

ABI v1 frozen: **yes**. The public structures, constants, ownership/lifecycle
rules, and 18-function symbol allowlist are the compatibility contract.
Incompatible changes require a new ABI version rather than mutation of v1.

HIR planning authorized: **yes**. No HIR implementation is part of this closure;
future HIR work begins only as a consumer of the frozen frontend, semantic,
project, and ABI v1 foundation.
