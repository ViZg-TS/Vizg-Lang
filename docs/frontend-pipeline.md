# Frontend Pipeline

The implemented frontend analyzes one source file at a time. Its public entry point is `frontend.analyze` in `src/frontend/frontend.zig`. Multi-file loading lives one layer above it in `src/modules_graph/`.

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
- import declarations
- export declarations and specifiers
- variable declarations and declarators
- function declarations and parameters
- return and expression statements
- call, member, binary, and assignment expressions
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

`frontend.analyze` remains single-file. Imports and exports are recorded as module metadata.

`modules.build` loads an entry file, analyzes it, follows static local imports, and caches modules by canonical path. Relative resolution tries:

- exact specifier when it ends in `.ts`
- `specifier + ".ts"`
- `specifier + "/index.ts"`

Non-relative imports are recorded as external edges and are not loaded. The module graph validates named imports against target value-space exports, reports missing local modules as `VZG5001`, missing named exports as `VZG5002`, and simple cycles as `VZG5003`.
