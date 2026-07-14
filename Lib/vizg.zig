//! Official ViZG C ABI v1 library root.

pub const abi = @import("abi.zig");

pub const VIZG_ABI_VERSION = abi.VIZG_ABI_VERSION;
pub const Vizg_ProjectStatus = abi.Vizg_ProjectStatus;
pub const Vizg_ProjectConfig = abi.Vizg_ProjectConfig;
pub const Vizg_ProjectSource = abi.Vizg_ProjectSource;
pub const Vizg_ProjectSpan = abi.Vizg_ProjectSpan;
pub const Vizg_ProjectRequestAttribute = abi.Vizg_ProjectRequestAttribute;
pub const Vizg_ProjectStep = abi.Vizg_ProjectStep;
pub const Vizg_ExternalExport = abi.Vizg_ExternalExport;
pub const Vizg_ExternalModule = abi.Vizg_ExternalModule;
pub const Vizg_ProjectResultSummary = abi.Vizg_ProjectResultSummary;

comptime {
    _ = abi;
}

test {
    _ = abi;
}
