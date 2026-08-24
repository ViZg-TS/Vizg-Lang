# HIR class detail ABI

HIR detail API v6 additively exposes the semantic composition already owned by
a `create_class` entity. A host reads the entity ID from the operation payload,
then calls:

- `vizg_hir_class_detail` for the constructor, optional instance/static
  initializer functions and ordered method count;
- `vizg_hir_class_method_at` for each method's static key, function ID, function
  kind and static flag.

All function and entity IDs belong to the immutable HIR result's identity
domain. `VIZG_HIR_ID_NONE` denotes an absent initializer. Strings are borrowed
from the result and remain valid until `vizg_project_result_destroy`.

The API publishes no allocation, object layout, prototype or invocation policy.
Those remain host/runtime responsibilities. Requests below detail version 6
return `VIZG_PROJECT_STATUS_INVALID_STATE`; unknown entities, non-class entities
and out-of-range methods return `VIZG_PROJECT_STATUS_INVALID_ARGUMENT`.
