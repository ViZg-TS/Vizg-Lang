// By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const ast = @import("frontend/ast.zig");
pub const binder = @import("frontend/binder.zig");
pub const cfg = @import("frontend/cfg.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const frontend = @import("frontend/frontend.zig");
pub const modules = @import("modules/root.zig");
pub const parser = @import("frontend/parser.zig");
pub const resolver = @import("frontend/resolver.zig");
pub const scanner = @import("frontend/scanner.zig");
pub const tokens = @import("frontend/tokens.zig");

pub const semantics = @import("semantics/root.zig");

// Moved: type model now lives under `types/` so the frontend stays focused on
// syntax and single-file structural analysis. Callers can reach the same
// types via vizg.types.TypeId, vizg.types.Type, vizg.types.Builtins, etc.
pub const types = @import("types/root.zig");

/// C-compatible surface linked into libvizg.a. Lib/vizg.zig is the single ABI
/// authority shared with Lib/vizg.h.
pub const abi = @import("vizg-abi");

comptime {
    _ = abi;
}

test {
    _ = diagnostics;
    _ = binder;
    _ = cfg;
    _ = parser;
    _ = resolver;
    _ = scanner;
    _ = frontend;
    _ = tokens;
    _ = abi;
    // Keep existing modules graph test registration.
    _ = @import("modules/graph.zig");
    _ = @import("modules/loader.zig");
    _ = @import("modules/resolver.zig");
    _ = @import("modules/root.zig");
    _ = @import("modules/tests.zig");
    _ = @import("modules/contracts_test.zig");
    // Keep semantics layer wired in so its tests register alongside the rest.
    _ = @import("semantics/root.zig");
    _ = @import("semantics/type_info.zig");
    _ = @import("semantics/type_collector_test.zig");
    _ = @import("frontend/syntax_corpus_test.zig");
    _ = @import("frontend/tests.zig");
}
