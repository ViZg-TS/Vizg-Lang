# Portable Core And Official ABI v1 Final Audit

Date: 2026-07-14

Goal 188 is closed. The post-remediation audit found no unresolved in-scope
defect. HIR planning may begin; HIR implementation still requires a separate
executable goal.

## Scope And Method

The audit covered the dependency graph rooted at `src/root.zig`, project and
request state transitions, source/external identity, C ABI layouts and handle
lifetimes, native and WebAssembly pointer ranges, the native filesystem host,
configured growth limits, cross-target compilation, and native/WASM symbols.
It used targeted code review, deterministic mutation, malformed-input tests,
path-replacement attacks, repeated lifecycle tests, four simultaneous
independent projects, exact symbol tables, and the complete build matrix.

## Remediated Findings

| ID | Severity | Reproduction and root cause | Fix | Regression |
|---|---|---|---|---|
| G188-1 | High | Place ABI config, output, source, external descriptors, or nested spans inside the project workspace. Validation used the allocator's changing buffer length, so later workspace bytes could be mistaken for host input. | Retain the original workspace extent; validate every public struct, nested pointer/length span, checked multiplication/addition, output, and wasm32 linear-memory range before use; reject all workspace overlap. | `official ABI v1 rejects aliased structs and stale handles without workspace mutation` |
| G188-2 | Medium | Reuse a destroyed project/result handle or destroy it twice. Opaque handles lacked an explicit live/dead discriminator. | Add typed magic values and destroyed state; reject stale handles and make repeated destroy calls inert. | Same ABI alias/stale-handle regression plus repeated lifecycle coverage. |
| G188-3 | Medium | Respond with external exports repeatedly in a bounded workspace. Temporary C-to-Zig descriptors were allocated below retained project copies and could not be reclaimed. | Convert descriptors in aligned scratch at the unused top of the fixed buffer, temporarily cap the persistent allocator below it, then restore the full buffer. | `external response conversion uses reclaimable workspace scratch` compares C conversion with direct core allocation. |
| G188-4 | High | Resolve an allowed file, replace a path component with an escaping symlink, then read. Canonicalize-then-reopen created a path race. | Anchor an open root directory; traverse canonical relative components with no-follow opens; retain the opened leaf and perform metadata and content reads through that same handle. | `filesystem host reads the opened file across a path replacement`, plus traversal, escaping-symlink, size, and module-limit tests. |
| G188-5 | Low | Link the Zig archive into the default Linux C executable. Zig's object lacks `.note.GNU-stack`, so GNU ld can infer an executable stack. | The Linux consumer link explicitly requests `-z noexecstack`; a `readelf` gate rejects a missing or executable `GNU_STACK`. | `zig build abi-native-consumer-test`, included in `zig build test`. |

## Post-Remediation Audit

- Portable core: no filesystem, POSIX, libc, WASI, environment, callback, or
  native-adapter dependency is reachable from `src/root.zig`. The structural
  freestanding lint and `wasm32-freestanding` compilation enforce the boundary.
- State machine: FIFO dispatch, stable waiting requests, copied specifiers and
  attributes, equivalent-request deduplication, foreign/stale/duplicate/order
  rejection, cycles, partial failures, and guarded finish converge
  deterministically.
- Identity: source `ModuleId`, external `ExternalModuleId`, and project-local
  `RequestId` remain distinct fixed-width types. Logical names never define
  identity. Collision and descriptor-conflict tests pass.
- Limits: cumulative source bytes, module count, diagnostics, graph depth, and
  semantic types return `LIMIT_EXCEEDED`; fixed-workspace exhaustion returns
  `OUT_OF_MEMORY`. Stress coverage includes source, module, graph, cycle,
  diagnostic, semantic, and repeated create/analyze/destroy growth.
- Host input: malformed source, tags, reserved bytes, spans, response ordering,
  specifier/attribute bytes, null/length pairs, integer overflow, workspace
  aliasing, and wasm32 offsets are rejected or diagnosed without corrupting
  live state.
- Native filesystem: traversal, absolute input, escaping symlinks, component
  replacement races, non-files, source size, and module count are confined by
  the adapter policy. Network adapters do not exist and remain out of scope.

## Symbol And Layout Audit

The native archive's only official global ABI symbols are:

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

Debug native toolchain imports are limited to `_DYNAMIC`, `__divti3`,
`__modti3`, `__tls_get_addr`, `getauxval`, `memcpy`, and `memmove`.
Release-mode compiler-runtime allowlists are separately exact. These are Zig
code-generation/runtime helpers, not core OS service calls. The freestanding
WASM module imports nothing and exports only memory plus the official ABI v1
allowlist. C-compiled probes verify every public size, alignment, offset, enum,
version, and symbol declaration.

## Final Verification

All commands passed on Zig 0.16.0:

```bash
zig build test --summary all          # 476/476 tests
zig build validate
git diff --check
zig build cross-check
zig build abi-cross-check
zig build abi-layout-test
zig build android-aarch64-lib
zig build wasm-freestanding
```

The test gate also enforces portable-core imports, native symbol/import tables,
default-PIE C linking, non-executable Linux stack, ABI lifecycle behavior, and
the C/Zig layout probe.

## Residual Contract Limits

- Native C callers must provide mapped readable/writable objects as required by
  C; portable code can validate null, length, overflow, alignment, nesting, and
  workspace overlap but cannot safely probe arbitrary unmapped virtual
  addresses. wasm32 ranges are fully checked against current linear memory.
- A project handle is single-threaded. Independent workspaces and immutable
  result reads may run concurrently; destruction requires synchronization.
- Exhaustion or internal failure is terminal for that project. Destroy it and
  restart. Partial terminal resolution failures remain inspectable by design.
- The network-adapter security non-goal remains unchanged.

These are documented API/environment preconditions, not unresolved defects.
