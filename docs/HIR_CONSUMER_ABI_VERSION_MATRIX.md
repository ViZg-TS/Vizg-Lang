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
| HIR detail | 4 | External structural type identity/member projection. |
| HIR detail | 5 | Resolved source language-item count and immutable identity records. |
| HIR detail | 6 | Additive class/interface semantic composition detail. |
| HIR detail | 7 | Executable value-language-item `FunctionId` lookup and immutable applied-generic resolved-target lookup; earlier record layouts remain frozen. |
| External module producer | 3 | Ordered structural types and signature references supplied by the host. |
| External module producer | 4 | Stable opaque intrinsic identity on source-less exports. |

Unchanged detail accessors accept requested versions 2 through 7. The external
declaration detail accessor requires version 3, external type identity requires
version 4, language-item enumeration requires version 5, class composition
requires version 6, and executable-language-item/applied-generic-target queries
require version 7. Unsupported older or future versions return
`VIZG_PROJECT_STATUS_INVALID_STATE`; null, misaligned, workspace-overlapping and
out-of-bounds outputs return `VIZG_PROJECT_STATUS_INVALID_ARGUMENT`.

Every detail version is additive: it does not change an earlier record layout.
In version 3,
`flags & 1` states whether `intrinsic_id` is present. When absent,
`intrinsic_id` is zero and must not be interpreted as an identity.
