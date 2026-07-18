# HIR region detail ABI fix

## Defect

The frozen HIR model contains structured `catch`, `finally`, and iterator-close
regions, but the supported public ABI exposed only the region identifiers carried
by `LEAVE_REGION`. A downstream MIR consumer could not recover region ownership,
nesting, protected blocks, handler blocks, or continuations without reading
ViZg-internal storage.

## Change

The versioned immutable HIR detail projection now provides:

- `vizg_hir_region_count`;
- `vizg_hir_region_detail_at`;
- `vizg_hir_region_protected_block_at`;
- explicit stable tags for every HIR region kind; and
- presence flags for optional parent and continuation identities.

`Vizg_HirRegionDetail` carries only abstract HIR identities and provenance. It
does not publish a runtime exception layout or constrain downstream lowering.

## Compatibility

This is an additive official-ABI-v1 extension. Existing structures, versions,
entry points, and frozen HIR layouts are unchanged. All new accessors require
`VIZG_HIR_DETAIL_API_VERSION`; version mismatches return
`VIZG_PROJECT_STATUS_INVALID_STATE`, while invalid ordinals or output pointers
return `VIZG_PROJECT_STATUS_INVALID_ARGUMENT`.

## Mirrored repair

The same source, header, Zig facade, ABI regression, documentation, and changelog
change is applied in the VZed `vendor/vizg` snapshot and the sibling `../vizg`
repository. This record exists in both trees so the downstream-required repair
remains auditable without tracking VZed's ignored `vendor/` directory.
