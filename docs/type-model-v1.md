# Type Model v1 — Design Document

**Status:** planned, not implemented.
**Purpose:** scaffolding for a future Type Checker v1. Defines the shape of types and their storage in the existing frontend pipeline and module graph without changing either today.

## Summary

This document describes the minimal type model needed to support a future Type Checker v1 on top of `vizg`'s current frontend (scanner → parser → binder → resolver → CFG) and module graph. It does **not** implement the type checker, add any new AST nodes, or change existing phases. All decisions are grounded in the structure already present in `src/frontend/`, `src/modules/graph.zig`, `src/modules/linker.zig`, and `src/diagnostics/root.zig`.

## Non-goals

Do not implement today:

- The type checker itself (no pass, no inference, no checks).
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

Future additions that are **not** in v1: `symbol`, `bigint`, object types, tuple types, array types, intersection, union (other than any/unknown), enums, namespaces, decorators.

### Node Representation

Types will live in their own arena-owned struct hierarchy under a future `src/frontend/types.zig`. They will not be mixed into the existing AST structs. A type is referenced through an opaque handle:

```zig
pub const TypeId = usize; // index into TypeArena
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
    // future: array, object, etc.
};
```

Because this is a plan document and not code to run, the exact field set is open for revision at implementation time; the invariant that matters is: types are arena-allocated and referenced by `TypeId`, never owned inline by AST nodes or symbols as slices/strings.

## 2. Unknown / Any Policy

**Decision:**

- `any` is **allowed** but restricted to explicit user opt-in (`type: any` annotation or `as any`).
- Unresolved or missing-type values are typed as `unknown`, not `any`.

Rationale tied to the current pipeline:

- The binder currently records declaration kinds and duplicate exports; the type model layer will extend this with a *defaulted* per-symbol type slot. When the resolver finishes but no type has been produced, the slot holds `undefined` — i.e., "no type known."
- `unknown` is the explicit encoding of that state: "we have something here but do not know what." This is distinguishable from a real value type and makes it easy to flag as an error or warning in Type Checker v1 (e.g., VZG6003 `implicit_unknown`) without needing a special sentinel.
- `any` requires a *source span* recording the annotation that granted permission to bypass checking; this matches how TypeScript surfaces `any` diagnostics today and gives users useful feedback.

## 3. Null / Undefined Policy

**Decision:**

- `null` and `undefined` are **separate** singleton types (`NULL`, `UNDEFINED`).
- The type checker will not treat them as subtypes of every other type by default. A strict mode flag (off in v1) may enable a nullable-everything rule later; for now, the policy matches current JavaScript semantics and keeps diagnostics simple.
- When the resolver binds an uninitialized `let` declaration, its *inferred* slot is left as "no value known" rather than auto-substituted with `undefined`. This prevents the model from conflating absence of a type (unknown) with an actual runtime undefined value.

## 4. Function Types

**Decision:**

- A function type is a **closed signature**: parameter types, parameter names, return type, and an optional "this" type (unused in v1).
- Signatures are compared by shape for equality: `(number, string) -> boolean`.
- Functions declared at the top level of one module will not get a structural `FunctionType` until Type Checker v1 adds that pass. For now, their type slot is a *placeholder* (`FUNCTION`) pointing to a future `FunctionSignatureId` that will resolve once the checker runs on the target module. This prevents a chicken-and-egg problem at link time (see §6).

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

## 5. How Node Types Will Be Stored

**Decision:**

- A future `src/frontend/type_arena.zig` owns all types and signatures via a bump allocator pattern: allocate once per analyzed file, drop at end of frontend pass.
- AST nodes will **not** carry type information in v1. The current architecture keeps the AST pure (parser output only). Types flow through binder → resolver → *type checker pass* as a separate layer that sits above `FrontendResult`.

Planned evolution path:

```txt
src/frontend/
  types.zig        -- type model (planned)
  type_arena.zig   -- arena for types/signatures (planned)
  frontend.zig     -- analyze returns FrontendResult as today; the checker will be added as a wrapper in modules/, not inside frontend/.
```

The `FrontendResult` struct grows by adding:

```zig
pub const FrontendResult = struct {
    // ... existing fields unchanged ...
    types: ?TypeArena,          // allocated when type check runs
    unresolved_count: usize,    // diagnostics aid
};
```

Existing callers (`vizg check`, `vizg tokens`, etc.) ignore the new field until a CLI command asks for it.

## 6. How Symbol Types Will Be Stored

**Decision:**

- The binder's symbol struct gains an optional type slot:

```zig
pub const Symbol = struct {
    name: []const u8,            // borrowed
    kind: Kind,                  // unchanged from current code
    scope_id: ScopeId,           // unchanged
    declared_type: ?TypeId = null,  // explicit annotation
    inferred_type: ?TypeId = null,  // type checker produced
};
```

- `declared_type` is set during a future *type annotation* pass that follows binder; it mirrors what the parser already captures for annotated declarations.
- `inferred_type` is set by the type checker during its forward/infer step. For top-level values, inference requires the module graph because initializer expressions may reference cross-file bindings — which is exactly why a single-file frontend pass is insufficient and we need Type Checker v1 to sit above the graph layer.

### Where the Slot Lives Today (Plan Only)

This document does **not** add these fields today; it records the design so that when the type checker team implements them, they slot into an existing arena + symbol model without requiring structural surgery on the binder or resolver.

## 7. How Imports Will Use Linked Target Symbols

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

**Decision for Type Checker v1:**

- When the type checker runs on file A and encounters a reference through an imported symbol, it walks `LinkedImport.target_symbol_id` to read the **target's declared_type + inferred_type**.
- For circular or late-resolved references (top-level initializer of a module imports itself transitively), the checker records the dependency edge in a `TypeDependency` list per module and runs a fixpoint iteration. This avoids infinite recursion while keeping type information fresh as symbols get filled in.

Planned data flow:

```txt
linker.Linker.link() produces LinkedImport[]
  -> TypeChecker.run(graph, linked_imports):
      for each module_id in graph.order():
          bind target.symbol to source.local via Link lookup
          infer declared_type from annotation (if any)
          iterate inferred_type until fixpoint or stable
      emit diagnostics with VZG6xxx codes
```

Namespace imports are typed structurally as an object whose keys are the exported symbol names and values are those symbols' types. Default imports resolve to whichever symbol is exported as default. External imports keep their declared external type when a registration was provided (see §8); otherwise they are `unknown`.

## 8. Diagnostic Code Range VZG6xxx

Reserved for the type checker. Starting codes per current design:

| Code | Name | Meaning | Status |
| --- | --- | --- | --- |
| `VZG6001` | `type_mismatch` | Assignment, return, or call argument does not match expected type. | Planned. Not implemented. |
| `VZG6002` | `cannot_assign_const` | Attempt to write a declared-const binding. | Planned; may be removed before implementation in favor of binder-level VZG3001 for redeclaration — decide at v1 design review. |
| `VZG6003` | `implicit_unknown` | Unannotated value used without inference producing a known type. | Planned. Not implemented. |

Full set is **not** frozen here — codes will be extended by the implementation pass with names and messages reflecting actual behavior. Codes 1–5 are *out of range* for this layer; no code in `VZG6xxx` should emit diagnostics that do not reference a type.

## 9. Design Questions Answered

### 1. Is `any` allowed, or should unresolved types become `unknown`?

Both exist. Unresolved → `unknown`. Opt-in `any` only via explicit annotation (`as any`, `: any`). Default-ignoring behavior requires the user to write it; the checker flags `any` at use sites with an optional `allowAny` diagnostic option in future work (not v1).

### 2. Are primitive annotation names like `number` and `string` represented as type nodes or raw identifiers?

Both, depending on phase:

- The **parser** sees the identifier token (`Identifier("number")`).
- The **binder** records it as a declaration only if there is an actual binding for it in scope (which there won't be in v1 — these are reserved words by convention).
- The **type annotation pass** converts recognized keyword-like identifiers into `Type.PrimitiveKind` nodes and leaves unrecognized identifiers to flow through as unresolved references.

The type node itself, once produced, is always a typed `TypeId`, not an identifier string.

### 3. How will `let x = 1` receive type `number`?

During Type Checker v1 forward inference:

```txt
for each top-level binding in declaration order:
    bind "x" in file scope
    visit RHS expression tree
        literal 1 → Type.PrimitiveKind.number (constant folding later if useful)
    assign inferred_type = number to symbol for "x"
    record "x:number" in a per-module type map for use by other modules after linking
```

### 4. How will `function f(x: number)` store parameter type?

The parser already captures the annotation span (or will, once Type Checker v1 adds that grammar). The binder stores the parameter symbol with its declared name; the type pass records `(parameter_name → type_id)` in a per-function signature entry and sets the function's own return type. No mutation of `src/binder/binder.zig` is required beyond adding an optional `TypeId?` slot that existing tests ignore.

### 5. How will cross-file imported functions/values expose type later?

Walk the linker link from file A to module B, read symbol B's inferred or declared type, and thread it back into A's reference resolution. If a cycle is detected at this stage, break with `unknown` for one side only, then fixpoint. Namespace imports expose their exports as an object type whose property types are the corresponding symbol types. Default imports resolve to whichever symbol is exported as default.

### 6. What diagnostics are reserved for Type Checker v1?

VZG6xxx range exclusively: type-mismatch errors (VZG6001), implicit-unknown warnings/errors (VZG6003). VZG5002 covers missing exports today; if the type checker ever wants to *re-report* an export as "not a valid import target" that will require a discussion but is unlikely in v1 — keep it as a structural check, not a type check.

## 10. Integration Points With Existing Code (Plan Only)

No changes are required to existing code by this document. The following integration points are anticipated for Type Checker v1 implementation:

| Layer | File | Change at v1 time |
| --- | --- | --- |
| Frontend AST | `src/frontend/ast.zig` | None in v1; keep type fields off AST nodes. |
| Frontend pipeline | `src/frontend/frontend.zig` | Optional field addition (`types: ?TypeArena`) — additive, backward compatible with all current CLI commands. |
| Binder | `src/frontend/binder.zig` | Optional `declared_type: ?TypeId` slot on Symbol; defaults to `null`. |
| Resolver | `src/frontend/resolver.zig` | None in v1 — resolver stays identifier-only. The type checker will read symbol types directly, bypassing the resolver for lookup purposes. |
| Module graph | `src/modules/graph.zig` | Graph returns a topological order of modules to the type checker so cyclic files get fixpoint treatment instead of infinite recursion. |
| Linker | `src/modules/linker.zig` | No structural change — linker already produces target_symbol_id needed for cross-file type lookup. |
| Diagnostics | `src/diagnostics/root.zig` | Add `VZG6001` (and later VZG6003, …) to the enum with phase = `.type_checker`. |

## 11. Testing Plan For Type Checker v1 Implementation (Not Part of This Goal)

When Type Checker v1 is actually implemented it should be tested against:

- `test/type_model/primitives.ts` — literal types match expected primitives.
- `test/type_model/function_signature.ts` — parameter and return types captured correctly.
- `test/type_model/cross_file_linking.ts` — imported symbols carry target types through linker links.
- `test/type_model/unknown_vs_any.ts` — explicit `any` vs implicit `unknown`.
- `test/type_model/null_undefined.ts` — null and undefined typed as separate singletons.
- `test/type_model/cycle_handling.ts` — circular imports get fixpoint resolution, not infinite recursion.

These tests are **not** added in this goal — they belong to Type Checker v1 implementation. This document only records what they should cover so the design does not drift at implementation time.

## 12. Open Questions for Review Before Implementation

These questions must be answered by whoever implements Type Checker v1; none block this document from being published:

1. Should `unknown` become an error at use sites (strict mode on), or remain silent? (Recommended: warning off, error on.)
2. Should the type model support a future `type_aliases` form with lazy expansion, or always eagerly resolve to underlying types in v1? (Recommended: eager resolution; aliases are deferred to a later milestone.)
3. How will generics be handled if at all in v1? (Recommended: out of scope for v1 — no generic parameters or inference.)

## Final Result

- One new document created: `docs/type-model-v1.md` (this file).
- No code changes, no test changes, no CLI changes.
- All six design questions answered with a rationale tied to the existing frontend and module graph.
- VZG6xxx diagnostic range reserved; three initial codes proposed but not yet registered in `src/diagnostics/root.zig`.
