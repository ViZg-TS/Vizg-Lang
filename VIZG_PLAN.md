# VIZG Development Plan (Phase 2+)

*Created: 2026-07-10 — Informed by V8 engine architecture, JavaScriptCore Inspector protocol, TypeScript compiler design.*

> **Mixed historical and active plan.** Goals through 207 are retained as closed
> design and audit context. Goal 207 froze the portable project API and official
> ABI v1. Goals 208–237 close the canonical HIR v1 final product. See
> `docs/FINAL_AUDIT.md`, `docs/HIR_V1_AUDIT.md`, `docs/hir-v1-design.md`, and
> `docs/hir-v1-lowering-matrix.md`.

## Architecture Reference

### V8 Engine Pipeline (Reference)

V8's compilation phases map cleanly to vizg's planned layers:

| V8 Phase | Purpose | Vizg Equivalent | Status |
|----------|---------|-----------------|--------|
| `Lexer` | Tokenize source text | `src/frontend/scanner.zig` | ✅ Implemented |
| `Parser` | Produce AST with spans | `src/frontend/parser.zig` | ✅ Implemented |
| `ScopeAnalyzer::Analyze()` | Determine bindings, hoisting, strict mode | `src/frontend/binder.zig` | ✅ Partially implemented (parameter scoping done; function-declaration hoisting and strict-mode resolution pending) |
| `TypeSpecialization` | Forward-infer types on AST → typed AST, then fixpoint iterate to stabilize circular references | Canonical pipeline in `src/semantics/type_collector.zig`, `type_inference.zig`, `dataflow.zig`, `narrowing.zig`, and `checker.zig` | ✅ Implemented for the supported syntax subset, including bounded project propagation |
| `BytecodeGenerator` (Ignition) | Reference for lowering typed syntax into normalized control flow | `src/hir/` | ✅ Implemented as target-independent HIR |
| `MacroAssembler` / TurboFan | Reference only for concerns below HIR | Outside ViZG | Not a ViZG roadmap layer |

**Key V8 insight:** Scope analysis *precedes* type specialization. Vizg follows that ordering: binding and module linking establish identities before annotation lowering, inference, dataflow narrowing, and checking.

### JavaScriptCore Inspector Protocol (Reference)

JSC uses an Inspector protocol for external tooling, analogous to V8's CDP:
- JSON-RPC style requests with `id`, `method`, `params` fields
- Response mirrors request `id`; errors use negative integer codes (`-32600..-32099`)
- Multiple "domains" handle different concerns (Runtime, Debugger, Network)
- Transport: WebSocket (browser), stdio (CLI tooling — like `rust-analyzer`, `clangd`)

Vizg maps this to its existing analysis layers since vizg is **analysis-only** (no execution):
| CDP Domain | Vizg Equivalent | Source of Truth |
|-----------|-----------------|-----------------|
| `Runtime` | `Analyze` domain | frontend pipeline output |
| `Debugger` | `ScopeInfo` domain | binder scopes + symbol table |
| `Network` | `Modules` domain | module graph + linker |
| `Types` | `TypeCheck` domain | semantics checker + type_info |

## Current Project State (as of 2026-07-10)

### Codebase Size
- ~11,250 lines Zig total across 40 source files
- 6 frontend pipeline stages implemented (scanner → CFG builder)
- Types model with context-local `TypeId` handles, module-qualified `SemanticDeclId` nominal identities, and one canonical `TypeStore` owning primitives, structural types, nominal types, and function signatures
- Semantics layer: canonical expression inference and checker passes with separate inferred, contextual, and effective node-type facts; aggregate context guides children without replacing source inference

### Key Files & Their Current State

| File | Lines | What It Does | Completeness |
|------|-------|-------------|--------------|
| `src/frontend/scanner.zig` | Scanner | Tokenizer with spans and diagnostics | ✅ Complete |
| `src/frontend/parser.zig` | Parser | Recursive descent parser | ✅ Complete (subset) |
| `src/frontend/binder.zig` | Binder | Scopes, symbols, imports/exports | ✅ Partial (hoisting + strict mode pending) |
| `src/frontend/resolver.zig` | Resolver | Identifier reference resolution | ✅ Complete |
| `src/frontend/cfg.zig` | CFG Builder | Basic blocks for function bodies | ✅ Complete (preliminary) |
| `src/semantics/checker.zig` | Checker v2 | Validates the supported semantic model through the canonical compatibility relation | ✅ Complete for supported syntax |
| `src/semantics/type_inference.zig` | Canonical Expression Inference | Infers expressions, calls, access, operators, aggregates, and function returns into the owned semantic result | ✅ Complete for supported syntax |
| `src/semantics/dataflow.zig` | CFG Dataflow | Computes deterministic block facts and narrowing program points | ✅ Complete for supported syntax |
| `src/project/contracts.zig` | Host Contract | Opaque module/request identities and source/external response descriptors | ✅ Implemented |
| `src/project/session.zig` | Project Session | One-shot host-driven module ingestion, graph construction, and semantic completion | ✅ Implemented; Goal 207 audit closed |
| `src/project/state_machine.zig` | Request State Machine | Deterministic pull-based module requests and host responses | ✅ Implemented; Goal 207 audit closed |
| `src/project/graph.zig` | Project Graph | Host-resolved source/external edges and discovered module metadata | ✅ Implemented; Goal 207 audit closed |
| `src/modules/linker.zig` | Cross-file Linking | Named/default/namespace import linking to host-supplied module identities | ✅ Implemented for supported syntax |
| `test/support/fs_validation_host.zig` | Validation Fixture | Test/reference filesystem provider used only to exercise the host API | 🧪 Test-only; not ViZG module resolution |

### Diagnostic Code Ranges Currently Allocated

| Range | Phase | Status |
|-------|-------|--------|
| `VZG1xxx` | Scanner/lexer errors | ✅ Used (VZG1001–VZG1004) |
| `VZG2xxx` | Parser errors | ✅ Used (VZG2001–VZG2003) |
| `VZG3xxx` | Binder errors | ✅ Used (VZG3001–VZG3002) |
| `VZG4xxx` | Resolver errors | ✅ Used (VZG4001) |
| `VZG5xxx` | Module graph errors | ✅ Used (VZG5001–VZG5003) |
| `VZG6xxx` | Type checker semantic errors | ✅ Used (VZG6004–VZG6009) |
| `VZG7xxx` | HIR/lowering errors | 📌 Reserved for Phase 2 |
| `VZG8xxx` | Protocol-level errors | 📌 Reserved for Phase 4 |

---

## Phase 1: Typed Semantics v2 — Complete For Supported Syntax

### Purpose
Provide one owned semantic pipeline for annotation lowering, expression and function inference, CFG dataflow narrowing, cross-module propagation, and checking. The pipeline consumes frontend/module results and produces one canonical `TypeStore`; no HIR was introduced.

Current foundation: annotation resolution has an explicit `TypeResolutionContext`, canonical builtin lookup, scope-aware local and generic type-space lookup, and exact imported/re-exported type identity. Value and type namespaces remain distinct; type-only imports have no runtime binding, cyclic imports recover with stable placeholders, and unresolved local names produce one stable diagnostic at the annotation span.

Completed Goal 139: generic declaration environments and imported type identities now preserve canonical `TypeId` and module-qualified declaration identity across aliases and re-exports. Namespace type-member lookup remains outside v1.

Completed Goal 140: canonical annotation lowering now exhaustively handles every supported `TypeNodeData` variant. Literal, indexed-access, object-like `keyof`, simple annotated-binding `typeof`, generic named, and existing structural forms resolve without an implicit `unknown` fallback; invalid operations emit targeted semantic diagnostics.

Completed Goal 141: class declarations now have distinct constructor-value and instance `TypeId`s backed by one `SemanticDeclId`; authoritative class records separate static/instance members and preserve visibility, constructor, and inheritance metadata. Interfaces are first-class structural, member-bearing semantic types keyed by the same module-qualified identity scheme.

Completed Goal 142: class and interface declarations now populate their semantic member tables. Fields, canonical method/constructor signatures, constructor parameter properties, static/instance separation, optional/readonly/visibility metadata, and heritage identities are preserved; initializer-only field inference remains an explicit `unknown` placeholder for the inference pass.

Completed Goal 143: class instances, constructor values, and interfaces now resolve their declared and inherited members deterministically. `new` validates the canonical constructor signature and returns the instance type, method access preserves receiver metadata, and Checker v2 diagnoses unknown members and invalid constructor targets.

Completed Goal 144: function return inference now uses CFG reachability for fallthrough, optional and callable-union calls retain argument validation and precise return unions, compound assignments validate inferred call results against their targets, and async/generator v1 categories are explicit.

Completed Goal 145: a reusable forward CFG dataflow solver now computes immutable block entry/exit facts with deterministic joins and worklist loop convergence; narrowing supplies language guards and records assignment-sensitive per-reference program points.

Completed Goal 146: sound narrowing v1 adds literal-aware truthiness, primitive `typeof`, constructor-to-instance `instanceof`, supported object/interface/class `in` guards, predecessor joins, and conservative invalidation on assignment and unknown calls.

Completed Goal 147: Checker v2 now covers the supported semantic model through one compatibility relation. Interfaces and anonymous objects compare structurally, inherited mismatches retain property paths, named contextual initializers use collector-resolved types without replacing inference, and class/enum identity remains nominal.

### Architecture — Direct V8 Mapping

```txt
V8: ScopeAnalyzer          → vizg: frontend binder and module linker
V8: TypeSpecialization     → vizg: canonical semantics pipeline
    ├── annotation lowering →    src/semantics/type_collector.zig
    ├── expression inference →   src/semantics/type_inference.zig
    ├── flow fixpoint       →    src/semantics/dataflow.zig + narrowing.zig
    ├── project propagation →    bounded iterations in src/semantics/root.zig
    └── typed output        →    TypeInfo plus one owned TypeStore

vizg TypeChecker v2:       →     src/semantics/checker.zig
    ├── check supported AST →    initializers, assignments, calls, returns, access, operators, satisfies
    ├── compatibility       →    src/semantics/type_compat.zig
    └── diagnostics         →    VZG6xxx codes with source and related spans
```

### Closure Summary

- A single canonical `TypeStore` owns builtin, structural, function, and nominal types for each semantic result/project.
- Named annotations, aliases, re-exports, cycles, and type-only imports preserve canonical identities across modules.
- Class instance/constructor identities remain nominal; interfaces and anonymous object types remain structural.
- Class and interface member shapes, inheritance, constructors, and signatures propagate across modules.
- `vizg types` uses `TypeStore.formatDebugAlloc` for useful structural and nominal output.
- The obsolete alternative `src/semantics/inference.zig` implementation was removed.
- Full TypeScript compatibility, HIR, MIR, bytecode, runtime, and backend work remain outside this phase.

---

## Phase 2: HIR v1 — Canonical Typed Lowering

### Status

**Completed final-product plan.** Goal 207 froze the project-input ABI v1.
Goals 208–237 define and close canonical HIR v1, including independent
ownership, stable externals, immutable consumers, and a separately versioned
public HIR access API.

Normative design documents:

- [`docs/hir-v1-design.md`](docs/hir-v1-design.md) — ownership, legal structure, invariants, textual form and TypeScript-to-HIR examples.
- [`docs/hir-v1-lowering-matrix.md`](docs/hir-v1-lowering-matrix.md) — exhaustive AST/type/operator/control/module equivalence table and coverage checklist.

### Purpose

Transform the immutable typed project result into one canonical, verified, target-independent HIR.

```txt
ProjectSemanticResult
→ eligibility gate
→ raw internal HIR
→ legal HIR operations
→ ANF temporary normalization
→ explicit blocks and terminators
→ mandatory local canonicalization
→ verification
→ immutable HirProject
```

HIR v1 is:

```txt
typed
ANF-like
block-based
binding-aware
module-aware
source-traceable
independent of optimize mode
```

HIR v1 is not:

```txt
an AST copy
full SSA
MIR
bytecode
runtime
backend
memory-management policy
GC or RC
```

Full SSA, global optimization, layout, async state machines, exception ABI,
memory management, bytecode, native lowering, linking, and executable/library
packaging are outside the ViZG product and roadmap.

---

### Goal 208 — Freeze HIR v1 Contract And Lowering Matrix

**Depends on:** Goal 207.

#### Work

- Add `docs/hir-v1-design.md` as the normative architectural contract.
- Add `docs/hir-v1-lowering-matrix.md` as the exhaustive lowering checklist.
- Define legal HIR versus illegal AST-only forms.
- Define the HIR/MIR boundary and explicitly exclude all memory-management decisions.
- Record the future reduction of pipeline syntax to ordinary calls without enabling the currently unsupported parser feature.
- Remove or supersede every contradictory Phase 2 design statement, including `SSA-lite`, declaration hoisting, `if`-to-ternary rewriting, and final `while_loop`/`for_loop` HIR nodes.

#### Acceptance

```txt
[ ] One unambiguous HIR v1 contract exists.
[ ] Every current NodeData and TypeNodeData variant has a documented outcome.
[ ] Every supported operator and assignment family has a documented outcome.
[ ] HIR and MIR responsibilities do not overlap.
[ ] No GC, RC, heap, root-map or safepoint field exists in the HIR contract.
```

---

### Goal 209 — Establish `src/hir/` Package, Ownership And Identity Domains

**Depends on:** Goal 208.

#### Work

Create the package skeleton:

```txt
src/hir/root.zig
src/hir/model.zig
src/hir/ids.zig
src/hir/result.zig
src/hir/tests.zig
```

Define opaque project-local IDs:

```txt
EntityId
FunctionId
BlockId
InstructionId
ValueId
BindingId
PlaceId
RegionId
OriginId
```

Define `HirResult` ownership:

- immutable after successful construction;
- project-owned;
- valid until project destruction;
- shares project-local `ModuleId`, semantic declaration identity and `TypeId` domains;
- does not alter frozen C ABI v1;
- has explicit deinitialization for all internal allocations.

#### Acceptance

```txt
[ ] Empty HirResult can be created and destroyed without leaks.
[ ] Invalid IDs have one canonical sentinel or checked representation.
[ ] IDs from another project/context are rejected in debug/verifier paths.
[ ] Semantic-result lifetime requirements are explicit and tested.
[ ] No filesystem, target, backend or runtime dependency enters `src/hir/`.
```

---

### Goal 210 — Implement Core HIR Schema And Legal Operation Set

**Depends on:** Goal 209.

#### Work

Implement the core records:

```txt
HirProject / HirResult
HirModule
HirEntity
HirFunction
HirBinding
HirCapture
HirBlock
HirBlockParameter
HirInstruction
HirTerminator
HirPlace
HirRegion
HirConstant
EffectSet
```

Implement the legal operation families documented in `hir-v1-design.md` without implementing lowering yet.

Key rules:

- immutable temporary `ValueId` results;
- mutable language `BindingId` values;
- semantic `PlaceId` references, never physical addresses;
- block parameters for temporary merge values;
- no final structured `if`, `switch`, loop, arrow, assignment, update or optional-chain nodes;
- no machine types or memory-management metadata.

#### Acceptance

```txt
[ ] Core HIR can represent every legal shape in the design examples.
[ ] Operation constructors validate immediate arity/payload invariants.
[ ] Every operation has a conservative EffectSet definition.
[ ] The schema contains no AST union payloads as executable fallbacks.
[ ] The schema contains no SSA phi node for mutable source bindings.
```

---

### Goal 211 — Add HIR Eligibility Gate, Diagnostics And Limits

**Depends on:** Goal 210.

#### Work

Create:

```txt
src/hir/eligibility.zig
src/hir/diagnostics.zig
src/hir/limits.zig
```

Before building HIR, reject projects/modules with:

- blocking frontend or semantic diagnostics;
- unsupported executable syntax;
- incomplete required module semantics;
- invalid type/symbol/module identities;
- partial-result categories that are not executable;
- exceeded HIR input or output limits.

Allocate stable `VZG7xxx` diagnostics beginning with the codes in the design document.

Add pre-growth limits for entities, functions, blocks, instructions, values, bindings, places, regions, origins, trace events and rewrites.

#### Acceptance

```txt
[ ] Ineligible projects produce diagnostics and no public partial HirResult.
[ ] Unsupported recovery nodes cannot enter lowering.
[ ] Every growth limit is checked before insertion/allocation.
[ ] Limit kind, summary and diagnostic remain consistent.
[ ] External modules may provide bindings/types without fabricated bodies.
```

---

### Goal 212 — Lower Project, Module And Entity Shells

**Depends on:** Goal 211.

#### Work

Create:

```txt
src/hir/builder.zig
src/hir/lower_project.zig
src/hir/lower_module.zig
```

Build deterministic project/module shells:

- one `HirModule` per reachable source module;
- exact host-supplied `ModuleId` preservation;
- one module-initialization function per source module;
- dependency/import/export descriptors from the linked semantic graph;
- deterministic entity/function ordering;
- external binding/entity references without executable bodies.

Do not resolve specifiers or inspect the filesystem.

#### Acceptance

```txt
[ ] Multi-module shell output is deterministic.
[ ] Module initialization dependencies match the project graph.
[ ] Import/export bindings preserve live semantic identities.
[ ] Logical names are descriptive only and never used as identity.
[ ] Module cycles build finite shells without recursive duplication.
```

---

### Goal 213 — Lower Constants, Bindings, Declarations And Type Erasure

**Depends on:** Goal 212.

#### Work

Implement lowering for:

```txt
Program / BlockStatement shell traversal
Literal
Identifier
VariableDeclaration / VariableDeclarator
Function declaration shell references
TypeAliasDeclaration
InterfaceDeclaration
AsExpression
SatisfiesExpression
NonNullExpression
all TypeNodeData
```

Define binding kinds and initialization states for:

```txt
var
let
const
parameter
catch
import
function
class
enum
synthetic
```

Erase type-only executable wrappers while retaining `TypeId`, symbol and origin metadata where configured.

#### Acceptance

```txt
[ ] Every identifier read uses its resolved semantic binding/entity.
[ ] No spelling-based lookup occurs during lowering.
[ ] `var`, `let` and `const` initialization/TDZ distinctions remain represented.
[ ] Type aliases, interfaces and type assertions emit no executable HIR.
[ ] Type-erasure snapshots preserve values and optional provenance.
```

---

### Goal 214 — Implement ANF Expression Builder And Evaluation Order

**Depends on:** Goal 213.

#### Work

Create:

```txt
src/hir/lower_expression.zig
src/hir/anf_builder.zig
```

Enforce:

- every non-trivial expression produces a named `ValueId`;
- instruction operands are already lowered values/constants/allowed handles;
- left-to-right source evaluation order;
- expression statements discard only the final value, never effects;
- sequence expressions lower all members in order;
- block parameters merge temporary expression values;
- temporary values are defined exactly once.

#### Acceptance

```txt
[ ] Nested effectful calls produce deterministic left-to-right instructions.
[ ] No legal instruction contains an unevaluated nested AST expression.
[ ] Sequence expressions retain all effects and return only the last value.
[ ] Branch-produced expression values merge through typed block parameters.
[ ] Temporary-value use-before-definition is impossible through builder APIs.
```

---

### Goal 215 — Implement Places, Simple Assignment, Compound Assignment And Updates

**Depends on:** Goal 214.

#### Work

Create:

```txt
src/hir/lower_place.zig
src/hir/lower_assignment.zig
```

Implement semantic places:

```txt
binding place
static property place
computed element place
super property place
```

Lower:

```txt
=
+= -= *= /= %= **=
&= |= ^= <<= >>= >>>=
++ --
delete
```

The base/key of a property target must evaluate exactly once. Prefix/postfix updates must return the correct old/new value.

Logical assignments are deferred to Goal 216 because they require control flow.

#### Acceptance

```txt
[ ] Side-effectful assignment targets evaluate exactly once.
[ ] LHS evaluation order relative to RHS matches language semantics.
[ ] Prefix/postfix result differences are tested.
[ ] No final assignment/update AST operation survives.
[ ] PlaceId never exposes a physical pointer or storage layout.
```

---

### Goal 216 — Lower Operators, Short Circuit, Logical Assignment And Optional Chains

**Depends on:** Goal 215.

#### Work

Implement all current unary and binary operators using semantic operation modes from typed semantics.

Lower control-sensitive forms:

```txt
&&
||
??
&&=
||=
??=
?:
optional member access
optional element access
optional call
```

Rules:

- truthiness uses explicit `to_boolean`;
- nullish checks use explicit `is_nullish`;
- unselected operands/arms are not evaluated;
- optional computed keys and arguments are not evaluated on nullish paths;
- loose and strict equality remain distinct;
- no target numeric representation is selected.

#### Acceptance

```txt
[ ] Every operator token supported by the parser has a lowering rule or a controlled eligibility failure.
[ ] `&&`, `||` and `??` differ correctly.
[ ] Logical assignments load their place once and store only on the selected path.
[ ] Optional chains preserve single evaluation and result `undefined` on the nullish path.
[ ] Pipeline syntax remains rejected but its future call reduction remains documented.
```

---

### Goal 217 — Lower Access, Calls, Receivers, Construction, Meta And Dynamic Import

**Depends on:** Goal 216.

#### Work

Lower:

```txt
MemberExpression
ElementAccessExpression
CallExpression
NewExpression
ThisExpression
SuperExpression
MetaProperty
ImportExpression
```

Use distinct canonical operations for:

```txt
ordinary call
method call with receiver
super method/constructor call
construct
dynamic import
import.meta
new.target
```

Preserve callee/base/key/argument evaluation order and receiver semantics.

#### Acceptance

```txt
[ ] `obj.method()` does not degrade into receiver-less `call(get_property(...))`.
[ ] Computed method keys evaluate once.
[ ] Optional method calls preserve receiver on the taken path.
[ ] `new` remains distinct from `call`.
[ ] Dynamic import remains runtime-semantic and performs no ViZG resolution.
```

---

### Goal 218 — Lower Objects, Arrays, Spread, Templates And RegExp

**Depends on:** Goal 217.

#### Work

Lower:

```txt
ObjectExpression / ObjectProperty kinds
ArrayExpression
SpreadElement in object/array/call contexts
TemplateExpression
TaggedTemplateExpression
RegExpLiteral
```

Required distinctions:

```txt
array hole versus explicit undefined
object spread versus iterable spread
method/accessor definition versus data property
tagged-template site identity
regexp creation per evaluation semantics
computed key/value source order
```

#### Acceptance

```txt
[ ] Object properties and spreads execute in source order.
[ ] Array holes remain distinguishable.
[ ] Spread lowering is context-specific.
[ ] Tagged templates preserve raw/cooked data and stable source-site identity.
[ ] RegExp lowering preserves pattern, flags, origin and observable identity creation.
```

---

### Goal 219 — Lower Functions, Parameters, Closures And Captures

**Depends on:** Goal 218.

#### Work

Unify:

```txt
FunctionDeclaration
FunctionExpression
ArrowFunctionExpression
object/class method
constructor
getter
setter
async/generator flags
```

Implement parameter plans:

```txt
ordinary argument read
default initializer branch
rest argument collection
optional marker erasure
parameter-property handoff to class initialization
```

Consume resolved capture information or derive it only from already resolved semantic identities. Do not re-resolve names.

#### Acceptance

```txt
[ ] All function-like forms use one canonical function body representation.
[ ] Arrow lexical receiver semantics are explicit.
[ ] Default initializers run per call and in parameter order.
[ ] Rest parameters collect from the correct index.
[ ] Captures are explicit without choosing environment layout.
```

---

### Goal 220 — Lower `if`, Ternary And Loop Families To Blocks

**Depends on:** Goal 219.

#### Work

Lower:

```txt
IfStatement
ConditionalExpression
WhileStatement
DoWhileStatement
ForStatement(classic)
ForStatement(in)
ForStatement(of)
```

Use explicit blocks, branches, jumps and iterator/enumeration operations.

For `for...of`, establish close-on-abrupt-exit region semantics. `for await...of` is completed in Goal 223.

#### Acceptance

```txt
[ ] No structured if/loop node survives.
[ ] Classic `for` continue targets update, not condition.
[ ] `do...while` body executes before the first condition.
[ ] `for...in` is not rewritten as `Object.keys`.
[ ] `for...of` preserves iterator closing on abrupt completion.
```

---

### Goal 221 — Lower `switch`, Labels, `break` And `continue`

**Depends on:** Goal 220.

#### Work

Lower `switch` into:

```txt
one discriminant evaluation
ordered strict-equality case-test chain
explicit default target
case-body blocks
fallthrough edges
resolved exit target
```

Erase label spellings after resolving break/continue target identities.

Support nested labeled loops and switches without target ambiguity.

#### Acceptance

```txt
[ ] Discriminant evaluates once.
[ ] Case expressions evaluate lazily and in source order.
[ ] Default works in any source position.
[ ] Fallthrough is represented only by CFG edges.
[ ] Labeled break/continue reaches the exact resolved target.
```

---

### Goal 222 — Lower Exceptions, Catch And Finally Regions

**Depends on:** Goal 221.

#### Work

Implement:

```txt
HirRegion exception/cleanup model
TryStatement
CatchClause
FinallyClause
leave_region
resume_completion
pending completion kinds
```

Pending completions:

```txt
normal
return
throw
break
continue
```

Do not duplicate finally bodies at each exit and do not choose a native exception ABI.

#### Acceptance

```txt
[ ] `finally` runs for normal and every abrupt completion.
[ ] A completion created inside finally replaces the pending completion.
[ ] Catch binding scope and initialization are correct.
[ ] Illegal region entry/exit is rejected.
[ ] No runtime/backend exception representation is encoded.
```

---

### Goal 223 — Lower Async, Generators, Yield And Async Iteration Semantics

**Depends on:** Goal 222.

#### Work

Lower and validate:

```txt
async function flags
await
generator flags
yield
yield*
async generators
for await...of
```

Retain semantic suspension operations and async iterator protocol. Do not construct state machines, frames or resume ABI.

#### Acceptance

```txt
[ ] `await` appears only in valid async contexts.
[ ] `yield`/`yield*` appear only in valid generator contexts.
[ ] `for await...of` preserves async iterator acquisition, await and close semantics.
[ ] Suspension operations carry source origin and result TypeId.
[ ] No state-machine blocks or runtime frame layout are introduced.
```

---

### Goal 224 — Lower Classes, Enums And Complete Module Initialization

**Depends on:** Goal 223.

#### Work

Implement canonical entities and initialization plans for:

```txt
ClassDeclaration / ClassExpression
ClassField
ClassMethod
constructors/getters/setters
extends evaluation
instance field initialization
static field initialization
parameter properties
EnumDeclaration / EnumMember
module top-level execution
imports/exports/re-exports/export-all
```

Preserve source order, class TDZ, derived-constructor `super()` constraints, live module bindings and enum reverse mapping.

Do not define prototype/object layout or constructor ABI.

#### Acceptance

```txt
[ ] Class syntax lowers to one class entity plus canonical function/init plans.
[ ] Field/static initialization order is covered by tests.
[ ] Parameter properties initialize at the correct constructor point.
[ ] Numeric and string enum behavior differs correctly.
[ ] Module initialization and live export binding behavior are deterministic across cycles.
```

---

### Goal 225 — Implement Mandatory Canonicalization

**Depends on:** Goal 224.

#### Work

Create:

```txt
src/hir/canonicalize.zig
src/hir/rewrite.zig
```

Implement deterministic worklist-based rewrites:

```txt
safe primitive literal folding
literal branch to jump
trivial copy elimination
unreachable block removal
legal jump-only block merging
identical merge-value collapse
unused proven-pure instruction removal
empty-return normalization
```

Canonicalization runs regardless of Zig optimize mode.

Explicitly exclude full SSA, SCCP, global DCE, CSE/GVN/PRE, LICM, inlining, specialization, escape analysis, layout and memory management.

#### Acceptance

```txt
[ ] Rewrites converge or return controlled VZG7009.
[ ] Each rewrite reduces a documented structural measure or is otherwise proven non-cyclic.
[ ] Origins remain traceable after replacement/merging.
[ ] Effectful or identity-creating operations are never removed as pure.
[ ] Canonical output is identical across build optimization modes.
```

---

### Goal 226 — Implement Structural, Semantic And Canonical HIR Verifier

**Depends on:** Goal 225.

#### Work

Create:

```txt
src/hir/verifier.zig
```

Verify:

```txt
ID ownership and ranges
module/entity/function ownership
block terminators and targets
block parameter arity/types
ValueId single definition and valid dominance/block flow
binding and place validity
instruction type contracts
function-context restrictions
exception/cleanup region nesting
absence of illegal AST-only forms
mandatory canonical-form invariants
```

Run verification after raw legal lowering and after canonicalization.

#### Acceptance

```txt
[ ] Corruption tests exist for every ID and operation family.
[ ] Invalid graphs return diagnostics instead of panics/undefined behavior.
[ ] Verifier accepts all canonical snapshots.
[ ] Verifier rejects every deliberately non-canonical test fixture.
[ ] Verification is deterministic and bounded.
```

---

### Goal 227 — Implement Source Provenance And Optional Lowering Trace

**Depends on:** Goal 226.

#### Work

Create:

```txt
src/hir/origin.zig
src/hir/trace.zig
```

Debug levels:

```txt
none
minimal
full
```

Preserve:

```txt
ModuleId
primary source span
principal and contributing AST NodeIds
original syntax kind
semantic declaration identity
TypeId
parent origin
lowering rule
synthetic reason
```

Full mode records transformation events without bloating executable node payloads.

#### Acceptance

```txt
[ ] Every executable instruction and terminator has a valid OriginId in minimal/full mode.
[ ] Multi-origin rewrites preserve all relevant source contributors.
[ ] Erased syntax can appear in full lowering trace without executable nodes.
[ ] Debug metadata can be disabled without changing executable HIR.
[ ] No origin record reconstructs module identity from a path.
```

---

### Goal 228 — Add Deterministic HIR Printer And Reference Snapshots

**Depends on:** Goal 227.

#### Work

Create:

```txt
src/hir/printer.zig
src/hir/snapshot_test.zig
```

Printer modes:

```txt
canonical
brief
with_types
with_origins
with_full_trace
```

Output is a stable debug/test representation, not a serialized ABI.

Add snapshots for every major example in the design document and every lowering-matrix family.

#### Acceptance

```txt
[ ] Same project produces byte-identical canonical text across repeated runs.
[ ] Ordering never depends on hash-map iteration or pointer addresses.
[ ] Types and origins can be enabled independently.
[ ] Snapshots cover all supported NodeData families.
[ ] Printer handles invalid IDs through controlled debug output and never out-of-bounds access.
```

---

### Goal 229 — Integrate HIR Into Project APIs And Close Lowering-Matrix Coverage

**Depends on:** Goal 228.

#### Work

- Add the Zig project/session entry point that derives HIR from a completed semantic project result.
- Keep C ABI v1 unchanged.
- Define terminal/idempotent behavior for repeated HIR derivation within the one-shot project lifecycle.
- Add project-owned immutable HIR access through Zig APIs.
- Mark every row in `hir-v1-lowering-matrix.md` with implementation/test evidence.
- Update `src/root.zig`, `docs/frontend-pipeline.md`, `docs/architecture.md`, `docs/roadmap.md` and README as appropriate.

Optional CLI printing may consume the Zig API, but it must remain an adapter and must not introduce filesystem policy into HIR.

#### Acceptance

```txt
[ ] Completed semantic project can derive exactly one canonical HirResult.
[ ] Repeated derivation is bounded and does not create unlimited snapshots.
[ ] Project destruction invalidates and frees HIR exactly once.
[ ] Frozen ABI v1 symbol/layout gates remain unchanged.
[ ] Every lowering-matrix row has passing evidence or a deliberate unsupported marker.
```

---

### Goal 230 — HIR Limits, Fuzzing, Adversarial Cases And Cross-Mode Reproducibility

**Depends on:** Goal 229.

#### Work

Test adversarial inputs:

```txt
deep expression nesting
wide blocks and modules
large switch dispatch
nested labels/loops
nested optional chains and logical assignments
deep try/finally nesting
abrupt iterator exits
module cycles
very large provenance/trace volume
canonicalization rewrite stress
corrupted HIR verifier fixtures
```

Run equivalent HIR snapshot tests in supported Zig optimize modes and portable build gates where HIR is compiled.

#### Acceptance

```txt
[ ] No unbounded recursion or growth on configured adversarial fixtures.
[ ] Every limit fails before growth and reports VZG7010 consistently.
[ ] Canonical HIR output is reproducible across optimize modes.
[ ] Fuzz/property tests preserve verifier invariants.
[ ] Existing frontend, ABI, Android and wasm-freestanding gates remain green.
```

---

### Goal 231 — Final HIR v1 Audit And Freeze

**Depends on:** Goal 230.

#### Work

Perform a clean-revision audit covering:

```txt
contract compliance
complete lowering matrix
ownership and teardown
limits and diagnostics
semantic preservation tests
canonicalization convergence
verifier completeness
deterministic textual snapshots
source provenance
module-host boundary
C ABI v1 non-regression
native/Android/wasm build gates
```

Create `docs/HIR_V1_AUDIT.md` with exact commit SHA, clean-tree status, commands and real outputs.

Recommended tag:

```sh
git tag -a vizg-hir-v1 -m "ViZG canonical typed HIR v1"
```

#### Acceptance

```txt
[ ] Goals 208–237: PASS.
[ ] Unresolved HIR P0/P1/P2 findings: 0.
[ ] Every supported lowering-matrix row is closed.
[ ] Every legal operation has verifier and printer coverage.
[ ] HIR contains no MIR/backend/memory-management policy.
[ ] Frozen project-input ABI v1 remains unchanged; HIR access is additive and separately versioned.
[ ] Exact audited working-tree revision and validation state are recorded.
[ ] No post-HIR implementation layer is assigned to ViZG.
```

---

### Goals 232–237 — Final Product Boundary, Consumers, Externals And Freeze

**Depends on:** Goal 231, in strict numerical order.

#### Goal 232 — Freeze ViZG at verified immutable HIR — COMPLETE

- `HirProject` is the final ViZG artifact.
- Sealed HIR owns every type, provenance and string fact needed by consumers.
- Semantic/project teardown cannot invalidate an owned HIR result.
- Post-HIR optimization, representation, execution, memory management,
  code generation, linking and packaging remain outside ViZG.

#### Goal 233 — Freeze the immutable HIR consumer contract — COMPLETE

- Deterministic iteration and checked lookup cover modules, functions, blocks,
  instructions, bindings, types, effects and provenance.
- IDs are result-local; invalid, stale and foreign handles fail safely.
- A standalone consumer needs no AST, binder, checker or mutable project.

#### Goal 234 — Stable external declarations — COMPLETE

- Host-supplied `ExternalSymbolId` is independent of descriptor order.
- External module, declaration, semantic and HIR identities remain distinct.
- Function/global/constant/type declarations retain complete semantic types,
  conservative effects and provenance without backend metadata.

#### Goal 235 — Canonical external lowering — COMPLETE

- Imports, aliases and re-exports retain canonical external identity.
- External functions remain body-less declarations and calls use ordinary HIR
  call/binding operations.
- Missing, duplicate or malformed external metadata is rejected.

#### Goal 236 — Official versioned HIR access — COMPLETE

- Zig consumers use immutable checked views.
- Non-Zig consumers use the additive `VIZG_HIR_API_VERSION` summary/record API
  through opaque result ownership.
- Borrowed strings and handles remain valid only for the owning result lifetime.
- `example/hir_consumer.c` validates a downstream consumer.
- HIR serialization remains out of scope.

#### Goal 237 — Final implementation audit and freeze — COMPLETE

- Goals 232–236 pass with zero unresolved HIR P0/P1/P2 findings.
- All supported access uses public APIs; VZed needs no private frontend state.
- The complete build, test, ABI, native, Android and WebAssembly matrix passes.

---

### Required implementation order

```txt
208 Contract and matrix
 ↓
209 Ownership and IDs
 ↓
210 Core schema
 ↓
211 Eligibility, diagnostics and limits
 ↓
212 Project/module shells
 ↓
213 Bindings, constants and erasure
 ↓
214 ANF evaluation order
 ↓
215 Places and assignment
 ↓
216 Operators and conditional expressions
 ↓
217 Calls, access and construction
 ↓
218 Aggregates, templates and regexp
 ↓
219 Functions and closures
 ↓
220 If and loops
 ↓
221 Switch and labeled control
 ↓
222 Exceptions and finally
 ↓
223 Async/generators
 ↓
224 Classes, enums and module initialization
 ↓
225 Mandatory canonicalization
 ↓
226 Verifier
 ↓
227 Provenance and trace
 ↓
228 Printer and snapshots
 ↓
229 Project integration and matrix closure
 ↓
230 Robustness and reproducibility
 ↓
231 Final audit and freeze
 ↓
232 Final product boundary
 ↓
233 Consumer contract
 ↓
234 Stable external identities
 ↓
235 External declaration lowering
 ↓
236 Official public HIR access
 ↓
237 Final implementation audit and freeze
```

No goal may silently implement work assigned to a later goal in a way that freezes an unreviewed contract. Earlier scaffolding may reserve types/APIs, but behavioral closure occurs only in its assigned goal.

### Planned files

| File | Action | Responsibility |
|---|---|---|
| `src/hir/root.zig` | New | Public Zig exports for the HIR package |
| `src/hir/ids.zig` | New | Opaque HIR identity types |
| `src/hir/model.zig` | New | Core immutable HIR schema and operation set |
| `src/hir/result.zig` | New | Ownership and project result lifecycle |
| `src/hir/eligibility.zig` | New | Lowering gate |
| `src/hir/diagnostics.zig` | New | `VZG7xxx` diagnostics |
| `src/hir/limits.zig` | New | Bounded HIR resource model |
| `src/hir/builder.zig` | New | Internal mutable construction state |
| `src/hir/lower_project.zig` | New | Project/entity ordering |
| `src/hir/lower_module.zig` | New | Modules, imports, exports and initialization |
| `src/hir/lower_expression.zig` | New | General expression lowering |
| `src/hir/anf_builder.zig` | New | Named temporary/value sequencing |
| `src/hir/lower_place.zig` | New | Semantic lvalue/place construction |
| `src/hir/lower_assignment.zig` | New | Assignment/update lowering |
| `src/hir/lower_control.zig` | New | Branches, loops, switch and labels |
| `src/hir/lower_function.zig` | New | Functions, parameters and closures |
| `src/hir/lower_class.zig` | New | Classes and enums |
| `src/hir/lower_exception.zig` | New | Exception and cleanup regions |
| `src/hir/lower_suspend.zig` | New | Async/generator semantic operations |
| `src/hir/canonicalize.zig` | New | Mandatory canonicalization driver |
| `src/hir/rewrite.zig` | New | Local convergent rewrite rules |
| `src/hir/verifier.zig` | New | Structural/semantic/canonical verification |
| `src/hir/origin.zig` | New | Source provenance side table |
| `src/hir/trace.zig` | New | Optional full lowering trace |
| `src/hir/printer.zig` | New | Stable textual HIR |
| `src/hir/tests.zig` | New | Unit and integration tests |
| `docs/hir-v1-design.md` | New | Normative architecture and examples |
| `docs/hir-v1-lowering-matrix.md` | New | Exhaustive lowering equivalence matrix |
| `docs/HIR_V1_AUDIT.md` | Goal 231 | Final revision evidence |

---

## Runtime Module Resolution — Outside ViZG

### Boundary

ViZG does not resolve module specifiers. It discovers import/export syntax,
emits an environment-neutral request, accepts a host-provided response, and
links the supplied `ModuleId` into the project graph.

```txt
ViZG:
    importer ModuleId
    raw specifier
    operation: import | re-export | dynamic import
    type_only flag
    import attributes
    source span

Runtime / consumer:
    resolve filesystem, URL, package, memory, or virtual-module policy
    assign the canonical ModuleId
    provide source bytes, external metadata, or a controlled failure
```

The following are explicitly outside the ViZG core and official ABI:

- relative or absolute path normalization;
- extension probing and `index.*` lookup;
- `package.json`, `node_modules`, import maps, or package exports;
- URL fetching, network policy, caches, credentials, or redirects;
- symlink, filesystem sandbox, or path-traversal policy;
- runtime-specific builtin-module detection.

A filesystem provider may exist under `test/support/` or inside the CLI only as
a validation fixture proving that an external consumer can drive the API. It
must not be exported from `src/root.zig`, the C ABI, or public documentation as
a ViZG resolver. Core module-system tests should use an in-memory provider.

### Active module work

The active module work is limited to the provider-independent contract:

1. discover imports, exports, and re-exports from source;
2. preserve raw specifier, operation, `type_only`, attributes, and spans;
3. emit deterministic `RequestId` values;
4. accept host-supplied `ModuleId` and source/external responses;
5. reject stale, duplicate, foreign, or invalid responses;
6. construct the graph and propagate semantic identities;
7. expose diagnostics and graph metadata through the official ABI;
8. enforce resource limits independent of resolver policy.

No package-resolution phase exists in ViZG. A future runtime may implement one
without changing the core module contract.

---

## Phase 4: Inspector Protocol (CDP-like)

### Purpose
Expose vizg as a server that external tools (IDEs, linters, analysis pipelines) can drive via structured protocol. Not an execution layer — pure analysis.

### Architecture — Direct CDP Mapping

Chrome DevTools Protocol v1 structure: JSON-RPC over stdio or WebSocket, with `id`, `method`, `params` on requests and matching response shape. Vizg mirrors this exactly but maps domains to existing frontend layers instead of runtime state.

```txt
CDP Request:                     Vizg Equivalent:
  { id: 1, method: "Runtime.evaluate", params: {...} }
    → { id: 1, result: { value: "...", exceptionDetails: null }, status: "success" }
                                       (error) → { id: 1, error: { code: -32601, message: "Method not found" } }

Vizg request/response over stdio:
  JSON-RPC line ← stdin   │   stdout → next response + method dispatch by `method` field
  Auto-detect server mode when !isatty(STDIN_FILENO) — like clangd / rust-analyzer
```

### Tasks

#### 4.1 Create `src/protocol/message.zig` — Message Format Definitions

```zig
pub const Request = struct {
    id: ?u32,           // optional for notifications (no response needed)
    method: []const u8, // domain.method e.g., "Analyze.analyzeFile"
    params: MessageValue = .{},  // union over known param shapes per method
};

pub const Response = struct {
    id: ?u32,
    result: ?MessageValue,
    error: ?ResponseError,  // CDP-style negative integer codes
};

// Error codes follow CDP convention (JSON-RPC standard)
pub const ProtocolErrorCode = enum(i32) {
    invalid_request = -32600,
    method_not_found = -32601,
    internal_error = -32603,
    // domain-specific error range: -32799..-32099 (reserved for vizg)
};

// MessageValue is a discriminated union over string / object / array — 
// matches CDP's flexible parameter shapes
pub const MessageValue = enum {
    null_value,
    bool_val: bool,
    int_val: i64,
    double_val: f64,
    string_val: []const u8,
    object_val: std.json.ObjectMap(u32, MessageValue),
};
```

#### 4.2 Create `src/protocol/server.zig` — JSON-RPC Server Loop

- Read one request from stdin (JSON line)
- Parse via minimal JSON parser (only the `{id, method, params}` shape needed)
- Route to handler by method name prefix (`Analyze.analyzeFile`, `ScopeInfo.getScopesForNode`)
- Write response with matching `id` back to stdout
- Handle: `disconnect`, `listDomains`, and `error` cases

#### 4.3 Create Handler Modules — One Per Domain

| File | Methods (CDP ↔ Vizg mapping) |
|------|------------------------------|
| `src/protocol/handlers.analyze.zig` | `Analyze.analyzeFile(path)` → returns AST dump + symbols + references |
| `src/protocol/handlers.scope.zig` | `ScopeInfo.getScopesForNode(nodeId)` / `ScopeInfo.listSymbols()` |
| `src/protocol/handlers.module.zig` | `Modules.listGraph(entryPath)` → returns module graph edges (same data as CLI `modules`) |
| `src/protocol/handlers.typecheck.zig` | `TypeCheck.checkFile(path)` → runs type checking, returns per-symbol types + errors; needs Phase 1 complete |

#### 4.4 CLI Entry Point — New Command

```sh
vizg server --stdio          # stdin/stdout JSON-RPC loop (default for non-TTY)
vizg server --ws [port]      # WebSocket mode (future, out of scope for Phase 4)
```

Auto-detect when `!isatty(STDIN_FILENO)` and switch to server mode automatically. Like `clangd` does this without a flag — vizg can follow suit after phase 1-3 establish the analysis pipeline's public APIs.

#### 4.5 Protocol Spec Docs

Document in `docs/protocol.md`:
- Request/response JSON shapes per method
- Error codes and their meanings
- Domain list with capability negotiation via `listDomains`

### V8 Reference Mapping
- Chrome DevTools Protocol v1 — direct structural reference for request/response format (see https://chromedevtools.github.io/devtools-protocol/tot/)
- CDP domains (`Runtime`, `Debugger`, `Network`, `Page`, `Inspector`) → vizg domains map to frontend layers (`Analyze`, `ScopeInfo`, `Modules`, `TypeCheck`)
- JSON-RPC over stdio is how tools like `clangd` and `rust-analyzer` expose analysis — proven pattern

### Files Changed (Phase 4)
| File | Action | Notes |
|------|--------|-------|
| `src/protocol/message.zig` | New | Message format definitions, error codes |
| `src/protocol/server.zig` | New | JSON-RPC over stdio server loop |
| `src/protocol/handlers.analyze.zig` | New | Analyze domain handler |
| `src/protocol/handlers.scope.zig` | New | ScopeInfo domain handler |
| `src/protocol/handlers.module.zig` | New | Modules domain handler |
| `src/protocol/handlers.typecheck.zig` | New | TypeCheck domain handler (needs Phase 1) |
| `src/main.zig` | Edit | Add `server` subcommand with auto-detect non-TTY mode |

---

## Implementation Order & Dependencies

```txt
Goals 189–207
└── closed portable frontend, project semantics and official ABI v1

Goals 208–237
└── closed strict HIR v1 final-product chain documented in Phase 2

Host module resolution
└── belongs to the consumer and is not a ViZG phase
```

### Required order

1. Goals 189–207 remain closed and are not reopened without new evidence.
2. Goals 208–237 execute in strict numerical order.
3. HIR work must not modify frozen project-input ABI v1 structures or introduce resolver policy.
4. ViZG has no implementation phase after verified immutable HIR.
5. Filesystem/package/URL resolution remains in the host or consumer that
   implements the module-provider contract.

---

## Diagnostic Code Allocation Summary

| Range | Purpose | Notes |
|-------|---------|-------|
| `VZG1xxx` | Scanner/lexer errors | Existing frontend diagnostics |
| `VZG2xxx` | Parser errors | Existing frontend diagnostics |
| `VZG3xxx` | Binder errors | Existing frontend diagnostics |
| `VZG4xxx` | Resolver errors | Identifier/type-name resolution, not module-specifier policy |
| `VZG5xxx` | Module-provider/graph errors | Missing, denied, failed, duplicate, invalid-response, or limit outcomes |
| `VZG6xxx` | Type checker semantic errors | Existing semantic diagnostics |
| `VZG7xxx` | HIR/lowering errors | Active allocation under Goals 208–237 |
| `VZG8xxx` | Future protocol errors | Reserved |

Module diagnostics describe the result of a host response or graph invariant.
They must not encode filesystem, package-manager, URL, or path-resolution policy.

---

## Open Decisions / Risks

1. **Exact Zig packing is not the contract.** `docs/hir-v1-design.md` freezes the
   semantic shape, identities and invariants. Goal 210 may choose efficient Zig
   layouts only when they preserve that contract.

2. **Dynamic language effects are easy to misclassify.** Property access,
   conversions, comparison, iteration and calls may invoke user code or throw.
   Canonicalization must use conservative `EffectSet` definitions.

3. **Exception/finally lowering is the highest semantic-risk area.** Goal 222
   must model pending abrupt completions without duplicating cleanup bodies or
   importing a backend exception ABI.

4. **Existing CFG is analysis input, not executable HIR.** It may guide lowering,
   but HIR must build its own typed blocks, values, places, terminators and
   regions. It must not wrap AST `NodeId` CFG blocks as the final representation.

5. **Public HIR access:** the additive versioned HIR API exposes only
   result-scoped records and borrowed strings. Context-local `TypeId`, HIR IDs
   and pointers are not portable global identities.

6. **Host provider design:** filesystem, package, URL, memory, and virtual
   module providers belong to the host/consumer. Their policies must not be
   copied into ViZG.

7. **Singular semantic ownership:** HIR consumes the canonical semantic result.
   It must not restore a parallel resolver, type store, inference engine or
   compatibility relation.

---

## Non-Goals Until Explicitly Revisited

- Resolving filesystem paths, URLs, packages, import maps, or `node_modules` in
  ViZG.
- Publishing a filesystem/provider implementation as part of the core or ABI.
- Claiming full TypeScript or JavaScript compatibility.
- Running or bundling imported modules.
- Acting as a browser, Node.js replacement, or package manager.
- Changing frozen project-input ABI v1 structures, constants, or lifecycle.
- Extending the separately versioned HIR access contract without a new version.
- Emitting MIR, bytecode, objects, native code, or linking executables in this
  frontend repository.
- Restoring the removed prototype ABI or introducing compatibility shims for it.
