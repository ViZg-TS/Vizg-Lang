# HIR binding-kind ABI fix

## Problem

`vizg_hir_record_at` projected a binding's internal `HirBindingKind` ordinal
directly through `Vizg_HirRecord.tag`, but the public ABI declared no constants
for those values. A downstream compiler could observe a number but could not
decode it from the supported public contract, and the number depended
accidentally on ViZg's private enum declaration order.

The defect was confined to the public projection. Frozen HIR v1 and binding
semantics remain unchanged.

## Fix

The HIR record ABI now declares explicit numeric constants for `var`, `let`,
`const`, parameter, import, catch, function, class, enum, synthetic, and
temporary bindings. `vizg_hir_record_at` maps the internal kind through an
exhaustive switch instead of exporting the internal ordinal. The Zig library
root re-exports the same constants, and an internal regression checks the
complete mapping, coverage, and uniqueness.

## Compatibility

The fix does not change `VIZG_ABI_VERSION`, `VIZG_HIR_API_VERSION`, frozen HIR
v1, any public struct layout, or runtime representation. The newly declared
values match the values previously emitted accidentally, while making their
meaning stable and supported for downstream consumers.
