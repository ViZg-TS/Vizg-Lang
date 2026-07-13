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
| `FUNCTION` | function | Closed set of named signature slots, see §3. |

The implemented model also includes `symbol`, `bigint`, objects, tuples, arrays, unions, intersections, callable types, nominal declarations, and type parameters. Decorator and namespace syntax remains outside the supported frontend subset.

### Node Representation

The type model is now implemented at `src/types/model.zig` with builtin kinds exported via `src/types/builtin.zig`, and semantic mappings of symbols/nodes to types in `src/semantics/type_info.zig`. Types will not be mixed into the existing AST structs. A type is referenced through an opaque handle:

```zig
pub const TypeId = u32; // context-local index into TypeStore
```

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
- Declarations, expressions, arrows, and object methods use the same interned signature representation. Annotated returns win; otherwise return statements are unioned deterministically, expression-bodied arrows contribute an implicit return, and no-value bodies return `void`.
- Calls validate count and argument compatibility through the shared compatibility layer. Method calls retain receiver metadata. The minimal constructor policy supports implicit zero-argument class construction; constructor-signature selection remains future work.
- Async returns are wrapped as `Promise<T>`. Generators use `Generator<unknown, T>`: yield-value inference and `next` input typing are deferred.
- Recursive functions use their stable declaration signature. Overload sets and overload resolution are intentionally deferred; duplicate same-scope declarations retain the binder diagnostic.

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
types. Each `FlowTypeInfo` entry is keyed by function node, CFG block, symbol,
and reference node, so callers can query a stable fact without mutating the AST
or the symbol's declared type.

The first narrowing contract supports truthy/falsy tests, `typeof` comparisons,
null/undefined equality, `instanceof`, and property-presence checks with `in`.
Facts join conservatively at branches and loops. Assignment and update discard
the target fact; calls through `any` or `unknown` discard all current facts.
Early exits preserve the surviving branch for following statements, and
expression-bodied arrows receive a normalized non-empty CFG body.

This pass deliberately omits complete reachability, discriminated-union
analysis, exception-edge facts, alias tracking, and interprocedural side-effect
modeling.

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

## 5. How Node Types Are Stored

AST nodes remain pure parser output. `src/semantics/type_info.zig` owns value-based `NodeTypeInfo`, `SymbolTypeInfo`, and `FlowTypeInfo` mappings. The semantic checker consumes these mappings after inference and does not reparse or duplicate type inference.

A single-file `SemanticResult` owns one arena, one `FrontendResult`, one canonical `TypeStore`, and its mappings. A `ProjectSemanticResult` owns its `ModuleGraph`, one project semantic arena, one canonical store shared by every module, and every cross-module semantic record. All stored slices remain valid until the owning result is deinitialized.

## 6. How Symbol Types Are Stored

Binder symbols remain syntax/scope records and do not contain context-dependent `TypeId` values. `SymbolTypeInfo` is keyed by binder `SymbolId` and records declared type, inferred type, and resolution state. This avoids coupling the frontend to semantics and prevents a symbol from retaining an ID from a destroyed or different type context.

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

Aliases and re-exports preserve the target's qualified declaration identity. Namespace imports are structural objects whose keys are runtime exports. Default imports resolve the default export. Type-only imports propagate type-space identity without a runtime binding. External and missing imports remain stable `unknown`/unresolved records. Cycles terminate with known declarations preserved and incomplete links marked cyclic-partial.

## 8. Diagnostic Code Range VZG6xxx

Reserved for the type checker. Starting codes per current design:

| Code | Name | Meaning | Status |
| --- | --- | --- | --- |
| `VZG6004` | `unknown_type_name` | A type annotation names a type that cannot be resolved. | Implemented. |
| `VZG6005` | `type_mismatch` | Initialization, assignment, return, operator, or `satisfies` types are incompatible. | Implemented. |
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

Tests cover primitives, functions, aggregates, access, calls, flow narrowing, compatibility, checker diagnostics, imported aliases, namespaces, default and star/named re-exports, type-only imports, missing exports, cyclic graphs, and repeated rebuild/teardown. Project tests assert qualified identity and `TypeId` equality only within one owning result.

## 12. Remaining Limits

Complete TypeScript compatibility, package resolution, generic inference, overload resolution, richer class member semantics, and advanced type forms remain outside v1. HIR is not implemented and must consume these semantic contracts rather than duplicate parsing, binding, inference, or type storage.

## Final Result

- Type model implemented at `src/types/`: canonical builtins, structural/nominal types, `TypeId`, and signatures.
- Semantic mapping and Checker v2 implemented at `src/semantics/`.
- Project propagation implemented over the existing module graph with one canonical project type context.
- VZG6xxx diagnostics are registered and emitted for the supported checker contract.
- HIR and complete TypeScript checking remain unimplemented.
