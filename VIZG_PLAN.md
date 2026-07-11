# VIZG Development Plan (Phase 2+)

*Created: 2026-07-10 — Informed by V8 engine architecture, JavaScriptCore Inspector protocol, TypeScript compiler design.*

## Architecture Reference

### V8 Engine Pipeline (Reference)

V8's compilation phases map cleanly to vizg's planned layers:

| V8 Phase | Purpose | Vizg Equivalent | Status |
|----------|---------|-----------------|--------|
| `Lexer` | Tokenize source text | `src/frontend/scanner.zig` | ✅ Implemented |
| `Parser` | Produce AST with spans | `src/frontend/parser.zig` | ✅ Implemented |
| `ScopeAnalyzer::Analyze()` | Determine bindings, hoisting, strict mode | `src/frontend/binder.zig` | ✅ Partially implemented (parameter scoping done; function-declaration hoisting and strict-mode resolution pending) |
| `TypeSpecialization` | Forward-infer types on AST → typed AST, then fixpoint iterate to stabilize circular references | `src/semantics/inference.zig` (forwardInfer stubbed) + new checker v2 | ⚠️ Partially implemented: forward pass classifies literals only; CallExpression classification is `_ = call; // unresolved stub` |
| `BytecodeGenerator` (Ignition) | Lower typed AST into compact bytecode form with normalized control flow and constants pool | New `src/hir/` layer | ❌ Not started — planned Phase 2 |
| `MacroAssembler` / TurboFan | Optimize bytecode into SSA IR → machine code | Future runtime/compiler backend | ❌ Not started (future) |

**Key V8 insight:** Scope analysis *precedes* type specialization. Vizg's binder already performs scope analysis; the next layer adds TypeSpecialization (forward classify → fixpoint → validate). This ordering matters: types are only reliable after bindings are resolved.

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
- Types model with `TypeId` enum (primitives + function signatures), `FunctionSignatureStore`, builtin kinds
- Semantics layer: v1 checker (literal RHS only), partial forward inference (stub for CallExpression classification)

### Key Files & Their Current State

| File | Lines | What It Does | Completeness |
|------|-------|-------------|--------------|
| `src/frontend/scanner.zig` | Scanner | Tokenizer with spans and diagnostics | ✅ Complete |
| `src/frontend/parser.zig` | Parser | Recursive descent parser | ✅ Complete (subset) |
| `src/frontend/binder.zig` | Binder | Scopes, symbols, imports/exports | ✅ Partial (hoisting + strict mode pending) |
| `src/frontend/resolver.zig` | Resolver | Identifier reference resolution | ✅ Complete |
| `src/frontend/cfg.zig` | CFG Builder | Basic blocks for function bodies | ✅ Complete (preliminary) |
| `src/semantics/checker.zig` | v1 Checker | Validates variable initializers and literal RHS assignments | ⚠️ ~60% — handles literals, has stub for call expressions (`lookupCallReturnTypeId`) |
| `src/semantics/inference.zig` | Forward Inference (V8-style) | Mirrors V8 TypeSpecialization: classify → fixpoint loop | ⚠️ ~40% — literal classification works; CallExpression classification is `_ = call; // unresolved stub` |
| `src/semantics/type_inference.zig` | Node-level Literal Inference | Walks AST, returns classified nodes slice | ✅ Complete for literals only |
| `src/modules/graph.zig` | Module Graph | Recursive analysis of local imports with cache | ✅ Partial — no package.json or node_modules lookup |
| `src/modules/resolver.zig` | Import Resolution | Relative path resolution + extension list | ⚠️ ~50% — relative imports work; external/package resolution stubbed |
| `src/modules/linker.zig` | Cross-file Linking | Named/default/namespace import linking to exports | ✅ Complete for local imports |
| `src/modules/externals.zig` | External Registry | Manual externals list (e.g., "node:fs", "lodash") | ⚠️ ~30% — manual registry only, no auto-detection from package.json |

### Diagnostic Code Ranges Currently Allocated

| Range | Phase | Status |
|-------|-------|--------|
| `VZG1xxx` | Scanner/lexer errors | ✅ Used (VZG1001–VZG1004) |
| `VZG2xxx` | Parser errors | ✅ Used (VZG2001–VZG2003) |
| `VZG3xxx` | Binder errors | ✅ Used (VZG3001–VZG3002) |
| `VZG4xxx` | Resolver errors | ✅ Used (VZG4001) |
| `VZG5xxx` | Module graph errors | ✅ Used (VZG5001–VZG5003) |
| `VZG6xxx` | Type checker semantic errors | 📌 Allocated, unused — Phase 1 will use these |
| `VZG7xxx` | HIR/lowering errors | 📌 Reserved for Phase 2 |
| `VZG8xxx` | Protocol-level errors | 📌 Reserved for Phase 4 |

---

## Phase 1: Type Checker v2 (Forward → Fixpoint)

### Purpose
Expand the type checker from literal-only RHS matching to full inference and semantic checking. Mirrors V8's `TypeSpecialization` architecture exactly: classify forward pass → fixpoint iteration on unresolved symbols → validate with a typed AST.

### Architecture — Direct V8 Mapping

```txt
V8: ScopeAnalyzer          → vizg: existing binder (complete)
V8: TypeSpecialization     → vizg: src/semantics/inference.zig (forwardInfer + fixpoint loop)
    ├── forward classify   →     walkDeclarations() + classifyInferred()
    ├── fixpoint iterate   →     retry unresolved until TypeInfoSnapshot stabilizes or N rounds hit
    └── typed AST output   →     TypeInfoSnapshot with symbol_ids and expr_types populated
V8: type guard insertion   →     not applicable (static analysis, no execution) but concept useful for future narrowing

vizg TypeChecker v2:       →     src/semantics/checker_v2.zig (new file)
    ├── checkFile          →     entry point replacing existing checkFile
    ├── isAssignable()     →     type compatibility validation
    ├── emit diagnostic    →     VZG6xxx codes
```

### Tasks

#### 1.1 Complete `src/semantics/inference.zig` — Fixpoint Iteration Framework

The file already has a working forward pass that classifies:
- Variable declarations with annotated types (`let x: number`)
- Function signatures (parameters + return type)
- Literal RHS values (number, string, boolean via `classifyLiteralValue()`)

**Missing:** CallExpression classification is `_ = call; // unresolved stub`. The framework for fixpoint iteration (`max_fixpoint_rounds = 10`, loop in `forwardInfer`) exists but the forward pass itself doesn't fill what fixpoint needs to retry.

**Work required:**
- Implement `classifyCallExpression()` that looks up callee name → finds function signature from binder → assigns return type
- Extend fixpoint loop: after first round, iterate while any symbol's `inferred_type` was updated in the previous round (up to `max_fixpoint_rounds`)
- Handle cross-import symbols: if a symbol is imported, look up its declaration in the linked module's forward inference result

#### 1.2 Create `src/semantics/checker_v2.zig` — Semantic Checker v2

This replaces the existing literal-only `checkFile()` with full semantic checking.

**Core types for isAssignable():**
```zig
fn isAssignable(from: TypeId, to: TypeId) bool
//   - exact TypeId match
//   - boolean-compatible-with-any-boolean (future: numeric subtypes)
//   - any/unknown assignable from/to anything
//   - function signatures: arity + parameter types + return type matching
```

**Three check paths:**

1. **Function call returns → assignment target** (`VZG6001` — type_mismatch):
   ```ts
   let x: number;
   x = getString();  // error: string is not assignable to number
   ```
   Walk each `VariableDeclarator.init`, check RHS expression type against LHS declared type via forward inference result.

2. **Object literal property validation** (`VZG6002` — unknown_type_name):
   ```ts
   let obj: { name: string; age: number };
   let o = { name: 42, age: "old" };  // error on each mismatched property
   ```
   Resolve member access from binder → match key type to declared object property type. Object types are represented in the AST as `ObjectLiteralExpression` (parser already handles); check property names + value types against any available annotation context (from prior typed assignments or interface definitions if those get added).

3. **Import-assigned variables** (`VZG6003` — unknown_type_name):
   ```ts
   import { X } from "./mod";
   let x = X;  // infer type from the imported symbol's declaration in mod.ts
   ```
   When a symbol is imported, forward inference should already classify it via the module graph link. The checker validates that the import target exists and its inferred type (from the source module's forward inference pass) matches what was declared as `X`'s declared type there.

#### 1.3 Extend existing `src/semantics/checker.zig` — Backward Compatibility

- Keep v1 `checkFile()` working for incremental adoption
- Add a `BuildOption.strict = false` flag (default true) that gates which checker runs
- The new `checker_v2.zig` becomes the default when strict mode is on

#### 1.4 Diagnostic Codes to Emit

| Code | Name | Message Pattern |
|------|------|-----------------|
| `VZG6005` (already exists) | `type_mismatch` | "cannot assign `<rhs_kind>` to declared `<expected_name>`" |
| `VZG6004` (already exists) | `unknown_type_name` | "unknown type name for imported symbol `<name>`" |

#### 1.5 Tests

- Add negative fixtures in `test/frontend/type_checks.ts`:
  - Function call returning wrong type assigned to variable with declared annotation → VZG6005
  - Object property value not matching declared property type → VZG6002 (or reuse VZG6005 as "type mismatch")
  - Import-assigned var where the imported name doesn't exist in target module → VZG6004
- Add positive fixture where everything matches
- Extend `src/semantics/checker.zig` tests to cover the new v2 path when strict mode enabled

### Files Changed (Phase 1)
| File | Action | Notes |
|------|--------|-------|
| `src/semantics/inference.zig` | Edit | Complete CallExpression classify, wire fixpoint loop fully |
| `src/semantics/checker_v2.zig` | New | Semantic checker entry point (replaces literal-only logic) |
| `src/semantics/checker.zig` | Edit | Add strict mode toggle; keep v1 as fallback |
| `test/frontend/type_checks.ts` | New | Fixture for type checking tests |
| `src/semantics/types_compat_test.zig` | New | Unit tests for `isAssignable()` |

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

## Phase 3: Module Graph Expansion — Package Lookup & package.json Resolution

### Purpose
Add proper external module semantics following Node.js resolution: `package.json` lookup, `node_modules` traversal, and subpath exports — so vizg can analyze projects with real dependency trees.

### Architecture — Direct V8/Node Mapping

V8 executes modules loaded through Node's resolver algorithm (inherited by JSC when running JS). Vizg mirrors this *resolution* phase only — it never executes the code:

```txt
V8/Node: Module._resolveFilename() → vizg: src/modules/resolver.zig extended
    ├── 1. relative specifier ("./foo")         → existing resolveRelative() ✅ already works
    ├── 2. package.json "main"/"module"/exports → NEW: read JSON from node_modules/<pkg>/package.json
    ├── 3. built-in node: protocol             → NEW: track as external, mark known
    └── 4. fallback to .ts/.js extension list → existing with extensions config ✅

Node resolution algorithm (simplified):
1. If specifier starts with "./" or "../": resolve relative path ✅ already implemented
2. Otherwise it's a package name:
   a. Walk up from source file dir looking for node_modules/<pkg>/package.json
   b. Read "main" field → entry point; if missing, use index.js/.ts
   c. If "exports" map present: match subpath (e.g., "./*": "./src/*.ts")
   d. If still not found after 3 levels up, mark as unresolved external
```

### Tasks

#### 3.1 Create `src/modules/package_json.zig` — Minimal JSON Parsing

Vizg only needs three fields: `"main"`, `"module"`, `"type"`. No full JSON parser required:

```zig
const PackageJson = struct {
    main: ?[]const u8,       // entry point filename (e.g., "index.ts")
    module: ?[]const u8,     // ESM entry point override
    @"type": []const u8,      // "commonjs" or "module" — affects import vs require semantics

    pub fn init(allocator: std.mem.Allocator, contents: []const u8) !PackageJson?
    //   - scan for known keys by substring search (avoid full parser)
    //   - return null if file doesn't exist or has no relevant fields
};
```

Cache parsed results per directory path to avoid repeated reads on module-graph traversal.

#### 3.2 Extend `src/modules/resolver.zig` — Package Lookup

Add a new resolution path after relative resolution fails:

```zig
// New method (returns resolved file path or marks as external)
pub fn resolveSpecifier(
    self: Resolver,
    from_path: []const u8,
    specifier: []const u8,
) !ResolvedImport {
    return if (isRelativeSpecifier(specifier)) .{
        // existing relative resolution path — already works
    } else {
        try lookupPackage(allocator, io, from_dir, specifier);
    };
}

fn lookupPackage(...) !?[]const u8
//   - walk up from `from_dir` looking for node_modules/<specifier>
//   - read package.json (max 5 levels deep — prevents DoS)
//   - apply "main" / "module" → "<dir>/<file>" or use "exports" map if present
```

#### 3.3 Extend `src/modules/loader.zig` — Package Integration

- After loading entry file, scan all imports for non-relative specifiers
- For each one, attempt package resolution via new resolver method
- Add resolved packages to the module graph with a new import edge status `.resolved_package` (distinguish from `.external` which means "not found")
- Existing `externals.zig` Registry handles manual externals; keep for backward compat

#### 3.4 Update Linker — External Handling

Distinguish three external states in `ImportEdge.status`:
```zig
pub const ImportStatus = enum {
    local,                    // resolved to a source file ✅ already exists
    @"package",               // NEW: resolved to npm package entry point (from package.json)
    external_known_builtin,   // e.g., "node:path" — known Node.js built-in
    external_unknown,         // truly unresolved import ❌ existing .external splits here
};
```

#### 3.5 CLI Flags — BuildOptions Extension

Add options to `loader.BuildOptions`:
- `--externals-dir <path>` — override where to look for node_modules (default: CWD + traverse up)
- `--modules-root <path>` — override modules search root
- These are stored in the loader but don't change resolver's core relative-path logic

### V8 Reference Mapping
- Node's `Module._resolveFilename()` algorithm → vizg's package resolver (direct mapping per step above)
- JSC's internal module loader uses similar resolution but with Webpack-style bundling awareness — useful if vizg ever needs to support bundle-aware analysis; out of scope for Phase 3

### Files Changed (Phase 3)
| File | Action | Notes |
|------|--------|-------|
| `src/modules/package_json.zig` | New | Parse package.json fields via substring search |
| `src/modules/resolver.zig` | Edit | Add resolveSpecifier() with package lookup fallback |
| `src/modules/loader.zig` | Edit | Scan imports, route through package resolution |
| `src/modules/graph.zig` | Edit | Handle new `.package` and `.external_known_builtin` import statuses |
| `src/main.zig` | Edit | Add --externals-dir / --modules-root CLI flags |

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

```
Phase 1 (type checker v2) — no phase dependencies; start here
├── Prereqs: existing types model, semantics type_info, diagnostics VZG6xxx codes
└── Parallelizable with Phase 3 (module graph expansion); both touch frontend but independently
│
Phase 3 (module graph expansion) — depends only on current module layer
├── Required: existing module graph, resolver, linker
└── Can run alongside Phase 1; no upstream dependencies on other phases
│
Phase 2 (HIR / lowering) — requires typed AST from Phase 1 to be meaningful
└── Deps on Phase 1 completed: HIR lowerer needs type info to annotate nodes properly
│
Phase 4 (inspector protocol) — depends on all three above; interfaces all layers via public APIs
├── Required: all phases above for anything useful to expose
└── Run last; exposes frontend results, type-checking output, and module graph as CDP-like messages
```

### Recommended Order (with rationale)

1. **Phase 3 first** (package lookup) — smallest work, unblocks Phase 4 protocol with real data
2. **Phase 1 second** (type checker v2) — critical layer; enables any backend to make type-aware decisions
3. **Phase 2 third** (HIR/lowering) — bridge to runtime or emission backends
4. **Phase 4 last** (inspector protocol) — requires stable public APIs from all previous phases

---

## Diagnostic Code Allocation Summary

| Range | Purpose | Allocated In Phase | Notes |
|-------|---------|-------------------|-------|
| `VZG6004` | unknown_type_name (type checker) | Phase 1 | Already exists as diagnostic code enum variant, unused |
| `VZG6005` | type_mismatch (type checker) | Phase 1 | Already emitted by v1 for literal mismatches; extended in v2 |
| `VZG7xxx` | HIR/lowering errors | Phase 2 | Reserved per roadmap |
| New VZG5xxx | package.json resolution failures | Phase 3 | Add: e.g., `VZG5004 module_not_found_package`, `VZG5005 invalid_package_json` |
| `VZG8xxx` | Protocol-level errors | Phase 4 | Reserved per roadmap; follow CDP negative-integer convention |

---

## Open Decisions / Risks

1. **Strict mode toggle vs opt-in checking**: TypeScript checks everything by default; vizg v1 defaults to minimal analysis. Recommend `--strict` flag (default on) that enables full type checking, HIR lowering, and package resolution — matches existing "check" command behavior while keeping existing CLI usage unchanged for backward compat.

2. **HIR representation choice**: Textual (human-readable) vs binary (compact). Start textual for inspection/debugging; binary format is optional later if performance matters for large programs or IDE integration latency concerns.

3. **Package.json parsing depth**: Minimal JSON parsing (string search for specific keys) vs full JSON decoder. Recommend minimal first since vizg only cares about `"main"`, `"module"`, `"type"` — a full parser adds complexity for marginal benefit at this stage; add one if subpath exports map gets needed later.

4. **Protocol transport**: stdio-first matches how `clangd` and `rust-analyzer` work (zero config, works with any editor). WebSocket fallback can be added later if needed for browser-remote analysis tools.

5. **ForwardInference + fixpoint split is correct but incomplete today**: The existing `inference.zig` already has the scaffolding (`forwardInfer`, `walkDeclarations`, `classifyInferred`). The CallExpression stub means fixpoint iteration has nothing to retry in most cases — fixing this is Phase 1's primary unblocking task.

---

## Non-Goals Until Explicitly Revisited

- Claiming full TypeScript or JavaScript support
- Running npm packages (only analysis, not execution)
- Acting as a browser or Node.js replacement
- Bundling packages (Phase 3 resolves but doesn't bundle)
- Emitting optimized native code from the current AST (future Phase 5+)
- Handling class members beyond what parser already accepts (out of scope for all phases)
- Hoisting, TDZ, or other runtime-order diagnostics (ScopeAnalyzer enhancement in binder is possible future work)
