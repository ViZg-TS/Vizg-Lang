# Frontend Pipeline

The implemented frontend analyzes one source file at a time. Its public entry point is `frontend.analyze` in `src/frontend/frontend.zig`. Multi-file loading lives one layer above it in `src/modules/`. The linker (cross-file import resolution) sits on top of the module graph and runs before diagnostics are finalized for each build.

## Entry Point

`frontend.analyze` accepts:

- `SourceFile`: path, source text, and source kind (`script` or `module`).
- `FrontendOptions`: comment collection and parser error recovery options.

It returns `FrontendResult`:

- `source`
- `tokens`
- `comments`
- `ast`
- `bind`
- `resolve`
- `cfgs`
- `diagnostics`

## Pipeline Steps

```txt
source text
  -> scanner.scanAll
  -> parser.parse
  -> binder.bind
  -> resolver.resolve
  -> cfg.build
  -> combined diagnostics
```

## Scanner

The scanner converts source text into tokens with source spans. It can skip comments or collect them, depending on options.
Slash tokens are contextual: expression-start positions can produce RegExp literals, while expression-ending positions preserve division operators.

Token output includes:

- token kind
- lexeme
- line and column
- byte start/end offsets
- contextual keyword display where applicable

Scanner diagnostics use `VZG1xxx` codes.

Example CLI shape:

```txt
1:1  Keyword_import  "import"  0..6
1:8  LBrace  "{"  7..8
1:10  Identifier  "log"  9..12
```

## Parser

The parser consumes scanner tokens and builds `ast.Ast`. The AST supports the current syntax subset:

- program and block statements
- identifiers and literals
- RegExp literals with pattern, flags, and full-literal spans
- import declarations
- export declarations and specifiers
- variable declarations and declarators
- function declarations and parameters
- return and expression statements
- call, member, binary, assignment, and prefix unary expressions
- postfix non-null assertions, distinct from prefix `!`
- right-associative exponentiation plus multiplicative, additive, shift, relational, equality, bitwise, logical, and assignment precedence levels
- template expressions with traversable interpolation expressions
- `if`, `while`, and `for` statements

Parser diagnostics use `VZG2xxx` codes.

## Binder

The binder walks the AST and builds:

- global, function, and block scopes
- variable, function, parameter, and import symbols
- AST node to symbol links
- module import records
- module export records

It reports duplicate declarations and duplicate exports with `VZG3xxx` codes.

`symbols <file>` prints output shaped like:

```txt
Scopes
  scope 0 kind=global parent=null symbols=[...]

Symbols
  symbol 0 name="..." kind=function scope=0 node=... span=.....

Imports
  localName from "module"

Exports
  exportedName node=...
```

## Resolver

The resolver records identifier references and connects them to binder symbols when possible.

Reference kinds:

- `read`
- `write`
- `call`
- `export_ref`

Missing names produce `VZG4001 cannot_find_name`.

Example CLI shape:

```txt
References
  ref 0 node=0 name="missing" kind=read scope=0 symbol=null span=8..15

Diagnostics
file.ts:1:9 error VZG4001 cannot_find_name: cannot find name 'missing'
```

## Control-Flow Graph

The CFG builder creates one preliminary graph per function. Each graph has:

- entry block id
- exit block id
- basic blocks
- block kind
- statement node ids
- successor block ids
- predecessor block ids

Current basic block kinds are `entry`, `exit`, `normal`, `condition`, and `unreachable`.

`cfg <file>` prints function graphs for inspection. The current CFG is a frontend analysis artifact, not a lowered IR.

## Diagnostics Combination

`frontend.analyze` combines scanner, parser, binder, and resolver diagnostics into `FrontendResult.diagnostics`. CFG diagnostics are not currently produced.

## Current Scope

`frontend.analyze` remains single-file. Imports and exports are recorded as module metadata and forwarded to the linker layer below for cross-file resolution.

## Note on Type Model Location

The type model and semantic mapping do **not** live inside `src/frontend/`. They are separate layers:

- Type model (primitives, function signatures): `src/types/root.zig`.
- Semantic mappings (per-symbol, per-node types): `src/semantics/type_info.zig`.

The frontend pipeline (`frontend.analyze`) produces syntax-level output only. Any type annotation syntax the parser captures remains AST structure; it does not trigger semantic analysis within this layer. Semantic typing is a future pass that sits above the module graph and consumes both types from `src/types/` and symbol/node mappings from `src/semantics/`.


## Module Graph And Linker (Cross-File Resolution)

The multi-file flow lives in `src/modules/`:

```txt
entry path
  -> read source
  -> frontend.analyze per file (single-file pipeline above)
  -> collect static imports from each file's binder
  -> resolve relative imports by canonical path
  -> recursively analyze imported files
  -> cache by canonical path
  -> build import edges
  -> link named/default/namespace imports to target symbols via linker.Linker
  -> validate named imports against exports
  -> module diagnostics (VZG5xxx)
```

The module graph layer exposes `ModuleGraph.linked_imports`, which is a snapshot of all per-build cross-file import links. Each link captures:

- the local name and imported name in the source file
- the kind (`named`, `default`, `namespace`, `external`, or `unresolved`)
- the target module id (for resolved imports) and symbol id (when exported by the target)

`vizg modules <file>` renders these links as a "Links" section after Imports in CLI output:

```txt
Modules
  module 0 path="..."
  module 1 path="..."

Imports
  module 0 -> module 1 specifier="./dep" status=local

Links
  link 0 local="value" imported="value" from="./dep" status=local -> module 1 name="value"
  link 1 local="readFile" imported="readFile" from="node:fs" status=external -> unresolved

Diagnostics
  none
```

### Module Layer Files

- `src/modules/root.zig`: public API re-export.
- `src/modules/graph.zig`: graph structure, recursive traversal, import edges, export validation, module diagnostics (`VZG5xxx`).
- `src/modules/loader.zig`: source loading and single-file frontend analysis.
- `src/modules/resolver.zig`: relative import resolution and path canonicalization.
- `src/modules/linker.zig`: cross-file import link construction (named/default/namespace imports resolve to exported symbols; external imports preserved as `.external`).

### Diagnostics Scope

Module graph validates named imports against target value-space exports, reports missing local modules as `VZG5001`, missing named exports as `VZG5002`, and simple cycles as `VZG5003`. The linker does not emit diagnostics itself — unresolved links surface through the importer's status tag only.
