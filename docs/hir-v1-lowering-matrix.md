# ViZG HIR v1 — TypeScript-to-HIR Lowering Matrix

**Status:** frozen normative coverage table for Goals 208–237
**Companion specification:** [`hir-v1-design.md`](hir-v1-design.md)

This document is the authoritative checklist connecting supported frontend forms to legal HIR v1 forms.

A row is complete only when its lowering, canonical output, diagnostics, provenance and tests exist.

---

## 1. Classification

| Class | Meaning |
|---|---|
| **Erase** | No executable HIR operation survives. Relevant type/source facts may remain in metadata. |
| **Entity** | Produces or references a canonical project/module/function/class/enum entity. |
| **Instruction** | Produces one or more legal HIR instructions. |
| **Control flow** | Produces blocks, terminators, block parameters or region edges. |
| **Module metadata** | Produces dependencies, live bindings, exports or initialization ordering. |
| **Region** | Produces target-independent exception/cleanup or suspension semantics visible to consumers. |
| **Reject** | Must fail the HIR eligibility gate; no public partial HIR is emitted. |
| **Future reduction** | Reserved documentation for a syntax feature not currently supported by the frontend. |

---

## 2. Legal HIR surface

Legal HIR v1 consists only of:

```txt
project/module/entity/function records
bindings, captures and parameter plans
basic blocks and block parameters
immutable temporary ValueId results
semantic PlaceId references
legal HIR instructions
jump / branch / return / throw / unreachable
exception and cleanup regions
module dependency/import/export metadata
origin and optional lowering-trace side tables
```

The following are never legal final HIR nodes:

```txt
AST Program or Statement nodes
IfStatement / SwitchStatement / loop nodes
ArrowFunctionExpression
ConditionalExpression
SequenceExpression
AssignmentExpression / UpdateExpression
optional-chain syntax nodes
As / Satisfies / NonNull wrappers
TypeNodeData
ImportDeclaration / ExportDeclaration syntax
```

---

## 3. Complete current `NodeData` mapping

| AST/source form | Classification | Canonical HIR equivalent | Required semantic constraints |
|---|---|---|---|
| `Program` | Module metadata | `HirModule` plus module initialization `HirFunction` | Preserve source statement initialization order and host-supplied `ModuleId`. |
| `BlockStatement` | Control flow | Lexical scope metadata plus one or more basic blocks | Do not hoist block-scoped declarations out of their source scope. |
| `ExpressionStatement` | Instruction/control flow | Lower expression; discard resulting value | Effects must remain even when the value is unused. |
| `Identifier` | Instruction | `load_binding`, entity/function reference, or import live-binding read | Use resolved semantic identity; never look up by spelling during lowering. |
| `Literal` | Instruction | `constant` | Preserve number spelling semantics, bigint, string, boolean and null. The current AST represents `undefined` as an `Identifier`; its resolved binding must remain distinct from a literal and from an array hole. |
| `RegExpLiteral` | Instruction | `create_regexp(pattern, flags, source_site)` | Do not share object identity across evaluations unless language semantics prove it. |
| `TemplateExpression` | Instruction | `build_string` with ordered `to_string` inputs | Preserve raw/cooked segments and conversion order. |
| `TaggedTemplateExpression` | Instruction/entity | `tagged_template_call(tag, TemplateSiteId, values)` | Preserve template object identity per source site, raw/cooked values and receiver semantics. |
| `ImportExpression` | Instruction | `dynamic_import(source, options, attributes)` | Runtime operation; does not resolve specifiers inside ViZG. |
| `MetaProperty(import.meta)` | Instruction | `load_meta import_meta` | Module/runtime semantic value; representation deferred. |
| `MetaProperty(new.target)` | Instruction | `load_meta new_target` | Legal only in valid function/constructor contexts. |
| `TypeAliasDeclaration` | Erase | No executable HIR | Type remains in semantic/debug tables. |
| `InterfaceDeclaration` | Erase | No executable HIR | Interface type/member metadata remains in semantic/debug tables. |
| `EnumDeclaration` | Entity/instruction | `HirEnumEntity` plus `create_enum_object` initialization plan | Preserve numeric reverse mapping and initializer order where applicable. |
| `EnumMember` | Entity metadata | Enum member descriptor and ordered initializer operation | Computed names and initializers evaluate in source order. |
| `VariableDeclaration` | Entity/instruction | One `HirBinding` per declarator plus initialization operations | Preserve `var` hoisting, `let`/`const` TDZ, mutability and initialization timing. |
| `VariableDeclarator` | Instruction | Binding creation metadata plus optional `store_binding` | Initializer evaluated once at the correct source point. |
| `FunctionDeclaration` | Entity | Canonical `HirFunction`; binding initialized according to declaration semantics | Preserve hoisting and module/function scope identity. |
| `FunctionExpression` | Entity/instruction | Canonical `HirFunction` plus `create_closure` | Named function-expression self-binding remains local to its body. |
| `YieldExpression` | Region/instruction | `yield` or `yield_delegate` | Legal only in generator context; suspension lowering deferred to MIR. |
| `ArrowFunctionExpression` | Entity/instruction | Canonical `HirFunction` plus `create_closure` | Preserve lexical `this`, `arguments`, `super` and `new.target`; expression body becomes return. |
| `Parameter` | Function metadata/instruction | `HirParameter`, argument read, default-value branch, optional rest collection | Optional marker/type/access modifiers erase unless parameter-property semantics apply. |
| `ClassDeclaration` | Entity/instruction | `HirClassEntity`; binding initialization in module/function body | Preserve class TDZ, `extends` evaluation, static initialization and source order. |
| `ClassExpression` | Entity/instruction | Anonymous/named `HirClassEntity` plus `create_class` | Preserve local class name visibility and evaluation timing. |
| `ClassField` | Entity/function metadata | Instance/static initializer plan | Type/access/readonly/optional/definite syntax erases; runtime initialization remains. |
| `ClassMethod` | Entity | Canonical `HirFunction` referenced by class descriptor | Preserve static/instance, constructor/getter/setter, `super`, receiver and flags. |
| `SpreadElement` | Contextual instruction | Array: `array_append_iterable`; call: ordered argument spread; object: `copy_object_properties` | Spread semantics are context-specific and must not use one ambiguous generic operation. |
| `ReturnStatement` | Terminator/region | `return value?` or `leave_region return(value?)` | Must execute enclosing `finally` cleanup before completion. |
| `ThrowStatement` | Terminator/region | `throw value` or `leave_region throw(value)` | Preserve exception origin and cleanup traversal. |
| `DebuggerStatement` | Instruction | `debugger_trap` | May be a no-op only by explicit consumer policy, not erased by canonical lowering. |
| `TryStatement` | Region | Protected region with optional catch and finally/cleanup entries | Cannot lower to ordinary `if`; abrupt completions must pass through `finally`. |
| `CatchClause` | Region/binding | Catch entry block plus catch binding initialization | Parameter exists only on catch entry and in catch scope. |
| `FinallyClause` | Region | Cleanup block ending in `resume_completion` or replacement completion | A completion produced inside finally replaces the pending completion. |
| `BreakStatement` | Control flow/region | Resolved `jump` or `leave_region break(target)` | Label resolution completed before HIR; no label spelling lookup remains. |
| `ContinueStatement` | Control flow/region | Resolved `jump` or `leave_region continue(target)` | Classic `for` continue targets update block; loop kind determines target. |
| `LabeledStatement` | Control flow metadata | Resolved break/continue target identity; label syntax erased | Labels do not survive as executable nodes. |
| `ThisExpression` | Instruction | `load_this` | Function kind determines lexical/dynamic receiver semantics. |
| `SuperExpression` | Instruction/place/call | `load_super`, `make_super_place`, or super-call semantic operation | Legal only in class contexts and must preserve receiver behavior. |
| `NewExpression` | Instruction | `construct(callee, args)` | Distinct from ordinary `call`; preserve argument order and constructability checks. |
| `CallExpression` | Instruction/control flow | `call`, `call_method`, or optional-call nullish branch | Member calls preserve receiver; optional calls evaluate callee/base once. |
| `MemberExpression` | Place/instruction/control flow | `make_property_place` + `load_place`; optional form lowers to nullish branch | Property access may call user code or throw; do not mark pure by default. |
| `ElementAccessExpression` | Place/instruction/control flow | Evaluate base/index once, `make_element_place`, `load_place`; optional form branches | Computed key evaluation order is observable. |
| `AsExpression` | Erase | Lower inner expression unchanged | Preserve declared assertion/type and source span only in provenance. |
| `SatisfiesExpression` | Erase | Lower inner expression unchanged | Compile-time checking already completed; runtime value is the original expression. |
| `NonNullExpression` | Erase | Lower inner expression unchanged | No runtime null check is introduced by TypeScript non-null assertion. |
| `UnaryExpression` | Instruction/place | See unary operator matrix | Preserve coercion, throw behavior and delete-place semantics. |
| `BinaryExpression` | Instruction/control flow | See binary operator matrix | `&&`, `\|\|`, `??` lower to branches; other operators use typed semantic modes. |
| `SequenceExpression` | Instruction | Lower every expression in order; discard all but final value | Empty sequence is invalid frontend input; effects of earlier expressions remain. |
| `ConditionalExpression` | Control flow | `branch` + merge block parameter | Only selected arm evaluates. |
| `UpdateExpression` | Place/instruction | Evaluate place once; load; add/subtract one; store; choose old/new result | Prefix and postfix results differ. |
| `AssignmentExpression` | Place/instruction/control flow | See assignment matrix | Evaluate LHS place before RHS as required; logical assignments short-circuit. |
| `IfStatement` | Control flow | `to_boolean` + `branch` + blocks + merge | No final `if` node. |
| `WhileStatement` | Control flow | condition block, body block, exit block | Continue targets condition. |
| `DoWhileStatement` | Control flow | body first, condition block, exit block | Body executes at least once. |
| `ForStatement(classic)` | Control flow | init, condition, body, update, exit blocks | Continue targets update; absent condition means true. |
| `ForStatement(in)` | Instruction/control flow | property-enumeration semantic operation plus loop blocks | Not equivalent to `Object.keys`; enumeration semantics remain explicit. |
| `ForStatement(of)` | Instruction/control flow/region | iterator protocol operations plus loop blocks and close-on-abrupt-exit cleanup | Sync iterator protocol; preserve iterator closing. |
| `ForStatement(await of)` | Instruction/control flow/region | async iterator protocol plus `await` operations and close cleanup | Legal only in async context; state machine deferred to MIR. |
| `SwitchStatement` | Control flow | evaluate discriminant once; ordered strict-equality dispatch blocks; body blocks | Preserve case-expression effects, default position and fallthrough. |
| `SwitchCase` | Control flow metadata | One test block when condition exists; one body entry | Case body edges encode fallthrough; `default` has no test expression. |
| `ImportDeclaration` | Module metadata | dependency plus import live-binding descriptors | Type-only imports erase; side-effect import adds initialization dependency. |
| `ExportDeclaration` | Module metadata/entity | export table entry, re-export link, export-all descriptor or default binding | Preserve live bindings and host-resolved module identity. |
| `ObjectExpression` | Instruction | `create_object` plus ordered property/method/spread operations | Computed keys, values and spreads evaluate in source order. |
| `ArrayExpression` | Instruction | `create_array` plus append/hole/spread operations | Preserve holes separately from explicit `undefined`. |

---

## 4. Complete current `TypeNodeData` mapping

All current type-node forms are compile-time-only for HIR v1.

| Type AST form | HIR equivalent | Metadata retained when debug requires it |
|---|---|---|
| `Named` | Erased | Resolved `TypeId`, source span, declaration identity |
| `Literal` | Erased | Resolved literal `TypeId`, spelling/span |
| `Array` | Erased | Resolved array `TypeId` |
| `Readonly` | Erased | Original readonly syntax and resolved `TypeId` |
| `IndexedAccess` | Erased | Resolved resulting `TypeId` and source type nodes |
| `KeyOf` | Erased | Resolved resulting `TypeId` |
| `TypeQuery` | Erased | Resolved resulting `TypeId` and queried symbol |
| `Union` | Erased | Canonical union `TypeId` |
| `Intersection` | Erased | Canonical intersection `TypeId` |
| `Object` | Erased | Structural object `TypeId` and member identities |
| `Function` | Erased | Function-signature `TypeId` |
| `Tuple` | Erased | Tuple `TypeId` |
| `Parenthesized` | Erased | Inner resolved `TypeId`; optional syntax origin |

Type erasure does not delete the semantic type system. Every value-producing HIR instruction still references the appropriate project-local `TypeId`.

---

## 5. Unary operator matrix

| TypeScript operator | Canonical HIR | Notes |
|---|---|---|
| unary `+x` | `unary_plus(mode, x)` | Preserve ECMAScript numeric coercion and possible throw. MIR may specialize later. |
| unary `-x` | `negate(mode, x)` | Preserve `-0`, bigint restrictions and dynamic coercion. |
| `!x` | `to_boolean x` then `boolean_not` | Truthiness conversion is explicit. |
| `~x` | `bit_not(mode, x)` | Numeric/bigint/dynamic semantic mode comes from typed semantics. |
| `typeof x` | `typeof_value x` | Identifier special cases must already be represented correctly by semantic lowering. |
| `void x` | evaluate `x`, then `void_value` | Effects of `x` remain; result is `undefined`. |
| `delete target` | evaluate `PlaceId`, then `delete_place` | Binding/property legality and strict-mode behavior must be preserved. |
| `await x` | `await x` | Suspension semantic remains in HIR; machine-state lowering is MIR. |
| `yield x` | `yield x` | Generator-only. |
| `yield* x` | `yield_delegate x` | Delegation protocol remains semantic. |

---

## 6. Binary operator matrix

| TypeScript operator | Canonical HIR | HIR versus MIR boundary |
|---|---|---|
| `a + b` | `add(mode, a, b)` | Mode is numeric/string/dynamic from semantics; unboxing is MIR. |
| `a - b` | `subtract(mode, a, b)` | Target numeric representation is MIR. |
| `a * b` | `multiply(mode, a, b)` | Same. |
| `a / b` | `divide(mode, a, b)` | Preserve JS/TS number semantics and throws for bigint cases. |
| `a % b` | `remainder(mode, a, b)` | Same. |
| `a ** b` | `exponentiate(mode, a, b)` | Same. |
| `a & b` | `bit_and(mode, a, b)` | Specialization deferred. |
| `a \| b` | `bit_or(mode, a, b)` | Not the pipeline token. |
| `a ^ b` | `bit_xor(mode, a, b)` | Specialization deferred. |
| `a << b` | `shift_left(mode, a, b)` | Preserve coercion/masking semantics. |
| `a >> b` | `shift_right(mode, a, b)` | Signed shift semantics. |
| `a >>> b` | `shift_right_unsigned(mode, a, b)` | BigInt invalidity remains checked/diagnosed. |
| `a < b` | `less(mode, a, b)` | Dynamic coercion may call user code. |
| `a <= b` | `less_equal(mode, a, b)` | Do not rewrite naïvely using negation if coercion order would change. |
| `a > b` | `greater(mode, a, b)` | Preserve operand/coercion order. |
| `a >= b` | `greater_equal(mode, a, b)` | Preserve operand/coercion order. |
| `a == b` | `equal_loose(mode, a, b)` | Never canonicalize to strict equality without proof. |
| `a != b` | `not_equal_loose(mode, a, b)` | Same. |
| `a === b` | `equal_strict(mode, a, b)` | May specialize in MIR. |
| `a !== b` | `not_equal_strict(mode, a, b)` | May specialize in MIR. |
| `key in object` | `in(key, object)` | Semantic operation may throw/call proxy traps. |
| `value instanceof ctor` | `instanceof(value, ctor)` | Semantic operation may call custom behavior. |
| `a && b` | truthiness `branch` + merge value | `b` executes only when `a` is truthy. |
| `a \|\| b` | truthiness `branch` + merge value | `b` executes only when `a` is falsy. |
| `a ?? b` | `is_nullish` `branch` + merge value | Must not use truthiness. |
| `a |> f` | **Future:** evaluate both in specified order, then `call f(a)` for simple F# semantics | Frontend currently rejects it; exact proposal must be frozen before implementation. No dedicated HIR pipeline op. |

---

## 7. Assignment and update matrix

All assignment lowering starts by evaluating the left-hand side into one `PlaceId` exactly once.

| Source form | Canonical HIR |
|---|---|
| `lhs = rhs` | `place = lower_place(lhs)`; `value = lower(rhs)`; `store_place place, value`; expression result is `value` |
| `lhs += rhs` | place; old=`load_place`; rhs; `add(mode, old, rhs)`; store; result=new |
| `lhs -= rhs` | place; old; rhs; `subtract`; store; result=new |
| `lhs *= rhs` | place; old; rhs; `multiply`; store; result=new |
| `lhs /= rhs` | place; old; rhs; `divide`; store; result=new |
| `lhs %= rhs` | place; old; rhs; `remainder`; store; result=new |
| `lhs **= rhs` | place; old; rhs; `exponentiate`; store; result=new |
| `lhs &= rhs` | place; old; rhs; `bit_and`; store; result=new |
| `lhs \|= rhs` | place; old; rhs; `bit_or`; store; result=new |
| `lhs ^= rhs` | place; old; rhs; `bit_xor`; store; result=new |
| `lhs <<= rhs` | place; old; rhs; `shift_left`; store; result=new |
| `lhs >>= rhs` | place; old; rhs; `shift_right`; store; result=new |
| `lhs >>>= rhs` | place; old; rhs; `shift_right_unsigned`; store; result=new |
| `lhs &&= rhs` | place; old=`load_place`; truthiness branch; evaluate/store rhs only on truthy path; merge old/new result |
| `lhs \|\|= rhs` | place; old; truthiness branch; evaluate/store rhs only on falsy path; merge old/new result |
| `lhs ??= rhs` | place; old; nullish branch; evaluate/store rhs only on nullish path; merge old/new result |
| `lhs++` | place; old; add one; store new; expression result=old |
| `++lhs` | place; old; add one; store new; expression result=new |
| `lhs--` | place; old; subtract one; store new; expression result=old |
| `--lhs` | place; old; subtract one; store new; expression result=new |

No final HIR instruction named `compound_assignment`, `logical_assignment` or `update_expression` is legal.

---

## 8. Call and access matrix

| Source form | Canonical HIR | Critical requirement |
|---|---|---|
| `fn(args)` | `call fn(args)` | Evaluate callee before arguments, arguments left-to-right. |
| `obj.method(args)` | `call_method obj, "method", args` | Preserve `obj` as receiver. |
| `obj[key](args)` | evaluate `obj`, then `key`; `call_method obj, key, args` | Base and key evaluated once. |
| `new C(args)` | `construct C(args)` | Distinct from call. |
| `obj.prop` | property place + `load_place` | Access may have effects. |
| `obj[key]` | element place + `load_place` | Key evaluated once. |
| `obj?.prop` | nullish branch; undefined arm; access arm; merge | Base evaluated once. |
| `obj?.[key]` | nullish branch before evaluating key; access arm; merge | Computed key does not evaluate on nullish arm. |
| `fn?.(args)` | nullish branch before evaluating arguments; call arm; merge | Arguments do not evaluate on nullish arm. |
| `obj.method?.(args)` | evaluate receiver/property reference once; nullish-check callee; `call_method` on call arm | Preserve receiver even though callee is optional. |
| `super(args)` | canonical super-constructor call operation | Enforce derived-constructor rules. |
| `super.prop` | super place + load | Preserve current receiver. |
| `super.method(args)` | super method call with current receiver | Preserve home object semantics. |

---

## 9. Aggregate literal matrix

| Source form | Canonical HIR sequence |
|---|---|
| `{}` | `create_object` |
| `{ key: value }` | create object; lower value; `define_property` |
| `{ key }` shorthand | create object; load resolved binding; `define_property` |
| `{ [keyExpr]: value }` | create object; lower key then value; `define_property` |
| `{ ...source }` | create object; lower source; `copy_object_properties` |
| `{ method() {} }` | create closure for canonical function; `define_method` |
| `{ get value() {} }` | canonical getter function; accessor definition operation |
| `{ set value(v) {} }` | canonical setter function; accessor definition operation |
| `[]` | `create_array` |
| `[value]` | create array; lower value; `array_append` |
| `[,]` | create array; `array_append_hole` |
| `[...iterable]` | create array; lower iterable; `array_append_iterable` |
| `` `a${x}b` `` | lower expressions in order; `to_string`; `build_string` |
| `tag\`a${x}b\`` | resolve `TemplateSiteId`; lower tag/expressions; `tagged_template_call` |
| `/pattern/flags` | `create_regexp` with source-site origin |

Implemented through Goal 218: data properties, methods, accessors, object
spread, array holes, and iterable array spread retain source order; call spread
is represented as a call argument. Untagged substitutions use ordered
`to_string`, while tagged sites retain receiver, raw/optional-cooked segments,
and stable source-site identity. Regexp creation retains pattern, canonical
flags, and stable source-site identity per evaluation.

---

## 10. Function-like mapping

| Source form | Canonical entity flags/plan |
|---|---|
| `function f(){}` | function entity, dynamic `this`, declaration binding semantics |
| `function(){}` | function entity + closure creation, dynamic `this` |
| `(x) => x` | function entity + closure creation, `lexical_this`, expression body → return |
| `async function` | function entity flag `async`; `await` remains semantic |
| `function*` | function entity flag `generator`; `yield` remains semantic |
| `async function*` | flags `async_generator`; await/yield remain semantic |
| object/class method | function entity plus method descriptor and receiver semantics |
| constructor | function entity flag `constructor`; parameter-property and instance-field plans inserted at required points |
| getter | function entity flag `getter`; zero ordinary parameters |
| setter | function entity flag `setter`; one ordinary parameter |
| default parameter | argument read + undefined test + branch + merge |
| rest parameter | `collect_rest_arguments(start_index)` |
| optional parameter marker | erased; call/argument type checking already complete |
| parameter property | ordinary parameter plus instance property initialization in constructor plan |

Closure capture analysis records semantic captures but does not choose environment layout.

Implemented through Goal 222: declarations, expressions, arrows, object
methods/accessors, and async/generator variants share canonical bodies. Argument
reads, ordered per-call defaults, and rest collection are explicit; captures
come from resolved semantic identities, with lexical arrow receiver state
retained and no environment layout selected. Conditional statements and sync
loops use explicit blocks; property enumeration and iterator protocols remain
semantic operations, with iterator-close cleanup on abrupt `for...of` exit.
Switch discriminants are evaluated once, non-default tests remain lazy and
source ordered even when `default` appears in the middle, and case fallthrough
is represented only by CFG edges. Labels erase after break/continue resolution
to exact block identities, including labeled iteration through cleanup regions.
Try/catch/finally uses explicit nested regions. Catch bindings initialize only
at handler entry, and one shared cleanup body resumes normal, return, throw,
break, or continue completion unless the cleanup creates a replacement
completion. Region validation rejects invalid ownership, nesting, entries,
cleanup exits, and resume sites without encoding a runtime exception ABI.

---

## 11. Control-flow mapping

| Source construct | Canonical blocks/regions |
|---|---|
| `if` | condition value → `to_boolean` → branch to then/else → merge |
| ternary | same, with branch values passed to merge block parameter |
| `while` | condition → branch body/exit; body → condition |
| `do...while` | body → condition → branch body/exit |
| classic `for` | init → condition → body → update → condition; exit |
| `for...in` | enumeration operation → next/done loop → body |
| `for...of` | iterator operations → next/done loop → body; close cleanup on abrupt exit |
| `for await...of` | async iterator operations and await points; close cleanup |
| `switch` | one discriminant evaluation; ordered case-test chain; body graph with fallthrough edges |
| `break` | direct jump or region leave to resolved break target |
| `continue` | direct jump or region leave to resolved continue target |
| label | target metadata only; syntax erased |
| `return` | direct terminator or region leave with pending return completion |
| `throw` | direct terminator or region leave with pending throw completion |
| `try/catch` | protected region and catch entry |
| `try/finally` | cleanup region with pending completion and `resume_completion` |

---

## 12. Module mapping

| TypeScript module form | HIR module equivalent |
|---|---|
| named import | live import binding linked to host-resolved module export |
| default import | live import binding linked to export `default` |
| namespace import | namespace binding descriptor for the resolved module |
| side-effect import | initialization dependency only |
| type-only import | erased executable binding; semantic type identity retained |
| local named export | export-table link to local live binding/entity |
| default expression export | synthetic/default binding initialized in module init; export-table link |
| declaration export | declaration entity/binding plus export-table link |
| re-export | export link to host-resolved dependency binding |
| export-all | export-all descriptor with conflict semantics preserved by linker contract |
| type-only export | erased executable export; semantic type identity retained |
| dynamic import | executable `dynamic_import` instruction |

HIR never canonicalizes paths or resolves raw specifiers.

---

## 13. Class and enum mapping

| Source form | Canonical HIR |
|---|---|
| class declaration/expression | one `HirClassEntity` and runtime class-identity creation operation |
| `extends expr` | evaluate base expression once at class evaluation time; attach semantic base |
| constructor | canonical function entity |
| derived constructor `super()` | explicit super-constructor semantic call |
| instance field | ordered instance-initializer plan |
| static field | ordered static-initializer plan |
| instance method | class method descriptor → canonical function |
| static method | static method descriptor → canonical function |
| getter/setter | accessor descriptor → canonical function |
| access modifier | erased from executable graph; optional metadata only |
| readonly/optional/definite marker | erased from executable graph |
| parameter property | constructor parameter + instance-property initialization |
| enum | enum entity plus ordered runtime enum-object initialization |
| numeric enum member | value definition plus reverse mapping |
| string enum member | value definition without numeric reverse mapping |

HIR does not define prototype representation, hidden classes, vtables, object field offsets or constructor ABI.

---

## 14. Current unsupported syntax

The following forms fail before HIR or at the eligibility gate. They do not need implementation for HIR v1.

| Syntax | HIR status |
|---|---|
| decorators | Reject; no HIR |
| private fields | Reject; no HIR |
| TypeScript namespaces | Reject; no HIR |
| mapped types | Reject/type-only; no HIR |
| conditional types | Reject/type-only; no HIR |
| JSX / TSX | Reject; no HIR |
| Astro/Vue template syntax | Not part of the TypeScript frontend; a future pre-frontend may emit compatible semantic input |
| pipeline operator `|>` | Reserved future reduction; parser currently rejects it |
| `with` statement | Reject; no HIR |

Unsupported syntax must produce its specific frontend diagnostic and must never become executable HIR through recovery nodes.

---

## 15. Reserved future reductions

These rows document desired canonical outcomes without authorizing frontend implementation.

| Future syntax | Desired HIR reduction | Prerequisite |
|---|---|---|
| simple F# pipeline `value |> fn` | ordered evaluation + ordinary `call fn(value)` | Freeze exact pipeline proposal. |
| placeholder pipeline `value |> fn(%, arg)` | ordered evaluation + call with one inserted pipeline value | Define placeholder multiplicity, scope and errors. |
| JSX element | frontend/pre-layer semantic construction calls, not a JSX HIR node | Define JSX factory/runtime contract outside core HIR. |
| TSX | same as JSX after syntax-specific parsing | Separate compatible frontend required. |
| Vue/Astro component syntax | pre-frontend lowers to shared semantic/module contract before HIR | Separate parser/semantic adapter; ViZG core does not parse it. |
| decorators | explicit decorator evaluation/application operations or pre-lowered calls | Freeze decorator proposal and class initialization order. |
| private fields | dedicated semantic private-name operations | Implement private-name binding and brand semantics first. |

---

## 16. Mandatory HIR canonicalization matrix

| Pattern | Required canonical result | Safety condition |
|---|---|---|
| type-only/source-only node | erased | Semantic/debug data already recorded. |
| copy of a value used only through the copy | replace uses with source | Types and origin merge remain valid. |
| `branch true, A, B` | `jump A` | Condition is a literal semantic boolean, not merely truthy. |
| `branch false, A, B` | `jump B` | Same. |
| jump-only block | redirect predecessors | Block is not a required region boundary, debug anchor or loop/cleanup entry. |
| unreachable block | remove | No metadata/export/region requires it. |
| unused pure instruction | remove | Effect set proves `pure` and not `creates_identity`. |
| merge block with identical incoming temporary value | use common value | Type and dominance/block-parameter rules remain valid. |
| primitive literal operation | folded constant | Exact ECMAScript semantics are implemented, including NaN, -0, bigint and throw behavior. |
| empty `return` | canonical `return` | Function contract permits it. |

Canonicalization must not perform global program optimization.

---

## 17. HIR versus downstream implementation boundary

| Transformation | HIR v1 | Outside ViZG |
|---|---:|---:|
| syntax erasure | Required | No |
| structured control-flow lowering | Required | No |
| ANF temporary naming | Required | No |
| evaluate-place-once expansion | Required | No |
| safe literal folding | Limited/required | Extended |
| trivial CFG cleanup | Limited/required | Extended |
| local unused-pure removal | Limited/required | Extended |
| full SSA / mem2reg | Forbidden | Consumer-defined |
| Value-dominance validation for temporary legality | Required by verifier | Required/retained |
| dominator trees for optimization and code motion | Not part of HIR canonicalization | Yes |
| SCCP | Forbidden | Yes |
| global DCE | Forbidden | Yes |
| CSE / GVN / PRE | Forbidden | Yes |
| LICM / code motion | Forbidden | Yes |
| inlining | Forbidden | Yes |
| devirtualization | Forbidden | Yes |
| union splitting | Forbidden | Yes |
| unboxing | Forbidden | Yes |
| escape analysis | Forbidden | Yes |
| object/class/closure layout | Forbidden | Yes/runtime |
| async/generator state machine | Forbidden | Yes/runtime |
| exception ABI lowering | Forbidden | Yes/runtime |
| memory management / GC / RC | Forbidden | Consumer-defined |
| target-specific lowering | Forbidden | Yes/backend |

---

## 18. Goal coverage map

| Matrix area | Primary goal |
|---|---:|
| Contract and legal surface | 208–210 |
| Eligibility and diagnostics | 211 |
| Project/module/entity shell | 212 |
| Literals, bindings, type erasure | 213 |
| ANF and evaluation order | 214 |
| Places, assignment and update | 215 |
| Operators, logical forms and optional chains | 216 |
| Calls, access, construction and dynamic import | 217 |
| Objects, arrays, spread, templates and regexp | 218 |
| Functions, parameters and closures | 219 |
| `if`, ternary and loops | 220 |
| `switch`, labels, break and continue | 221 |
| exceptions and finally | 222 |
| async, generators and async iteration | 223 |
| classes, enums and module initialization | 224 |
| canonicalization | 225 |
| verifier | 226 |
| provenance and trace | 227 |
| printer and snapshots | 228 |
| project integration and coverage closure | 229 |
| limits, fuzzing and adversarial robustness | 230 |
| final audit and HIR v1 freeze | 231 |
| final-product boundary and independent ownership | 232 |
| immutable consumer contract | 233 |
| stable external declaration identity and semantics | 234 |
| canonical external lowering | 235 |
| official versioned public HIR API and consumer example | 236 |
| final implementation audit and freeze | 237 |

---

## 19. Completion rule

### Goal 229 row closure

Every data row above has explicit closure status. A section range applies to
each row in that range; split rows identify the deliberate exceptions.

| Rows | Status | Implementation and test evidence |
|---|---|---|
| §3 literals and bindings | Implemented | `src/hir/lower_expression.zig`, `lower_body.zig`, `lower_function.zig`, `lower_module.zig`; unit and snapshot tests |
| §4 type/syntax erasure | Deliberately erased | `lower_body.zig` plus provenance erased-syntax events; erasure tests |
| §5 unary/update/sequence | Implemented | `lower_expression.zig`, operator and suspension tests |
| §6 operators except pipeline | Implemented | `lower_expression.zig`; operator, logical, canonicalization, and snapshot tests |
| §6 pipeline operator | Deliberately unsupported | frontend rejection plus eligibility diagnostic `VZG2004`; no HIR operation |
| §7 places/assignment/update | Implemented | `lower_place.zig`, `lower_assignment.zig`; place and assignment tests |
| §8 access/call/construction | Implemented | `lower_expression.zig`; access, call, optional-chain, and snapshot tests |
| §9 aggregates/templates/regexp | Implemented | `lower_expression.zig`; aggregate and snapshot tests |
| §10 function-like forms | Implemented | `lower_function.zig`; function, closure, async/generator, and snapshot tests |
| §11 control flow | Implemented | `lower_body.zig`, `region_validation.zig`; control, exception, and snapshot tests |
| §12 modules | Implemented | `lower_project.zig`, `lower_module.zig`; module and cyclic-project tests |
| §13 classes/enums/init | Implemented | `lower_function.zig`, `lower_body.zig`; class, enum, module-init, and snapshot tests |
| §14 unsupported frontend forms | Deliberately unsupported | frontend diagnostics and `src/hir/eligibility.zig` prevent lowering |
| §15 future syntax | Deliberately unsupported | forms are absent from the accepted AST/HIR operation unions |
| §16 canonicalization | Implemented | `src/hir/canonicalize.zig`; fixed-point and rewrite-budget tests |
| §17 HIR-required concerns | Implemented | schema, lowering, canonicalization, verifier, provenance, and printer tests |
| §17 outside-HIR concerns | Deliberately excluded | absent from `Operation` and guarded by architecture-boundary tests |

Closure is exercised through the family-complete reference snapshots and the
project/session integration tests; a supported row without implementation,
verifier coverage, and a family test remains a Goal 229 failure.

HIR v1 is not complete because examples print correctly. It is complete only when:

```txt
every supported `NodeData` row is covered
all type-only rows are deliberately erased
all unsupported rows are blocked
all legal operations have verifier rules
all effectful evaluation-order cases have tests
all mandatory canonicalization rules converge
all output is deterministic
all configured limits fail safely
Goals 208–237 pass in strict order
```
