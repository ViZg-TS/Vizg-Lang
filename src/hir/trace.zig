//! Full-debug-only lowering history. Events are metadata and never alter HIR.

const ids = @import("ids.zig");

pub const EventKind = enum {
    switch_to_dispatch,
    conditional_to_branch,
    logical_and_to_branch,
    optional_chain_to_nullish_branch,
    compound_assignment_to_place_load_store,
    arrow_to_function,
    interface_erased,
    type_alias_erased,
    constant_folded,
    unreachable_removed,
    blocks_merged,
    canonical_rewrite,
};

pub const Event = struct {
    kind: EventKind,
    inputs: []const ids.OriginId = &.{},
    output: ?ids.OriginId = null,
};

pub const LoweringTrace = struct {
    events: []const Event = &.{},
};
