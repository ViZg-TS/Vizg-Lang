//! Official ViZG C ABI v1 library root.

pub const abi = @import("abi.zig");

/// Version sentinel — host must compare \`vizg_abi_version()\` against this.
pub const VIZG_ABI_VERSION = abi.VIZG_ABI_VERSION;
pub const VIZG_HIR_API_VERSION = abi.VIZG_HIR_API_VERSION;
pub const VIZG_HIR_PAYLOAD_API_VERSION = abi.VIZG_HIR_PAYLOAD_API_VERSION;
pub const VIZG_HIR_DETAIL_API_VERSION = abi.VIZG_HIR_DETAIL_API_VERSION;
pub const VIZG_EXTERNAL_MODULE_API_VERSION = abi.VIZG_EXTERNAL_MODULE_API_VERSION;
pub const VIZG_HIR_ID_NONE = abi.VIZG_HIR_ID_NONE;
pub const VIZG_HIR_U32_NONE = abi.VIZG_HIR_U32_NONE;
pub const VIZG_HIR_TYPE_PRIMITIVE = abi.VIZG_HIR_TYPE_PRIMITIVE;
pub const VIZG_HIR_TYPE_FUNCTION = abi.VIZG_HIR_TYPE_FUNCTION;
pub const VIZG_HIR_TYPE_PROMISE = abi.VIZG_HIR_TYPE_PROMISE;
pub const VIZG_HIR_TYPE_GENERATOR = abi.VIZG_HIR_TYPE_GENERATOR;
pub const VIZG_HIR_TYPE_LITERAL = abi.VIZG_HIR_TYPE_LITERAL;
pub const VIZG_HIR_TYPE_UNION = abi.VIZG_HIR_TYPE_UNION;
pub const VIZG_HIR_TYPE_INTERSECTION = abi.VIZG_HIR_TYPE_INTERSECTION;
pub const VIZG_HIR_TYPE_ARRAY = abi.VIZG_HIR_TYPE_ARRAY;
pub const VIZG_HIR_TYPE_TUPLE = abi.VIZG_HIR_TYPE_TUPLE;
pub const VIZG_HIR_TYPE_OBJECT = abi.VIZG_HIR_TYPE_OBJECT;
pub const VIZG_HIR_TYPE_CLASS = abi.VIZG_HIR_TYPE_CLASS;
pub const VIZG_HIR_TYPE_CLASS_CONSTRUCTOR = abi.VIZG_HIR_TYPE_CLASS_CONSTRUCTOR;
pub const VIZG_HIR_TYPE_INTERFACE = abi.VIZG_HIR_TYPE_INTERFACE;
pub const VIZG_HIR_TYPE_ENUM = abi.VIZG_HIR_TYPE_ENUM;
pub const VIZG_HIR_TYPE_PARAMETER = abi.VIZG_HIR_TYPE_PARAMETER;
pub const VIZG_HIR_TYPE_APPLIED_GENERIC = abi.VIZG_HIR_TYPE_APPLIED_GENERIC;
pub const VIZG_HIR_MODULE_REFERENCE_SOURCE = abi.VIZG_HIR_MODULE_REFERENCE_SOURCE;
pub const VIZG_HIR_MODULE_REFERENCE_EXTERNAL = abi.VIZG_HIR_MODULE_REFERENCE_EXTERNAL;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_VALUE = abi.VIZG_HIR_SEMANTIC_NAMESPACE_VALUE;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_TYPE = abi.VIZG_HIR_SEMANTIC_NAMESPACE_TYPE;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_NAMESPACE = abi.VIZG_HIR_SEMANTIC_NAMESPACE_NAMESPACE;
pub const VIZG_HIR_BINDING_STATE_HOISTED_UNDEFINED = abi.VIZG_HIR_BINDING_STATE_HOISTED_UNDEFINED;
pub const VIZG_HIR_BINDING_STATE_HOISTED_FUNCTION = abi.VIZG_HIR_BINDING_STATE_HOISTED_FUNCTION;
pub const VIZG_HIR_BINDING_STATE_TEMPORAL_DEAD_ZONE = abi.VIZG_HIR_BINDING_STATE_TEMPORAL_DEAD_ZONE;
pub const VIZG_HIR_BINDING_STATE_INITIALIZED = abi.VIZG_HIR_BINDING_STATE_INITIALIZED;
pub const VIZG_HIR_BINDING_STATE_LIVE_IMPORT = abi.VIZG_HIR_BINDING_STATE_LIVE_IMPORT;
pub const VIZG_HIR_CAPTURE_SOURCE_BINDING = abi.VIZG_HIR_CAPTURE_SOURCE_BINDING;
pub const VIZG_HIR_CAPTURE_SOURCE_THIS = abi.VIZG_HIR_CAPTURE_SOURCE_THIS;
pub const VIZG_HIR_CAPTURE_SOURCE_ARGUMENTS = abi.VIZG_HIR_CAPTURE_SOURCE_ARGUMENTS;
pub const VIZG_HIR_CAPTURE_SOURCE_SUPER = abi.VIZG_HIR_CAPTURE_SOURCE_SUPER;
pub const VIZG_HIR_CAPTURE_SOURCE_NEW_TARGET = abi.VIZG_HIR_CAPTURE_SOURCE_NEW_TARGET;
pub const VIZG_HIR_CAPTURE_MODE_LIVE_BINDING = abi.VIZG_HIR_CAPTURE_MODE_LIVE_BINDING;
pub const VIZG_HIR_CAPTURE_MODE_LEXICAL_VALUE = abi.VIZG_HIR_CAPTURE_MODE_LEXICAL_VALUE;
pub const VIZG_HIR_REGION_CATCH = abi.VIZG_HIR_REGION_CATCH;
pub const VIZG_HIR_REGION_FINALLY = abi.VIZG_HIR_REGION_FINALLY;
pub const VIZG_HIR_REGION_ITERATOR_CLOSE = abi.VIZG_HIR_REGION_ITERATOR_CLOSE;
pub const VIZG_HIR_REGION_HAS_PARENT = abi.VIZG_HIR_REGION_HAS_PARENT;
pub const VIZG_HIR_REGION_HAS_CONTINUATION = abi.VIZG_HIR_REGION_HAS_CONTINUATION;
pub const VIZG_HIR_BINDING_KIND_VAR = abi.VIZG_HIR_BINDING_KIND_VAR;
pub const VIZG_HIR_BINDING_KIND_LET = abi.VIZG_HIR_BINDING_KIND_LET;
pub const VIZG_HIR_BINDING_KIND_CONST = abi.VIZG_HIR_BINDING_KIND_CONST;
pub const VIZG_HIR_BINDING_KIND_PARAMETER = abi.VIZG_HIR_BINDING_KIND_PARAMETER;
pub const VIZG_HIR_BINDING_KIND_IMPORT = abi.VIZG_HIR_BINDING_KIND_IMPORT;
pub const VIZG_HIR_BINDING_KIND_CATCH = abi.VIZG_HIR_BINDING_KIND_CATCH;
pub const VIZG_HIR_BINDING_KIND_FUNCTION = abi.VIZG_HIR_BINDING_KIND_FUNCTION;
pub const VIZG_HIR_BINDING_KIND_CLASS = abi.VIZG_HIR_BINDING_KIND_CLASS;
pub const VIZG_HIR_BINDING_KIND_ENUM = abi.VIZG_HIR_BINDING_KIND_ENUM;
pub const VIZG_HIR_BINDING_KIND_SYNTHETIC = abi.VIZG_HIR_BINDING_KIND_SYNTHETIC;
pub const VIZG_HIR_BINDING_KIND_TEMPORARY = abi.VIZG_HIR_BINDING_KIND_TEMPORARY;
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
pub const Vizg_ExternalDeclarationKind = abi.Vizg_ExternalDeclarationKind;
pub const VIZG_EXTERNAL_DECLARATION_FUNCTION = abi.VIZG_EXTERNAL_DECLARATION_FUNCTION;
pub const VIZG_EXTERNAL_DECLARATION_GLOBAL = abi.VIZG_EXTERNAL_DECLARATION_GLOBAL;
pub const VIZG_EXTERNAL_DECLARATION_CONSTANT = abi.VIZG_EXTERNAL_DECLARATION_CONSTANT;
pub const VIZG_EXTERNAL_DECLARATION_TYPE = abi.VIZG_EXTERNAL_DECLARATION_TYPE;
pub const Vizg_ExternalEffectFlags = abi.Vizg_ExternalEffectFlags;
pub const VIZG_EXTERNAL_EFFECT_READS_MEMORY = abi.VIZG_EXTERNAL_EFFECT_READS_MEMORY;
pub const VIZG_EXTERNAL_EFFECT_WRITES_MEMORY = abi.VIZG_EXTERNAL_EFFECT_WRITES_MEMORY;
pub const VIZG_EXTERNAL_EFFECT_THROWS = abi.VIZG_EXTERNAL_EFFECT_THROWS;
pub const VIZG_EXTERNAL_EFFECT_ALLOCATES = abi.VIZG_EXTERNAL_EFFECT_ALLOCATES;
pub const VIZG_EXTERNAL_EFFECT_IO = abi.VIZG_EXTERNAL_EFFECT_IO;
pub const VIZG_EXTERNAL_EFFECT_ASYNC = abi.VIZG_EXTERNAL_EFFECT_ASYNC;
pub const VIZG_EXTERNAL_EFFECT_UNKNOWN = abi.VIZG_EXTERNAL_EFFECT_UNKNOWN;
pub const Vizg_ExternalExport = abi.Vizg_ExternalExport;
pub const Vizg_ExternalModule = abi.Vizg_ExternalModule;
pub const Vizg_ExternalParameterV2 = abi.Vizg_ExternalParameterV2;
pub const Vizg_ExternalFunctionV2 = abi.Vizg_ExternalFunctionV2;
pub const Vizg_ExternalExportV2 = abi.Vizg_ExternalExportV2;
pub const Vizg_ExternalModuleV2 = abi.Vizg_ExternalModuleV2;
pub const Vizg_AmbientGlobal = abi.Vizg_AmbientGlobal;
pub const Vizg_AmbientMember = abi.Vizg_AmbientMember;
pub const Vizg_AmbientGlobalV2 = abi.Vizg_AmbientGlobalV2;
pub const Vizg_SourceHostBinding = abi.Vizg_SourceHostBinding;

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
pub const Vizg_HirPayload = abi.Vizg_HirPayload;
pub const Vizg_HirPayloadItem = abi.Vizg_HirPayloadItem;
pub const Vizg_HirTypeDetail = abi.Vizg_HirTypeDetail;
pub const Vizg_HirFunctionSignature = abi.Vizg_HirFunctionSignature;
pub const Vizg_HirSignatureParameter = abi.Vizg_HirSignatureParameter;
pub const Vizg_HirFunctionDetail = abi.Vizg_HirFunctionDetail;
pub const Vizg_HirFunctionParameter = abi.Vizg_HirFunctionParameter;
pub const Vizg_HirBlockDetail = abi.Vizg_HirBlockDetail;
pub const Vizg_HirBlockParameter = abi.Vizg_HirBlockParameter;
pub const Vizg_HirOriginDetail = abi.Vizg_HirOriginDetail;
pub const Vizg_HirSemanticIdentity = abi.Vizg_HirSemanticIdentity;
pub const Vizg_HirModuleDetail = abi.Vizg_HirModuleDetail;
pub const Vizg_HirModuleDependency = abi.Vizg_HirModuleDependency;
pub const Vizg_HirModuleImport = abi.Vizg_HirModuleImport;
pub const Vizg_HirModuleExport = abi.Vizg_HirModuleExport;
pub const Vizg_HirBindingDetail = abi.Vizg_HirBindingDetail;
pub const Vizg_HirFunctionStorageDetail = abi.Vizg_HirFunctionStorageDetail;
pub const Vizg_HirFunctionCapture = abi.Vizg_HirFunctionCapture;
pub const Vizg_HirRegionDetail = abi.Vizg_HirRegionDetail;

comptime {
    _ = abi;
}

test {
    _ = abi;
}
