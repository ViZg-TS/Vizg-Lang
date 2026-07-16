# CLI

The `vizg` CLI lives in `src/main.zig`. Single-file commands read source bytes
once, call the source-only semantic API, and print one inspection view. The
`modules` command drives the portable project API through the optional native

> The CLI filesystem behavior is only a validation host for the module-provider API. ViZG itself does not resolve modules.

test-only `FsValidationHost` fixture.

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
  types <file>    print canonical semantic symbol and expression types
  modules <file>  build and print the portable module project
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

## `types <file>`

Purpose: run typed semantics and print canonical symbol and expression types. Structural types include their members; class and interface output includes stable nominal identity information. Supported structural types are not rendered as `<unknown>`.

Example:

```sh
zig build run -- types test/frontend/vizg_capabilities_test.ts
```

Exit behavior: exits `0` when semantic analysis completes. Semantic diagnostics remain inspectable in the output.

## `modules <file>`

Purpose: validate the portable module-provider contract from a development
entry file and print Modules, Imports, Links, and Diagnostics.

This command uses the repository-only `FsValidationHost` fixture. It is not a
ViZG resolver and does not define runtime behavior. The fixture reads files and
answers the same requests that any external host could answer from memory,
URLs, packages, a database, or virtual modules.

ViZG itself:

- receives the root source bytes;
- discovers imports, exports, re-exports, type-only edges, and dynamic requests;
- emits raw specifiers and spans;
- accepts host-assigned `ModuleId` values and source/external/failure responses;
- builds the graph and semantic links.

External declarations are validation metadata only and are never executed:

```txt
vizg modules <file> --add-external "name"
vizg modules <file> --externals-dir ./externals
```

`--add-external name=label` remains accepted; only `name` is the raw specifier.
`--externals-dir` uses basenames to create source-less descriptors and does not
execute file contents.

Example:

```sh
zig build run -- modules test/frontend/modules/manual/success.ts
```

Output shape:

```txt
Modules
  module 1 path=".../success.ts" state=complete
  module 2 path=".../dep.ts" state=complete

Imports
  module 1 -> module 2 specifier="./dep" operation=static_import type_only=false status=resolved span=...

Links
  link 0 module=1 local="value" imported="value" state=resolved span=...

Diagnostics
  none
```

Exit behavior: exits `0` when the project has no error diagnostics and `1` for
terminal host responses or syntax/semantic/module errors. Partial modules,
edges, spans, and diagnostics remain printable.

A runtime implements the same contract directly: submit roots, call
`Project.step()`, answer each request exactly once, then call `finish()`. Only
`ModuleId` is canonical. A host must not submit imports/exports for ordinary
source modules because ViZG derives them from the supplied source.

The project is one-shot. It has no stale-response or source-revision workflow.
To analyze changed source, destroy the project and create another one.

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
