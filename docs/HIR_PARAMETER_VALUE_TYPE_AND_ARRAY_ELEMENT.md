# HIR Parameter Value Types and Array Elements

Default parameters have two related contracts:

- the signature records that the argument may be omitted with `has_default`;
- the executable parameter binding records the value type after default
  initialization.

For `function power(value: number, exponent = 2)`, both the signature parameter
and the executable parameter therefore publish the canonical `number` TypeId.
The default flag remains present, so consumers do not need to add `undefined`
to the value used in the function body.

Rest parameters retain their array TypeId. The additive
`vizg_hir_array_element_type()` HIR detail accessor returns the element TypeId
for an array type and rejects non-array TypeIds. This lets downstream compilers
construct typed rest storage without depending on ViZG internals or requiring
an `Array` runtime object.

The lifecycle regression checks both public signature/function parameter
records for the narrowed default type and resolves `number[]` to its public
`number` element TypeId.
