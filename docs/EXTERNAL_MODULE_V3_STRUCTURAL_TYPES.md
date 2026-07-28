# External-Module API v3 Structural Types

## Purpose

External-module API v2 can publish primitive function signatures but cannot
name a structural type or reuse it in multiple parameter and return positions.
API v3 adds that missing origin-neutral type graph.

## Contract

`VIZG_EXTERNAL_MODULE_API_VERSION` is `3`.
`vizg_project_respond_external_v3()` accepts:

- module-local stable external type identities;
- named closed structural types with ordered members;
- builtin or declared type references for every member;
- the same references for exports and function parameters/returns; and
- the stable symbols, declaration kinds and effects already required by v2.

All data is borrowed for the response call and copied into project-owned
storage. References to missing type identities, duplicate type/member names,
duplicate identities, malformed flags and nonzero reserved bytes are rejected.
V1 and v2 structures and entry points are unchanged.

The descriptor is semantic only. It contains no native size, alignment, offset,
calling convention, header, library or linker data.

## HIR projection

Named structural descriptors become ordinary canonical object types in the
semantic/HIR type store. `vizg_hir_type_member_count()` and
`vizg_hir_type_member_at()` enumerate object or interface members by HIR
`TypeId`. Returned member strings are borrowed for the result lifetime.

## Validation

The ABI lifecycle test publishes a raylib-like `Color` type with ordered
`r`, `g`, `b`, `a` members and a `Fade(Color, number): Color` declaration. It
then observes the four ordered members through the public HIR detail API.
C/Zig layout comparison covers every new public structure, and the ABI symbol
allowlist covers all new entry points.
