# HIR function completion type ABI fix

## Defect

The public HIR function signature correctly preserves the externally visible
return type, including `Promise<T>` and `Generator<Y, R>` wrappers. The HIR
detail type projection does not expose the private wrapper payloads, however,
so a downstream MIR consumer could not recover the type accepted by `return`
inside an async function, generator, or async generator.

## Change

The immutable HIR detail projection now provides
`vizg_hir_function_completion_type`. Given a function `TypeId`, the accessor
returns its body completion type: it unwraps the generator return component and
then the async promise component according to the canonical signature flags.
The original wrapped type remains available through
`Vizg_HirFunctionSignature.return_type_id`.

The accessor publishes only a result-local `TypeId`. It does not expose the
type-store representation, a suspension-frame layout, scheduling policy, or an
event-loop contract.

## Compatibility

This is an additive official-ABI-v1 extension. Existing structures, versions,
entry points, and frozen HIR layouts are unchanged. The new accessor requires
`VIZG_HIR_DETAIL_API_VERSION`; version mismatches return
`VIZG_PROJECT_STATUS_INVALID_STATE`, while invalid type identities or output
pointers return `VIZG_PROJECT_STATUS_INVALID_ARGUMENT`.

## Mirrored repair

The same source, header, standalone consumer, ABI regressions, documentation,
and changelog change is applied in the VZed `vendor/vizg` snapshot and the
sibling `../vizg` repository. This record exists in both trees so the
downstream-required repair remains auditable without tracking VZed's ignored
`vendor/` directory.
