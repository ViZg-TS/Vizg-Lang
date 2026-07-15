# VIZG Development Plan (Phase 2+)

*Created: 2026-07-10 — Informed by V8 engine architecture, JavaScriptCore Inspector protocol, TypeScript compiler design.*

> **Historical and non-executable.** This document is retained only as design
> context. Goals 189–207 closed the portable project API and official ABI v1.
> The unpublished prototype ABI was removed and receives no compatibility
> support. Goal 207 passed the repeated complete local gate matrix with no unresolved
> in-scope finding, froze ABI v1, and authorized HIR planning. See
> `docs/FINAL_AUDIT.md` for the current evidence.

## Architecture Reference

### V8 Engine Pipeline (Reference)

V8's compilation phases map cleanly to vizg's planned layers:

| V8 Phase | Purpose | Vizg Equivalent | Status |
|----------|---------|-----------------|--------|
| `Lexer` | Tokenize source text | `src/frontend/scanner.zig` | ✅ Implemented |
| `Parser` | Produce AST with spans | `src/frontend/parser.zig` | ✅ Implemented |
| `ScopeAnalyzer::Analyze()` | Determine bindings, hoisting, strict mode | `src/frontend/binder.zig` | ✅ Partially implemented (parameter scoping done; function-declaration hoisting and strict-mode resolution pending) |
| `TypeSpecialization` | Forward-infer types on AST → typed AST, then fixpoint iterate to stabilize circular references | Canonical pipeline in `src/semantics/type_collector.zig`, `type_inference.zig`, `dataflow.zig`, `narrowing.zig`, and `checker.zig` | ✅ Implemented for the supported syntax subset, including bounded project propagation |
| `BytecodeGenerator` (Ignition) | Lower typed AST into compact bytecode form with normalized control flow and constants pool | New `src/hir/` layer | ❌ Not started — planned Phase 2 |
| `MacroAssembler` / TurboFan | Optimize bytecode into SSA IR → machine code | Future runtime/compiler backend | ❌ Not started (future) |

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

## Phase 2: HIR / Lowering Layer

### Purpose
Bridge between frontend AST and any backend (emitter, interpreter, optimizer) by normalizing control flow and expression forms. Mirrors V8's Ignition bytecode generation — post-analysis, before execution/optimization.

### Architecture — Direct V8 Mapping

```txt
V8: TypedAST                → vizg: AST from frontend pipeline (with optional TypeChecker output)
V8: BytecodeGenerator        → vizg: src/hir/hir_builder.zig (lowering pass)
    ├── emit constants       →     fold literals into HIRConstants pool
    ├── normalize control    →     convert if/else → ternary, flatten loops to while-goto form
    └── SSA-like renaming    →     rename shadowed variables per basic block (SSA-lite)
V8: MacroAssembler           → vizg: future emitter layer (JavaScript? native?) — not in scope

HIR representation choice: textual over binary. Visual inspection is the use case,
not performance for execution — matches how TypeScript's --showConfig and other
analysis tools expose IRs for readability.
```

### Tasks

#### 2.1 Create `src/hir/hir_node.zig` — Compact IR Node Set

Keep only what any backend needs:
- Declarations (let/const/var with initializers)
- Assignments (`=` and compound `+=`, etc.)
- Calls (function + arguments, no parameter list inline)
- Member access (`.prop`) and element access (`[expr]`)
- Binary ops (all operators — needed for all computation)
- Conditions/branches (if/else → conditional branch to blocks)
- Loops (while/for → while-goto with condition block + loop back)
- Returns
- Block scopes (mirroring CFG basic blocks)

Drop: comments, import/export syntax sugar (moved to module layer), type annotations (already in types layer), AST node IDs mapped to HIR node indices.

```zig
pub const HirNodeKind = enum {
    declaration,        // let x = init;
    assignment,         // x = expr;
    call,               // foo(a, b);
    member_access,      // obj.prop
    element_access,     // arr[idx]
    binary_op,          // a + b
    conditional,        // if/else
    while_loop,         // while
    for_loop,           // for (init; cond; step) → lowered to while-goto form
    return_statement,   // return expr;
    block,              // group of sequential statements
};

pub const HirNode = struct {
    id: usize,
    kind: HirNodeKind,
    // Various field sets depending on `kind` — discriminated union.
};
```

#### 2.2 Create `src/hir/hir_builder.zig` — Lowering Pass

Walk AST and emit HIR nodes using existing CFG structure (from `cfg.zig`) as the basic block decomposition guide:
- Use CFG's already-built basic blocks to split long function bodies into manageable scopes
- Map each AST node to its HIR equivalent, preserving spans for diagnostics
- Handle expression statement stripping (`expr;` → pure side-effect call or discard result)

#### 2.3 Create `src/hir/normalization.zig` — Control Flow Normalization

- Hoist declarations out of conditional branches (C++ semantics: "declarations in a block are scoped to that block" — normalize to single-decl-at-function-entry + separate assignments in branches)
- Convert simple if-else with same LHS into ternary when both branches are pure expressions (`if(cond){a=1}else{a=2}` → `a = cond ? 1 : 2;`)
- Flatten nested loops — optional, keep simpler form for now

#### 2.4 CLI Integration — New Command

```sh
vizg hir <file>           # print HIR in readable textual form (like tsc --showConfig)
vizg hir --brief <file>   # single-line per statement
```

In `src/main.zig`: add new subcommand handler that calls into a new `print_hir` helper.

### V8 Reference Mapping
- Ignition bytecode → vizg HIR: both are post-analysis normalized forms
- Constants pool → could be extended to constant-fold literals in the HIR pass later
- TurboFan IR (SSA form) → optional future step if optimization is ever needed; not for Phase 2

### Files Changed (Phase 2)
| File | Action | Notes |
|------|--------|-------|
| `src/hir/hir_node.zig` | New | Compact IR node set, basic blocks mirroring CFG |
| `src/hir/hir_builder.zig` | New | Lower AST → HIR using existing CFG as guide |
| `src/hir/normalization.zig` | New | Control flow normalization (hoisting, ternary conversion) |
| `src/hir/print_hir.zig` | New | Human-readable textual representation |
| `src/main.zig` | Edit | Add `hir` subcommand |
| `docs/frontend-pipeline.md` | Edit | Document new HIR layer in pipeline diagram |

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
├── complete result ABI and runtime version query
├── harden host/WASM memory validation
├── make project updates transactional
├── enforce the one-shot bounded-memory lifecycle
├── preserve orthogonal module request metadata
├── close resource-limit and diagnostic accounting
├── isolate concrete host fixtures outside the product API
└── repeat the complete local audit and freeze ABI v1

HIR
└── planning authorized after Goal 207 passed every repeated local gate

Runtime module resolution
└── belongs to a separate runtime/consumer layer and is not a ViZG phase
```

### Required order

1. Goals 189–207 are complete and validated in strict sequence.
2. Official ABI v1 is frozen by the repeated clean Goal 207 audit.
3. HIR planning is authorized after that freeze.
4. Build filesystem/package/URL resolution in the runtime or consumer that
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
| `VZG7xxx` | HIR/lowering errors | Reserved; HIR not started |
| `VZG8xxx` | Future protocol errors | Reserved |

Module diagnostics describe the result of a host response or graph invariant.
They must not encode filesystem, package-manager, URL, or path-resolution policy.

---

## Open Decisions / Risks

1. **HIR representation:** choose the first HIR shape from the frozen Goal 207
   foundation. It must consume the stable semantic contract rather than
   compensate for ABI or module-provider defects.

2. **Future ABI extension:** semantic symbol/type queries may be added through
   additive versioned structures or explicit capability queries. Do not expose
   unstable internal `TypeId` values across independent contexts.

3. **Runtime provider design:** filesystem, package, URL, memory, and virtual
   module providers belong to the runtime/consumer. Their policies must not be
   copied into ViZG.

4. **Protocol transport:** any future inspector/LSP-like transport consumes the
   public project/result APIs. It must not bypass ownership or recreate module
   resolution inside the frontend.

5. **Singular semantic ownership:** future type-system work must extend the
   canonical collector, inference, dataflow, narrowing, checker, and project
   propagation pipeline. It must not restore a parallel `TypeStore` or inference
   result.

---

## Non-Goals Until Explicitly Revisited

- Resolving filesystem paths, URLs, packages, import maps, or `node_modules` in
  ViZG.
- Publishing a filesystem/provider implementation as part of the core or ABI.
- Claiming full TypeScript or JavaScript compatibility.
- Running or bundling imported modules.
- Acting as a browser, Node.js replacement, or package manager.
- Changing frozen ABI v1 structures, constants, lifecycle, or symbols from HIR
  work instead of introducing an explicitly versioned ABI.
- Emitting MIR, bytecode, objects, native code, or linking executables in this
  frontend repository.
- Restoring the removed prototype ABI or introducing compatibility shims for it.
