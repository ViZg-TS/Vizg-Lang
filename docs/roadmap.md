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

## Future Milestone: Type Checker

Planned, not implemented:

Types and semantics are already implemented at `src/types/` (pure type model) and `src/semantics/` (per-symbol / per-node mappings). The next work is the Type Checker pass itself:
- Infer types via a forward/infer step.
- Resolve type annotations beyond syntax capture.
- Validate variable initializers, assignments, returns, and calls.
- Resolve member accesses semantically.
- Check exported API surfaces.
- Reserve `VZG6xxx` diagnostics for type errors.

## Future Milestone: HIR And Lowering

Planned, not implemented:

- Lower AST or typed AST into a compact intermediate representation.
- Normalize control flow and expression forms.
- Prepare for interpretation, analysis, or code generation.
- Reserve `VZG7xxx` diagnostics for lowering errors.

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
