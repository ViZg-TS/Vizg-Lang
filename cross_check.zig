//! Compile-only portability probe for the generic analysis layers.
//! OS-specific CLI, filesystem, C ABI, and packaging adapters stay outside it.

const std = @import("std");
const frontend = @import("src/frontend/frontend.zig");
const types = @import("src/types/root.zig");
const semantics = @import("src/semantics/root.zig");

comptime {
    std.testing.refAllDecls(frontend);
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(semantics);
}
