# HIR consumer ABI version matrix

ViZG publishes independently versioned, read-only HIR surfaces. A caller must
query each version function and pass a supported requested version to every
accessor. Records and strings are borrowed from the immutable
`Vizg_ProjectResult`; they remain valid until
`vizg_project_result_destroy()` and must not be freed by the caller.

| Surface | Version | Contract |
|---|---:|---|
| Frozen HIR records | 1-2 | Summary and generic entity records. Existing layouts remain frozen. |
| HIR payload | 1 | Operation and terminator payload projections. |
| HIR detail | 2 | Type, signature, module, binding, storage, capture, region and origin projections. |
| HIR detail | 3 | All detail-v2 projections plus `Vizg_HirExternalDeclarationDetail`, including stable module/symbol identity and optional opaque intrinsic identity. |
| External module producer | 3 | Ordered structural types and signature references supplied by the host. |

Unchanged detail accessors accept requested versions 2 and 3. The external
declaration detail accessor requires version 3. Unsupported older or future
versions return `VIZG_PROJECT_STATUS_INVALID_STATE`; null, misaligned,
workspace-overlapping and out-of-bounds outputs return
`VIZG_PROJECT_STATUS_INVALID_ARGUMENT`.

Version 3 is additive: it does not change the layout of any version-2 record.
`flags & 1` states whether `intrinsic_id` is present. When absent,
`intrinsic_id` is zero and must not be interpreted as an identity.
