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
- `path`: optional source path for diagnostics produced outside a single-file result.

The CLI prints diagnostics as:

```txt
file.ts:1:9 error VZG4001 cannot_find_name: cannot find name 'missing'
```

When no path is available, the leading `file.ts:` prefix is omitted.

Across the C ABI, diagnostic messages and paths are pointer/length pairs. Consumers must not assume NUL termination. An absent path is always represented by a null pointer and a zero length.

## Current Codes

| Code | Name | Phase | Meaning |
| --- | --- | --- | --- |
| `VZG1001` | `invalid_character` | scanner | Unknown character. |
| `VZG1002` | `unterminated_string` | scanner | String or template string did not terminate. |
| `VZG1003` | `unterminated_block_comment` | scanner | Block comment did not terminate. |
| `VZG1004` | `invalid_number` | scanner | Invalid number format, exponent, or numeric separator. |
| `VZG1005` | `invalid_escape_sequence` | scanner | Invalid or incomplete string/template escape sequence. |
| `VZG2001` | `unexpected_token` | parser | Token was not valid in the current parse position. |
| `VZG2002` | `expected_token` | parser | Parser expected a specific token. |
| `VZG3001` | `duplicate_declaration` | binder | Scope already contains a declaration with that name. |
| `VZG3002` | `duplicate_export` | binder | Module already exports that name. |
| `VZG4001` | `cannot_find_name` | resolver | Identifier reference did not resolve to a symbol. |
| `VZG5001` | `module_not_found` | module_graph | Relative import could not be resolved to a source file. |
| `VZG5002` | `missing_export` | module_graph | Named import requested an export the target module does not provide. |
| `VZG5003` | `circular_import` | module_graph | Static local imports formed a cycle. |
| `VZG9001` | `internal_error` | internal | Internal diagnostic bucket. |

## Code Ranges

| Range | Owner | Status |
| --- | --- | --- |
| `VZG1xxx` | scanner | Implemented. |
| `VZG2xxx` | parser | Implemented. |
| `VZG3xxx` | binder | Implemented. |
| `VZG4xxx` | resolver | Implemented. |
| `VZG5xxx` | module graph | Implemented for minimal module graph errors. |
| `VZG6xxx` | type checker | Reserved for future work. |
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

Scanner, parser, binder, resolver, and module graph currently produce normal diagnostics. Other phase names are reserved so stable diagnostic shape can survive new layers.

## Labels, Notes, And Hints

The current struct has one optional `label`. It does not yet model multi-label diagnostics, notes, or fix-it hints. Reserve those concepts for future diagnostic rendering work.
