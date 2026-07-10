# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
Comments, named/default imports, `let`/`const`/`var`, exported variables and functions, typed parameters, primitive literals (string, number), binary expressions, assignment operators, call expressions, member/accessor expressions, `if`/`else`, `while`, `for`, `return`, named exports, and aliased exports.

### Documentation
- Architecture overview (`docs/architecture.md`).
- Frontend pipeline design (`docs/frontend-pipeline.md`).
- Diagnostic code reference (`docs/diagnostics.md`).
- CLI command reference (`docs/cli.md`).
- Roadmap with planned milestones (`docs/roadmap.md`).

[0.0.1]: https://github.com/moliko/vizg/releases/tag/v0.0.1
