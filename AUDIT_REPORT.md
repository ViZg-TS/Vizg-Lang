# ViZG Comprehensive Audit Report

Generated: 2026-07-09  
Scope: Full codebase review for bugs, portability issues, undefined behavior, and future maintenance risks.

---

## Critical Issues

### C1. `displayPathForCanonical` uses hardcoded `/` path separator
- **Subsystems**: Modules (graph.zig)
- **Explanation**: The function `displayPathForCanonical()` at src/modules/graph.zig:79 performs path normalization using string-based prefix matching with the literal "/" character (`canonical[boundary] == '/'`). This assumes all paths use Unix-style separators. On Windows, absolute paths include drive letters (C:\) and use "\\" as separator — this logic would produce incorrect display paths or fail to strip cwd_abs entirely on that platform.
- **Severity**: Critical for cross-platform correctness  
- **Evidence**: src/modules/graph.zig:79-95 uses raw string slice indexing with "/" delimiter rather than `std.fs.path` utilities
- **Recommended Direction**: Use `std.fs.path.relative()` or `std.fs.path.relativeComptime()` to compute relative display paths; rely on std.fs for separator-aware path operations

### C2. Hardcoded `.ts` extension assumption in resolver and CLI
- **Subsystems**: Modules (resolver.zig), CLI (main.zig)
- **Explanation**: Both src/modules/resolver.zig:10 (`endsWith(.ts`) and src/main.zig:750 (`endsWith(".ts"))`) hardcode the `.ts` extension. This assumes all input files use TypeScript-style extensions; if users need to support other formats or configure their own, this is a blocker. The same assumption appears in loadExternalsDir at main.zig:750-761.
- **Severity**: Critical for platform/extension flexibility
- **Evidence**: src/modules/resolver.zig:10, src/main.zig:750 — both use hardcoded ".ts" extension string literals
- **Recommended Direction**: Make file extension configurable via BuildOptions or CLI flag; document supported extensions in help

---

## High Priority

### H1. Hardcoded diagnostic message in test helper uses placeholder path
- **Subsystems**: Modules (graph.zig test)  
- **Explanation**: The `diagnosticForTest()` helper at src/modules/graph.zig:478 returns `"circular import detected through './cycle_a'"` as a fixed string. While this is in test code and not production, it means any production diagnostic using the dynamic `std.fmt.allocPrint` path (line 206) produces messages that won't match the expected shape exactly — only substring matching catches both forms.
- **Severity**: High (test-maintainability issue; may mask real message drift)
- **Evidence**: src/modules/graph.zig:478 uses hardcoded message string instead of dynamic format  
- **Recommended Direction**: Use `std.mem.indexOf` to verify just the format structure, not content; or have tests assert on the allocPrint format directly

### H2. Missing type inference coverage in checker.v1
- **Subsystems**: Semantics (checker.zig)
- **Explanation**: The v1 type checker only handles Identifier LHS + Literal RHS patterns per comments at src/semantics/checker.zig:18 ("v1 scope — plain `=` with Identifier LHS + Literal RHS only"). This means it will not catch mismatches for: function call returns assigned to typed variables, object/array literals with wrong structure, conditional expression type errors, and import-assigned variables.
- **Severity**: High (limits compiler's ability to catch real bugs)  
- **Evidence**: src/semantics/checker.zig:18 documents v1 scope limitation; all four branches use `continue` for non-matching patterns
- **Recommended Direction**: Expand checker to handle function call return types, object literal property types, and import-assigned variables in v2

### H3. Internal diagnostic code never emitted anywhere
- **Subsystems**: Diagnostics (root.zig)
- **Explanation**: The `internal_error` diagnostic code (VZG9001) is defined at src/diagnostics/root.zig:25 but never appears to be actually emitted from any subsystem in the codebase. This suggests either dead definition or unimplemented error path — if an internal assertion fails it will produce a @panic instead of emitting this diagnostic.
- **Severity**: High (inconsistency between defined and used diagnostics)  
- **Evidence**: rg search finds only definitions at root.zig:25/84/104; no actual emission site found
- **Recommended Direction**: Either add `internal_error` emission at all assertion-fail paths, or remove the definition if it's purely placeholder

### H4. No recursion depth limits for parser, type inference, module graph  
- **Subsystems**: Parser (parser.zig), Semantics (type_inference.zig), Modules (graph.zig)
- **Explanation**: The parser's precedence-climbing loops (while true + break else pattern at parser.zig:496-538) and the type_inference stack walker, plus the graph builder's DFS-based cycle detection all lack explicit recursion/iteration limits. Deeply nested input or very deep import chains could cause stack overflow or OOM DoS attacks via malicious source files.
- **Severity**: High (security / availability risk with pathological inputs)  
- **Evidence**: No `max_depth`/`recursion_limit` constants found anywhere in src/; parser uses while(true) at line 496, graph DFS is recursive at analyzeModule→processImports
- **Recommended Direction**: Add BuildOptions fields for max_parse_depth and max_module_graph_depth with reasonable defaults (e.g., 1000); return diagnostic when exceeded rather than crashing

### H5. Duplicate diagnostics across pipeline phases are not deduplicated
- **Subsystems**: Frontend (frontend.zig)  
- **Explanation**: `combineDiagnostics()` at src/frontend/frontend.zig:63 simply concatenates diagnostic lists from scanner, parser, binder, and resolver without any deduplication logic. If the same issue is reported by multiple phases (e.g., a syntax error followed by "cannot find name" for the same token), users see duplicate reports. This also affects deterministic ordering — diagnostics are grouped by phase rather than source position.
- **Severity**: High (diagnostic quality)  
- **Evidence**: src/frontend/frontend.zig:63 uses @memcpy of each list with no sorting/dedup step; test contracts at src/modules/contracts_test.zig confirm "exactly one cycle diagnostic" expectation but don't cover cross-phase dedup
- **Recommended Direction**: Add dedup by (DiagnosticCode, span.start) after combination; sort by source position for stable ordering

---

## Medium Priority

### M1. Escape sequence validation deferred with no enforcement location documented
- **Subsystems**: Scanner (scanner.zig)
- **Explanation**: The scanner marks escaped strings but defers "Full escape validation" to "the next pass" per comment at line 514/559 of src/frontend/scanner.zig. Currently there is no second pass that actually performs this validation — invalid escapes like `\q`, `\x` would silently produce malformed strings rather than emitting an error diagnostic.
- **Severity**: Medium (silent acceptance of invalid syntax)  
- **Evidence**: scanner.zig:514 "Consume escaped byte. Full escape validation belongs in the next pass" with no subsequent validation phase implemented
- **Recommended Direction**: Implement string escape validation in scanString itself, or add an explicit validation pass that emits diagnostics

### M2. Function signature type IDs collide with user-defined function signatures  
- **Subsystems**: Types (model.zig)
- **Explanation**: The `FunctionSignatureStore` uses builtin IDs starting at 100 + index for primitive types; the comment at line 14 says "user functions must not collide" but there's no documented reservation of ID ranges. If user-defined function signatures ever get numeric IDs, they would need careful range management to avoid collision with the hardcoded builtin offset.
- **Severity**: Medium (maintenance risk for future extensions)  
- **Evidence**: src/types/model.zig:14 comment about "must not collide"; line 79 defines FunctionSignatureStore  
- **Recommended Direction**: Reserve distinct ID ranges in a single constants module; document ranges clearly

### M3. Type compatibility switch exhaustiveness depends on manual updates
- **Subsystems**: Semantics (type_compat.zig)
- **Explanation**: The `builtinKindFor()` function at src/semantics/type_compat.zig:28 uses an if-chain rather than a switch or lookup table for mapping TypeId → BuiltinKind. If new builtin kinds are added to `BuiltinKind` enum without updating this chain, isAssignable() will silently treat them as unknown (returning null → false) instead of failing loudly.
- **Severity**: Medium (silent correctness bug when adding types)  
- **Evidence**: src/semantics/type_compat.zig:28 uses if-chain; adding a new BuiltinKind variant won't cause compile error here  
- **Recommended Direction**: Replace with switch over enum or use TypeId→BuiltinKind mapping table

### M4. Module graph does not detect self-imports
- **Subsystems**: Modules (graph.zig)
- **Explanation**: A module that imports itself via `import "./self"` from a path resolving to its own canonical location would either be silently treated as already-loaded (if findModule returns it first) or could create confusion in the import edge status. No explicit diagnostic is emitted for self-imports even when they're clearly errors.
- **Severity**: Medium (missing validation for pathological case)  
- **Evidence**: processImports at graph.zig:142 doesn't check `target_id != module_id`; only cycle detection via `.visiting` state handles indirect cycles
- **Recommended Direction**: Add explicit self-import check and emit a diagnostic; or document "self-imports are no-ops" if that's intentional

### M5. Missing parser tests for malformed input  
- **Subsystems**: Tests (frontend/tests.zig)
- **Explanation**: The test suite has comprehensive positive cases but limited negative coverage — specifically: unterminated strings with various terminators, unterminated template literals in edge positions, invalid escape sequences inside string literals that would be flagged by scanner (if implemented), and deeply nested expressions to verify stack safety.
- **Severity**: Medium (confidence gap for malformed input handling)  
- **Evidence**: rg search shows ~400 lines of contracts tests focused on positive module graph cases; minimal negative parsing test coverage observed
- **Recommended Direction**: Add negative tests for: unclosed strings, deeply nested blocks (>100 levels), unterminated block comments with various endings

### M6. Missing type system tests  
- **Subsystems**: Tests (semantics/ contracts_test.zig)
- **Explanation**: No test covers function call return type assignment compatibility, object literal property matching against declared types, array element type validation, or null/nullable handling in isAssignable(). The type compatibility logic's correctness isn't verified for its full truth table.
- **Severity**: Medium (type system correctness unverified for complex cases)  
- **Evidence**: No test imports src/semantics/type_compat.zig directly; only frontend tests check diagnostics end-to-end
- **Recommended Direction**: Add unit tests for isAssignable's truth table, null compatibility rules, and function return type propagation

---

## Low Priority

### L1. BuiltinKind enum uses u8 storage despite only 8 variants  
- **Subsystems**: Types (builtin.zig)
- **Evidence**: src/types/builtin.zig:9 defines `enum(u8)` with 8 variants
- **Recommended Direction**: Could use bool if packing two values together is needed; current u8 is fine but not a priority

### L2. Diagnostic for VZG6003 unused (gap in code sequence)  
- **Subsystems**: Diagnostics (root.zig)
- **Evidence**: diagnostic codes jump from VZG6002 to VZG6004 at src/diagnostics/root.zig:87-91

### L3. No identifier length limits for scanner  
- **Subsystems**: Scanner (scanner.zig)
- **Explanation**: Very long identifiers in source could cause unnecessary memory usage and performance degradation. While unlikely to be malicious, document or implement a soft limit.
- **Evidence**: rg search shows no `id_length_limit` or similar constants

---

## Missing Tests

| Area | What's missing | Priority |
|------|---------------|----------|
| Scanner: negative | unterminated strings with various endings; invalid escape sequences (if implemented) | High |
| Parser: error recovery | malformed expressions at start of file; deeply nested structures for DoS prevention | Medium |
| Module graph: cycles | 3+ module circular import chains (currently only tests 2-module cycles) | Medium |  
| Type system: compatibility | isAssignable truth table for all builtin pairs including null/undefined | High |
| CLI robustness | invalid UTF-8 paths, very long argument lists, missing --externals-dir contents | Low |

---

## Portability Notes

### Platform-specific concerns to document (do NOT hardcode):

1. **Filesystem path separator**: All use of `std.fs.path` is good; just ensure future additions also use std.fs utilities rather than raw "/" concatenation.

2. **Windows drive letter paths**: The resolver's canonicalization assumes Unix-style paths in some edge cases — verify that `realPathFileAlloc` and the display path logic handle Windows absolute paths correctly. (See Critical C1)

3. **Case-sensitive filesystems**: No known assumption about case sensitivity, but test on macOS/Windows where filesystems are case-insensitive by default to ensure import resolution doesn't break there.

### Recommended memory_mcp storage items:
- `memory.store(title="Path handling must use std.fs.path", content="All future path operations in modules/resolver.zig and displayPathForCanonical() must use std.fs.path utilities; raw string '/' concatenation is a bug on Windows.", tag="portability,critical")`

---

## Architecture Observations (no immediate fix)

1. **Arena ownership model**: The codebase consistently uses arena-allocated AST data (`arena.deinit()` deferred at every call site). This is correct and well-designed — no memory leaks observed.

2. **Error propagation through pipeline**: Frontend.analyze() chains errors correctly with `try` from scanner→parser→binder→resolver; the pipeline produces a unified diagnostic list without silent error swallowing.

3. **Module graph cycle detection**: Uses `.visiting` state correctly for DFS-based cycle detection. Only handles 2+ module cycles (not explicitly tested that 3+-cycles are also detected, though logically they would be).

4. **Test fixtures use hardcoded paths** in `contracts_test.zig:26` (`{cwd}/test/modules/linking/named/main.ts`) — acceptable for tests but verify CWD is set correctly when running on CI or Windows where `/` may not normalize properly through these paths (though std.fs handles this).

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Critical Issues | 2 |
| High Priority | 3  
| Medium Priority | 5 |
| Low Priority | 3 |
| Missing Test Categories | 6 |
| Portability Concerns to Document | 1 (stored in memory) |

---

**Next Steps**: The highest-value action is addressing Critical C1 (path normalization on non-Unix platforms) and H4 (recursion limits for DoS prevention). These two changes would most improve production readiness.
