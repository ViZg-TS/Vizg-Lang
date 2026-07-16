# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

Maintain `Unreleased` for notable features, behavior changes, bug fixes, and removals. Individual commits do not require entries unless they materially affect the project.

## [Unreleased]

- Froze canonical HIR v1 after Goals 232–237 and the full native, cross-target,
  ABI, Android, and import-free WebAssembly matrix passed. The contract is
  identified by `hir-v1.0.0`; ViZG now enters contractual maintenance and
  post-HIR development moves downstream to VZed.
- Capped every source at the public `VIZG_MAX_SOURCE_LENGTH` (`UINT32_MAX`)
  representation boundary, rejecting oversized configuration and source
  descriptors before pointer access, copying, or scanning while keeping
  aggregate byte accounting overflow-safe.
- Made official ABI result summaries cover every canonical error phase with an
  explicit project-error flag and an `is_partial` OR across syntax, semantic,
  project, and module-host failures. Parser recursion now reports its own exact
  limit kind, and non-limit project calls clear the previous limit category.
- Enforced semantic-type and diagnostic limits from the first project module,
  bounded diagnostic collection before retained allocation, and made
  over-depth source responses transactional so rejected responses leave the
  pending request and graph unchanged.
- Moved external-module metadata into the project semantic graph before import
  and re-export propagation. External value/type identities now participate in
  the single bounded fixed point and reach the checker, so value-only names are
  rejected as types, combined class exports retain constructor/instance
  identities, and downstream external re-exports preserve canonical `TypeId`s.
- Froze official ABI v1 only after the repeated Goal 207 audit closed Goals
  203–206, fixed the newly found oversized-configuration limit-kind lifecycle
  gap with a regression, and passed 448 tests plus the validation,
  cross-target, native/Android, layout, symbol, hostile-host,
  allocation-failure, and import-free freestanding WASM gates. HIR planning is
  now authorized against this frozen contract.
- Hardened scanner/parser boundaries found by the final audit: `\\0` is accepted
  only as the complete legacy-free null escape, parser depth limits cover all
  recursive expression/type paths, disabled recovery stops after the first
  parser error, and malformed caller-supplied token streams fail safely.
- Fixed named and star external re-exports to preserve external module/edge
  provenance and value/type/both namespace availability, including type-only
  star exports and default exclusion.
- External export descriptors now declare value, type, or combined namespace
  availability across the portable API and official C ABI. Zero/unknown flags
  are rejected, while combined class exports link in constructor expressions
  and type annotations.
- Added exhaustive allocation-failure injection across project creation, source
  and frontend processing, semantic metadata, request/edge construction,
  external descriptors/linking, project results, canonical diagnostics, and ABI
  snapshot publication. Every injected failure tears down without leaks or
  publishing an uncommitted result pointer.
- Project limits are now enforced by their owning collections before retained
  copies or capacity growth, including an aggregate source-byte cap and exact
  stable C ABI limit categories. Graph depth now uses the canonical shortest
  resolved path from any root, independent of discovery order and cycles.
- Final project results now retain only the root-reachable module closure,
  include reachable module-host failures in `is_partial`, and expose exact
  external-import and re-export provenance through explicit presence flags and
  graph edge indexes.
- Hardened every official ABI v1 host-memory boundary on native and WASM:
  typed inputs and outputs require C alignment and complete overflow-safe
  ranges, nested arrays and strings are checked before use, and project
  creation rejects config/output/workspace aliasing without mutating state or
  output on invalid input.
- Added one project-owned canonical diagnostic table shared by the Zig and C
  result APIs, with explicit module identities, fixed public phases,
  deterministic exact-row deduplication, and distinct not-found, access-denied,
  and other module-host failure codes.
- Added the Goals 189–196 portable-core completion changes: complete project
  result accessors, runtime ABI version reporting, hostile host/WASM range
  validation, transactional project rollback, a bounded one-shot lifecycle,
  orthogonal request operation/type-only metadata, canonical limits, and
  source-derived module results.
- Removed source revisions, stale request/edge states, independent result
  destruction, the convenience source-analysis ABI, and all legacy ABI symbols.
  `finish()` is terminal and returns a project-owned immutable view.
- Isolated all concrete module hosts as validation fixtures. ViZG does not
  resolve filesystem, package, URL, or virtual-module specifiers; runtimes own
  that policy.
- Added `lint-module-host-boundary` and an explicit local Goal 196 audit
  checklist. The changelog does not claim the local Zig matrix passed until the
  repository owner records those results.
- Closed the adversarial Typed Semantics v2 audit: module parser-depth options now propagate, malformed recovered function bodies cannot trigger invalid-node dereferences, canonical composite/generic growth has controlled limits, and Debug safety mutation, lifecycle, parallel, ABI, cross-target, and validation gates are documented.
- Closed Typed Semantics v2 for the supported subset: canonical structural and nominal CLI formatting, cross-module class/interface shape preservation, one inference/store ownership path, and removal of the obsolete alternative inference implementation. No HIR or backend layer was introduced.
- Added the owned Zig `SemanticResult` API with single-pass analysis, explicit teardown, stable ID lookups, partial-result metadata, and deterministic syntax/semantic diagnostic views.
- Replaced competing type identity allocators with one canonical per-context `TypeStore`; all primitive, structural, nominal, and function-signature IDs share that store, and `TypeId` equality is meaningful only inside its owning semantic result/project.
- Qualified class, interface, and enum declaration identity by module, preventing equal local AST node IDs in different files from colliding in type compatibility, semantic maps, or import/export links.
- Split class constructor values from class instances, added authoritative static/instance member tables with four-state visibility and inheritance metadata, and made interfaces first-class structural member-bearing semantic types.
- Populated class and interface semantic tables from declarations, including annotated and placeholder-inferred fields, canonical method and constructor signatures, constructor parameter properties, static/instance separation, optional/readonly/visibility metadata, and heritage identities.
- Integrated class and interface models with access and call inference: constructor validation returns instance types, static, instance, and inherited lookup is deterministic, method receivers survive, and Checker v2 reports unknown members and invalid constructors.
- Added the owned canonical `TypeStore` with structural interning, nominal identity boundaries, recursive-type reservation, function-signature ownership, normalized unions/intersections, and stable result-backed type queries.
- Added symbol-driven semantic typing for every binder symbol kind, including enum members, class fields, and methods, with explicit unknown recovery instead of silent exclusions.
- Completed executable-expression type coverage for RegExp, tagged templates, dynamic import, meta-properties, yield, `this`, `super`, and class expressions; accepted deferred expressions now receive `unknown` plus a targeted warning instead of a missing node fact.
- Added symbol-driven semantic typing for variables, parameters, functions, classes, interfaces, enums, and type aliases, including resolver-backed identifier types and explicit unresolved, uninitialized, and error states.
- Added scope-aware type-namespace resolution for canonical builtins and local aliases, interfaces, classes, and enums, with distinct value/type lookup, symbol-backed identities, lexical shadowing, and one deterministic `VZG6004` diagnostic per unresolved annotation.
- Added stable generic type-parameter identities and cross-module annotation resolution for named, aliased, normal, and type-only imports; re-exports preserve the target declaration identity and cyclic modules recover with stable unknown placeholders.
- Made supported type-node lowering exhaustive, including literal types, object-like indexed access and `keyof`, simple annotated-binding `typeof` queries, generic-arity validation, and targeted recovery diagnostics instead of silent `unknown` fallback.
- Added canonical generic applications with local/imported arity metadata, defaults, constraint validation, recursive substitution through structural and callable shapes, and cycle-safe reuse of equivalent instantiations.
- Made indexed access, `keyof`, and identifier `typeof` resolve through canonical local/imported/inherited semantic shapes, including generic substitution, optional-value propagation, explicit union/intersection key policy, and targeted invalid-operator diagnostics.
- Made expression-level flow joins sound for ternaries, logical/coalescing expressions and assignments, and optional-chain indexes/arguments, preserving only narrowing facts valid on every outgoing path.
- Hardened canonical type identity with one-shot nominal completion, identity-only mutable nominal keys, order-insensitive object shape keys, context-local comparison tests, and removal of the legacy semantic `TypeInfo.Builder`.
- Added primitive expression inference with centralized unary/binary operator rules, fixed-point symbol propagation, sequence/conditional/assignment/update typing, `as` assertions, type-preserving `satisfies`, and recoverable invalid-operand diagnostics.
- Added aggregate inference for homogeneous arrays, context-required tuples, array holes, readonly structural annotations, complete object-property forms, deterministic spread/duplicate handling, and terminating recursive object shells.
- Separated inferred, contextual, and effective expression types so aggregate annotations guide child inference without erasing source facts; array, tuple, and object mismatches now retain precise element/property evidence and converge deterministically.
- Added typed property and indexed access with strict union-branch lookup, nullish optional-chain recovery, tuple/array/string indexing, method receiver metadata, and distinct unknown-property and invalid-index diagnostics.
- Added canonical function signatures and call typing with optional/default/rest parameters, deterministic return inference, method receivers, minimal constructor/async/generator categories, recursive-call stability, and targeted argument-count/type diagnostics.
- Unified declarations, expressions, arrows, object methods/accessors, and class methods/constructors/accessors behind one function-like semantic and CFG pipeline, including inferred method returns, receiver typing, annotated-return checks, and deterministic constructor/accessor restrictions.
- Made function and call inference CFG-aware: reachable fallthrough contributes `undefined`, optional and union calls preserve validation and return unions, non-callable union branches receive targeted diagnostics, and compound assignments validate call-derived results against their targets.
- Made return inference consume only reachable CFG results, honor non-completing `finally` overrides, combine source-intersection members for structural compatibility, and refresh namespace import shapes during project fixed-point propagation.
- Added sound CFG-backed narrowing v1 with per-reference flow types, literal-aware truthy/falsy filtering (`false`, zero, empty string, and nullish values), primitive `typeof` guards, constructor-to-instance `instanceof`, object/interface/class `in` guards, conservative joins, invalidation on mutation and unknown calls, early-exit propagation, and expression-body arrow normalization.
- Added a reusable forward CFG dataflow engine with immutable entry/exit facts, deterministic predecessor joins, worklist loop fixed points, edge/block transfer hooks, assignment replacement, and per-reference program-point queries.
- Added one terminating structural compatibility engine for primitives, literals, unions, arrays, tuples, objects, and strict-variance functions, with explicit readonly/optional/error policies and deterministic failure paths for diagnostics.
- Closed Checker v2 over canonical semantic inference and compatibility data, covering initialization, assignment, returns, calls, access, operators, and `satisfies`; interfaces and anonymous objects compare structurally with inherited-property failure paths, while classes and enums remain nominal.
- Added owned project semantics with one shared canonical type context, qualified export identities, named/default/namespace/type-only import and re-export propagation, bounded cycle recovery, and inspectable partial links.
- Integrated TypeScript `as` and `satisfies` into general binary precedence, including multiplicative, exponentiation, logical, coalescing, and relational grouping with full-token matrix coverage.


## [0.0.3] — 2026-07-13

- `do { ... } while (condition);` now has a body-first AST/CFG representation, with a required trailing semicolon and stable missing-`while` recovery.
- Closed Syntax Coverage v2.1 traversal and recovery gaps: the full frontend suite is registered, anonymous default async/generator exports parse coherently, `as`/`satisfies` precedence matches binary grouping, function CFG discovery is structural, and malformed recovered nodes remain safe through analysis.
- Generic constraints/defaults are explicitly syntax-and-scope data until Typed Semantics v2; type queries are limited to simple identifiers and unsupported `typeof import()` forms recover as one construct.

### Added

- `debugger;` now has a dedicated AST statement, while `with` statements receive targeted unsupported-syntax recovery.
- TypeScript enums, generic declarations, rich parameters, constructor parameter properties, and literal/indexed/query type nodes now preserve source structure.
- Static import attributes and dynamic-import options are preserved for module analysis.
- Reserved pipeline syntax now emits targeted `VZG2004` recovery; fixtures support ordered multi-diagnostic span contracts.
- Labeled statements now preserve label metadata, validate `break` and `continue` targets, and build label-aware CFG edges.
- Generator declarations, expressions, object methods, and class methods now preserve generator flags; `yield`, `yield value`, and delegated `yield*` use a contextual, traversable AST representation.
- Function declarations, expressions, arrows, object methods, and class methods now share coherent async/generator flags; async declaration/default-export forms parse directly.
- `import.meta` and `new.target` now use strict, dedicated meta-property AST nodes with normal postfix nesting.
- Dynamic `import(source, options?)` now has a dedicated AST expression and stays outside the static module graph.
- Tagged template expressions now preserve identifier/member tags and a unified raw/optional-cooked payload for interpolated and no-substitution templates.
- TypeScript `satisfies` expressions now have a distinct AST node, preserve structured type syntax, and compose with `as` assertions.
- Logical `&&=` and `||=` assignments now parse alongside `??=`, and all compound assignments use read-modify-write reference semantics.
- Prefix `++` and `--` now produce update-expression AST nodes with read-modify-write resolution, matching existing postfix forms.
- Relational expressions now support `in` and `instanceof`, while `for` headers preserve unambiguous classic, `for-in`, and `for-of` parsing.
- Comma expressions now produce ordered `SequenceExpression` AST nodes in full-expression positions while preserving structural commas in arguments, arrays, objects, and declarations.
- Targeted `VZG2004`-`VZG2006` diagnostics and bounded parser recovery for intentionally unsupported decorators, private fields, namespaces, JSX/TSX, and advanced, mapped, or conditional TypeScript types.
- Organized valid/invalid syntax fixture corpus covering Syntax Coverage v2, with expected parser-code contracts and full-token-consumption checks integrated into `zig build test`.
- Numeric literal scanning now validates decimal, exponent, radix, separator, and BigInt forms as complete tokens; malformed forms report one stable `VZG1004` span, and arbitrarily long spellings remain overflow-safe scan-only metadata.
- Unicode 17.0 ECMAScript-style identifiers, identifier Unicode escapes, deterministic generated property tables, and `VZG1008 invalid_utf8` diagnostics for malformed source bytes.
- Type aliases and interfaces now have declaration AST nodes, structured type members, preserved interface `extends` lists, type-namespace binder symbols, export metadata, and AST/symbol output.
- Classes now have declaration/expression and member AST nodes, `extends`, fields, constructors, methods, static/access-modifier metadata, class/member binding scopes, resolver traversal, and AST output.
- Type annotations now use a span-preserving structured AST and parse generic, array, readonly, union, intersection, object, function, tuple, and parenthesized forms with stable malformed-member recovery.
- Export syntax now distinguishes declaration exports, default expressions, local exports, named re-exports, star re-exports, and type-only exports; re-export sources are traversed and retained on module graph edges.
- Static imports now support default, namespace, side-effect, declaration-level type-only, and mixed default-plus-named forms, with explicit AST/binder kinds and module-edge kind/type metadata.
- Array literals now preserve elisions as nullable AST element slots while keeping spread elements explicit and excluding trailing commas from the element count.
- Object literals now preserve shorthand, computed, spread, method, async method, getter, and setter property kinds, with computed-key traversal and method function scopes.
- `try` statements now support binding and bindingless `catch` clauses plus `finally`, with explicit AST branches, isolated catch bindings, resolver/type traversal, structural CFG paths, diagnostics for a missing clause, and AST output.
- `throw expression;` statements now have AST, binder/resolver traversal, same-line expression diagnostics, terminating CFG edges, and AST output.
- `switch` statements now preserve ordered `case`/`default` clauses in the AST, diagnose duplicate defaults, bind and resolve clause contents, and model dispatch, fallthrough, and `break` exits in CFGs.
- Classic `for`, `for-in`, `for-of`, and syntax-only `for await...of` loops now have discriminated AST forms, loop-header binding scopes, resolver traversal, CFG exits, and AST output.
- Unlabeled `break` and `continue` now have distinct AST nodes and loop-aware CFG edges; labeled forms use the label-aware CFG system.
- Spread elements now parse in call, array, and object literals; function and arrow rest parameters preserve AST metadata, bind normally, and diagnose non-final positions.
- Optional chaining now preserves optional member, computed-access, and call boundaries in the AST, resolver traversal, and AST output.
- Function expressions now support anonymous, named, and contextual `async` forms in expression positions, with private recursive names, function scopes, resolution, and AST output.
- Arrow functions now support single and parenthesized parameters, type annotations, expression and block bodies, contextual `async`, nested arrows, scope binding, resolution, and AST output.
- Primary expressions now represent `this`, `super`, and constructor-style `new` calls with distinct AST nodes, postfix chaining, resolution traversal, and AST output.
- Template literals now tokenize interpolation segments and produce traversable `TemplateExpression` AST nodes for binder, resolver, type inference, and AST output.
- Contextual RegExp literal scanning now distinguishes division, preserves patterns and flags in the AST, and reports invalid flags or unterminated literals.
- Prefix unary expressions now support `!`, `~`, `-`, `+`, `typeof`, `void`, `delete`, and `await`, while preserving postfix non-null assertions.
- Expression parsing now applies JavaScript-style precedence for right-associative exponentiation, shifts, bitwise operators, and their compound assignment forms.
- Nullish coalescing and nullish assignment now parse with deterministic rejection of unparenthesized `??` mixing with `&&` or `||`.
- Ternary conditional expressions now parse right-associatively between nullish coalescing and assignment, with stable missing-colon recovery and traversable branches.

## [0.0.2] — 2026-07-12

### Added

- `zig build android-aarch64-lib` packages the pre-release C surface as an Android AArch64/API 24 static archive and header, with a target-compiled minimal C consumer probe.
- Added early pre-release ABI version, ownership, lifetime, pointer/length,
  thread-safety, status, size, and platform validation contracts.
- Added early status-returning source analysis with explicit out-of-memory reporting.
- Added a C-compatible static library and installed header.
- Added early file/source analysis and result cleanup entry points.
- Memory-first analysis accepts source bytes and an optional diagnostic path without reading the filesystem.
- Added early C and Zig ABI interop examples.
- Added a portable silent-library structural check.
- Portable `zig build validate` step that installs artifacts, runs tests, and exercises the CLI without shell or `/tmp` dependencies.
- Scanner validation for string and template escape sequences, including `\\xNN`, `\\uNNNN`, and trailing backslashes, with diagnostic `VZG1005 invalid_escape_sequence`.
- Forward type-inference groundwork with bounded fixpoint iteration in `src/semantics/inference.zig`; this remains experimental and is not yet wired into the public semantics pipeline.
- Development roadmap in `VIZG_PLAN.md` covering planned post-frontend phases.
- Android target-query and NDK-discovery helper coverage in `android.build.zig`.
- Foreign-caller C ABI tests covering source analysis, invalid arguments, result lifecycles, and parallel use.
- Compile-only `zig build cross-check` matrix for generic frontend, types, and semantics layers across Linux, Windows, macOS, and Android targets.
- Compile-only `zig build abi-cross-check` matrix producing consumer-equivalent C ABI static archives and compiling the public header for Linux, Windows, macOS, and Android targets.
- C-compiled public ABI layout probe, exposed as `zig build abi-layout-test` and integrated into `zig build test`.

### Changed

- `src/root.zig` is now both the public Zig package root and the root module of the static library; `Lib/vizg.zig` owns the C ABI surface.
- C ABI diagnostics expose explicit message and path lengths, and token flags use fixed-width FFI-safe fields.
- Result lifecycle coverage now includes repeated allocation/free cycles, reverse-order cleanup, empty files, missing files, long paths, and in-memory sources.
- The library is silent by default; `zig build lint-silent` rejects debug-print calls in library, semantic, and test source while preserving CLI and example output.
- `zig build run -- <args>` forwards arguments to the development CLI.
- The default build now installs `vizg`, `libvizg.a`, and `vizg.h`; shell validation and lint scripts are wrappers around Zig build steps.
- Zig cache and generated example artifacts have broader `.gitignore` coverage.
- C ABI results now carry independent ownership metadata without shared global lifecycle state.

### Fixed

- Made Android NDK discovery deterministic and corrected target mappings for aarch64, arm, x86, and x86_64; Android API levels now reach Zig's target query.
- Propagated recoverable allocation failures through frontend diagnostics, external-module registration, CLI commands, and the C ABI instead of panicking or silently continuing.
- Corrected the C/Zig `Vizg_Token` layout mismatch that caused invalid token strides and crashes after the first token.
- Preserved the ABI invariant that an absent diagnostic path has both a null pointer and zero length.
- Ensured C ABI symbols are retained in `libvizg.a` and the public header is installed before consumer smoke tests compile.
- Prevented out-of-bounds scanner reads for incomplete escape sequences at end of input.
- Forced the C smoke-test executable to use a non-executable ELF stack (`GNU_STACK RW`) instead of inheriting `RWE` from missing `.note.GNU-stack` metadata.
- Restored the missing `VIZG_DIAG_INVALID_ESCAPE_SEQUENCE` C declaration and named the contextual-keyword enum for direct ABI validation.

### Removed

- Redundant static-library wrapper modules `src/lib.zig` and `src/lib_abi.zig`.
- Unconditional debug output from C ABI operations.

## [0.0.1] — 2026-07-10

### Added

**Scanner & Lexer**
- Tokenizer for TypeScript/JavaScript-like syntax (identifiers, strings, numbers, operators, delimiters).
- Single-line and block comment collection with span tracking.
- Lexical diagnostics: invalid characters (`VZG1001`), unterminated strings/comments (`VZG1002`, `VZG1003`), invalid numbers (`VZG1004`).

**Parser & AST**
- Full parser for a focused TypeScript/JavaScript subset.
- AST model covering programs, declarations (variables, functions, classes), expressions (binary, call, member, literals), control flow (if/else, while, for, return), and imports/exports.
- Parse diagnostics: unexpected tokens (`VZG2001`), expected token errors (`VZG2002`).

**Binder (Scope Resolution)**
- Scope-based symbol binding for variables, functions, and parameters.
- Import/export declaration processing with named, default, and namespace forms.
- Duplicate diagnostics: duplicate declarations (`VZG3001`), duplicate exports (`VZG3002`).

**Resolver (Reference Analysis)**
- Read/write/call export reference tracking for all identifiers.
- Missing-name detection (`VZG4001`) for unresolved references.

**Control-Flow Graphs**
- Preliminary CFG construction for function bodies, capturing branches and return points.

**Module Layer v1**
- Multi-file module graph builder with recursive analysis from an entry point.
- Relative import resolution supporting `.ts` extension and `index.ts` fallback.
- Canonical path caching to prevent redundant analysis.
- Named import validation against target module exports.
- Cross-file import linker: classifies each import as named, default, namespace, external, or unresolved; resolves local imports to exported symbols.
- Module diagnostics: missing modules (`VZG5001`), missing exports (`VZG5002`), circular imports (`VZG5003`).

**Types Layer**
- Pure type model with primitive types and function signature representation.
- Builtin type registry in `src/types/`.

**Semantics Layer**
- Per-symbol and per-node type mapping in `src/semantics/`.

**CLI Commands** (`vizg`)
| Command | Description |
|---------|-------------|
| `check <file>` | Run full frontend pipeline; print diagnostics (errors + warnings) |
| `tokens <file>` | Print scanned tokens for a file |
| `ast <file>` | Print readable AST tree |
| `symbols <file>` | Print scopes, symbols, imports, exports, and diagnostics |
| `references <file>` | Print resolved identifier references |
| `refs <file>` | Alias for `references` |
| `cfg <file>` | Print function control-flow graphs |
| `modules <file>` | Build module graph; print Modules, Imports, Links, and Diagnostics sections |
| `help` | Print usage and command list |

**Internal / Infrastructure**
- Unified diagnostic model in `src/diagnostics/root.zig`.
- Stable error code scheme: `VZG1xxx` (scanner), `VZG2xxx` (parser), `VZG3xxx` (binder), `VZG4xxx` (resolver), `VZG5xxx` (module graph), `VZG9001` (internal).
- Zig build system with default target install and separate test step.
- Validation script (`tools/validate.sh`) for repeatable CI-style checks.

### Supported Syntax Subset
Comments, named/default imports, `let`/`const`/`var`, exported variables and functions, typed parameters, primitive literals (string, number), binary expressions, assignment operators, call expressions, member/accessor expressions, optional member/call/computed chains, `if`/`else`, `while`, `for`, `return`, named exports, and aliased exports.

### Documentation
- Architecture overview (`docs/architecture.md`).
- Frontend pipeline design (`docs/frontend-pipeline.md`).
- Diagnostic code reference (`docs/diagnostics.md`).
- CLI command reference (`docs/cli.md`).
- Roadmap with planned milestones (`docs/roadmap.md`).

[Unreleased]: https://github.com/moliko/vizg/compare/v0.0.3...HEAD
[0.0.3]: https://github.com/moliko/vizg/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/moliko/vizg/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/moliko/vizg/releases/tag/v0.0.1
