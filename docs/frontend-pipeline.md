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
- declaration, default-expression, local, star, named re-export, and type-only export forms
- variable declarations and declarators
- function declarations, ordinary parameters, and final rest parameters
- structured type annotations with generic, array, readonly, union, intersection, object, function, tuple, and parenthesized nodes
- type alias declarations and interfaces whose members reuse the structured type AST; interface `extends` lists are preserved
- class declarations and expressions with optional `extends`, typed fields, constructors, methods, `static`, and `public`/`private`/`protected` syntax
- return, throw, try/catch/finally, break, continue, and expression statements
- call, member, binary, conditional, assignment, and prefix unary expressions
- spread elements in calls, arrays, and object literals
- postfix non-null assertions, distinct from prefix `!`
- right-associative exponentiation plus multiplicative, additive, shift, relational, equality, bitwise, logical, nullish-coalescing, conditional, and assignment precedence levels
- deterministic parser diagnostics for unparenthesized mixing of `??` with `&&` or `||`
- template expressions with traversable interpolation expressions
- `if`, `switch`/`case`/`default`, `while`, `do`/`while`, classic `for`, `for-in`, `for-of`, and syntax-only `for await...of` statements

`break` and `continue` are currently unlabeled. A following label produces a stable parser diagnostic and parsing resumes after the statement.
`throw` requires an expression on the same source line. Its expression is traversed normally, and its CFG block terminates the current path; exception typing remains out of scope.
`try` requires at least one `catch` or `finally` clause. A catch binding lives in a dedicated block scope and does not leak outside its clause. The CFG preserves try, catch, and finally branches without exception-flow type analysis.
Iteration declarations accept exactly one variable without an initializer. Their binding lives in a loop-header scope shared with the iteration RHS and body.

Parser diagnostics use `VZG2xxx` codes.

## Binder

The binder walks the AST and builds:

- global, function, and block scopes
- variable, function, parameter, import, type-alias, interface, class, field, and method symbols
- separate value and type namespaces, so a type declaration can share a name with a value declaration
- AST node to symbol links
- module import records
- module export records

It reports duplicate declarations and duplicate exports with `VZG3xxx` codes.
Interfaces do not merge; a repeated interface or type alias in the same type namespace is a duplicate declaration.

Classes bind in both value and type namespaces. Each class has a member scope; each method or constructor has a nested function scope. `this` and `super` are syntax nodes traversed within those scopes. Decorators, private fields, abstract semantics, and class type checking are deferred.

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

Loop CFGs route `break` to the loop exit and `continue` to the condition, or to a classic `for` update block when present. `for-in` and `for-of` condition blocks retain body and exit edges. A `do`/`while` CFG enters the body before its condition. Switch dispatch blocks reach every clause, omit the unmatched exit when a default exists, and connect non-terminating clauses to the next clause to preserve fallthrough. `break` uses the innermost loop or switch exit; `continue` remains loop-only.

Try CFGs expose normal try and catch paths and join their fallthrough through an explicit finally branch when present. Exception-flow typing and lowering remain out of scope.

`cfg <file>` prints function graphs for inspection. The current CFG is a frontend analysis artifact, not a lowered IR.

## Diagnostics Combination

`frontend.analyze` combines scanner, parser, binder, and resolver diagnostics into `FrontendResult.diagnostics`. CFG diagnostics are not currently produced.

## Current Scope

`frontend.analyze` remains single-file. Imports and exports are recorded as module metadata and forwarded to the linker layer below for cross-file resolution.

## Note on Type Model Location

The type model and semantic mapping do **not** live inside `src/frontend/`. They are separate layers:

- Type model (primitives, function signatures): `src/types/root.zig`.
- Semantic mappings (per-symbol, per-node types): `src/semantics/type_info.zig`.

The frontend pipeline (`frontend.analyze`) produces syntax-level output only. Type annotations are a structured, span-preserving syntax tree with dedicated union, intersection, function, and array precedence. This syntax tree is distinct from semantic `TypeId` values. Primitive named annotations remain compatible with the current semantic collector; composite interpretation remains a later semantic pass above the module graph.


## Module Graph And Linker (Cross-File Resolution)

The multi-file flow lives in `src/modules/`:

```txt
entry path
  -> read source
  -> frontend.analyze per file (single-file pipeline above)
  -> collect static imports and re-export sources from each file's AST
  -> resolve relative imports by canonical path
  -> recursively analyze imported and re-exported files
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

Each import edge also preserves source specifier, declaration kind (`named`, `default`, `namespace`, `side_effect`, or `mixed`), and declaration-level `type_only` marker. Mixed imports retain per-specifier default/named kinds in AST and binder records.

`vizg modules <file>` renders these links as a "Links" section after Imports in CLI output:

```txt
Modules
  module 0 path="..."
  module 1 path="..."

Imports
  module 0 -> module 1 specifier="./dep" kind=named type_only=false status=local

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
