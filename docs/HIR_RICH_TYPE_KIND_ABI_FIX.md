# HIR rich type-kind ABI fix

## Problem

`vizg_hir_type_detail_at` projected the active tag of ViZg's internal
`TypeKind` union directly. The public ABI declared only the primitive and
function values, although valid programs can retain promises, generators,
literals, unions, intersections, arrays, tuples, objects, classes, interfaces,
enums, type parameters, and applied generic types. A conforming downstream
compiler therefore could not decode the type table for ordinary rich-value
programs, and the numeric values depended accidentally on private declaration
order.

The defect was confined to the public projection. Frozen HIR v1 and its type
semantics remain unchanged.

## Fix

The HIR detail ABI now declares explicit numeric constants for every semantic
type category. `vizg_hir_type_detail_at` maps internal tags through an
exhaustive switch instead of exporting internal enum ordinals. Primitive
details continue to carry `builtin_kind`; every other category continues to
use `VIZG_HIR_BUILTIN_NONE`.

The Zig library root re-exports the same constants, and the C lifecycle test
now consumes a valid program containing arrays and objects and verifies that
all non-primitive, non-function details use a declared rich-type range. An
internal regression checks the complete explicit mapping.

## Compatibility

The fix does not change `VIZG_ABI_VERSION`, `VIZG_HIR_DETAIL_API_VERSION`,
frozen HIR v1, any public struct layout, or runtime representation. The newly
declared values match the values previously emitted accidentally, while making
their meaning stable and supported for downstream consumers.
