# Portable Core And Official ABI v1 — Local Final Audit Checklist

This document accompanies the Goals 189–196 patch series. The patches were
constructed and statically reviewed, but the Zig build/test matrix was not run
in the patch-generation environment. ABI v1 remains a release candidate and
HIR planning remains blocked until the repository owner completes this checklist
locally with no unresolved in-scope finding.

## Scope

Audit these components together:

```txt
src/root.zig
src/project/
Lib/abi.zig
Lib/vizg.h
Lib/vizg.zig
test/wasm/official_abi_v1.mjs
test/support/fs_validation_host.zig
build.zig
```

The filesystem fixture is audited only as test code. Filesystem/package/URL
resolution policy is not part of ViZG.

## Required Contract Checks

- [ ] `vizg_abi_version()` equals `VIZG_ABI_VERSION`.
- [ ] The exported symbol table exactly matches the ABI v1 allowlist.
- [ ] Project input is one-shot; duplicate source identities are rejected.
- [ ] `finish()` is terminal and repeated calls return the same result pointer.
- [ ] Result views remain valid until project destruction and not afterward.
- [ ] Summary, module, diagnostic, edge, import, and export accessors match their
      documented counts and reject out-of-range indexes.
- [ ] Every host pointer/length is validated before dereference or slicing.
- [ ] Host/WASM ranges cannot overlap the exclusive project workspace.
- [ ] Null, overflow, past-end, misaligned, and hostile WASM offsets return a
      controlled status instead of trapping.
- [ ] Allocation failure leaves no dangling semantic result or partial commit.
- [ ] Module operation and `type_only` remain orthogonal, including
      `export type ... from`.
- [ ] Source/module/request/edge/diagnostic/depth/type limits trigger at the
      documented boundary.
- [ ] ViZG public roots contain no filesystem or concrete resolver policy.
- [ ] Concrete module hosts remain test/example-only.

## Required Commands

Run from a clean checkout after applying all eight patches:

```bash
git diff --check
zig build test --summary all
zig build validate
zig build audit-safety
zig build lint-portable-core
zig build lint-module-host-boundary
zig build cross-check
zig build abi-cross-check
zig build abi-layout-test
zig build abi-symbols-test
zig build abi-native-consumer-test
zig build android-aarch64-lib
zig build wasm-freestanding
```

Record the exact Zig version and complete output. Do not replace failed commands
with documentation claims.

## Failure Procedure

For every failure:

1. preserve the smallest reproducer;
2. identify the root cause;
3. correct the implementation rather than weakening the test;
4. add a regression test;
5. rerun the entire matrix, not only the failed command.

## Closure Record

Fill this section only after all commands pass:

```txt
Date:
Zig version:
Commit:
Tests:
Cross-target gates:
Native ABI symbols/layout:
Android:
WASM freestanding:
Unresolved in-scope findings: 0
ABI v1 frozen: yes
HIR planning authorized: yes
```

Until this record is completed, the correct status is:

```txt
ABI v1 release candidate
HIR gate closed
```
