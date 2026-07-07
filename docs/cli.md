# CLI

The `vizg` CLI lives in `src/main.zig`. Most commands read one source file, run `frontend.analyze`, and print one inspection view. The `modules` command loads an entry file plus local imports and prints the module graph.

Build first:

```sh
zig build
```

Run through Zig:

```sh
zig build run -- <command> [file]
```

Run installed binary:

```sh
./zig-out/bin/vizg <command> [file]
```

## Commands

## `help`

Purpose: print usage and command list.

Example:

```sh
zig build run -- help
```

Output shape:

```txt
usage: .../vizg <command> [file]

commands:
  check <file>    run frontend pipeline and print diagnostics
  tokens <file>   print scanner tokens
  ast <file>      print readable AST tree
  symbols <file>  print scopes, symbols, imports, exports, diagnostics
  references <file> print resolved identifier references
  refs <file>       alias for references
  cfg <file>      print function control-flow graphs
  modules <file>  build and print the module graph
  help            print this help
```

Exit behavior: exits `0` for `help`. Passing a file argument to `help` exits `1`.

## `check <file>`

Purpose: run the whole frontend pipeline and print diagnostic counts plus diagnostics.

Example:

```sh
zig build run -- check test/frontend/vizg_capabilities_test.ts
```

Output shape:

```txt
checked: test/frontend/vizg_capabilities_test.ts
source kind: module
diagnostics: 0 errors, 0 warnings
```

With errors:

```txt
checked: test/frontend/resolver_missing_name.ts
source kind: module
diagnostics: 1 errors, 0 warnings
test/frontend/resolver_missing_name.ts:1:9 error VZG4001 cannot_find_name: cannot find name 'missing'
```

Exit behavior: exits `0` when there are no error diagnostics. Exits `1` when error diagnostics exist, when the command is unknown, when arguments are invalid, or when the file cannot be read.

## `tokens <file>`

Purpose: print scanner tokens.

Example:

```sh
zig build run -- tokens test/frontend/basic-module.ts
```

Output shape:

```txt
1:1  Keyword_import  "import"  0..6
1:8  LBrace  "{"  7..8
1:10  Identifier  "log"  9..12
...
8:1  EOF  ""  138..138
```

Exit behavior: exits `0` if the frontend command completes. Scanner diagnostics are printed only by commands that include diagnostics output, such as `check`, `symbols`, and `references`.

## `ast <file>`

Purpose: print a readable AST tree.

Example:

```sh
zig build run -- ast test/frontend/basic-module.ts
```

Output shape:

```txt
Program
  ImportDeclaration ...
  FunctionDeclaration ...
    BlockStatement
      VariableDeclaration ...
```

Exit behavior: exits `0` if the frontend command completes.

## `symbols <file>`

Purpose: print binder output: scopes, symbols, imports, exports, and diagnostics.

Example:

```sh
zig build run -- symbols test/frontend/vizg_capabilities_test.ts
```

Output shape:

```txt
Scopes
  scope 0 kind=global parent=null symbols=[...]

Symbols
  symbol 0 name="..." kind=function scope=0 node=... span=.....

Imports
  ... from "..."

Exports
  ... node=...

Diagnostics
  none
```

Exit behavior: exits `0` if the frontend command completes.

## `references <file>`

Purpose: print resolver references and diagnostics.

Example:

```sh
zig build run -- references test/frontend/resolver_missing_name.ts
```

Output shape:

```txt
References
  ref 0 node=0 name="missing" kind=read scope=0 symbol=null span=8..15

Diagnostics
test/frontend/resolver_missing_name.ts:1:9 error VZG4001 cannot_find_name: cannot find name 'missing'
```

Exit behavior: exits `0` if the frontend command completes. This command prints diagnostics but does not fail solely because diagnostics exist.

## `refs <file>`

Purpose: alias for `references <file>`.

Example:

```sh
zig build run -- refs test/frontend/resolver_missing_name.ts
```

Expected output and exit behavior match `references`.

## `cfg <file>`

Purpose: print preliminary function control-flow graphs.

Example:

```sh
zig build run -- cfg test/frontend/control-flow.ts
```

Output shape:

```txt
Function name #node
  entry: 0
  exit: 1

  block 0
    kind: entry
    statements: [...]
    successors: [...]
    predecessors: [...]
```

Exit behavior: exits `0` if the frontend command completes.

## `modules <file>`

Purpose: build a minimal module graph from an entry file.

Relative imports are resolved by canonical path. The resolver tries the exact specifier when it already ends in `.ts`, then `specifier + ".ts"`, then `specifier + "/index.ts"`. Non-relative imports are recorded as external edges and are not loaded or export-validated.

Example:

```sh
zig build run -- modules test/frontend/modules/manual/success.ts
```

Output shape:

```txt
Modules
  0 /absolute/path/test/frontend/modules/manual/success.ts
  1 /absolute/path/test/frontend/modules/manual/dep.ts

Imports
  0 -> 1 "./dep" [local]
  0 -> external "node:fs" [external]

Diagnostics
  none
```

Exit behavior: exits `0` when the graph has no error diagnostics. Exits `1` for module graph errors such as `VZG5001 module_not_found`, `VZG5002 missing_export`, or `VZG5003 circular_import`.

## Argument And Read Errors

No command or unknown command prints help to stderr and exits `1`.

File read errors print:

```txt
path.ts: error reading file: ErrorName
```

Frontend runtime errors print:

```txt
path.ts: frontend error: ErrorName
```
