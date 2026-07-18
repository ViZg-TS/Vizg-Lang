# HIR lowering detail ABI fix

## Problem

The public C HIR projection exposed entity records plus operation and
terminator payloads, but it did not expose enough immutable information to
reconstruct typed SSA faithfully. A downstream compiler could not distinguish
primitive types, read function signatures or declared parameters, identify a
function entry block, recover block parameters at joins, or preserve the end
of an origin span.

Those omissions were in the public projection only. Canonical HIR v1 already
contained the information, so the HIR model and its semantics did not need to
change.

## Fix

`VIZG_HIR_DETAIL_API_VERSION` introduces an additive, read-only detail API:

- `vizg_hir_type_detail_at` exposes the stable type ID, kind, and primitive
  builtin kind.
- `vizg_hir_function_signature` and
  `vizg_hir_signature_parameter_at` expose a function type's return type,
  parameters, generic arity, and async/generator/constructor flags.
- `vizg_hir_function_detail_at` and
  `vizg_hir_function_parameter_at` expose entry blocks and declared HIR
  parameters.
- `vizg_hir_block_detail_at` and `vizg_hir_block_parameter_at` expose SSA block
  parameters.
- `vizg_hir_origin_detail_at` exposes the complete primary span plus optional
  symbol, type, parent, and synthetic-reason provenance.

Function signature access is keyed by a type whose detail kind is
`VIZG_HIR_TYPE_FUNCTION`. Module-initialization HIR functions intentionally use
the builtin `void` type and therefore have no function signature record;
consumers still obtain their entry block and parameters from function detail.

Entity indexes use the same deterministic order as `Vizg_HirRecord`. Returned
strings are borrowed from the immutable result. A version mismatch or invalid
result returns `VIZG_PROJECT_STATUS_INVALID_STATE`; invalid IDs, indexes, or
outputs return `VIZG_PROJECT_STATUS_INVALID_ARGUMENT`. Output memory follows
the existing alignment, mutability, and workspace non-aliasing rules.

## Compatibility

The fix does not change `VIZG_ABI_VERSION`, frozen HIR v1, the
`Vizg_HirRecord` layout, or payload API layouts. It only adds symbols, constants,
and structs. Native and WebAssembly export allowlists, C/Zig layout probes, the
official C consumer, and lifecycle tests cover the new surface.
