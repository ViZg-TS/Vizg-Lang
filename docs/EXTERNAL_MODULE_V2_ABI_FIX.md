# External-Module API v2 ABI Fix

## Problem

The portable project contract already retained stable external symbol IDs,
declaration kinds, function signatures, and effect metadata. Canonical HIR
requires the same fields for every external declaration. The official C ABI v1
external response, however, exposed only export name, namespace, and optional
primitive type metadata. A C ABI host therefore could not construct the
origin-neutral external declarations required by HIR without losing identity or
inventing compiler-internal defaults.

## Change

The fix is an additive, versioned extension. `VIZG_EXTERNAL_MODULE_API_VERSION`
is `2`, `vizg_external_module_api_version()` reports it, and
`vizg_project_respond_external_v2()` accepts `Vizg_ExternalModuleV2` with:

- a stable `external_symbol_id` for every export;
- an explicit function, global, constant, or type declaration kind;
- a portable function signature for function declarations; and
- origin-neutral effect flags for memory, throws, allocation, I/O, async, and
  unknown behavior.

The public effect-bit layout is translated field by field into the internal
effect set. In particular, public `ALLOCATES`, `IO`, and `ASYNC` bits map to
internal `allocates`, `calls_unknown`, and `may_suspend`; the implementation
does not bit-cast between the two differently ordered layouts.

All strings and arrays are borrowed only for the response call and are validated
with the same alignment, range, workspace-alias, tag, boolean, and reserved-byte
rules as ABI v1. The descriptor is copied into the project-owned portable graph.
No OS path, C header, native library, linker symbol, or resolver-policy detail is
part of the extension.

The implementation also preserves the ABI-wide null/zero convention: a null
array pointer is valid when its element count is zero. The initial v2 response
path validated that representation but still formed slices from null export and
parameter pointers, which trapped in safety-enabled builds. Empty arrays are now
skipped before dereferencing their pointers.

## Compatibility

The official ABI version remains `1`. Existing structures, symbols, and
`vizg_project_respond_external()` are unchanged. Consumers opt into the new
contract only after checking the external-module API version.
The declaration-only Zig companion publishes the same version constant from
the official header.

## Validation Record

The change is covered by C/Zig layout comparison, native symbol and WASM export
allowlists, hostile pointer/range validation inherited by the response path, and
a lifecycle test that publishes a function descriptor and observes its external
declaration and translated effect bits in immutable HIR. A separate lifecycle
regression publishes an empty external module with `exports_ptr = NULL` and
`export_count = 0` and completes the project successfully.
