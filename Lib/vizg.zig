//! Official ViZG C ABI v1 library root.

pub const abi = @import("abi.zig");

/// Version sentinel — host must compare \`vizg_abi_version()\` against this.
pub const VIZG_ABI_VERSION = abi.VIZG_ABI_VERSION;
pub const VIZG_HIR_API_VERSION = abi.VIZG_HIR_API_VERSION;
pub const VIZG_MAX_SOURCE_LENGTH = abi.VIZG_MAX_SOURCE_LENGTH;

/// Project construction / lifecycle types.
pub const Vizg_ProjectStatus = abi.Vizg_ProjectStatus;
pub const Vizg_LimitKind = abi.Vizg_LimitKind;
pub const Vizg_ProjectConfig = abi.Vizg_ProjectConfig;
pub const Vizg_ProjectSource = abi.Vizg_ProjectSource;
pub const Vizg_ProjectSpan = abi.Vizg_ProjectSpan;
pub const Vizg_ProjectRequestAttribute = abi.Vizg_ProjectRequestAttribute;
pub const Vizg_ProjectStep = abi.Vizg_ProjectStep;

/// External module / export descriptors.
pub const Vizg_ExternalNamespaceFlags = abi.Vizg_ExternalNamespaceFlags;
pub const VIZG_EXTERNAL_NAMESPACE_VALUE = abi.VIZG_EXTERNAL_NAMESPACE_VALUE;
pub const VIZG_EXTERNAL_NAMESPACE_TYPE = abi.VIZG_EXTERNAL_NAMESPACE_TYPE;
pub const VIZG_EXTERNAL_NAMESPACE_BOTH = abi.VIZG_EXTERNAL_NAMESPACE_BOTH;
pub const Vizg_ExternalExport = abi.Vizg_ExternalExport;
pub const Vizg_ExternalModule = abi.Vizg_ExternalModule;

/// Result introspection types — summary plus per-item iterators.
pub const Vizg_ProjectResultSummary = abi.Vizg_ProjectResultSummary;
pub const Vizg_ProjectModuleInfo = abi.Vizg_ProjectModuleInfo;
pub const Vizg_ProjectDiagnostic = abi.Vizg_ProjectDiagnostic;
pub const Vizg_ProjectEdgeInfo = abi.Vizg_ProjectEdgeInfo;
pub const Vizg_ProjectImportInfo = abi.Vizg_ProjectImportInfo;
pub const Vizg_ProjectExportInfo = abi.Vizg_ProjectExportInfo;

/// Versioned immutable HIR result view.
pub const Vizg_HirEntityKind = abi.Vizg_HirEntityKind;
pub const Vizg_HirSummary = abi.Vizg_HirSummary;
pub const Vizg_HirRecord = abi.Vizg_HirRecord;

comptime {
    _ = abi;
}

test {
    _ = abi;
}
