const graph_impl = @import("graph.zig");

pub const loader = @import("loader.zig");
pub const resolver = @import("resolver.zig");
pub const fs_module_host = @import("../fs_module_host.zig");

pub const BuildOptions = loader.BuildOptions;
pub const build = graph_impl.build;

pub const ModuleId = graph_impl.ModuleId;
pub const ImportEdgeId = graph_impl.ImportEdgeId;
pub const ImportStatus = graph_impl.ImportStatus;
pub const Module = graph_impl.Module;
pub const ImportEdge = graph_impl.ImportEdge;
pub const ModuleGraph = graph_impl.ModuleGraph;

pub const externals = @import("vizg-core").modules.externals;
pub const Registry = externals.Registry;
pub const LinkedImportKind = @import("vizg-core").modules.LinkedImportKind;

test {
    _ = graph_impl;
    _ = loader;
    _ = resolver;
    _ = fs_module_host;
    _ = @import("tests.zig");
    _ = @import("contracts_test.zig");
    _ = @import("semantic_project_tests.zig");
}
