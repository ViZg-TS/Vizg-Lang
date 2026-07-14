# CLI

The `vizg` CLI lives in `src/main.zig`. Single-file commands read source bytes
once, call the source-only semantic API, and print one inspection view. The
`modules` command drives the portable project API through the optional native
`FsModuleHost` adapter.

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

Purpose: drive a portable project from an entry file and print the Modules,
Imports, Links, and Diagnostics sections.

`FsModuleHost` accepts relative specifiers and tries `.ts`, `.tsx`, `.js`, and
`.jsx` files before matching `index` files. It confines canonical results to the
root file's directory. Missing, denied, and failed loads become explicit project
responses; cyclic requests terminate through the portable state machine.

The core derives imports, exports, graph diagnostics, and semantic links from
host-supplied bytes. Output preserves each source logical path and import span.

External declarations (optional):

The CLI accepts two flags for registering externals — API contracts only, never executed or bundled:

```txt
vizg modules <file> --add-external "name"
vizg modules <file> --externals-dir ./externals
```

`--add-external name=label` remains accepted; only `name` is the specifier.
`--externals-dir` registers each file basename as a source-less descriptor and
does not read or execute file contents.

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
  module 1 -> module 2 specifier="./dep" kind=static import_kind=named status=resolved span=...

Links
  link 0 module=1 local="value" imported="value" state=resolved span=...

Diagnostics
  none
```

The Links section appears when the finished project exposes semantic imports.
Each line reports the owning module, local/imported names, portable link state,
and original source span.

Exit behavior: exits `0` when the project has no error diagnostics. Exits `1`
for terminal host responses or semantic/module errors. Partial modules, edges,
spans, and diagnostics remain printable.

An embedding can replace `FsModuleHost` with any driver that submits root
bytes, calls `Project.step()`, resolves requests, and supplies source, external,
not-found, denied, or failed responses. No filesystem adapter is required by
core.

The driver must treat `ModuleId` as the only canonical source identity. Paths,
URLs, logical names, and raw specifiers are presentation or lookup inputs, not
graph keys. The core parses every supplied source and derives its imports and
exports; a host must not submit an import/export table for source modules.
External descriptors use `ExternalModuleId`, remain distinct from source
modules, and describe only host-known exports and portable type metadata.

For recovery, answer each request exactly once and call `step` again. A stale,
foreign, duplicate, or out-of-order response is rejected without becoming a
new request. Missing, denied, and failed responses are terminal graph facts but
do not discard completed modules; `finish` exposes the partial project. Bounds
or workspace exhaustion are not retry/rollback guarantees: destroy the project
and restart with corrected inputs or capacity.

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
