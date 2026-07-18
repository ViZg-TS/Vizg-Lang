# HIR payload consumer API v1

`VIZG_HIR_PAYLOAD_API_VERSION` versions an additive, read-only projection of
the frozen HIR v1 operations and terminators. It does not change the HIR model.
Callers must pass this version to every payload accessor.

Operation ordinals are identical to `VIZG_HIR_ENTITY_INSTRUCTION` record
ordinals. Terminator ordinals are identical to `VIZG_HIR_ENTITY_BLOCK` record
ordinals. In both cases `Vizg_HirPayload.tag` equals the corresponding
`Vizg_HirRecord.tag`. All identifiers are returned as their HIR integer value.
An absent optional identifier is `VIZG_HIR_ID_NONE`; bit 0 of `flags` says
whether that optional value is present. Strings are borrowed from the result.

Consumers should request HIR record API v2 alongside this payload API. For an
instruction record, `secondary_id` is then the operation's result `ValueId`, or
`VIZG_HIR_ID_NONE` when flags bit 0 is clear. HIR record API v1 remains
accepted for older consumers and retains its parent-function `secondary_id`.

For a binding record, `tag` is one of the explicit
`VIZG_HIR_BINDING_KIND_*` constants. These values describe `var`, `let`,
`const`, parameter, import, catch, function, class, enum, synthetic, and
temporary bindings without exposing ViZg's internal enum declaration order.

Exceptional-control-flow consumers must also enumerate the immutable region
table with `vizg_hir_region_count`, `vizg_hir_region_detail_at`, and
`vizg_hir_region_protected_block_at`. Those detail-version accessors expose the
region kind, owning function, optional parent, handler, optional continuation,
protected blocks, and origin needed to interpret `THROW`, `LEAVE_REGION`, and
`RESUME_COMPLETION`. Optional region identities use `VIZG_HIR_ID_NONE`; the
matching `VIZG_HIR_REGION_HAS_*` flag states whether each value is present.

## Common subfields

Constants use `tag0` as `Vizg_HirConstantTag`: boolean data is in `operand0`,
number data is the IEEE-754 bit pattern in `operand0`, and bigint or string data
is in `string0`. Undefined and null have no additional data.

Property-bearing operations use `tag1` as `Vizg_HirPropertyKeyTag`. A static
key is in `string0`, a computed-key value ID is in `operand3`, and a private key
uses `operand2` for its module ID and `operand3` for its declaration ID. Private
keys set bit 8 of `flags` when the declaration is external.

## Operation payloads

Fields not named below are zero. Operation names correspond to the
`VIZG_HIR_OPERATION_*` constants in `vizg.h`.

| Operation | Payload |
| --- | --- |
| `CONSTANT` | common constant mapping |
| `COPY` | `operand0=value` |
| `LOAD_BINDING` | `operand0=binding` |
| `INITIALIZE_BINDING`, `STORE_BINDING` | `operand0=binding`, `operand1=value` |
| `LOAD_THIS`, `LOAD_SUPER` | no fields |
| `LOAD_META` | `tag0=Vizg_HirMetaKind` |
| `MAKE_BINDING_PLACE` | `operand0=result place`, `operand1=binding` |
| `MAKE_PROPERTY_PLACE` | `operand0=result place`, `operand1=base`, common property-key mapping |
| `MAKE_ELEMENT_PLACE` | `operand0=result place`, `operand1=base`, `operand2=key value` |
| `MAKE_SUPER_PLACE` | `operand0=result place`, `operand1=receiver`, common property-key mapping |
| `LOAD_PLACE`, `DELETE_PLACE` | `operand0=place` |
| `STORE_PLACE` | `operand0=place`, `operand1=value` |
| `TO_BOOLEAN`, `IS_NULLISH`, `TYPEOF_VALUE`, `VOID_VALUE` | `operand0=value` |
| `UNARY` | `tag0=Vizg_HirUnaryOperator`, `tag1=Vizg_HirNumericMode`, `operand0=operand` |
| `BINARY` | `tag0=Vizg_HirBinaryOperator`, `tag1=Vizg_HirNumericMode`, `operand0=left`, `operand1=right` |
| `ADD` | `tag0=Vizg_HirAddMode`, `operand0=left`, `operand1=right` |
| `CALL`, `CONSTRUCT` | `operand0=callee`, call arguments in items |
| `CALL_METHOD`, `CALL_SUPER_METHOD` | bit 0 says optional callee is present, `operand0=callee`, `operand1=receiver`, common property-key mapping, arguments in items |
| `CALL_SUPER_CONSTRUCTOR` | call arguments in items |
| `TAGGED_TEMPLATE_CALL` | bit 0 says optional receiver is present, `operand0=tag`, `operand1=receiver`, `operand2=template site`, substitutions in items |
| `DYNAMIC_IMPORT` | bit 0 says optional options is present, `operand0=source`, `operand1=options`, attributes in items |
| `CREATE_OBJECT`, `CREATE_ARRAY` | no fields |
| `CREATE_CLOSURE` | `operand0=function` |
| `CREATE_CLASS` | bit 0 says optional base is present, `operand0=entity`, `operand1=base` |
| `CREATE_ENUM_OBJECT` | `operand0=entity` |
| `CREATE_REGEXP` | `operand0=source site`, `string0=pattern`, `string1=flags` |
| `CREATE_TEMPLATE_SITE` | `operand0=source site`, template entries in items |
| `DEFINE_PROPERTY` | `operand0=object`, `operand1=value`, common property-key mapping |
| `DEFINE_METHOD` | `tag0=Vizg_HirFunctionKind`, bit 0 is `is_static`, `operand0=object`, `operand1=function`, common property-key mapping |
| `COPY_OBJECT_PROPERTIES` | `operand0=target`, `operand1=source` |
| `ARRAY_APPEND` | `operand0=array`, `operand1=value` |
| `ARRAY_APPEND_HOLE` | `operand0=array` |
| `ARRAY_APPEND_ITERABLE` | `operand0=array`, `operand1=iterable` |
| `BUILD_STRING` | string parts in items |
| `TO_STRING`, iterator/enumerator operations, `AWAIT`, `YIELD`, `YIELD_DELEGATE` | `operand0=value` |
| `COLLECT_REST_ARGUMENTS`, `READ_ARGUMENT` | `operand0=argument index` |
| `CREATE_ARGUMENTS_OBJECT`, `DEBUGGER_TRAP` | no fields |

`item_count` is the number of available items. Call and construct items use
`tag` as `VIZG_HIR_CALL_ARGUMENT_VALUE` or
`VIZG_HIR_CALL_ARGUMENT_SPREAD` and place the value ID in `operand0`. Tagged
template substitution items place the value ID in `operand0`. Dynamic import
attribute items use `string0=key` and `string1=value`. Template-site items set
bit 0 when cooked text is present, store cooked text in `string0`, and raw text
in `string1`. Build-string items use `tag=VIZG_HIR_TEMPLATE_PART_TEXT` with text
in `string0`, or `tag=VIZG_HIR_TEMPLATE_PART_VALUE` with the value ID in
`operand0`.

## Terminator payloads

| Terminator | Payload |
| --- | --- |
| `JUMP` | `operand0=target block`, argument value IDs in item `operand0` |
| `BRANCH` | `operand0=condition`, `operand1=true block`, `operand2=false block` |
| `RETURN` | bit 0 says optional return value is present, `operand0=value` |
| `THROW` | `operand0=value` |
| `UNREACHABLE`, `RESUME_COMPLETION` | no fields |
| `LEAVE_REGION` | `operand0=region`, `operand1=cleanup block`, `tag0=Vizg_HirCompletionTag`, `operand2=completion target/value`; normal and return completions use bit 0 plus `VIZG_HIR_ID_NONE` for absence |

Accessors return `VIZG_PROJECT_STATUS_INVALID_STATE` for a version mismatch or
an invalid result handle, and `VIZG_PROJECT_STATUS_INVALID_ARGUMENT` for an
invalid ordinal, item ordinal, or output pointer. As with the base result API,
payload outputs must be aligned, mutable, and outside the project workspace.
