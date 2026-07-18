# HIR storage and module metadata ABI fix

## Problem

Frozen HIR v1 already records module initialization dependencies, canonical
imports and exports, binding initialization state, and function captures. The
public read-only HIR projection did not expose those records. A downstream MIR
lowerer therefore could not distinguish source modules from external modules,
preserve live imported bindings, schedule module initialization, or construct
abstract closure environments without guessing from names.

The missing information was confined to the ABI projection. Canonical HIR v1
and its semantics remain unchanged.

## Fix

The additive `VIZG_HIR_DETAIL_API_VERSION` surface now includes:

- `Vizg_HirModuleDetail` plus indexed dependency, import, and export accessors;
- `Vizg_HirSemanticIdentity`, preserving stable declaration, symbol, type, and
  external-module identity;
- `Vizg_HirBindingDetail`, including the canonical initial binding state;
- `Vizg_HirFunctionStorageDetail` and indexed captures, preserving capture
  source and live-binding or lexical-value mode.

Module references explicitly identify source and external providers. Imported
bindings retain their local binding ID and canonical target. Dependency records
state whether initialization ordering is required. Capture records describe
semantic storage only: no byte offsets, frame layouts, environment layouts, or
target-specific representation are exposed.

## Compatibility and validation

This extension does not change `VIZG_ABI_VERSION`, frozen HIR v1, or any
existing public struct layout. It adds constants, structs, and read-only
symbols. Native and WebAssembly symbol allowlists, C/Zig layout probes, the C
HIR consumer, and lifecycle tests cover the extension, including source and
external imports, live binding state, initialization dependencies, and closure
captures.
