# Roadmap

This roadmap separates implemented frontend work from planned layers. It is not a release promise.

## Current Milestone: Frontend And Module Graph v1

Implemented:

- Scanner with tokens, comments, spans, and lexical diagnostics.
- Parser for the current TypeScript/JavaScript-like subset.
- AST model for supported declarations, statements, and expressions.
- Binder with scopes, symbols, imports, exports, and duplicate diagnostics.
- Resolver with read/write/call/export references and missing-name diagnostics.
- Preliminary function CFGs.
- Minimal multi-file module graph for static local imports.
- Relative import resolution by `.ts` and `/index.ts`.
- Module cache keyed by canonical file path.
- Named import validation against target value-space exports.
- Cross-file import linking via `src/modules/linker.zig`: each named/default/namespace or external import becomes a `LinkedImport` carrying local name, imported name, kind (`named`, `default`, `namespace`, `external`, or `unresolved`), and the resolved target module/symbol when available.
- Linker output surfaced in CLI as the "Links" section on `vizg modules <file>`.
- Module graph diagnostics `VZG5001`, `VZG5002`, and `VZG5003`.
- CLI inspection commands.
- Zig build and test wiring.
- Static library `libvizg.a` rooted at `src/root.zig`, with the C ABI implemented in `Lib/vizg.zig`.
- Public C header with file analysis, memory-first source analysis, and explicit result cleanup.
- C runtime smoke test and silent-library structural check in `zig build test`.
- Scanner diagnostic `VZG1005` for invalid or incomplete escape sequences.

Useful next work inside this milestone:

- Add more parser recovery tests.
- Expand fixture coverage for unsupported syntax errors.
- Improve CLI formatting consistency.
- Add snapshot-style tests for CLI output (including `modules` Links section).
- Document each AST node in source comments or generated docs.
- Add module graph snapshot tests.

## Next Milestone: Module Layer Expansion

Planned, not implemented:

- Package or `node_modules` lookup.
- `package.json` or `tsconfig` path resolution.
- Dynamic import resolution.
- CommonJS interop.
- Default import export validation.
- Code emission, bundling, or tree shaking.

## Type Checker Milestone

Implemented for the supported syntax subset:

- Owned single-file and project semantic results with explicit teardown.
- One canonical `TypeStore` per result/project and context-local `TypeId` equality.
- Declared, expression, aggregate, access, function, call, and CFG-narrowed types.
- Central compatibility and Checker v2 diagnostics for initializers, assignments, returns, calls, access, operators, and `satisfies`.
- Cross-module identities and type propagation for values, functions, classes, enums, interfaces, type aliases, aliases, default/namespace imports, re-exports, and type-only imports.
- Bounded cyclic propagation and partially inspectable missing/external links.

Complete TypeScript compatibility and advanced annotation forms remain out of scope.

## Future Milestone: HIR And Lowering

Planned, not implemented:

- Lower AST or typed AST into a compact intermediate representation.
- Normalize control flow and expression forms.
- Prepare for interpretation, analysis, or code generation.
- Reserve `VZG7xxx` diagnostics for lowering errors.

### HIR Entry Checklist — Satisfied 2026-07-13

No HIR implementation was introduced while closing Typed Semantics v2.

- [x] The owned `SemanticResult` and `ProjectSemanticResult` contracts are stable, including teardown and partial-result behavior.
- [x] One canonical `TypeStore` per result/project and context-local ID rules remain enforced.
- [x] Tests cover value/function/class/enum/interface/type-alias exports; aliases, default/namespace/re-export/type-only imports; missing/external links; cycles; and repeated rebuild/teardown.
- [x] Checker diagnostics retain stable source and related spans while recovered semantic data stays inspectable.
- [x] Full test, validation, cross-target, Android, and ABI gates are green.
- [x] Future HIR must consume semantic results. It must not parse, bind, infer again, or create a competing `TypeStore`.

### Typed Semantics v2 Closure Verification — 2026-07-13

- `zig build test` — PASS, exit 0, no command output. The registered suite reports 403/403 tests passed with `zig build test --summary all`.
- `zig build validate` — PASS, exit 0: `test/frontend/vizg_capabilities_test.ts` produced 0 errors and 0 warnings.
- `zig build cross-check` — PASS, exit 0, no command output.
- `zig build abi-cross-check` — PASS, exit 0, no command output.
- `zig build abi-layout-test` — PASS, exit 0, no command output.
- `zig build android-aarch64-lib` — PASS, exit 0, no command output; produced the Android AArch64 static library.
- `zig build run -- types test/frontend/satisfies-expression-test.ts` — PASS, exit 0; output included `interface Config#1000[module=0,declaration=0,members=1]` and `object#1001[properties=1,first=enabled:106]`, with no structural `<unknown>` placeholder.
- `git diff --check` — PASS, exit 0, no output.

## Future Milestone: Runtime Or Compiler Backend

Possible future directions, not implemented:

- Interpreter.
- Native compiler backend.
- JavaScript emitter.
- Bytecode VM.

No runtime or compiler backend exists today. Reserve `VZG8xxx` diagnostics for runtime-facing errors if that layer is added.

## Non-Goals Until Explicitly Revisited

- Claiming full JavaScript or TypeScript support.
- Running npm packages.
- Acting as a browser or Node.js replacement.
- Bundling packages.
- Emitting optimized native code from the current AST.
- Treating external package imports as resolved module semantics.
