# ViZG HIR v1 — Canonical Typed High-Level IR

**Status:** frozen normative contract for Goals 208–237
**Scope:** ViZG frontend repository  
**Input:** immutable project semantic result  
**Output:** immutable, canonical, typed HIR project  
**Excluded:** MIR, bytecode, runtime, memory management, GC, native ABI, backend

---

## 1. Purpose

HIR v1 is the canonical executable meaning of a supported TypeScript project after parsing, binding, module linking, type collection, inference, narrowing, and checking have completed.

HIR records what the program does rather than how the source spelled it.

```txt
Source TypeScript
→ Scanner / Parser / AST
→ Binder / Resolver / CFG
→ Typed project semantics
→ HIR eligibility gate
→ Raw internal HIR
→ semantic legalization
→ ANF normalization
→ explicit control-flow lowering
→ mandatory canonicalization
→ HIR verification
→ immutable HIR v1
```

HIR v1 must be:

```txt
canonical
fully typed for the supported language subset
explicit about evaluation order
explicit about control flow
independent of target and runtime
safe for direct consumption after verification
traceable back to source
stable across optimization modes
```

HIR v1 is not an AST with fewer node kinds, and it is not an early MIR.

---

## 2. Normative boundary

### ViZG owns

```txt
semantic eligibility for lowering
source-to-HIR lowering
syntax erasure
semantic desugaring
ANF-style temporary values
explicit basic blocks and terminators
resolved bindings and module identities
canonical language operations
mandatory local canonicalization
structural and semantic HIR verification
source provenance and optional lowering traces
human-readable HIR printing
```

### Outside the ViZG product boundary

```txt
full SSA construction and variable promotion
dominator-based optimization infrastructure and global data-flow optimization
SCCP, GVN, PRE, LICM and global DCE
inlining and interprocedural specialization
union splitting, unboxing and representation specialization
object, class, closure and environment layout
exception ABI and cleanup implementation
async/generator state-machine layout
calling conventions and target types
stack frames, registers and instruction selection
memory management of every kind
GC, RC, arenas, ownership, root maps and safepoints
bytecode, native code, object files and linking
```

ViZG does not own, schedule, package, or roadmap those concerns. Independent
downstream consumers may interpret or lower verified HIR under their own
contracts.

### Memory-management neutrality

HIR operations describe semantic creation and identity, not physical allocation.

```txt
create_object
create_array
create_closure
create_class
construct
create_regexp
```

The operations above do **not** imply:

```txt
heap allocation
stack allocation
arena allocation
reference counting
garbage collection
object headers
rooting
write barriers
```

A HIR consumer may interpret, lower or analyze those operations without adopting any particular memory model.

---

## 3. Design basis

The design deliberately combines established compiler patterns rather than copying one compiler wholesale:

| Source | Adopted lesson | ViZG decision |
|---|---|---|
| Rust HIR/THIR/MIR | Desugar syntax before a lower optimization IR and keep representation decisions outside HIR. | HIR preserves language semantics; independent consumers own any lower representation. |
| A-Normal Form | Name non-trivial intermediate results and make evaluation order explicit. | HIR instructions consume constants or `ValueId` operands; nested effectful expressions are flattened. |
| GCC GIMPLE | Small operations and explicit control flow simplify later analyses. | Structured control statements disappear into blocks and terminators. |
| Swift SIL | Separate mandatory canonicalization from optional performance optimization. | Every HIR result passes required canonicalization; optimize mode does not change canonical HIR semantics. |
| MLIR legalization/canonicalization | Define legal operations, reject illegal survivors, and use bounded convergent rewrites. | Lowering must eliminate every AST-only form; canonicalization is local, deterministic and budgeted. |
| SSA literature | SSA is powerful for global data-flow optimization. | Full SSA is outside ViZG; only immutable temporary values and block parameters exist in HIR. |

Primary references are listed at the end of this document.

---

## 4. Canonicality rule

The central rule is:

> Source constructs with the same runtime semantics must converge to the same legal HIR shape.

Examples:

```txt
IfStatement                 → branch + blocks
ConditionalExpression       → branch + merge block parameter
SwitchStatement             → ordered strict-equality dispatch blocks
While / DoWhile / For       → blocks + branch + jump
Break / Continue / labels   → resolved jumps
ArrowFunction               → canonical function entity
As / Satisfies / NonNull    → erased executable wrapper
CompoundAssignment          → evaluate place once + load + op + store
OptionalChain               → nullish branch + merge
LogicalAnd / Or / Nullish   → short-circuit branch + merge
```

The HIR graph must never contain both a surface form and its canonical equivalent.

---

## 5. Non-negotiable semantic preservation

Every lowering rule must preserve:

```txt
left-to-right evaluation order
single evaluation of source subexpressions
short-circuit behavior
strict versus coercive equality
truthiness versus nullish testing
method receiver and `this` binding
`super` behavior
object identity
getter, setter and proxy observability
TDZ and hoisting behavior
fallthrough
break and continue targets
iterator acquisition and closing
exception propagation and finally execution
suspension points
module initialization dependencies
live import/export bindings
source-level provenance
```

A smaller graph is not valid if it changes any observable behavior.

---

## 6. Ownership and lifetime

HIR v1 is an immutable owned result with project-local identity domains.

```txt
project creates semantic result
→ project derives HIR result
→ verification succeeds
→ HIR seals owned type, provenance and string storage
→ host-assigned ModuleId, SemanticDeclId and TypeId remain project-context-local
→ semantic/project storage may be destroyed
→ the owning HirResult remains valid until its explicit destruction
```

`HirResult` owns all allocations created by lowering plus a sealed read-only
type snapshot and has explicit deinitialization. Project/session and public ABI
results may own it, but semantic storage is not required after sealing. After
successful construction, consumers receive immutable views only. Failed
construction frees internal allocations and exposes no partial public result.

HIR v1 does not define an independently serializable binary format. A future serialized HIR must introduce explicit stable identities and versioning rather than exposing context-local `TypeId` values as portable global IDs.

The project-input C ABI v1 remains unchanged. HIR exposure is an additive,
separately versioned public contract: opaque `Vizg_ProjectResult` ownership,
version negotiation, deterministic summary/record iteration, and borrowed
strings whose lifetime is the result lifetime. Unsupported versions and
invalid or foreign IDs fail in a controlled way. Serialization remains
explicitly outside HIR v1.

### Consumer surface

The official immutable consumer surface provides deterministic iteration and
checked lookup for modules, external declarations, functions, blocks,
instructions, bindings, types, effects, and source origins. All IDs are scoped
to one `HirResult`; consumers must not compare them across results. A consumer
requires no AST, binder, checker, or mutable project state.

### Stable external declarations

Host-supplied `ExternalSymbolId` is the canonical identity of an external
declaration and is independent of descriptor order. External module,
declaration, semantic, and HIR identity domains remain distinct. Declarations
record function/global/constant/type kind, complete function parameter and
result types where applicable, conservative effects, and provenance. They have
no fabricated HIR body and carry no target, calling-convention, layout,
link-name, runtime, or backend metadata.

---

## 7. Identity model

Recommended opaque integer handles:

```zig
pub const EntityId = u32;
pub const FunctionId = u32;
pub const BlockId = u32;
pub const InstructionId = u32;
pub const ValueId = u32;
pub const BindingId = u32;
pub const PlaceId = u32;
pub const RegionId = u32;
pub const OriginId = u32;
```

Existing identities are reused within their owning project context:

```txt
ModuleId
SemanticDeclId / resolved SymbolId when applicable
TypeId
AST NodeId, only through provenance metadata
```

No path or logical name may substitute for `ModuleId`.

---

## 8. Project-level structure

The target structure is conceptual; exact Zig field packing is an implementation detail.

```zig
pub const HirProject = struct {
    version: u32,
    modules: []const HirModule,
    entities: []const HirEntity,
    functions: []const HirFunction,
    constants: []const HirConstant,
    regions: []const HirRegion,
    origins: OriginTable,
    lowering_trace: ?LoweringTrace,
};

pub const HirModule = struct {
    module_id: ModuleId,
    logical_name: []const u8,
    initialization: FunctionId,
    dependencies: []const HirModuleDependency,
    imports: []const HirImportBinding,
    exports: []const HirExportBinding,
    entities: []const EntityId,
    origin: OriginId,
};
```

Every source module has one canonical module-initialization function. Top-level executable declarations and initializers lower into that function in required source/module order.

Static imports and exports are module metadata and binding links, not ordinary executable statements. Side-effect imports contribute initialization dependencies. Dynamic `import()` remains an executable HIR operation.

---

## 9. Entity structure

An entity is a project-level semantic declaration that should not be duplicated as statement syntax.

```zig
pub const HirEntity = union(enum) {
    function: HirFunctionEntity,
    class: HirClassEntity,
    enum_object: HirEnumEntity,
    module_binding: HirModuleBindingEntity,
};
```

Type-only declarations do not produce executable entities:

```txt
type aliases
interfaces
type parameters
type-only imports and exports
```

Their semantic information remains available through the semantic result and optional provenance metadata.

---

## 10. Function structure

All executable function-like syntax lowers to one canonical function representation:

```txt
function declaration
function expression
arrow function
object method
class method
constructor
getter
setter
async function
generator
async generator
```

Recommended structure:

```zig
pub const HirFunction = struct {
    id: FunctionId,
    module_id: ModuleId,
    symbol: ?SemanticDeclId,
    kind: HirFunctionKind,
    flags: HirFunctionFlags,
    signature_type: TypeId,
    parameters: []const HirParameter,
    bindings: []const HirBinding,
    captures: []const HirCapture,
    blocks: []const HirBlock,
    entry: BlockId,
    regions: []const RegionId,
    origin: OriginId,
};
```

Function flags carry semantics that cannot be erased:

```txt
lexical_this
dynamic_this
constructor
getter
setter
async
generator
async_generator
uses_super
uses_new_target
```

Arrow syntax disappears, but lexical `this`, lexical `arguments`, `super`, and `new.target` behavior remains when applicable.

---

## 11. Values, bindings and places

HIR uses a hybrid model:

```txt
ValueId     immutable temporary result, defined exactly once
BindingId   mutable language binding with scope/TDZ/hoisting semantics
PlaceId     evaluated assignable reference; not a physical address
```

This is intentionally **not** full SSA.

### Values

Non-trivial expressions produce `ValueId` results. Instruction operands must already be values, constants, bindings or places allowed by the operation.

### Bindings

Bindings preserve language-level storage semantics:

```txt
var    created and initialized according to var hoisting rules
let    created uninitialized and subject to TDZ
const  created uninitialized and initialized once
param  initialized from the call parameter plan
import live binding linked to another module
catch  initialized on catch entry
```

### Places

A `PlaceId` ensures that assignment targets are evaluated once:

```txt
binding place
property place(base, static_key)
element place(base, computed_key)
super property place(receiver, key)
```

A place is a semantic lvalue reference. It does not imply a memory address, pointer, stack slot or heap location.

Canonical operations:

```txt
make_binding_place
make_property_place
make_element_place
make_super_place
load_place
store_place
delete_place
```

---

## 12. Basic blocks

```zig
pub const HirBlock = struct {
    id: BlockId,
    parameters: []const HirBlockParameter,
    instructions: []const HirInstruction,
    terminator: HirTerminator,
    origin: OriginId,
};
```

Block parameters merge temporary expression values without promoting mutable program bindings to global SSA.

Legal terminators:

```txt
jump target(arguments...)
branch condition, true_target, false_target
return optional_value
throw value
unreachable
leave_region completion, target
resume_completion
```

`leave_region` and `resume_completion` exist to preserve abrupt completion through `finally` without duplicating the cleanup body in HIR.

No block may omit a terminator.

---

## 13. Instruction form

```zig
pub const HirInstruction = struct {
    id: InstructionId,
    result: ?ValueId,
    result_type: ?TypeId,
    operation: HirOperation,
    effects: EffectSet,
    origin: OriginId,
};
```

The operation set is language-semantic and target-independent.

### Core operation families

| Family | Representative operations |
|---|---|
| Values | `constant`, `copy`, `load_binding`, `load_this`, `load_super`, `load_meta` |
| Places | `make_binding_place`, `make_property_place`, `make_element_place`, `load_place`, `store_place`, `delete_place` |
| Tests/conversions | `to_boolean`, `is_nullish`, `typeof_value`, `void_value` |
| Arithmetic | `add`, `subtract`, `multiply`, `divide`, `remainder`, `exponentiate` |
| Bitwise | `bit_and`, `bit_or`, `bit_xor`, `shift_left`, `shift_right`, `shift_right_unsigned` |
| Comparison | `less`, `less_equal`, `greater`, `greater_equal`, `equal_loose`, `equal_strict`, `not_equal_loose`, `not_equal_strict`, `in`, `instanceof` |
| Calls | `call`, `call_method`, `construct`, `tagged_template_call`, `dynamic_import` |
| Identity creation | `create_object`, `create_array`, `create_closure`, `create_class`, `create_enum_object`, `create_regexp`, `create_template_site` |
| Aggregate mutation | `define_property`, `define_method`, `copy_object_properties`, `array_append`, `array_append_hole`, `array_append_iterable` |
| Strings | `build_string`, `to_string` |
| Iteration | `enumerate_properties`, `enumerator_next`, `enumerator_done`, `enumerator_value`, `get_iterator`, `get_async_iterator`, `iterator_next`, `iterator_done`, `iterator_value`, `iterator_close` |
| Functions | `collect_rest_arguments`, `read_argument`, `create_arguments_object` when required |
| Suspension | `await`, `yield`, `yield_delegate` |
| Debug | `debugger_trap` |

Exact operator modes may be encoded as operation payloads. For example, `add` carries the semantic mode established by typed semantics:

```txt
numeric
string_concat
dynamic
```

HIR must not invent a target representation such as `i32.add` or `f64.add` unless that representation is already a language-semantic fact rather than a backend choice.

---

## 14. Effect classification

Every operation has a conservative language-level effect set.

```zig
pub const EffectSet = packed struct {
    pure: bool,
    may_throw: bool,
    may_call_user_code: bool,
    reads_state: bool,
    writes_state: bool,
    may_suspend: bool,
    creates_identity: bool,
};
```

This classification supports safe canonicalization and analysis.

It deliberately contains no memory-management fields such as `may_gc`, `requires_safepoint`, `heap_value`, `root` or `write_barrier`.

Property access, element access, conversions, comparisons, calls and iteration must be treated conservatively because getters, proxies and coercion hooks can execute user code or throw.

---

## 15. Textual HIR notation

The printer uses a stable textual form for tests and debugging. It is not the in-memory representation.

```txt
module @42 "src/main.ts" {
  import live @value from module @7 export "value"
  export "result" = binding @result

  func @module_init() -> void {
  bb0:
    %0 = constant 1 : number
    store_binding @result, %0
    return
  }
}
```

Conventions:

```txt
@name       entity, function or binding identity
%number     temporary ValueId
bbN         BlockId
placeN      PlaceId when printed explicitly
: Type      semantic TypeId debug rendering
!origin(N)  optional provenance annotation
```

Printer output must be deterministic for the same immutable project result.

---

## 16. TypeScript → HIR examples

The examples are normative shapes, not exact final printer syntax.

### 16.1 ANF expression order

TypeScript:

```ts
const result = foo(a(), b() + 1);
```

HIR:

```txt
bb0:
  %0 = call @a() : Ta
  %1 = call @b() : number
  %2 = add.numeric %1, 1 : number
  %3 = call @foo(%0, %2) : TResult
  store_binding @result, %3
  return
```

`a()` is evaluated before `b()`, and both are evaluated before `foo`.

### 16.2 Type erasure

TypeScript:

```ts
interface Named { name: string }
type Id = string | number;
const value = input as Named;
const checked = input satisfies Named;
const nonNull = maybe!;
```

HIR:

```txt
%0 = load_binding @input
store_binding @value, %0

%1 = load_binding @input
store_binding @checked, %1

%2 = load_binding @maybe
store_binding @nonNull, %2
```

The assertions remain available as origin/type metadata when full debug information is enabled.

### 16.3 Conditional expression

TypeScript:

```ts
const result = cond ? left() : right();
```

HIR:

```txt
bb0:
  %0 = load_binding @cond
  %1 = to_boolean %0
  branch %1, bb1, bb2

bb1:
  %2 = call @left()
  jump bb3(%2)

bb2:
  %3 = call @right()
  jump bb3(%3)

bb3(%4: TResult):
  store_binding @result, %4
  return
```

There is no `ConditionalExpression` operation in legal HIR.

### 16.4 `if`

TypeScript:

```ts
if (cond) {
    yes();
} else {
    no();
}
```

HIR:

```txt
bb0:
  %0 = load_binding @cond
  %1 = to_boolean %0
  branch %1, bb1, bb2

bb1:
  %2 = call @yes()
  jump bb3

bb2:
  %3 = call @no()
  jump bb3

bb3:
  return
```

### 16.5 Compound assignment with a computed target

TypeScript:

```ts
object[index()] += value();
```

HIR:

```txt
%0 = load_binding @object
%1 = call @index()
place0 = make_element_place %0, %1
%2 = load_place place0
%3 = call @value()
%4 = add.dynamic %2, %3
store_place place0, %4
```

The base and index are evaluated once.

### 16.6 Prefix and postfix update

TypeScript:

```ts
const old = counter++;
const next = ++counter;
```

HIR:

```txt
place0 = make_binding_place @counter
%0 = load_place place0
%1 = add.numeric %0, 1
store_place place0, %1
store_binding @old, %0

place1 = make_binding_place @counter
%2 = load_place place1
%3 = add.numeric %2, 1
store_place place1, %3
store_binding @next, %3
```

### 16.7 Logical short circuit

TypeScript:

```ts
const result = left && right();
```

HIR:

```txt
%0 = load_binding @left
%1 = to_boolean %0
branch %1, bb_right, bb_merge_left

bb_right:
  %2 = call @right()
  jump bb_merge(%2)

bb_merge_left:
  jump bb_merge(%0)

bb_merge(%3):
  store_binding @result, %3
```

`||` uses the inverse truthiness branch. `??` uses `is_nullish`, not `to_boolean`.

### 16.8 Optional member and method call

TypeScript:

```ts
const result = service?.handler();
```

HIR:

```txt
%0 = load_binding @service
%1 = is_nullish %0
branch %1, bb_null, bb_call

bb_null:
  jump bb_merge(undefined)

bb_call:
  %2 = call_method %0, "handler", []
  jump bb_merge(%2)

bb_merge(%3):
  store_binding @result, %3
```

The method receiver remains `%0`; lowering to `call(get_property(...))` would lose `this` semantics.

### 16.9 `switch`

TypeScript:

```ts
switch (getValue()) {
    case first():
        a();
    case second():
        b();
        break;
    default:
        c();
}
```

HIR:

```txt
bb0:
  %0 = call @getValue()
  jump bb_test_0

bb_test_0:
  %1 = call @first()
  %2 = equal_strict %0, %1
  branch %2, bb_case_0, bb_test_1

bb_test_1:
  %3 = call @second()
  %4 = equal_strict %0, %3
  branch %4, bb_case_1, bb_default

bb_case_0:
  %5 = call @a()
  jump bb_case_1

bb_case_1:
  %6 = call @b()
  jump bb_exit

bb_default:
  %7 = call @c()
  jump bb_exit

bb_exit:
  return
```

The discriminant is evaluated once, case expressions are evaluated in source order, and fallthrough is represented by edges.

### 16.10 Classic `for`

TypeScript:

```ts
for (init(); test(); step()) {
    body();
}
```

HIR:

```txt
bb0:
  %0 = call @init()
  jump bb_condition

bb_condition:
  %1 = call @test()
  %2 = to_boolean %1
  branch %2, bb_body, bb_exit

bb_body:
  %3 = call @body()
  jump bb_update

bb_update:
  %4 = call @step()
  jump bb_condition

bb_exit:
  return
```

A `continue` in the body targets `bb_update`.

### 16.11 `for...of`

TypeScript:

```ts
for (const value of iterable) {
    consume(value);
}
```

HIR:

```txt
%0 = load_binding @iterable
%1 = get_iterator %0
jump bb_next

bb_next:
  %2 = iterator_next %1
  %3 = iterator_done %2
  branch %3, bb_exit, bb_value

bb_value:
  %4 = iterator_value %2
  store_binding @value, %4
  %5 = call @consume(%4)
  jump bb_next

bb_exit:
  return
```

Normal iterator exhaustion does not invoke abrupt-close behavior. `break`, `return`, `throw`, or another abrupt exit from the loop must route through an iterator-close cleanup region when the ECMAScript protocol requires it. A downstream consumer decides how the iterator protocol is implemented.

### 16.12 Object and array literals

TypeScript:

```ts
const object = {
    a: first(),
    [key()]: second(),
    ...source,
};

const array = [head, , ...tail];
```

HIR:

```txt
%0 = create_object
%1 = call @first()
define_property %0, "a", %1
%2 = call @key()
%3 = call @second()
define_property %0, %2, %3
%4 = load_binding @source
copy_object_properties %0, %4
store_binding @object, %0

%5 = create_array
%6 = load_binding @head
array_append %5, %6
array_append_hole %5
%7 = load_binding @tail
array_append_iterable %5, %7
store_binding @array, %5
```

An array hole is not equivalent to an explicit `undefined` element.

Object members lower in source order. Computed data properties evaluate their
key before their value; methods and accessors use their distinct definition
operations; object spread copies enumerable properties at its source position.
Array spread is iterable spread, while call spread remains an explicitly tagged
call argument rather than an array operation.

Untagged templates convert substitutions in order and then build the string.
Tagged templates preserve the tag receiver, one stable source-site identity,
and copied raw/optional-cooked segments; the template site is created before
substitutions evaluate. Each regexp evaluation creates a fresh value from its
pattern, canonical flags, and stable source-site identity. Full per-instruction
source provenance remains the Goal 227 layer.

### 16.13 Functions and default/rest parameters

TypeScript:

```ts
const fn = (value = makeValue(), ...rest) => use(value, rest);
```

HIR shape:

```txt
function @fn flags[lexical_this] parameters[value, rest] {
entry:
  %0 = read_argument 0
  %1 = equal_strict %0, undefined
  branch %1, bb_default, bb_present

bb_default:
  %2 = call @makeValue()
  jump bb_value(%2)

bb_present:
  jump bb_value(%0)

bb_value(%3):
  store_binding @value, %3
  %4 = collect_rest_arguments 1
  store_binding @rest, %4
  %5 = call @use(%3, %4)
  return %5
}
```

The default initializer executes per call, not at closure creation time.
Parameters initialize strictly from left to right. Optional markers erase,
rest collection begins at the parameter's ordinary argument index, and
parameter-property metadata is retained only as a handoff to class instance
initialization.

All function-like forms use this same body representation. Arrow functions
retain lexical receiver behavior through flags and explicit captures; ordinary
functions retain dynamic receiver behavior. Captures refer only to resolved
semantic bindings or lexical `this`, `arguments`, `super`, and `new.target`.
HIR records live-versus-lexical capture mode but deliberately leaves closure
environment layout to later layers.

### 16.14 Classes

TypeScript:

```ts
class Child extends Base {
    value = makeValue();
    method(arg: number) { return use(this.value, arg); }
}
```

HIR shape:

```txt
class @Child {
  base_expression: <lowered in module initialization>
  constructor: @Child.constructor
  instance_initializers: @Child.instance_init
  methods: ["method" => @Child.method]
}
```

The class remains a semantic entity. HIR does not choose prototype layout, object layout, method tables or allocation strategy.

### 16.15 `try` / `finally`

TypeScript:

```ts
try {
    work();
    return result;
} finally {
    cleanup();
}
```

HIR shape:

```txt
region r0 finally bb_finally continuation bb_after

bb_try:
  %0 = call @work()
  %1 = load_binding @result
  leave_region return(%1), bb_finally

bb_finally:
  %2 = call @cleanup()
  resume_completion
```

HIR does not duplicate `cleanup()` at every abrupt exit. MIR/runtime chooses the final exception and cleanup implementation.

### 16.16 Async and generator operations

TypeScript:

```ts
async function load() {
    return await fetchValue();
}

function* values() {
    yield first;
    yield* rest;
}
```

HIR retains semantic suspension operations:

```txt
%0 = call @fetchValue()
%1 = await %0
return %1

%2 = load_binding @first
yield %2
%3 = load_binding @rest
yield_delegate %3
return
```

State-machine construction is a downstream-consumer responsibility.

### 16.17 Imports and exports

TypeScript:

```ts
import { value as local } from "dep";
import "side-effect";
export { local as result };
```

HIR module metadata:

```txt
dependency module @dep, initialization_required
import live binding @local = module @dep export "value"
dependency module @side_effect, initialization_required
export "result" = binding @local
```

No specifier resolution occurs in HIR.

### 16.18 Future pipeline operator

The current parser deliberately rejects `|>`. HIR v1 must not accept an unsupported AST node.

When a pipeline syntax is formally introduced, it should not require a new runtime HIR operation if its semantics are reducible to calls.

For a simple F#-style contract:

```ts
source |> transform
```

future lowering would be:

```txt
%0 = lower source
%1 = lower transform
%2 = call %1(%0)
```

Before implementation, the language feature must define placeholder syntax, receiver behavior, argument insertion, async interaction and exact evaluation order. The matrix reserves the reduction but does not authorize the frontend feature.

---

## 17. Exceptions and abrupt completion

`try`, `catch` and `finally` cannot be reduced to ordinary conditionals.

HIR uses explicit exception/cleanup regions and completion kinds:

```txt
normal
return(value?)
throw(value)
break(target)
continue(target)
```

A `finally` region receives and resumes the pending completion unless its own body replaces that completion by returning, throwing, breaking or continuing.

The verifier must ensure:

```txt
protected blocks belong to one valid region nesting
catch parameters are initialized only on catch entry
leave_region targets the correct cleanup
resume_completion occurs only in a cleanup region
no jump illegally enters a protected region
```

---

## 18. Mandatory canonicalization

Mandatory canonicalization is part of producing legal HIR. It is not an optional optimize mode.

Allowed transformations:

```txt
erase type-only and syntax-only constructs
remove redundant copies
fold completely safe primitive literal operations
replace literal branches with jumps
remove unreachable blocks
merge trivial jump-only blocks when region boundaries allow it
remove unused instructions proven pure
collapse identical temporary merge inputs
normalize empty returns
normalize function-like forms
normalize all assignment targets through places
```

Requirements:

```txt
local or cheaply bounded
semantics preserving
deterministic
convergent
worklist driven
rewrite-budget protected
origin preserving
```

Legalization may never stop with an illegal AST operation because a budget was exhausted. Rewrite budgets apply only after every operation is legal.

---

## 19. Optimizations forbidden in HIR v1

These transformations are outside ViZG even when they appear attractive:

```txt
full SSA conversion
mem2reg
phi insertion for mutable source bindings
SCCP and global constant propagation
global copy propagation
global DCE
CSE, GVN and PRE
LICM and code motion
loop unrolling
function inlining
tail-call optimization
devirtualization
interprocedural analysis
union splitting
monomorphization
numeric unboxing
property access specialization
object shape specialization
escape analysis
scalar replacement
closure environment layout
object/class layout
async/generator state-machine construction
exception ABI lowering
memory management or lifetime strategy
backend- or target-specific intrinsics
```

The HIR printer and snapshots should remain stable whether ViZG itself was built in Debug, ReleaseSafe, ReleaseFast or ReleaseSmall.

---

## 20. Debug and provenance

Executable HIR stays compact. Debug data lives in side tables.

```zig
pub const OriginRecord = struct {
    module_id: ModuleId,
    primary_span: Span,
    ast_nodes: []const NodeId,
    original_syntax: SyntaxKind,
    symbol: ?SemanticDeclId,
    type_id: ?TypeId,
    parent: ?OriginId,
    lowering_rule: LoweringRule,
    synthetic_reason: ?SyntheticReason,
};
```

Supported debug levels:

```txt
none
minimal
full
```

`minimal` preserves primary span, module, principal AST node, symbol and type where applicable.

`full` additionally records lowering events:

```txt
switch_to_dispatch
conditional_to_branch
logical_and_to_branch
optional_chain_to_nullish_branch
compound_assignment_to_place_load_store
arrow_to_function
interface_erased
constant_folded
unreachable_removed
blocks_merged
```

A transformed instruction may reference multiple origins. An erased source node may remain represented by a trace event without occupying executable HIR.

---

## 21. Eligibility contract

HIR lowering accepts only modules that are semantically complete and lowering-safe.

Reject lowering when any reachable source module has:

```txt
blocking scanner/parser/binder/resolver/type/checker diagnostic
unsupported executable syntax
invalid or missing semantic identity
invalid TypeId or SymbolId reference
unresolved required source-module edge
partial result category that forbids execution
resource-limit outcome that makes semantic data incomplete
```

External modules supplied by the host may appear as typed external bindings, but ViZG must not invent executable bodies for them.

Lowering failure uses reserved `VZG7xxx` diagnostics and never emits a partially valid public HIR result.

---

## 22. HIR verifier contract

A final HIR result is valid only when all checks pass.

### Structural checks

```txt
all IDs are in range and belong to the project
all blocks have exactly one terminator
all block targets exist in the same function
block argument arity and types match block parameters
ValueId is defined exactly once
ValueId use is dominated by its definition or supplied as a block parameter
PlaceId refers to valid already-evaluated operands
regions are properly nested
module/entity/function ownership ranges are valid
```

### Semantic checks

```txt
instruction operand/result types satisfy the operation contract
stores target writable places
const bindings initialize once
TDZ-sensitive reads are not introduced before source initialization
method calls preserve the receiver
construct operations use constructable semantic values
await appears only in async contexts
yield appears only in generator contexts
super operations appear only in legal class contexts
return values match the function contract established by semantics
no AST-only or type-only operation remains
no unsupported syntax reaches HIR
```

### Canonical checks

```txt
no structured if/switch/loop node remains
no arrow/function-expression distinction remains
no compound assignment or update node remains
no optional chain or short-circuit operator remains
no executable type assertion remains
no trivial illegal copy/jump pattern forbidden by canonical form remains
```

Verification runs after raw lowering and again after mandatory canonicalization.

---

## 23. Diagnostics

The `VZG7xxx` range is reserved for HIR/lowering.

Recommended initial allocation:

| Code | Meaning |
|---|---|
| `VZG7001` | module is not eligible for HIR lowering |
| `VZG7002` | unsupported executable syntax reached lowering |
| `VZG7003` | missing semantic identity required by lowering |
| `VZG7004` | invalid type or symbol reference in lowering input |
| `VZG7005` | illegal HIR operation survived legalization |
| `VZG7006` | invalid HIR control-flow graph |
| `VZG7007` | invalid HIR value, binding or place use |
| `VZG7008` | invalid exception or cleanup region |
| `VZG7009` | canonicalization did not converge within the allowed budget |
| `VZG7010` | HIR resource limit reached |
| `VZG7011` | internal lowering invariant failed |

Internal invariant failures must be diagnosable during debug/testing, but public APIs must return controlled failures rather than exposing undefined behavior.

---

## 24. Resource limits

HIR introduces bounded project resources independent of target or runtime:

```txt
maximum HIR entities
maximum functions
maximum blocks per function/project
maximum instructions
maximum values
maximum bindings
maximum places
maximum region nesting
maximum origin records
maximum lowering trace events
maximum canonicalization rewrites
```

Pre-growth checks must occur before allocation or insertion. Limit outcomes must use one canonical limit kind in summaries and diagnostics.

These limits protect the frontend; they are unrelated to runtime memory management.

---

## 25. Testing contract

Each lowering rule requires:

```txt
positive source fixture
expected canonical textual HIR snapshot
source-order/effect assertion where relevant
origin/span assertion
negative eligibility fixture when applicable
verifier corruption test for the produced operation family
```

Cross-cutting tests must cover:

```txt
nested short circuit and optional chains
side-effectful switch case expressions
labeled nested loops
break/continue through finally
iterator closing on abrupt completion
method calls after optional access
class field initialization order
module cycles and live bindings
async/generator suspension placement
very deep and very wide source within configured limits
deterministic output across repeated runs
```

The lowering matrix in `hir-v1-lowering-matrix.md` is the coverage checklist. Every row must be marked implemented, deliberately erased, deliberately unsupported, or deferred with a blocking reason.

---

## 26. Stable contract summary

```txt
HIR v1 is typed, ANF-like and block-based.

Temporary values are immutable.
Source bindings remain explicit and mutable.
Expression merges use block parameters.
Structured control syntax is eliminated.
Language-semantic operations remain target-independent.
Only mandatory local canonicalization runs in ViZG.
Full SSA and global optimization are outside ViZG.
Memory management is outside ViZG.
Debug provenance is optional side-table data.
Only verified immutable HIR is exposed to consumers.
```

---

## 27. References

- Rust Compiler Development Guide, “The HIR” and “Lowering AST to HIR”: <https://rustc-dev-guide.rust-lang.org/hir.html>
- Rust Compiler Development Guide, “The THIR”: <https://rustc-dev-guide.rust-lang.org/thir.html>
- Rust Compiler Development Guide, “MIR optimizations”: <https://rustc-dev-guide.rust-lang.org/mir/optimizations.html>
- Swift compiler documentation, “Swift Intermediate Language (SIL)”: <https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md>
- GCC Internals, “Tree SSA” and GIMPLE: <https://gcc.gnu.org/onlinedocs/gccint/Tree-SSA.html>
- Flanagan, Sabry, Duba, Felleisen, “The Essence of Compiling with Continuations” (ANF): <https://users.soe.ucsc.edu/~cormac/papers/pldi93.pdf>
- MLIR, “Dialect Conversion”: <https://mlir.llvm.org/docs/DialectConversion/>
- MLIR, “Operation Canonicalization”: <https://mlir.llvm.org/docs/Canonicalization/>
- Cytron et al., “Efficiently Computing Static Single Assignment Form and the Control Dependence Graph”: <https://dl.acm.org/doi/10.1145/75277.75280>
- Wegman and Zadeck, “Constant Propagation with Conditional Branches”: <https://dl.acm.org/doi/10.1145/103135.103136>
