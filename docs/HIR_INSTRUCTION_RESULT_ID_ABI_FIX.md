# HIR instruction result identity ABI fix

Date: 2026-07-16

## Defect

`Vizg_HirRecord` instruction rows exposed the instruction, block, and function
identities, but omitted `HirInstruction.result`. Instruction IDs and result
`ValueId`s are independent HIR domains, so a downstream MIR consumer could not
connect an operation definition to operands that reference its result.

## Change

- `VIZG_HIR_API_VERSION` is now 2.
- An instruction record requested with v2 stores its optional result `ValueId`
  in `secondary_id`; absence is `VIZG_HIR_ID_NONE`, matching flags bit 0.
- Requests for v1 remain accepted and keep the original parent-function value
  in `secondary_id`.
- The parent function remains recoverable from the instruction's parent block.
- `Vizg_HirRecord`, the official ABI v1 layout, symbols, ownership, and frozen
  HIR v1 model are unchanged.

The change is synchronized between VZed's ignored `vendor/vizg` checkout and
the sibling `../vizg` source repository.

## Validation

- `zig build test --summary all`: 29/29 build steps and 503/503 tests passed
  independently in both trees.
- `zig build validate --summary all`: 36/36 steps and 503/503 tests passed in
  the sibling source repository; the three emitted `VZG2004` diagnostics are
  the validation fixture's expected warnings.
- Official ABI layout, symbol, and native C-consumer checks passed as part of
  both test runs.
- Standalone C11 header syntax, `zig fmt --check`, and `git diff --check`
  passed in both trees.
