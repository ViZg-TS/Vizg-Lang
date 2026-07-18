# External Function Coarse-Type Precedence Fix

## Problem

External module v2 descriptors may provide both a detailed portable function
signature and coarse primitive type metadata. The initial semantic graph used
the coarse metadata first, so the checker could diagnose a valid imported
function call as `VZG6005` (expression is not callable) before external-link
enrichment installed the detailed signature.

The defect was exposed by VZed while translating a target-selected C header
function into an origin-neutral ViZg external module.

## Change

When an external export contains a detailed function signature, ViZg now omits
the coarse fallback from the initial graph export. External-link enrichment
therefore installs the authoritative function type before checker analysis.
Coarse metadata remains unchanged for descriptors without a detailed function
signature.

## Compatibility

This is an internal precedence correction. It does not change the external
module v2 descriptor layout, public ABI versions, or frozen HIR v1 contracts.

## Regression Coverage

The project-session regression supplies both `.type_metadata = .object` and a
detailed number-returning function signature, imports and calls that symbol,
and verifies that checking succeeds with the imported type classified as a
function.
