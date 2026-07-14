# Type Model v1 — Design Document

**Status:** Implemented at `src/types/` and `src/semantics/`. Primitive, aggregate, access, function, call, control-flow, checker, and project propagation passes run in owned semantic-result pipelines. Broader TypeScript checker behavior remains planned.

## Summary

This document describes the minimal type model used by typed semantics on top of `vizg`'s frontend (scanner → parser → binder → resolver → CFG). The model, semantic mappings, and initial inference/checking passes are implemented. Full TypeScript compatibility is not.

## Non-goals

Do not implement today:

- Complete TypeScript checker behavior beyond the implemented semantic checks.
- Any parser support for type annotations beyond what the current grammar already accepts.
- A full TypeScript or JavaScript runtime semantics model.
- HIR, LLVM, native compilation, bytecodes, VMs, interpreters, or bundlers.
- Package resolution, `node_modules`, `package.json` exports, or tsconfig paths.
- Class member semantics beyond current parser support.
- Hoisting, TDZ, or other runtime-order diagnostics beyond what the resolver already produces.

Nothing in this section is a commitment to future implementation; these are explicitly out of scope for Type Model v1 and likely for several milestones after.

## 1. Primitive Value Types

The initial type universe starts as a small closed set:

| Tag | Name | Notes |
| --- | --- | ----- |
| `NUMBER` | number | Integer, float, NaN, Infinity — no numeric subkinds in v1. |
| `STRING` | string | UTF-16 code units for simplicity; do not model Unicode grapheme clusters yet. |
| `BOOLEAN` | boolean | True or false only. |
| `VOID` | void | Function return type when no value is produced. |
| `NULL` | null | Singleton. |
| `UNDEFINED` | undefined | Singleton (not the JS global). |
| `UNKNOWN` | unknown | Top type for unresolved / untyped values. |
| `ANY` | any | Opt-in escape hatch, see §2 policy. |
| `FUNCTION` | function | Immutable structural signatures owned by `TypeStore`. |

The implemented model also includes `symbol`, `bigint`, objects, tuples, arrays, unions, intersections, callable types, nominal declarations, and type parameters. Decorator and namespace syntax remains outside the supported frontend subset.

Class, interface, and enum declarations use `SemanticDeclId`, the pair
`(module_id, declaration_id)`. A raw AST `NodeId` is only local to one module and
is never a semantic declaration key. TypeStore maps, cloning, compatibility,
debug output, and project import/export links preserve this qualified identity.

A class declaration creates two distinct types: its constructor value and its
instance. The constructor points to the instance, while the authoritative class
record keeps separate static and instance member tables, an optional constructor
signature, and `extends`/`implements` links. Interfaces are first-class structural
types with their own member table and inheritance links. Member visibility is the
four-state `none`, `public`, `protected`, or `private` enum; it is never reduced to
a boolean.

The declaration collector populates those tables directly from class and
interface syntax. Annotated fields retain their declared type; initializer-only
fields use an explicit `unknown` inference placeholder until expression inference
connects them. Methods and constructors use canonical function types owned by the
same `TypeStore`, constructor parameter properties become instance members, and
static members remain constructor-side only. Optional, `readonly`, visibility,
and heritage metadata survive collection. Instance access searches a class's
instance table before its single base class; constructor-value access searches
the static table in the same order. Interface access searches the local table,
then bases in source order. The nearest declaration wins. Explicit constructor
signatures validate `new` arguments and return the class instance type; a class
without a constructor accepts only zero arguments. Inheritance compatibility,
overrides, and visibility enforcement remain later semantic passes.

### Type annotation lowering

`type_collector` exhaustively lowers every supported `TypeNodeData` variant.
Literal annotations retain their string, number, bigint, or boolean value;
`null` uses the canonical builtin. Arrays, tuples, unions, intersections,
objects, functions, `readonly`, and parenthesized annotations preserve their
existing structural representation.

Indexed access currently accepts a string-literal key on a structural object or
local interface, for example `User["name"]`. `keyof` supports the same
object-like inputs and produces a union of literal property names. A type query
is limited to a simple value identifier with an explicit annotation, for
example `const value: string = "x"; type Value = typeof value;`.

Named generic references use the scope-aware type namespace and validate type
argument arity across local and imported declarations. An applied generic owns
the declaration identity and canonical argument list, so equal applications
reuse one `TypeId` while distinct arguments remain distinct. Defaults fill
omitted trailing arguments and constraints are checked before instantiation.
Substitution covers function parameters/returns, arrays, tuples, objects,
unions, intersections, interface/class members, and nested applications; a
recursion guard terminates self-referential aliases. Call-site generic inference
remains outside v1. Unsupported operations emit a targeted `VZG6005` diagnostic
and recover as `unknown`; no supported type-node variant reaches an implicit
fallback.

### Node Representation

The type model is now implemented at `src/types/model.zig` with builtin kinds exported via `src/types/builtin.zig`, and semantic mappings of symbols/nodes to types in `src/semantics/type_info.zig`. Types will not be mixed into the existing AST structs. A type is referenced through an opaque handle:

```zig
pub const TypeId = u32; // context-local index into TypeStore
```

A `TypeId` is meaningful only within its owning `SemanticResult` or project
semantic context. Numeric IDs from different contexts must never be compared or
combined.

Within one context, nominal declarations are keyed only by their module-qualified
declaration identity and reserve one stable `TypeId`. Class and interface member
tables complete exactly once without participating in that interning key. Object
types use an order-insensitive property-set key: equivalent unique-name properties
reuse one ID regardless of source order, while the first interned representation
retains its original order for deterministic display.

An initial concrete shape (pseudocode):

```zig
const PrimitiveKind = enum { number, string, boolean, null, undefined, void };

pub const Type = struct {
    kind: Kind,
};

pub const Kind = union(enum) {
    primitive: PrimitiveKind,
    function: FunctionType,
    // aggregate, callable, nominal, union, intersection, etc.
};
```

Because this is a plan document and not code to run, the exact field set is open for revision at implementation time; the invariant that matters is: types are arena-allocated and referenced by `TypeId`, never owned inline by AST nodes or symbols as slices/strings.

## 2. Unknown / Any Policy

**Decision:**

- `any` is **allowed** but restricted to explicit user opt-in (`type: any` annotation or `as any`).
- Unresolved or missing-type values are typed as `unknown`, not `any`.

Rationale tied to the current pipeline:

- The binder records declaration kinds and duplicate exports. Semantic `SymbolTypeInfo`, not binder symbols, holds declared/inferred types and resolution state.
- `unknown` encodes "a value exists but its type is not known." This stays distinct from `undefined`, which is an actual value type, and from the recovered error sentinel used to suppress cascades.
- `any` requires a *source span* recording the annotation that granted permission to bypass checking; this matches how TypeScript surfaces `any` diagnostics today and gives users useful feedback.

## 3. Null / Undefined Policy

**Decision:**

- `null` and `undefined` are **separate** singleton types (`NULL`, `UNDEFINED`).
- The type checker will not treat them as subtypes of every other type by default. A strict mode flag (off in v1) may enable a nullable-everything rule later; for now, the policy matches current JavaScript semantics and keeps diagnostics simple.
- When the resolver binds an uninitialized `let` declaration, its *inferred* slot is left as "no value known" rather than auto-substituted with `undefined`. This prevents the model from conflating absence of a type (unknown) with an actual runtime undefined value.

## 4. Function Types

**Decision:**

- A function type is a **closed signature**: parameter names and types, optional/default/rest metadata, return type, type-parameter count, and async/generator/constructor flags.
- Signatures are compared by shape for equality: `(number, string) -> boolean`.
- Declarations, expressions, arrows, object methods/accessors, and class methods/constructors/accessors enter one function-like descriptor and use the same interned signature representation. Annotated returns win; otherwise return statements are unioned deterministically, expression-bodied arrows contribute an implicit return, and a CFG-reachable fallthrough adds `undefined` when a body has explicit value returns. A body with no value-producing return remains `void`.
- Class receiver context types `this` and `super`. Constructors cannot declare or return a value; getters take no parameters; setters take exactly one required non-rest parameter and cannot declare or return a value. Async and generator flags remain part of the shared signature pipeline and wrap return categories deterministically.
- Calls validate count and argument compatibility through the shared compatibility layer. Callable unions distribute the call across every non-nullish member; each remaining member must be callable and accept the arguments. An optional call removes `null`/`undefined` branches for validation and always adds `undefined` to the union of callable return types. Method calls retain receiver metadata. Class construction validates the canonical explicit constructor signature and returns the instance type; a missing constructor means an implicit zero-argument constructor.
- Async returns are wrapped as `Promise<T>`. Generators use `Generator<unknown, T>`: yield-value inference and `next` input typing are deferred. In the minimal v1 model an async generator is categorized as `Generator<unknown, Promise<T>>`; a distinct `AsyncGenerator` model is deferred.
- Recursive functions use their stable declaration signature. Overload sets and overload resolution are intentionally deferred; duplicate same-scope declarations retain the binder diagnostic.

Compound assignments infer the read-modify-write result first, then require that result to be assignable back to the target. This applies equally when the right operand is a function call.

Pseudocode signature shape:

```zig
pub const Parameter = struct {
    name: SymbolName, // borrowed from binder symbol
    type_id: TypeId,
};

pub const FunctionSignature = struct {
    parameters: []const Parameter,  // arena-owned slice
    return_type: TypeId,
};
```

Closure expressions in source will be typed as an anonymous function signature whose parameter list is inferred from use sites or defaulted to `(unknown) -> unknown`.

### Control-flow narrowing v1

The semantic pipeline consumes the frontend CFG for each function and records
flow-sensitive reference types separately from canonical symbol and expression
types. A reusable forward dataflow solver computes immutable block entry and
exit fact sets with deterministic predecessor joins and a worklist fixed point.
Language-specific guards remain edge-transfer policy outside the generic CFG
engine.

Each `FlowTypeInfo` entry is keyed by function node, CFG block, program point,
symbol, and reference node. Callers can query a particular reference or point
without mutating the AST or the symbol's declared type, including two uses of
the same symbol separated by an assignment in one basic block.

The first narrowing contract supports literal-aware truthy/falsy tests,
null/undefined equality, primitive `typeof` comparisons (`string`, `number`,
`boolean`, `bigint`, `symbol`, and `undefined`), constructor-to-instance
`instanceof`, and property-presence checks with `in` over supported object,
interface, and class-instance shapes. Literal `false`, numeric and bigint zero,
the empty string, `null`, and `undefined` stay in the falsy branch; broad
primitive types remain conservative in both branches. Facts join conservatively
at branches and loops. Assignment replaces the target
fact with the assigned type when known; update discards it, and calls through
`any` or `unknown` discard all current facts.
Expression-level control flow uses the same fact lattice: ternary branches,
`&&`, `||`, `??`, logical assignments, and optional-chain execution/skip paths
join their outgoing states before the next reference. Side effects from a
short-circuited operand or skipped optional-chain index/argument therefore do
not leak into paths where that operand was not evaluated.
Early exits preserve the surviving branch for following statements, and
expression-bodied arrows receive a normalized non-empty CFG body.

The generic engine exposes block and edge transfer hooks for assignments,
calls, returns, throws, and structured control-flow edges. The TypeScript
narrowing policy deliberately omits discriminated-union analysis, exception-edge
facts, alias tracking, and interprocedural side-effect modeling.

### Structural compatibility v1

`src/semantics/type_compat.zig` owns the single source-to-target compatibility
relation used by semantic consumers. It supports primitives, literals,
deterministic source and target unions, arrays, tuples, objects, and functions.
Recursive structural pairs terminate through coinductive active-pair guards and
successful-pair memoization. Incompatibilities report a stable first path through
union members, tuple elements, properties, parameters, and return types.

Readonly arrays, tuples, and properties cannot flow into mutable targets.
Optional source members cannot satisfy required target members. Array elements
and function returns are covariant; strict v1 function parameters are
contravariant. `any` accepts and supplies all types, `unknown` accepts all source
types but only supplies `unknown` or `any`, `never` supplies every target, and
the recovered error sentinel is treated as compatible to prevent cascades.

Interfaces are structural targets: anonymous objects, interfaces, and class
instances may satisfy their direct and inherited members. Anonymous object
targets likewise accept matching interface and class-instance sources. Missing
or incompatible inherited members retain the full property path for checker
diagnostics. Class, constructor, enum, and type-parameter identities remain
nominal under the v1 policy.

Source intersections expose the combined member surface of every constituent
when checked against structural object and interface targets. Detailed aggregate
diagnostics use the same compatibility engine as their enclosing assignment, so
compatible literal and structural property types are not reported as mismatches.

## 5. How Node Types Are Stored

AST nodes remain pure parser output. `src/semantics/type_info.zig` defines value-based `NodeTypeInfo`, `SymbolTypeInfo`, and `FlowTypeInfo` mappings owned directly by `SemanticResult`. No public parallel builder owns semantic mappings. The semantic checker consumes these mappings after inference and does not reparse or duplicate type inference.

Expression facts keep three roles separate. `NodeTypeInfo.type_id` is the
source-inferred type, `contextual_type` is an optional expected type from an
annotation, and `effective()` returns the inferred type only after successful
resolution. Aggregate context guides array/tuple elements and object-property
values but never replaces their source facts. The checker compares inferred
facts with contextual targets after inference, allowing precise element and
property diagnostics while fixed-point change tracking converges on stable
fact pairs.

For named annotations, the declaration collector seeds the initializer's
contextual type before aggregate inference. This preserves imported, aliased,
and inherited semantic identity while the initializer keeps its independently
inferred source type.

Every executable expression accepted by the parser receives `NodeTypeInfo`.
Primitive, aggregate, access, call, function, control-flow, and class-context
expressions use their semantic type. RegExp and `import.meta` use the builtin
object type; dynamic import uses `Promise<unknown>`; `yield` uses its value or
`undefined`; tagged templates use the tag's return type. Class expressions have
separate canonical constructor and instance identities. Instance `this` uses the
enclosing class instance and `super` uses its base instance. If an accepted
expression has no implemented semantic rule, the pipeline records a resolved
`unknown` recovery type and emits one targeted warning instead of omitting the
node mapping.

Callable return inference consumes only return statements in reachable CFG
blocks. A reachable function exit contributes `undefined`; unreachable returns
do not affect the union. A non-completing `finally` return or throw overrides
the return results collected from its associated `try` and `catch` paths.

Adversarial type construction has explicit `TypeStore` ceilings: normalized
unions and intersections contain at most 1024 members, generic declarations and
applications contain at most 256 parameters or arguments, and recursive generic
substitution is limited to 256 levels. Crossing a ceiling returns the controlled
`error.TypeComplexityLimit`; recursive stored shapes also retain active-type
cycle detection. Callers must propagate this error rather than recover as a
silent `unknown`.

A single-file `SemanticResult` owns one arena, one `FrontendResult`, one canonical `TypeStore`, and its mappings. A `ProjectSemanticResult` owns its `ModuleGraph`, one project semantic arena, one canonical store shared by every module, and every cross-module semantic record. All stored slices remain valid until the owning result is deinitialized.

## 6. How Symbol Types Are Stored

Binder symbols remain syntax/scope records and do not contain context-dependent `TypeId` values. `SymbolTypeInfo` is keyed by binder `SymbolId` and records declared type, inferred type, and resolution state. Every binder symbol kind has an entry: variables, functions, parameters, imports, aliases, interfaces, classes, enums, enum members, type parameters, fields, and methods. Deferred inference is represented explicitly as `unknown`; no symbol kind is silently excluded. This avoids coupling the frontend to semantics and prevents a symbol from retaining an ID from a destroyed or different type context.

`TypeResolutionContext` resolves annotations through binder scopes in the type namespace. Builtins come from the canonical `TypeStore`; local aliases, interfaces, classes, and enums resolve through binder `SymbolId` and module-qualified semantic declaration identity. Generic declarations predeclare a lexical type-parameter environment, and each parameter has a stable owner declaration plus binder-symbol identity. Generic references therefore resolve before module/global names and use one `TypeId` consistently across parameters and returns. Value-only names are rejected as types, lexical declarations shadow outer declarations, and unresolved names remain structured results that emit one deterministic `VZG6004` diagnostic at the annotation span.

Cross-module identity is represented by `SemanticIdentity`, qualified by `ModuleId`, optional `SymbolId`, declaration `NodeId`, namespace, and `TypeId`. A project uses one shared store, so propagated IDs are canonical within that result. Repeated builds create new contexts; IDs from separate results are never comparable.

## 7. How Imports Use Linked Target Symbols

The linker in `src/modules/linker.zig` already produces cross-file links with a target module/symbol reference:

```txt
LinkedImport {
    local_name: Identifier,   // in source file A
    imported_name: ?Identifier,
    kind: .named | .default | .namespace | .external | .unresolved,
    target_module: ?ModuleId,
    target_symbol_id: ?SymbolId,
}
```

Implemented data flow:

```txt
ModuleGraph owns FrontendResult[] and LinkedImport[]
  -> analyzeModuleGraph consumes those snapshots without reparsing
  -> collect direct export identities in one shared TypeStore
  -> propagate named/default/namespace/type-only imports and re-exports
  -> iterate to a bounded fixed point for cycles
  -> run the checker over propagated TypeInfo
  -> return one owned, partially inspectable ProjectSemanticResult
```

Aliases and re-exports preserve the target's qualified declaration identity. Named and aliased imports used in annotations reuse the exported target `TypeId`; declaration-level type-only imports do not create runtime bindings. Default imports resolve the default export. External, missing, and incomplete cyclic imports receive stable `unknown` placeholders, so collection terminates while known declarations remain available and the project is marked partial.

Namespace-import policy for v1 is intentionally narrow: runtime namespace objects contain value exports only. A type-only namespace import has no runtime binding, and qualified namespace type-member lookup is deferred; v1 does not merge value and type namespaces.

During project fixed-point propagation, namespace object shapes are rebuilt from
the current export identities before dependent import, reference, expression,
and export facts are refreshed. No module retains a `TypeId` from an earlier
semantic context or a stale pre-propagation namespace shape.

### Supported semantic type operators

The v1 operator subset reads only canonical `TypeStore` shapes and linked
symbol identities:

- `T[K]` supports string properties on objects, interfaces, class instances,
  inherited shapes, and generic applications. Numeric indexing supports arrays
  and tuples. Optional properties/elements add `undefined`; readonly metadata
  remains on the canonical member even though value lookup does not remove it.
- `keyof T` reads canonical member tables. For unions it returns keys present
  on every branch; for intersections it returns the union of branch keys.
  Imported and inherited members follow semantic identities without reopening
  another module's AST.
- `typeof name` supports a resolved value identifier. It uses that symbol's
  effective `SymbolTypeInfo`, including inferred and imported value types.
  `typeof import()` and compound query expressions remain unsupported.

Unsupported keys, indexes, non-object `keyof` operands, and unresolved query
targets emit targeted diagnostics and recover as `unknown`; an empty valid key
set is `never`.

## 8. Diagnostic Code Range VZG6xxx

Reserved for the type checker. Starting codes per current design:

| Code | Name | Meaning | Status |
| --- | --- | --- | --- |
| `VZG6004` | `unknown_type_name` | A type annotation names a type that cannot be resolved. | Implemented. |
| `VZG6005` | `type_mismatch` | Initialization, assignment, compound-assignment result, return/fallthrough, operator, `satisfies`, call target, or constructor target types are incompatible. | Implemented. |
| `VZG6002` | `cannot_assign_const` | Attempt to write a declared-const binding. | Planned; may be removed before implementation in favor of binder-level VZG3001 for redeclaration — decide at v1 design review. |
| `VZG6003` | `implicit_unknown` | Unannotated value used without inference producing a known type. | Planned. Not implemented. |
| `VZG6006` | `unknown_property` | Property lookup failed on the receiver type. | Implemented. |
| `VZG6007` | `invalid_index` | Indexed access used an unsupported key or index. | Implemented. |
| `VZG6008` | `invalid_argument_count` | Call argument count does not match the signature. | Implemented. |
| `VZG6009` | `invalid_argument_type` | Call argument is incompatible with its parameter. | Implemented. |

The set is extensible, but assigned codes and names are stable. No code in
`VZG6xxx` should emit diagnostics that do not reference a type.

Checker v2 runs over the canonical semantic result data rather than reparsing
or maintaining its own inference map. All assignment-like checks use the shared
structural compatibility engine. Inference records issue metadata for operators,
accesses, calls, and `satisfies`; the checker turns it into source-ordered
diagnostics with primary and related spans. Unresolved, unknown, and recovered
error types suppress cascades.

## 9. Design Questions Answered

### 1. Is `any` allowed, or should unresolved types become `unknown`?

Both exist. Unresolved → `unknown`. Opt-in `any` only via explicit annotation (`as any`, `: any`). Default-ignoring behavior requires the user to write it; the checker flags `any` at use sites with an optional `allowAny` diagnostic option in future work (not v1).

### 2. Are primitive annotation names like `number` and `string` represented as type nodes or raw identifiers?

Both, depending on phase:

- The **parser** sees the identifier token (`Identifier("number")`).
- The **binder** records it as a declaration only if there is an actual binding for it in scope (which there won't be in v1 — these are reserved words by convention).
- The **type annotation pass** converts recognized keyword-like identifiers into `Type.PrimitiveKind` nodes and leaves unrecognized identifiers to flow through as unresolved references.

The type node itself, once produced, is always a typed `TypeId`, not an identifier string.

### 3. How does `let x = 1` receive type `number`?

During semantic inference:

```txt
for each top-level binding in declaration order:
    bind "x" in file scope
    visit RHS expression tree
        literal 1 → Type.PrimitiveKind.number (constant folding later if useful)
    assign inferred_type = number to symbol for "x"
    record "x:number" in a per-module type map for use by other modules after linking
```

### 4. How does `function f(x: number)` store parameter type?

The parser captures the annotation syntax and the binder creates the parameter symbol. Semantics resolves the annotation, records the parameter's `SymbolTypeInfo`, and installs the owned parameter and return records in the canonical function signature. Binder symbols do not store `TypeId` values.

### 5. How do cross-file imported functions/values expose types?

Project semantics walks the linker identity from file A to module B, propagates B's canonical type and qualified identity into A's import symbol, then refreshes dependent inference to a bounded fixed point. Namespace imports expose runtime exports as an object type. Default, named, type-only, and re-export forms preserve their target identity. Missing, external, and incomplete cyclic links stay inspectable with `unknown`.

### 6. What diagnostics are reserved for Type Checker v1?

VZG6xxx is reserved for type diagnostics. Current implemented codes are
VZG6004–VZG6009; VZG6002 and VZG6003 remain reserved. VZG5002 continues to own
missing exports as a structural module-graph check.

## 10. Current Integration Points

| Layer | File | Contract |
| --- | --- | --- |
| Frontend AST | `src/frontend/ast.zig` | Keeps type data off syntax nodes. |
| Frontend pipeline | `src/frontend/frontend.zig` | Produces the syntax/binding snapshot consumed exactly once by semantics. |
| Binder/resolver | `src/frontend/binder.zig`, `src/frontend/resolver.zig` | Supply stable symbol/reference identity; never retain semantic `TypeId` values. |
| Module graph/linker | `src/modules/graph.zig`, `src/modules/linker.zig` | Own module snapshots, edges, and cross-file target IDs consumed by project semantics. |
| Type store | `src/types/type_store.zig` | Owns canonical, context-local types and signatures. |
| Semantic pipeline | `src/semantics/root.zig` | Owns single-file/project results, mappings, propagation, checking, and teardown. |
| Diagnostics | `src/diagnostics/root.zig` | Owns stable VZG6xxx codes, related spans, and `.type_checker` phase mappings. |

## 11. Required Test Contract

Tests cover primitives, generic parameter/return identity, canonical generic applications, defaults, constraints, recursive substitution, functions, aggregates, access, calls, flow narrowing, compatibility, checker diagnostics, imported and re-exported aliases and generics, namespaces, default and star/named re-exports, type-only imports without runtime bindings, missing exports, cyclic type placeholders, repeated rebuild/teardown, and equal local declaration IDs in distinct modules. Project tests assert qualified identity and `TypeId` equality only within one owning result.

## 12. Remaining Limits

Complete TypeScript compatibility, package resolution, generic inference, overload resolution, decorator-aware class semantics, and advanced type forms remain outside v1. HIR is not implemented and must consume these semantic contracts rather than duplicate parsing, binding, inference, or type storage.

## Final Result

- Type model implemented at `src/types/`: canonical builtins, structural/nominal types, `TypeId`, and signatures.
- Semantic mapping and Checker v2 implemented at `src/semantics/`.
- Project propagation implemented over the existing module graph with one canonical project type context.
- VZG6xxx diagnostics are registered and emitted for the supported checker contract.
- HIR and complete TypeScript checking remain unimplemented.
