//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("frontend/ast.zig");
pub const binder = @import("frontend/binder.zig");
pub const cfg = @import("frontend/cfg.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const frontend = @import("frontend/frontend.zig");
pub const modules = @import("modules_graph/root.zig");
pub const parser = @import("frontend/parser.zig");
pub const resolver = @import("frontend/resolver.zig");
pub const scanner = @import("frontend/scanner.zig");
pub const tokens = @import("frontend/tokens.zig");

test {
    _ = @import("diagnostics/root.zig");
    _ = @import("frontend/binder.zig");
    _ = @import("frontend/cfg.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/resolver.zig");
    _ = @import("frontend/scanner.zig");
    _ = @import("frontend/tests.zig");
    _ = @import("frontend/tokens.zig");
    _ = @import("modules_graph/graph.zig");
    _ = @import("modules_graph/loader.zig");
    _ = @import("modules_graph/resolver.zig");
    _ = @import("modules_graph/root.zig");
    _ = frontend;
}
