//! Dependency lint for the portable core import graph.
//! A freestanding compile forces every public core declaration to remain free
//! of filesystem, process, POSIX, WASI, environment, adapter, and ABI imports.

const std = @import("std");
const core = @import("src/root.zig");

comptime {
    std.testing.refAllDecls(core);
}
