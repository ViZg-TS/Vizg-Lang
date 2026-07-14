//! Native host adapter package root. Kept at src/ so adapter implementations
//! may consume portable core files without escaping the Zig module boundary.
const adapter = @import("adapters/native_fs/root.zig");

pub const loader = adapter.loader;
pub const resolver = adapter.resolver;
pub const fs_module_host = adapter.fs_module_host;
pub const FsModuleHost = adapter.fs_module_host.FsModuleHost;
pub const BuildOptions = adapter.BuildOptions;
pub const build = adapter.build;
pub const ModuleId = adapter.ModuleId;
pub const ImportEdgeId = adapter.ImportEdgeId;
pub const ImportStatus = adapter.ImportStatus;
pub const Module = adapter.Module;
pub const ImportEdge = adapter.ImportEdge;
pub const ModuleGraph = adapter.ModuleGraph;
pub const externals = adapter.externals;
pub const Registry = adapter.Registry;
pub const LinkedImportKind = adapter.LinkedImportKind;

test {
    _ = adapter;
}
