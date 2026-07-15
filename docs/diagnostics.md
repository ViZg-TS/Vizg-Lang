# Diagnostics

Diagnostics are structured records defined in `src/diagnostics/root.zig`.

## Model

Each diagnostic has:

- `severity`: `error`, `warning`, `info`, or `hint`.
- `code`: stable enum value mapped to a `VZG` code.
- `phase`: pipeline phase that produced the diagnostic.
- `message`: human-readable text.
- `span`: source span with line, column, and byte offsets.
- `label`: optional short label.
- `related`: zero or more related source spans with explanatory messages.
- `path`: optional source path for diagnostics produced outside a single-file result.

The CLI prints diagnostics as:

```txt
file.ts:1:9 error VZG4001 cannot_find_name: cannot find name 'missing'
```

When no path is available, the leading `file.ts:` prefix is omitted.

Across the C ABI, diagnostic messages and paths are pointer/length pairs. Consumers must not assume NUL termination. An absent path is always represented by a null pointer and a zero length.

## Canonical Project Diagnostics

`Project` owns one canonical diagnostic table after `finish()`. Each row contains
an explicit optional `ModuleId`, canonical project phase, severity, code,
message, logical name, and span. `logical_name` is descriptive only and is
never used to recover or infer module identity.

The project phases exposed through the Zig API and C ABI are exactly:

- `scanner`
- `parser`
- `binder`
- `resolver`
- `types`
- `checker`
- `module_host`
- `project`

Scanner, parser, binder, resolver, type, and checker diagnostics retain the
identity of the source module that produced them. Module request failures are
classified as `module_host`; graph and linking failures are classified as
`project`. The final table is deterministic and removes only rows whose module
identity, phase, severity, code, message, logical name, and span are all equal.

The C ABI reads this table directly through
`vizg_project_result_diagnostic`. It does not reconstruct module identity from
logical names or merge a second diagnostics source.

## Current Codes

| Code | Name | Phase | Meaning |
| --- | --- | --- | --- |
| `VZG1001` | `invalid_character` | scanner | Unknown character. |
| `VZG1002` | `unterminated_string` | scanner | String or template string did not terminate. |
| `VZG1003` | `unterminated_block_comment` | scanner | Block comment did not terminate. |
| `VZG1004` | `invalid_number` | scanner | Invalid number format, exponent, or numeric separator. |
| `VZG1005` | `invalid_escape_sequence` | scanner | Invalid or incomplete string/template escape sequence. |
| `VZG1006` | `unterminated_regexp` | scanner | RegExp literal did not terminate. |
| `VZG1007` | `invalid_regexp` | scanner | RegExp literal contains invalid or duplicate flags. |
| `VZG1008` | `invalid_utf8` | scanner | Source text is not valid UTF-8. |
| `VZG2001` | `unexpected_token` | parser | Token was not valid in the current parse position. |
| `VZG2002` | `expected_token` | parser | Parser expected a specific token. |
| `VZG2003` | `parse_recursion_limit_reached` | parser | Configured parser recursion limit was reached. |
| `VZG2004` | `unsupported_syntax` | parser | Recognized JavaScript syntax is intentionally unsupported. |
| `VZG2005` | `unsupported_ts_syntax` | parser | Recognized TypeScript syntax is intentionally unsupported. |
| `VZG2006` | `unsupported_jsx` | parser | Recognized JSX or TSX syntax is intentionally unsupported. |
| `VZG3001` | `duplicate_declaration` | binder | Scope already contains a declaration with that name. |
| `VZG3002` | `duplicate_export` | binder | Module already exports that name. |
| `VZG4001` | `cannot_find_name` | resolver | Identifier reference did not resolve to a symbol. |
| `VZG5001` | `module_not_found` | module_graph | Relative import could not be resolved to a source file. |
| `VZG5002` | `missing_export` | module_graph | Named import requested an export the target module does not provide. |
| `VZG5003` | `circular_import` | module_graph | Static local imports formed a cycle. |
| `VZG5004` | `module_access_denied` | module_graph | The host denied access while resolving a module request. |
| `VZG5005` | `module_host_failed` | module_graph | The host failed a module request for another reason. |
| `VZG6004` | `unknown_type_name` | type_checker | A type annotation names a type that cannot be resolved. |
| `VZG6005` | `type_mismatch` | type_checker | Initialization, assignment, compound-assignment result, return/fallthrough, operator, `satisfies`, call target, or constructor target types are incompatible. |
| `VZG6006` | `unknown_property` | type_checker | Property lookup failed on the receiver type. |
| `VZG6007` | `invalid_index` | type_checker | Indexed access used an unsupported key or index. |
| `VZG6008` | `invalid_argument_count` | type_checker | Call argument count does not match the function signature. |
| `VZG6009` | `invalid_argument_type` | type_checker | Call argument is incompatible with its parameter. |
| `VZG9001` | `internal_error` | internal | Internal diagnostic bucket. |

## Code Ranges

| Range | Owner | Status |
| --- | --- | --- |
| `VZG1xxx` | scanner | Implemented. |
| `VZG2xxx` | parser | Implemented. |
| `VZG3xxx` | binder | Implemented. |
| `VZG4xxx` | resolver | Implemented. |
| `VZG5xxx` | module graph | Implemented for minimal module graph errors. |
| `VZG6xxx` | type checker | Implemented for current semantic checks. |
| `VZG7xxx` | HIR/lowering | Reserved for future work. |
| `VZG8xxx` | runtime | Reserved for future work. |
| `VZG9xxx` | internal errors | Partially reserved; `VZG9001` exists. |

## Phases

The diagnostic phase enum includes:

- `scanner`
- `parser`
- `binder`
- `resolver`
- `cfg`
- `module_graph`
- `type_checker`
- `lowering`
- `runtime`
- `internal`

Scanner, parser, binder, resolver, module graph, and type checker currently produce normal diagnostics. Other phase names are reserved so stable diagnostic shape can survive new layers.

Unsupported-syntax diagnostics point at the construct that selected the
unsupported grammar path. The parser skips to that construct's statement,
member, or type boundary so later statements can still be analyzed without a
cascade of generic token errors.

Checker diagnostics use the offending expression or argument as the primary
span and attach the relevant declaration, target, callee, receiver, or operand
as a related span when available. They are emitted in deterministic source
order. Nodes already typed as unresolved, unknown, or recovered error suppress
derivative checker diagnostics.

Structural `VZG6005` diagnostics include the stable failing property path when
an interface or anonymous-object member is missing or incompatible, including
requirements inherited from base interfaces.

## Labels, Notes, And Hints

The current struct has one optional `label` plus related spans. It does not yet
model fix-it hints or a richer note hierarchy.
