# Source language items

ViZG source language-item contract v1 transports host-authorized semantic role
identity. It does not decide which project is a standard library, assign
built-in meaning, or recognize names such as `Array`, `Object`, or `String`.

A host registers each `SourceLanguageItem` before adding source. The descriptor
contains a non-zero opaque `LanguageItemId`, source `ModuleId`, exported-name
locator, and exact value or type namespace. ViZG owns a copy of the locator,
rejects duplicate role IDs and duplicate targets, and resolves the descriptor
after project semantic linking. Moving the source file or renaming the export
only changes the host-provided locator; downstream consumers use the stable role
ID and resolved semantic declaration.

Missing exports report `missing_language_item` (`VZG8002`). Exports that exist
only in the other namespace report `language_item_namespace_mismatch`
(`VZG8003`). An ambiguous semantic target reports
`duplicate_language_item_target` (`VZG8004`). These are project errors, so the
project result remains inspectable but no executable HIR is published.

Successful HIR schema v2 contains a sorted `HirLanguageItem` table. Each record
retains the role ID, diagnostic export spelling, and exact `HirSemanticIdentity`.
The Zig consumer API version is 2. Official ABI v1 exposes the additive
`vizg_project_register_source_language_items` entry point and HIR detail API v5
`vizg_hir_language_item_count`/`vizg_hir_language_item_at` accessors. Existing
source-host-binding and earlier HIR detail layouts are unchanged.

HIR detail API v7 additively exposes
`vizg_hir_language_item_function(LanguageItemId)`. A source-defined value
language item whose resolved declaration is an ordinary HIR function returns
that executable `FunctionId`; type-only or non-callable roles return
`VIZG_HIR_ID_NONE`. Source-function value-language-item modules are executable HIR roots so
downstream compilers can invoke an authorized protocol even when ordinary
application imports do not reach its implementation module. Type-only and
non-callable value language items remain semantic-only and do not by themselves
keep a module executable.

Signature or behavioral compatibility for a particular role is deliberately a
host concern: ViZG supplies the resolved type identity and optional executable
function identity so the host can validate and invoke its own versioned role
contract without moving compiler/runtime policy into the frontend.
