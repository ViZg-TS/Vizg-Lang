//! Official ViZG C ABI v1: memory-first, host-driven project analysis.

const std = @import("std");
const builtin = @import("builtin");
const vizg = @import("vizg-impl");

pub const VIZG_ABI_VERSION: u32 = 1;
pub const VIZG_HIR_API_VERSION: u32 = 2;
pub const VIZG_HIR_PAYLOAD_API_VERSION: u32 = 1;
pub const VIZG_HIR_DETAIL_API_VERSION: u32 = 2;
pub const VIZG_EXTERNAL_MODULE_API_VERSION: u32 = 2;
pub const VIZG_HIR_ID_NONE: u64 = std.math.maxInt(u64);
pub const VIZG_HIR_U32_NONE: u32 = std.math.maxInt(u32);
pub const VIZG_HIR_TYPE_PRIMITIVE: u32 = 0;
pub const VIZG_HIR_TYPE_FUNCTION: u32 = 1;
pub const VIZG_HIR_TYPE_PROMISE: u32 = 2;
pub const VIZG_HIR_TYPE_GENERATOR: u32 = 3;
pub const VIZG_HIR_TYPE_LITERAL: u32 = 4;
pub const VIZG_HIR_TYPE_UNION: u32 = 5;
pub const VIZG_HIR_TYPE_INTERSECTION: u32 = 6;
pub const VIZG_HIR_TYPE_ARRAY: u32 = 7;
pub const VIZG_HIR_TYPE_TUPLE: u32 = 8;
pub const VIZG_HIR_TYPE_OBJECT: u32 = 9;
pub const VIZG_HIR_TYPE_CLASS: u32 = 10;
pub const VIZG_HIR_TYPE_CLASS_CONSTRUCTOR: u32 = 11;
pub const VIZG_HIR_TYPE_INTERFACE: u32 = 12;
pub const VIZG_HIR_TYPE_ENUM: u32 = 13;
pub const VIZG_HIR_TYPE_PARAMETER: u32 = 14;
pub const VIZG_HIR_TYPE_APPLIED_GENERIC: u32 = 15;
pub const VIZG_HIR_BUILTIN_NONE: u32 = std.math.maxInt(u32);
pub const VIZG_HIR_BUILTIN_ANY: u32 = 0;
pub const VIZG_HIR_BUILTIN_UNKNOWN: u32 = 1;
pub const VIZG_HIR_BUILTIN_NEVER: u32 = 2;
pub const VIZG_HIR_BUILTIN_VOID: u32 = 3;
pub const VIZG_HIR_BUILTIN_UNDEFINED: u32 = 4;
pub const VIZG_HIR_BUILTIN_NULL: u32 = 5;
pub const VIZG_HIR_BUILTIN_BOOLEAN: u32 = 6;
pub const VIZG_HIR_BUILTIN_NUMBER: u32 = 7;
pub const VIZG_HIR_BUILTIN_BIGINT: u32 = 8;
pub const VIZG_HIR_BUILTIN_STRING: u32 = 9;
pub const VIZG_HIR_BUILTIN_SYMBOL: u32 = 10;
pub const VIZG_HIR_BUILTIN_OBJECT: u32 = 11;
pub const VIZG_HIR_FUNCTION_FLAG_LEXICAL_THIS: u16 = 1 << 0;
pub const VIZG_HIR_FUNCTION_FLAG_DYNAMIC_THIS: u16 = 1 << 1;
pub const VIZG_HIR_FUNCTION_FLAG_CONSTRUCTOR: u16 = 1 << 2;
pub const VIZG_HIR_FUNCTION_FLAG_GETTER: u16 = 1 << 3;
pub const VIZG_HIR_FUNCTION_FLAG_SETTER: u16 = 1 << 4;
pub const VIZG_HIR_FUNCTION_FLAG_ASYNC: u16 = 1 << 5;
pub const VIZG_HIR_FUNCTION_FLAG_GENERATOR: u16 = 1 << 6;
pub const VIZG_HIR_FUNCTION_FLAG_ASYNC_GENERATOR: u16 = 1 << 7;
pub const VIZG_HIR_FUNCTION_FLAG_USES_SUPER: u16 = 1 << 8;
pub const VIZG_HIR_FUNCTION_FLAG_USES_NEW_TARGET: u16 = 1 << 9;
pub const VIZG_HIR_SIGNATURE_ASYNC: u8 = 1 << 0;
pub const VIZG_HIR_SIGNATURE_GENERATOR: u8 = 1 << 1;
pub const VIZG_HIR_SIGNATURE_CONSTRUCTOR: u8 = 1 << 2;
pub const VIZG_HIR_PARAMETER_OPTIONAL: u8 = 1 << 0;
pub const VIZG_HIR_PARAMETER_HAS_DEFAULT: u8 = 1 << 1;
pub const VIZG_HIR_PARAMETER_REST: u8 = 1 << 2;
pub const VIZG_HIR_PARAMETER_PROPERTY: u8 = 1 << 3;
pub const VIZG_HIR_ORIGIN_HAS_SYMBOL: u8 = 1 << 0;
pub const VIZG_HIR_ORIGIN_HAS_TYPE: u8 = 1 << 1;
pub const VIZG_HIR_ORIGIN_HAS_PARENT: u8 = 1 << 2;
pub const VIZG_HIR_ORIGIN_HAS_SYNTHETIC_REASON: u8 = 1 << 3;
pub const VIZG_HIR_BINDING_KIND_VAR: u32 = 0;
pub const VIZG_HIR_BINDING_KIND_LET: u32 = 1;
pub const VIZG_HIR_BINDING_KIND_CONST: u32 = 2;
pub const VIZG_HIR_BINDING_KIND_PARAMETER: u32 = 3;
pub const VIZG_HIR_BINDING_KIND_IMPORT: u32 = 4;
pub const VIZG_HIR_BINDING_KIND_CATCH: u32 = 5;
pub const VIZG_HIR_BINDING_KIND_FUNCTION: u32 = 6;
pub const VIZG_HIR_BINDING_KIND_CLASS: u32 = 7;
pub const VIZG_HIR_BINDING_KIND_ENUM: u32 = 8;
pub const VIZG_HIR_BINDING_KIND_SYNTHETIC: u32 = 9;
pub const VIZG_HIR_BINDING_KIND_TEMPORARY: u32 = 10;
pub const VIZG_HIR_MODULE_REFERENCE_SOURCE: u32 = 0;
pub const VIZG_HIR_MODULE_REFERENCE_EXTERNAL: u32 = 1;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_VALUE: u32 = 0;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_TYPE: u32 = 1;
pub const VIZG_HIR_SEMANTIC_NAMESPACE_NAMESPACE: u32 = 2;
pub const VIZG_HIR_BINDING_STATE_HOISTED_UNDEFINED: u32 = 0;
pub const VIZG_HIR_BINDING_STATE_HOISTED_FUNCTION: u32 = 1;
pub const VIZG_HIR_BINDING_STATE_TEMPORAL_DEAD_ZONE: u32 = 2;
pub const VIZG_HIR_BINDING_STATE_INITIALIZED: u32 = 3;
pub const VIZG_HIR_BINDING_STATE_LIVE_IMPORT: u32 = 4;
pub const VIZG_HIR_CAPTURE_SOURCE_BINDING: u32 = 0;
pub const VIZG_HIR_CAPTURE_SOURCE_THIS: u32 = 1;
pub const VIZG_HIR_CAPTURE_SOURCE_ARGUMENTS: u32 = 2;
pub const VIZG_HIR_CAPTURE_SOURCE_SUPER: u32 = 3;
pub const VIZG_HIR_CAPTURE_SOURCE_NEW_TARGET: u32 = 4;
pub const VIZG_HIR_CAPTURE_MODE_LIVE_BINDING: u32 = 0;
pub const VIZG_HIR_CAPTURE_MODE_LEXICAL_VALUE: u32 = 1;
pub const VIZG_HIR_REGION_CATCH: u32 = 0;
pub const VIZG_HIR_REGION_FINALLY: u32 = 1;
pub const VIZG_HIR_REGION_ITERATOR_CLOSE: u32 = 2;
pub const VIZG_HIR_REGION_HAS_PARENT: u8 = 1 << 0;
pub const VIZG_HIR_REGION_HAS_CONTINUATION: u8 = 1 << 1;
pub const VIZG_MAX_SOURCE_LENGTH: usize = vizg.tokens.MAX_SOURCE_LENGTH;
pub const Vizg_ExternalNamespaceFlags = u8;
pub const VIZG_EXTERNAL_NAMESPACE_VALUE: Vizg_ExternalNamespaceFlags = 1;
pub const VIZG_EXTERNAL_NAMESPACE_TYPE: Vizg_ExternalNamespaceFlags = 2;
pub const VIZG_EXTERNAL_NAMESPACE_BOTH: Vizg_ExternalNamespaceFlags = 3;
pub const Vizg_ExternalDeclarationKind = u32;
pub const VIZG_EXTERNAL_DECLARATION_FUNCTION: Vizg_ExternalDeclarationKind = 0;
pub const VIZG_EXTERNAL_DECLARATION_GLOBAL: Vizg_ExternalDeclarationKind = 1;
pub const VIZG_EXTERNAL_DECLARATION_CONSTANT: Vizg_ExternalDeclarationKind = 2;
pub const VIZG_EXTERNAL_DECLARATION_TYPE: Vizg_ExternalDeclarationKind = 3;
pub const Vizg_ExternalEffectFlags = u16;
pub const VIZG_EXTERNAL_EFFECT_READS_MEMORY: Vizg_ExternalEffectFlags = 1 << 0;
pub const VIZG_EXTERNAL_EFFECT_WRITES_MEMORY: Vizg_ExternalEffectFlags = 1 << 1;
pub const VIZG_EXTERNAL_EFFECT_THROWS: Vizg_ExternalEffectFlags = 1 << 2;
pub const VIZG_EXTERNAL_EFFECT_ALLOCATES: Vizg_ExternalEffectFlags = 1 << 3;
pub const VIZG_EXTERNAL_EFFECT_IO: Vizg_ExternalEffectFlags = 1 << 4;
pub const VIZG_EXTERNAL_EFFECT_ASYNC: Vizg_ExternalEffectFlags = 1 << 5;
pub const VIZG_EXTERNAL_EFFECT_UNKNOWN: Vizg_ExternalEffectFlags = 1 << 6;

pub const Vizg_ProjectStatus = enum(u32) {
    OK = 0,
    INVALID_ARGUMENT = 1,
    OUT_OF_MEMORY = 2,
    INVALID_STATE = 3,
    LIMIT_EXCEEDED = 4,
    INTERNAL_ERROR = 5,
};

pub const Vizg_LimitKind = enum(u32) {
    NONE = 0,
    SOURCE_BYTES = 1,
    TOTAL_SOURCE_BYTES = 2,
    MODULES = 3,
    REQUESTS = 4,
    EDGES = 5,
    GRAPH_DEPTH = 6,
    DIAGNOSTICS = 7,
    SEMANTIC_GROWTH = 8,
    PARSE_DEPTH = 9,
};

pub const Vizg_ProjectConfig = extern struct {
    workspace_ptr: [*c]u8,
    workspace_len: usize,
    max_source_bytes: usize,
    max_total_source_bytes: usize,
    max_modules: usize,
    max_requests: usize,
    max_edges: usize,
    max_diagnostics: usize,
    max_graph_depth: usize,
    max_semantic_types: usize,
};

pub const Vizg_ProjectSource = extern struct {
    module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    source_ptr: [*c]const u8,
    source_len: usize,
    kind: u32,
    is_root: u8,
    reserved: [3]u8,
};

pub const Vizg_ProjectSpan = extern struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
};

pub const Vizg_ProjectRequestAttribute = extern struct {
    key_ptr: [*c]const u8,
    key_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectStep = extern struct {
    kind: u32,
    request_id: u64,
    importer_module_id: u64,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    request_operation: u32,
    type_only: u8,
    reserved: [3]u8,
    attributes_ptr: [*c]const Vizg_ProjectRequestAttribute,
    attribute_count: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ExternalExport = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    kind: u32,
    namespace_flags: Vizg_ExternalNamespaceFlags,
    has_type_metadata: u8,
    reserved: [2]u8,
    type_metadata: u32,
};

pub const Vizg_ExternalModule = extern struct {
    external_module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    exports_ptr: [*c]const Vizg_ExternalExport,
    export_count: usize,
};

pub const Vizg_ExternalParameterV2 = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    type_metadata: u32,
    optional: u8,
    has_default: u8,
    rest: u8,
    reserved: u8,
};

pub const Vizg_ExternalFunctionV2 = extern struct {
    parameters_ptr: [*c]const Vizg_ExternalParameterV2,
    parameter_count: usize,
    return_type: u32,
    type_parameter_count: u32,
    is_async: u8,
    is_generator: u8,
    is_constructor: u8,
    reserved: u8,
};

pub const Vizg_ExternalExportV2 = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    kind: u32,
    namespace_flags: Vizg_ExternalNamespaceFlags,
    has_type_metadata: u8,
    has_function: u8,
    reserved: u8,
    type_metadata: u32,
    declaration_kind: u32,
    effect_flags: u16,
    reserved2: u16,
    external_symbol_id: u64,
    function: Vizg_ExternalFunctionV2,
};

pub const Vizg_ExternalModuleV2 = extern struct {
    external_module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    exports_ptr: [*c]const Vizg_ExternalExportV2,
    export_count: usize,
};

/// Borrowed ambient global descriptor passed to `vizg_project_register_ambient_globals`.
/// `name_ptr`/`name_len` reference host memory borrowed for the call. When
/// `has_type_metadata` is 0, `type_metadata` must be `VIZG_EXTERNAL_TYPE_UNKNOWN`.
pub const Vizg_AmbientGlobal = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    namespace_flags: Vizg_ExternalNamespaceFlags,
    has_type_metadata: u8,
    type_metadata: u32,
    host_binding_id: u64,
    reserved: [8]u8,
};

/// Borrowed structural member used by the additive ambient-global V2 API.
pub const Vizg_AmbientMember = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    has_type_metadata: u8,
    optional: u8,
    readonly: u8,
    self_reference: u8,
    type_metadata: u32,
    reserved: [8]u8,
};

/// Borrowed ambient descriptor with structural members.
pub const Vizg_AmbientGlobalV2 = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    namespace_flags: Vizg_ExternalNamespaceFlags,
    has_type_metadata: u8,
    type_metadata: u32,
    host_binding_id: u64,
    members_ptr: [*c]const Vizg_AmbientMember,
    member_count: usize,
    reserved: [8]u8,
};

/// Borrowed mapping from a top-level source value declaration to a stable
/// host identity. The declaration and type remain defined by source text.
pub const Vizg_SourceHostBinding = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    host_binding_id: u64,
    reserved: [8]u8,
};

pub const Vizg_ProjectResultSummary = extern struct {
    module_count: usize,
    diagnostic_count: usize,
    edge_count: usize,
    import_count: usize,
    export_count: usize,
    is_partial: u8,
    has_syntax_errors: u8,
    has_semantic_errors: u8,
    has_project_errors: u8,
    has_module_failures: u8,
    reserved: [3]u8,
};

pub const Vizg_ProjectModuleInfo = extern struct {
    module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    state: u32,
    is_root: u8,
    has_source: u8,
    reserved: [2]u8,
};

pub const Vizg_ProjectDiagnostic = extern struct {
    module_id: u64,
    has_module_id: u8,
    severity: u8,
    phase: u8,
    reserved: u8,
    code: u32,
    message_ptr: [*c]const u8,
    message_len: usize,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectEdgeInfo = extern struct {
    request_id: u64,
    importer_module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    request_operation: u32,
    state: u32,
    type_only: u8,
    has_target_module: u8,
    has_external_target: u8,
    reserved: u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectImportInfo = extern struct {
    module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    edge_index: usize,
    target_type_id: u32,
    link_state: u32,
    request_operation: u32,
    local_name_ptr: [*c]const u8,
    local_name_len: usize,
    imported_name_ptr: [*c]const u8,
    imported_name_len: usize,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    type_only: u8,
    runtime_binding: u8,
    has_target_module: u8,
    has_external_target: u8,
    has_edge_index: u8,
    has_semantic_target: u8,
    reserved: [2]u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectExportInfo = extern struct {
    module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    edge_index: usize,
    target_type_id: u32,
    name_ptr: [*c]const u8,
    name_len: usize,
    type_only: u8,
    re_export: u8,
    has_target_module: u8,
    has_external_target: u8,
    has_edge_index: u8,
    reserved: [3]u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_HirEntityKind = enum(u32) {
    MODULE = 0,
    EXTERNAL_DECLARATION = 1,
    FUNCTION = 2,
    BLOCK = 3,
    INSTRUCTION = 4,
    BINDING = 5,
    TYPE = 6,
    ORIGIN = 7,
};

pub const Vizg_HirSummary = extern struct {
    module_count: usize,
    external_declaration_count: usize,
    function_count: usize,
    block_count: usize,
    instruction_count: usize,
    binding_count: usize,
    type_count: usize,
    origin_count: usize,
};

/// Kind-neutral immutable record. `tag`, `parent_id`, `secondary_id`, and
/// `flags` are interpreted according to `kind` and the requested HIR API
/// version; unknown fields are zero. For instruction records, v1 reports the
/// parent function in `secondary_id`, while v2 reports the optional result
/// `ValueId` (`VIZG_HIR_ID_NONE` when absent). For origin records, v2 sets
/// `flags` bit 0 exactly when `type_id` is present; v1 leaves that flag clear.
pub const Vizg_HirRecord = extern struct {
    kind: Vizg_HirEntityKind,
    tag: u32,
    id: u64,
    parent_id: u64,
    secondary_id: u64,
    module_id: u64,
    type_id: u32,
    effect_bits: u16,
    flags: u8,
    reserved: [1]u8,
    origin_id: u32,
    name_ptr: [*c]const u8,
    name_len: usize,
    child_count: usize,
};

/// Versioned operation or terminator payload. The active HIR tag determines
/// the meaning of the generic tag, operand, string, and item fields.
pub const Vizg_HirPayload = extern struct {
    tag: u32,
    tag0: u32,
    tag1: u32,
    flags: u32,
    operand0: u64,
    operand1: u64,
    operand2: u64,
    operand3: u64,
    string0_ptr: [*c]const u8,
    string0_len: usize,
    string1_ptr: [*c]const u8,
    string1_len: usize,
    item_count: usize,
};

/// One variable-length child of a `Vizg_HirPayload`.
pub const Vizg_HirPayloadItem = extern struct {
    tag: u32,
    flags: u32,
    operand0: u64,
    operand1: u64,
    string0_ptr: [*c]const u8,
    string0_len: usize,
    string1_ptr: [*c]const u8,
    string1_len: usize,
};

/// Scalar and callable type information omitted from the kind-neutral record.
pub const Vizg_HirTypeDetail = extern struct {
    id: u32,
    kind: u32,
    builtin_kind: u32,
    reserved: u32,
};

pub const Vizg_HirFunctionSignature = extern struct {
    type_id: u32,
    return_type_id: u32,
    type_parameter_count: u32,
    flags: u8,
    reserved: [3]u8,
    parameter_count: usize,
};

pub const Vizg_HirSignatureParameter = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    type_id: u32,
    flags: u8,
    reserved: [3]u8,
};

pub const Vizg_HirFunctionDetail = extern struct {
    id: u64,
    entry_block_id: u64,
    parameter_count: usize,
    flags: u16,
    reserved: [6]u8,
};

pub const Vizg_HirFunctionParameter = extern struct {
    binding_id: u64,
    type_id: u32,
    argument_index: u32,
    origin_id: u32,
    flags: u8,
    reserved: [3]u8,
};

pub const Vizg_HirBlockDetail = extern struct {
    id: u64,
    parameter_count: usize,
};

pub const Vizg_HirBlockParameter = extern struct {
    value_id: u64,
    type_id: u32,
    origin_id: u32,
};

pub const Vizg_HirOriginDetail = extern struct {
    id: u32,
    module_id: u64,
    span_start: u32,
    span_end: u32,
    original_syntax: u32,
    lowering_rule: u32,
    type_id: u32,
    parent_id: u32,
    synthetic_reason: u32,
    symbol_module_id: u64,
    symbol_declaration_id: u32,
    symbol_external: u8,
    flags: u8,
    reserved: [2]u8,
};

/// Exact module-linking and storage identity used by HIR v1.
pub const Vizg_HirSemanticIdentity = extern struct {
    declaration_module_id: u64,
    external_module_id: u64,
    external_symbol_id: u64,
    symbol_id: u32,
    declaration_id: u32,
    type_id: u32,
    namespace_kind: u32,
    declaration_external: u8,
    has_host_binding_id: u8,
    reserved: [6]u8,
    /// Host-assigned identity for ambient globals. Valid when the flag is set.
    host_binding_id: u64,
};

pub const Vizg_HirModuleDetail = extern struct {
    module_id: u64,
    initialization_function_id: u64,
    dependency_count: usize,
    import_count: usize,
    export_count: usize,
};

pub const Vizg_HirModuleDependency = extern struct {
    module_id: u64,
    initialization_required: u8,
    reserved: [7]u8,
};

pub const Vizg_HirModuleImport = extern struct {
    local_binding_id: u64,
    source_id: u64,
    exported_name_ptr: [*c]const u8,
    exported_name_len: usize,
    target: Vizg_HirSemanticIdentity,
    source_kind: u32,
    type_only: u8,
    reserved: [3]u8,
};

pub const Vizg_HirModuleExport = extern struct {
    binding_id: u64,
    entity_id: u64,
    exported_name_ptr: [*c]const u8,
    exported_name_len: usize,
    target: Vizg_HirSemanticIdentity,
    type_only: u8,
    reserved: [7]u8,
};

pub const Vizg_HirBindingDetail = extern struct {
    id: u64,
    declaration_id: u32,
    initial_state: u32,
    declaration_module_id: u64,
    declaration_external: u8,
    has_host_binding_id: u8,
    reserved: [6]u8,
    host_binding_id: u64,
};

pub const Vizg_HirFunctionStorageDetail = extern struct {
    id: u64,
    capture_count: usize,
};

pub const Vizg_HirFunctionCapture = extern struct {
    local_binding_id: u64,
    source_binding_id: u64,
    source_kind: u32,
    mode: u32,
};

/// Structured exceptional-control-flow region metadata required by HIR
/// consumers. Optional identities use `VIZG_HIR_ID_NONE` and are paired with
/// the corresponding flag bit.
pub const Vizg_HirRegionDetail = extern struct {
    id: u64,
    function_id: u64,
    parent_region_id: u64,
    handler_block_id: u64,
    continuation_block_id: u64,
    origin_id: u32,
    kind: u32,
    protected_block_count: usize,
    flags: u8,
    reserved: [7]u8,
};

pub const Vizg_Project = opaque {};
pub const Vizg_ProjectResult = opaque {};

const OwnedProject = struct {
    magic: u64 = project_magic,
    fba: std.heap.FixedBufferAllocator,
    project: vizg.Project,
    step_attributes: std.ArrayList(Vizg_ProjectRequestAttribute) = .empty,
    workspace_len: usize,
    last_limit: Vizg_LimitKind = .NONE,
    result_view: OwnedProjectResult = undefined,
    result_ready: bool = false,
    creation_limited: bool = false,
    destroyed: bool = false,

    fn deinit(self: *OwnedProject) void {
        if (self.destroyed) return;
        const allocator = self.fba.allocator();
        self.step_attributes.deinit(allocator);
        if (self.result_ready) {
            if (self.result_view.hir_result) |*value| value.deinit();
            self.result_view.hir_result = null;
            self.result_view.destroyed = true;
        }
        self.project.deinit();
        if (self.result_ready) self.result_view.magic = 0;
        self.result_ready = false;
        self.destroyed = true;
    }
};

const OwnedProjectResult = struct {
    magic: u64 = result_magic,
    summary: Vizg_ProjectResultSummary,
    owner: *OwnedProject,
    hir_result: ?vizg.hir.HirResult = null,
    owns_owner: bool = false,
    destroyed: bool = false,
};

const project_magic: u64 = 0x565a_4750_524f_4a31;
const result_magic: u64 = 0x565a_4752_4553_5531;

fn validHostRange(ptr: anytype, len: usize) bool {
    if (len == 0) return true;
    if (@intFromPtr(ptr) == 0) return false;
    const start = @intFromPtr(ptr);
    const end = std.math.add(usize, start, len) catch return false;
    if (comptime builtin.cpu.arch == .wasm32) {
        const memory_bytes = std.math.mul(usize, @wasmMemorySize(0), 64 * 1024) catch return false;
        return end <= memory_bytes;
    }
    return true;
}

fn checkedByteLen(comptime T: type, count: usize) ?usize {
    return std.math.mul(usize, @sizeOf(T), count) catch null;
}

fn validAlignedHostObject(comptime T: type, ptr: anytype) bool {
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    return validHostRange(ptr, @sizeOf(T));
}

fn validAlignedHostArray(comptime T: type, ptr: [*c]const T, count: usize) bool {
    if (count == 0) return true;
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    const byte_len = checkedByteLen(T, count) orelse return false;
    return validHostRange(ptr, byte_len);
}

fn validAlignedMutableHostArray(comptime T: type, ptr: [*c]T, count: usize) bool {
    if (count == 0) return true;
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    const byte_len = checkedByteLen(T, count) orelse return false;
    return validHostRange(ptr, byte_len);
}

fn rangesOverlap(a_ptr: anytype, a_len: usize, b_ptr: anytype, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_start = @intFromPtr(a_ptr);
    const b_start = @intFromPtr(b_ptr);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn ownedProject(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    if (!validAlignedHostObject(OwnedProject, handle)) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic or owned.destroyed) return null;
    return owned;
}

fn ownedProjectForDestroy(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    if (!validAlignedHostObject(OwnedProject, handle)) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic) return null;
    return owned;
}

fn ownedResult(result: ?*const Vizg_ProjectResult) ?*const OwnedProjectResult {
    const handle = result orelse return null;
    if (!validAlignedHostObject(OwnedProjectResult, handle)) return null;
    const owned: *const OwnedProjectResult = @ptrCast(@alignCast(handle));
    if (owned.magic != result_magic or owned.destroyed) return null;
    const owner_handle: *Vizg_Project = @ptrCast(owned.owner);
    const owner = ownedProject(owner_handle) orelse return null;
    if (owner != owned.owner or !rangeInsideWorkspace(owner, handle, @sizeOf(OwnedProjectResult))) return null;
    return owned;
}

fn workspace(config: *const Vizg_ProjectConfig) ?[]u8 {
    if (config.workspace_ptr == null or config.workspace_len < projectWorkspaceOverhead()) return null;
    if (!validAlignedMutableHostArray(u8, config.workspace_ptr, config.workspace_len)) return null;
    if (@intFromPtr(config.workspace_ptr) % projectWorkspaceAlignment() != 0) return null;
    if (config.max_source_bytes == 0 or config.max_total_source_bytes == 0 or
        config.max_modules == 0 or config.max_diagnostics == 0 or
        config.max_requests == 0 or config.max_edges == 0 or config.max_graph_depth == 0 or
        config.max_semantic_types == 0) return null;
    return config.workspace_ptr[0..config.workspace_len];
}

fn inputOutsideWorkspace(owned: *const OwnedProject, ptr: anytype, len: usize) bool {
    if (len == 0) return true;
    if (!validHostRange(ptr, len)) return false;
    return !rangesOverlap(ptr, len, owned, owned.workspace_len);
}

fn rangeInsideWorkspace(owned: *const OwnedProject, ptr: anytype, len: usize) bool {
    if (!validHostRange(ptr, len)) return false;
    const start = @intFromPtr(ptr);
    const end = std.math.add(usize, start, len) catch return false;
    const workspace_start = @intFromPtr(owned);
    const workspace_end = std.math.add(usize, workspace_start, owned.workspace_len) catch return false;
    return start >= workspace_start and end <= workspace_end;
}

fn sourceInputsOutsideWorkspace(owned: *const OwnedProject, input: *const Vizg_ProjectSource) bool {
    return inputOutsideWorkspace(owned, input.logical_name_ptr, input.logical_name_len) and
        inputOutsideWorkspace(owned, input.source_ptr, input.source_len);
}

fn validSourceScalars(input: *const Vizg_ProjectSource) bool {
    return sourceKind(input.kind) != null and input.is_root <= 1 and
        input.reserved[0] == 0 and input.reserved[1] == 0 and input.reserved[2] == 0;
}

fn sourceLengthStatus(owned: *OwnedProject, source_len: usize) ?Vizg_ProjectStatus {
    if (source_len > VIZG_MAX_SOURCE_LENGTH or source_len > owned.project.limits.max_source_bytes)
        return limitStatus(owned, .SOURCE_BYTES);
    return null;
}

fn diagnosticSeverity(value: vizg.diagnostics.Severity) u8 {
    return switch (value) {
        .@"error" => 0,
        .warning => 1,
        .info => 2,
        .hint => 3,
    };
}

fn diagnosticPhase(value: vizg.ProjectDiagnosticPhase) u8 {
    return @intFromEnum(value);
}

fn diagnosticCode(value: vizg.diagnostics.DiagnosticCode) u32 {
    return switch (value) {
        .invalid_character => 1001,
        .unterminated_string => 1002,
        .unterminated_block_comment => 1003,
        .invalid_number => 1004,
        .invalid_escape_sequence => 1005,
        .unterminated_regexp => 1006,
        .invalid_regexp => 1007,
        .invalid_utf8 => 1008,
        .unexpected_token => 2001,
        .expected_token => 2002,
        .parse_recursion_limit_reached => 2003,
        .unsupported_syntax => 2004,
        .unsupported_ts_syntax => 2005,
        .unsupported_jsx => 2006,
        .duplicate_declaration => 3001,
        .duplicate_export => 3002,
        .cannot_find_name => 4001,
        .module_not_found => 5001,
        .module_access_denied => 5004,
        .module_host_failed => 5005,
        .missing_export => 5002,
        .circular_import => 5003,
        .unknown_type_name => 6004,
        .type_mismatch => 6005,
        .unknown_property => 6006,
        .invalid_index => 6007,
        .invalid_argument_count => 6008,
        .invalid_argument_type => 6009,
        .global_ambient_collision => 8001,
    };
}

fn diagnosticCount(owned: *const OwnedProject) usize {
    return owned.project.diagnostics().len;
}

fn bytes(ptr: [*c]const u8, len: usize) []const u8 {
    return if (len == 0) "" else ptr[0..len];
}

fn sourceKind(value: u32) ?vizg.project.SourceKind {
    return switch (value) {
        0 => .script,
        1 => .module,
        else => null,
    };
}

fn requestOperation(value: vizg.project.RequestOperation) u32 {
    return @intFromEnum(value);
}

fn span(value: vizg.project.SourceSpan) Vizg_ProjectSpan {
    return .{
        .start = value.start,
        .end = value.end,
        .line = value.line,
        .column = value.column,
    };
}

fn moduleSource(input: *const Vizg_ProjectSource) ?vizg.ModuleSource {
    if (!validAlignedHostArray(u8, input.logical_name_ptr, input.logical_name_len) or
        !validAlignedHostArray(u8, input.source_ptr, input.source_len) or
        !validSourceScalars(input))
    {
        return null;
    }
    return .{
        .id = .init(input.module_id),
        .logical_name = bytes(input.logical_name_ptr, input.logical_name_len),
        .bytes = bytes(input.source_ptr, input.source_len),
        .kind = sourceKind(input.kind) orelse return null,
    };
}

fn statusFromError(owned: *OwnedProject, err: anyerror) Vizg_ProjectStatus {
    if (limitKindFromError(err)) |kind| return limitStatus(owned, kind);
    return switch (err) {
        error.OutOfMemory => .OUT_OF_MEMORY,
        error.PendingRequests,
        error.IncompleteModules,
        error.ForeignRequest,
        error.InvalidResponseOrder,
        error.DuplicateResponse,
        error.DuplicateModule,
        error.DuplicateGlobalRoot,
        error.UnknownImporter,
        error.UnknownModule,
        error.SourceNotSupplied,
        error.ModuleNotAnalyzed,
        error.ProjectFinished,
        => .INVALID_STATE,
        error.InvalidExternalExport,
        error.DuplicateExternalExport,
        error.ExternalDescriptorConflict,
        error.DuplicateAmbientGlobal,
        error.InvalidAmbientGlobal,
        error.AmbientGlobalsLateRegistration,
        error.DuplicateSourceHostBinding,
        error.InvalidSourceHostBinding,
        error.SourceHostBindingsLateRegistration,
        => .INVALID_ARGUMENT,
        else => .INTERNAL_ERROR,
    };
}

fn limitKindFromError(err: anyerror) ?Vizg_LimitKind {
    return switch (err) {
        error.SourceLimitExceeded => .SOURCE_BYTES,
        error.TotalSourceLimitExceeded => .TOTAL_SOURCE_BYTES,
        error.ModuleLimitExceeded => .MODULES,
        error.RequestLimitExceeded, error.RequestIdExhausted => .REQUESTS,
        error.EdgeLimitExceeded => .EDGES,
        error.GraphDepthLimitExceeded => .GRAPH_DEPTH,
        error.DiagnosticLimitExceeded => .DIAGNOSTICS,
        error.SemanticTypeLimitExceeded, error.TypeComplexityLimit => .SEMANTIC_GROWTH,
        error.ParseRecursionLimitReached => .PARSE_DEPTH,
        else => null,
    };
}

fn limitStatus(owned: *OwnedProject, kind: Vizg_LimitKind) Vizg_ProjectStatus {
    owned.last_limit = kind;
    return .LIMIT_EXCEEDED;
}

fn beginProjectCall(owned: *OwnedProject) void {
    owned.last_limit = .NONE;
}

pub fn abiVersion() callconv(.c) u32 {
    return VIZG_ABI_VERSION;
}

fn projectSemantic(owned: *const OwnedProjectResult) ?*const vizg.semantics.BorrowedProjectSemanticResult {
    return owned.owner.project.semanticResult();
}

fn resultHasPhase(owned: *const OwnedProjectResult, phase: vizg.ProjectDiagnosticPhase) bool {
    for (owned.owner.project.diagnostics()) |item| {
        if (item.severity == .@"error" and item.phase == phase) return true;
    }
    return false;
}

fn outputOutsideWorkspace(owned: *const OwnedProjectResult, ptr: anytype, len: usize) bool {
    return validHostRange(ptr, len) and inputOutsideWorkspace(owned.owner, ptr, len);
}

pub fn projectWorkspaceAlignment() callconv(.c) usize {
    return @alignOf(OwnedProject);
}

pub fn projectWorkspaceOverhead() callconv(.c) usize {
    return std.mem.alignForward(usize, @sizeOf(OwnedProject), @alignOf(OwnedProject));
}

pub fn projectCreate(config: ?*const Vizg_ProjectConfig, out_project: [*c]?*Vizg_Project) callconv(.c) Vizg_ProjectStatus {
    const args = config orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectConfig, args) or
        !validAlignedMutableHostArray(?*Vizg_Project, out_project, 1) or
        rangesOverlap(args, @sizeOf(Vizg_ProjectConfig), out_project, @sizeOf(?*Vizg_Project)))
    {
        return .INVALID_ARGUMENT;
    }
    const storage = workspace(args) orelse return .INVALID_ARGUMENT;
    if (rangesOverlap(args, @sizeOf(Vizg_ProjectConfig), storage.ptr, storage.len) or
        rangesOverlap(out_project, @sizeOf(?*Vizg_Project), storage.ptr, storage.len)) return .INVALID_ARGUMENT;
    out_project[0] = null;
    const owned: *OwnedProject = @ptrCast(@alignCast(storage.ptr));
    owned.magic = project_magic;
    owned.fba = .init(storage[projectWorkspaceOverhead()..]);
    owned.step_attributes = .empty;
    owned.workspace_len = storage.len;
    owned.last_limit = if (args.max_source_bytes > VIZG_MAX_SOURCE_LENGTH) .SOURCE_BYTES else .NONE;
    owned.result_ready = false;
    owned.creation_limited = owned.last_limit != .NONE;
    owned.destroyed = false;
    owned.project = .initWithLimits(owned.fba.allocator(), .{
        .max_source_bytes = @min(args.max_source_bytes, VIZG_MAX_SOURCE_LENGTH),
        .max_total_source_bytes = args.max_total_source_bytes,
        .max_modules = args.max_modules,
        .max_requests = args.max_requests,
        .max_edges = args.max_edges,
        .max_diagnostics = args.max_diagnostics,
        .max_graph_depth = args.max_graph_depth,
        .max_semantic_types = args.max_semantic_types,
    });
    out_project[0] = @ptrCast(owned);
    if (owned.last_limit != .NONE) return .LIMIT_EXCEEDED;
    return .OK;
}

pub fn projectDestroy(project: ?*Vizg_Project) callconv(.c) void {
    const owned = ownedProjectForDestroy(project) orelse return;
    owned.deinit();
}

pub fn projectLimitKind(project: ?*Vizg_Project) callconv(.c) Vizg_LimitKind {
    const owned = ownedProject(project) orelse return .NONE;
    return owned.last_limit;
}

pub fn projectAddSource(project: ?*Vizg_Project, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectSource, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource)) or
        !validSourceScalars(args)) return .INVALID_ARGUMENT;
    if (sourceLengthStatus(owned, args.source_len)) |status| return status;
    if (!sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    if (args.is_root == 1) {
        owned.project.addRoot(source) catch |err| return statusFromError(owned, err);
    } else {
        owned.project.supplySource(source) catch |err| return statusFromError(owned, err);
    }
    return .OK;
}

pub fn projectAddGlobalRoot(project: ?*Vizg_Project, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectSource, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource)) or
        !validSourceScalars(args)) return .INVALID_ARGUMENT;
    if (sourceLengthStatus(owned, args.source_len)) |status| return status;
    if (!sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    owned.project.addGlobalRoot(source) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectRegisterAmbientGlobals(
    project: ?*Vizg_Project,
    globals_ptr: [*c]const Vizg_AmbientGlobal,
    count: usize,
) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    if (count == 0) return .OK;
    if (!validAlignedHostArray(Vizg_AmbientGlobal, globals_ptr, count)) return .INVALID_ARGUMENT;
    const items_bytes = checkedByteLen(Vizg_AmbientGlobal, count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, globals_ptr, items_bytes)) return .INVALID_ARGUMENT;

    for (globals_ptr[0..count]) |*item| {
        if (item.namespace_flags == 0 or (item.namespace_flags & ~VIZG_EXTERNAL_NAMESPACE_BOTH) != 0) return .INVALID_ARGUMENT;
        if (item.has_type_metadata > 1) return .INVALID_ARGUMENT;
        if (item.has_type_metadata == 1) {
            if (externalType(item.type_metadata) == null) return .INVALID_ARGUMENT;
        } else if (item.type_metadata != 0) {
            return .INVALID_ARGUMENT;
        }
        if (!std.mem.eql(u8, &item.reserved, &[_]u8{0} ** 8)) return .INVALID_ARGUMENT;
        if (!validAlignedHostArray(u8, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
        if (!inputOutsideWorkspace(owned, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
    }

    const descriptor_bytes = checkedByteLen(vizg.AmbientGlobal, count) orelse return .OUT_OF_MEMORY;
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const unaligned_start = std.math.sub(usize, buffer_end, descriptor_bytes) catch return .OUT_OF_MEMORY;
    const scratch_start = std.mem.alignBackward(usize, unaligned_start, @alignOf(vizg.AmbientGlobal));
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (scratch_start < used_end) return .OUT_OF_MEMORY;
    const scratch_index = scratch_start - buffer_start;
    owned.fba.buffer = buffer[0..scratch_index];
    defer owned.fba.buffer = buffer;
    const out_ptr: [*]vizg.AmbientGlobal = @ptrFromInt(scratch_start);
    const out_slice = out_ptr[0..count];
    for (out_slice, 0..) |*output, index| {
        const item = globals_ptr[index];
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .namespace = .{
                .value = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_VALUE != 0,
                .type = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_TYPE != 0,
            },
            .type_metadata = if (item.has_type_metadata == 1) externalType(item.type_metadata).? else null,
            .host_binding_id = item.host_binding_id,
        };
    }
    owned.project.registerAmbientGlobals(out_slice) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectRegisterAmbientGlobalsV2(
    project: ?*Vizg_Project,
    globals_ptr: [*c]const Vizg_AmbientGlobalV2,
    count: usize,
) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    if (count == 0) return .OK;
    if (!validAlignedHostArray(Vizg_AmbientGlobalV2, globals_ptr, count)) return .INVALID_ARGUMENT;
    const items_bytes = checkedByteLen(Vizg_AmbientGlobalV2, count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, globals_ptr, items_bytes)) return .INVALID_ARGUMENT;

    var total_members: usize = 0;
    for (globals_ptr[0..count]) |*item| {
        if (item.namespace_flags == 0 or (item.namespace_flags & ~VIZG_EXTERNAL_NAMESPACE_BOTH) != 0) return .INVALID_ARGUMENT;
        if (item.has_type_metadata > 1) return .INVALID_ARGUMENT;
        if (item.has_type_metadata == 1) {
            if (externalType(item.type_metadata) == null) return .INVALID_ARGUMENT;
        } else if (item.type_metadata != 0) return .INVALID_ARGUMENT;
        if (!std.mem.eql(u8, &item.reserved, &[_]u8{0} ** 8)) return .INVALID_ARGUMENT;
        if (!validAlignedHostArray(u8, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
        if (!inputOutsideWorkspace(owned, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
        if (!validAlignedHostArray(Vizg_AmbientMember, item.members_ptr, item.member_count)) return .INVALID_ARGUMENT;
        const member_bytes = checkedByteLen(Vizg_AmbientMember, item.member_count) orelse return .INVALID_ARGUMENT;
        if (!inputOutsideWorkspace(owned, item.members_ptr, member_bytes)) return .INVALID_ARGUMENT;
        total_members = std.math.add(usize, total_members, item.member_count) catch return .OUT_OF_MEMORY;
        for (item.members_ptr[0..item.member_count]) |*member| {
            if (member.has_type_metadata > 1 or member.optional > 1 or member.readonly > 1 or member.self_reference > 1)
                return .INVALID_ARGUMENT;
            if (member.self_reference == 1) {
                if (member.has_type_metadata != 0 or member.type_metadata != 0 or member.optional != 0 or member.readonly != 1)
                    return .INVALID_ARGUMENT;
            } else if (member.has_type_metadata != 1 or externalType(member.type_metadata) == null) {
                return .INVALID_ARGUMENT;
            }
            if (!std.mem.eql(u8, &member.reserved, &[_]u8{0} ** 8)) return .INVALID_ARGUMENT;
            if (!validAlignedHostArray(u8, member.name_ptr, member.name_len)) return .INVALID_ARGUMENT;
            if (!inputOutsideWorkspace(owned, member.name_ptr, member.name_len)) return .INVALID_ARGUMENT;
        }
    }

    const descriptor_bytes = checkedByteLen(vizg.AmbientGlobal, count) orelse return .OUT_OF_MEMORY;
    const members_offset = std.mem.alignForward(usize, descriptor_bytes, @alignOf(vizg.AmbientMember));
    const member_bytes = checkedByteLen(vizg.AmbientMember, total_members) orelse return .OUT_OF_MEMORY;
    const scratch_bytes = std.math.add(usize, members_offset, member_bytes) catch return .OUT_OF_MEMORY;
    const scratch_alignment = @max(@alignOf(vizg.AmbientGlobal), @alignOf(vizg.AmbientMember));
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const unaligned_start = std.math.sub(usize, buffer_end, scratch_bytes) catch return .OUT_OF_MEMORY;
    const scratch_start = std.mem.alignBackward(usize, unaligned_start, scratch_alignment);
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (scratch_start < used_end) return .OUT_OF_MEMORY;
    owned.fba.buffer = buffer[0 .. scratch_start - buffer_start];
    defer owned.fba.buffer = buffer;

    const out_globals: [*]vizg.AmbientGlobal = @ptrFromInt(scratch_start);
    const out_members: [*]vizg.AmbientMember = @ptrFromInt(scratch_start + members_offset);
    var member_index: usize = 0;
    for (out_globals[0..count], 0..) |*output, index| {
        const item = globals_ptr[index];
        const member_start = member_index;
        for (item.members_ptr[0..item.member_count]) |member| {
            out_members[member_index] = .{
                .name = bytes(member.name_ptr, member.name_len),
                .type_metadata = if (member.has_type_metadata == 1) externalType(member.type_metadata).? else null,
                .optional = member.optional == 1,
                .readonly = member.readonly == 1,
                .self_reference = member.self_reference == 1,
            };
            member_index += 1;
        }
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .namespace = .{
                .value = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_VALUE != 0,
                .type = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_TYPE != 0,
            },
            .type_metadata = if (item.has_type_metadata == 1) externalType(item.type_metadata).? else null,
            .host_binding_id = item.host_binding_id,
            .members = out_members[member_start..member_index],
        };
    }
    owned.project.registerAmbientGlobals(out_globals[0..count]) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectRegisterSourceHostBindings(
    project: ?*Vizg_Project,
    bindings_ptr: [*c]const Vizg_SourceHostBinding,
    count: usize,
) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    if (count == 0) return .OK;
    if (!validAlignedHostArray(Vizg_SourceHostBinding, bindings_ptr, count)) return .INVALID_ARGUMENT;
    const items_bytes = checkedByteLen(Vizg_SourceHostBinding, count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, bindings_ptr, items_bytes)) return .INVALID_ARGUMENT;

    for (bindings_ptr[0..count]) |*item| {
        if (!std.mem.eql(u8, &item.reserved, &[_]u8{0} ** 8)) return .INVALID_ARGUMENT;
        if (item.name_len == 0 or !validAlignedHostArray(u8, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
        if (!inputOutsideWorkspace(owned, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
    }

    const descriptor_bytes = checkedByteLen(vizg.SourceHostBinding, count) orelse return .OUT_OF_MEMORY;
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const unaligned_start = std.math.sub(usize, buffer_end, descriptor_bytes) catch return .OUT_OF_MEMORY;
    const scratch_start = std.mem.alignBackward(usize, unaligned_start, @alignOf(vizg.SourceHostBinding));
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (scratch_start < used_end) return .OUT_OF_MEMORY;
    owned.fba.buffer = buffer[0 .. scratch_start - buffer_start];
    defer owned.fba.buffer = buffer;

    const out_ptr: [*]vizg.SourceHostBinding = @ptrFromInt(scratch_start);
    for (out_ptr[0..count], 0..) |*output, index| {
        const item = bindings_ptr[index];
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .host_binding_id = item.host_binding_id,
        };
    }
    owned.project.registerSourceHostBindings(out_ptr[0..count]) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectStep(project: ?*Vizg_Project, out_step: ?*Vizg_ProjectStep) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const output = out_step orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectStep, output, 1) or
        !inputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectStep))) return .INVALID_ARGUMENT;
    output.* = std.mem.zeroes(Vizg_ProjectStep);
    const next = owned.project.step() catch |err| return statusFromError(owned, err);
    switch (next) {
        .complete => output.kind = 0,
        .request => |request| {
            owned.step_attributes.clearRetainingCapacity();
            owned.step_attributes.ensureTotalCapacity(owned.fba.allocator(), request.attributes.len) catch return .OUT_OF_MEMORY;
            for (request.attributes) |attribute| owned.step_attributes.appendAssumeCapacity(.{
                .key_ptr = if (attribute.key.len == 0) null else attribute.key.ptr,
                .key_len = attribute.key.len,
                .value_ptr = if (attribute.value.len == 0) null else attribute.value.ptr,
                .value_len = attribute.value.len,
                .span = span(attribute.span),
            });
            output.* = .{
                .kind = 1,
                .request_id = request.id.value(),
                .importer_module_id = request.importer.value(),
                .specifier_ptr = if (request.raw_specifier.len == 0) null else request.raw_specifier.ptr,
                .specifier_len = request.raw_specifier.len,
                .request_operation = requestOperation(request.operation),
                .type_only = @intFromBool(request.type_only),
                .reserved = .{ 0, 0, 0 },
                .attributes_ptr = if (owned.step_attributes.items.len == 0) null else owned.step_attributes.items.ptr,
                .attribute_count = owned.step_attributes.items.len,
                .span = span(request.span),
            };
        },
    }
    return .OK;
}

pub fn projectRespondSource(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectSource, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource)) or
        !validSourceScalars(args)) return .INVALID_ARGUMENT;
    if (args.is_root != 0) return .INVALID_ARGUMENT;
    if (sourceLengthStatus(owned, args.source_len)) |status| return status;
    if (!sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    owned.project.respondSource(.init(request_id), source) catch |err| return statusFromError(owned, err);
    return .OK;
}

fn exportKind(value: u32) ?vizg.ExternalExportKind {
    return switch (value) {
        0 => .named,
        1 => .default,
        2 => .namespace,
        else => null,
    };
}

fn externalType(value: u32) ?vizg.ExternalType {
    return switch (value) {
        0 => .unknown,
        1 => .any,
        2 => .never,
        3 => .void,
        4 => .undefined,
        5 => .null_,
        6 => .boolean,
        7 => .number,
        8 => .bigint,
        9 => .string,
        10 => .symbol,
        11 => .object,
        else => null,
    };
}

fn externalDeclarationKind(value: u32) ?vizg.ExternalDeclarationKind {
    return switch (value) {
        0 => .function,
        1 => .global,
        2 => .constant,
        3 => .type,
        else => null,
    };
}

const external_effect_mask: u16 = 0x7f;

fn externalEffects(value: u16) ?vizg.ExternalEffectSet {
    if (value & ~external_effect_mask != 0) return null;
    return .{
        .reads_memory = value & VIZG_EXTERNAL_EFFECT_READS_MEMORY != 0,
        .writes_memory = value & VIZG_EXTERNAL_EFFECT_WRITES_MEMORY != 0,
        .may_throw = value & VIZG_EXTERNAL_EFFECT_THROWS != 0,
        .may_suspend = value & VIZG_EXTERNAL_EFFECT_ASYNC != 0,
        .allocates = value & VIZG_EXTERNAL_EFFECT_ALLOCATES != 0,
        .calls_unknown = value & VIZG_EXTERNAL_EFFECT_IO != 0,
        .unknown = value & VIZG_EXTERNAL_EFFECT_UNKNOWN != 0,
    };
}

fn validExternalExport(owned: *const OwnedProject, item: *const Vizg_ExternalExport) bool {
    if (!validAlignedHostArray(u8, item.name_ptr, item.name_len) or
        !inputOutsideWorkspace(owned, item.name_ptr, item.name_len) or
        item.namespace_flags == 0 or
        item.namespace_flags & ~@as(Vizg_ExternalNamespaceFlags, VIZG_EXTERNAL_NAMESPACE_BOTH) != 0 or
        item.has_type_metadata > 1 or
        item.reserved[0] != 0 or item.reserved[1] != 0 or
        exportKind(item.kind) == null)
    {
        return false;
    }
    return item.has_type_metadata == 0 or externalType(item.type_metadata) != null;
}

pub fn projectRespondExternal(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ExternalModule) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ExternalModule, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ExternalModule))) return .INVALID_ARGUMENT;
    if (!validAlignedHostArray(u8, args.logical_name_ptr, args.logical_name_len) or
        !validAlignedHostArray(Vizg_ExternalExport, args.exports_ptr, args.export_count)) return .INVALID_ARGUMENT;

    const exports_bytes = checkedByteLen(Vizg_ExternalExport, args.export_count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, args.logical_name_ptr, args.logical_name_len) or
        !inputOutsideWorkspace(owned, args.exports_ptr, exports_bytes)) return .INVALID_ARGUMENT;
    if (args.export_count != 0) {
        for (args.exports_ptr[0..args.export_count]) |*item| {
            if (!validExternalExport(owned, item)) return .INVALID_ARGUMENT;
        }
    }

    const descriptor_bytes = checkedByteLen(vizg.ExternalExportDescriptor, args.export_count) orelse return .OUT_OF_MEMORY;
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const unaligned_start = std.math.sub(usize, buffer_end, descriptor_bytes) catch return .OUT_OF_MEMORY;
    const scratch_start = std.mem.alignBackward(usize, unaligned_start, @alignOf(vizg.ExternalExportDescriptor));
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (scratch_start < used_end) return .OUT_OF_MEMORY;
    const scratch_index = scratch_start - buffer_start;
    owned.fba.buffer = buffer[0..scratch_index];
    defer owned.fba.buffer = buffer;
    const exports_ptr: [*]vizg.ExternalExportDescriptor = @ptrFromInt(scratch_start);
    const exports = exports_ptr[0..args.export_count];
    for (exports, 0..) |*output, index| {
        const item = args.exports_ptr[index];
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .kind = exportKind(item.kind).?,
            .namespace = .{
                .value = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_VALUE != 0,
                .type = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_TYPE != 0,
            },
            .type_metadata = if (item.has_type_metadata == 1)
                externalType(item.type_metadata).?
            else
                null,
        };
    }
    owned.project.respondExternalModule(.init(request_id), .{
        .id = .init(args.external_module_id),
        .logical_name = bytes(args.logical_name_ptr, args.logical_name_len),
        .exports = exports,
    }) catch |err| return statusFromError(owned, err);
    return .OK;
}

fn validExternalParameterV2(owned: *const OwnedProject, item: *const Vizg_ExternalParameterV2) bool {
    return validAlignedHostArray(u8, item.name_ptr, item.name_len) and
        inputOutsideWorkspace(owned, item.name_ptr, item.name_len) and
        externalType(item.type_metadata) != null and
        item.optional <= 1 and item.has_default <= 1 and item.rest <= 1 and
        item.reserved == 0;
}

fn zeroExternalFunctionV2(function: Vizg_ExternalFunctionV2) bool {
    return function.parameters_ptr == null and function.parameter_count == 0 and
        function.return_type == 0 and function.type_parameter_count == 0 and
        function.is_async == 0 and function.is_generator == 0 and
        function.is_constructor == 0 and function.reserved == 0;
}

fn validExternalFunctionV2(owned: *const OwnedProject, function: *const Vizg_ExternalFunctionV2) bool {
    if (!validAlignedHostArray(Vizg_ExternalParameterV2, function.parameters_ptr, function.parameter_count) or
        function.is_async > 1 or function.is_generator > 1 or function.is_constructor > 1 or
        function.reserved != 0 or externalType(function.return_type) == null)
    {
        return false;
    }
    const parameters_bytes = checkedByteLen(Vizg_ExternalParameterV2, function.parameter_count) orelse return false;
    if (!inputOutsideWorkspace(owned, function.parameters_ptr, parameters_bytes)) return false;
    if (function.parameter_count != 0) {
        for (function.parameters_ptr[0..function.parameter_count]) |*parameter| {
            if (!validExternalParameterV2(owned, parameter)) return false;
        }
    }
    return true;
}

fn validExternalExportV2(owned: *const OwnedProject, item: *const Vizg_ExternalExportV2) bool {
    if (!validAlignedHostArray(u8, item.name_ptr, item.name_len) or
        !inputOutsideWorkspace(owned, item.name_ptr, item.name_len) or
        item.namespace_flags == 0 or
        item.namespace_flags & ~@as(Vizg_ExternalNamespaceFlags, VIZG_EXTERNAL_NAMESPACE_BOTH) != 0 or
        item.has_type_metadata > 1 or item.has_function > 1 or item.reserved != 0 or item.reserved2 != 0 or
        exportKind(item.kind) == null or externalDeclarationKind(item.declaration_kind) == null or
        externalEffects(item.effect_flags) == null)
    {
        return false;
    }
    if (item.has_type_metadata == 1 and externalType(item.type_metadata) == null) return false;
    if (item.has_function == 0) return zeroExternalFunctionV2(item.function) and item.declaration_kind != 0;
    return item.declaration_kind == 0 and validExternalFunctionV2(owned, &item.function);
}

pub fn externalModuleApiVersion() callconv(.c) u32 {
    return VIZG_EXTERNAL_MODULE_API_VERSION;
}

pub fn projectRespondExternalV2(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ExternalModuleV2) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ExternalModuleV2, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ExternalModuleV2)) or
        !validAlignedHostArray(u8, args.logical_name_ptr, args.logical_name_len) or
        !validAlignedHostArray(Vizg_ExternalExportV2, args.exports_ptr, args.export_count)) return .INVALID_ARGUMENT;

    const exports_bytes = checkedByteLen(Vizg_ExternalExportV2, args.export_count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, args.logical_name_ptr, args.logical_name_len) or
        !inputOutsideWorkspace(owned, args.exports_ptr, exports_bytes)) return .INVALID_ARGUMENT;

    var parameter_count: usize = 0;
    if (args.export_count != 0) {
        for (args.exports_ptr[0..args.export_count]) |*item| {
            if (!validExternalExportV2(owned, item)) return .INVALID_ARGUMENT;
            parameter_count = std.math.add(usize, parameter_count, item.function.parameter_count) catch
                return .INVALID_ARGUMENT;
        }
    }

    const descriptor_bytes = checkedByteLen(vizg.ExternalExportDescriptor, args.export_count) orelse return .OUT_OF_MEMORY;
    const parameter_bytes = checkedByteLen(vizg.ExternalParameterDescriptor, parameter_count) orelse return .OUT_OF_MEMORY;
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const descriptor_unaligned = std.math.sub(usize, buffer_end, descriptor_bytes) catch return .OUT_OF_MEMORY;
    const descriptor_start = std.mem.alignBackward(usize, descriptor_unaligned, @alignOf(vizg.ExternalExportDescriptor));
    const parameter_unaligned = std.math.sub(usize, descriptor_start, parameter_bytes) catch return .OUT_OF_MEMORY;
    const parameter_start = std.mem.alignBackward(usize, parameter_unaligned, @alignOf(vizg.ExternalParameterDescriptor));
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (parameter_start < used_end) return .OUT_OF_MEMORY;
    owned.fba.buffer = buffer[0 .. parameter_start - buffer_start];
    defer owned.fba.buffer = buffer;

    const descriptors_ptr: [*]vizg.ExternalExportDescriptor = @ptrFromInt(descriptor_start);
    const descriptors = descriptors_ptr[0..args.export_count];
    const parameters_ptr: [*]vizg.ExternalParameterDescriptor = @ptrFromInt(parameter_start);
    const parameters = parameters_ptr[0..parameter_count];
    var next_parameter: usize = 0;
    for (descriptors, 0..) |*output, index| {
        const item = args.exports_ptr[index];
        var function: ?vizg.ExternalFunctionDescriptor = null;
        if (item.has_function == 1) {
            const start = next_parameter;
            if (item.function.parameter_count != 0) {
                for (item.function.parameters_ptr[0..item.function.parameter_count]) |parameter| {
                    parameters[next_parameter] = .{
                        .name = bytes(parameter.name_ptr, parameter.name_len),
                        .type_metadata = externalType(parameter.type_metadata).?,
                        .optional = parameter.optional == 1,
                        .has_default = parameter.has_default == 1,
                        .rest = parameter.rest == 1,
                    };
                    next_parameter += 1;
                }
            }
            function = .{
                .parameters = parameters[start..next_parameter],
                .return_type = externalType(item.function.return_type).?,
                .type_parameter_count = item.function.type_parameter_count,
                .is_async = item.function.is_async == 1,
                .is_generator = item.function.is_generator == 1,
                .is_constructor = item.function.is_constructor == 1,
            };
        }
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .kind = exportKind(item.kind).?,
            .namespace = .{
                .value = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_VALUE != 0,
                .type = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_TYPE != 0,
            },
            .type_metadata = if (item.has_type_metadata == 1) externalType(item.type_metadata).? else null,
            .symbol_id = .init(item.external_symbol_id),
            .declaration_kind = externalDeclarationKind(item.declaration_kind).?,
            .function = function,
            .effects = externalEffects(item.effect_flags).?,
        };
    }

    owned.project.respondExternalModule(.init(request_id), .{
        .id = .init(args.external_module_id),
        .logical_name = bytes(args.logical_name_ptr, args.logical_name_len),
        .exports = descriptors,
    }) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectRespondFailure(project: ?*Vizg_Project, request_id: u64, failure_kind: u32) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    switch (failure_kind) {
        0 => owned.project.respondNotFound(.init(request_id)) catch |err| return statusFromError(owned, err),
        1 => owned.project.respondDenied(.init(request_id)) catch |err| return statusFromError(owned, err),
        2 => owned.project.respondFailed(.init(request_id)) catch |err| return statusFromError(owned, err),
        else => return .INVALID_ARGUMENT,
    }
    return .OK;
}

pub fn projectFinish(project: ?*Vizg_Project, out_result: [*c]?*Vizg_ProjectResult) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (owned.creation_limited) return .INVALID_STATE;
    beginProjectCall(owned);
    if (!validAlignedMutableHostArray(?*Vizg_ProjectResult, out_result, 1) or
        !inputOutsideWorkspace(owned, out_result, @sizeOf(?*Vizg_ProjectResult))) return .INVALID_ARGUMENT;
    out_result[0] = null;
    const finished = owned.project.finish() catch |err| return statusFromError(owned, err);
    if (owned.result_ready) {
        if (owned.result_view.destroyed) return .INVALID_STATE;
        out_result[0] = @ptrCast(&owned.result_view);
        return .OK;
    }
    var hir_result: ?vizg.hir.HirResult = null;
    if (!finished.has_failures) {
        var lowered = vizg.hir.lowerProject(owned.fba.allocator(), &owned.project, .{}) catch |err|
            return statusFromError(owned, err);
        switch (lowered) {
            .result => |value| {
                hir_result = value;
                lowered = undefined;
            },
            .diagnostics => |*report| report.deinit(),
        }
    }
    errdefer if (hir_result) |*value| value.deinit();
    const result = &owned.result_view;
    const semantic_result = owned.project.semanticResult();
    const canonical_diagnostic_count = diagnosticCount(owned);
    result.* = .{ .magic = result_magic, .summary = .{
        .module_count = finished.module_count,
        .diagnostic_count = canonical_diagnostic_count,
        .edge_count = owned.project.edges().len,
        .import_count = if (semantic_result) |value| value.imports.len else 0,
        .export_count = if (semantic_result) |value| value.exports.len else 0,
        .is_partial = @intFromBool(false),
        .has_syntax_errors = @intFromBool(false),
        .has_semantic_errors = @intFromBool(false),
        .has_project_errors = @intFromBool(false),
        .has_module_failures = @intFromBool(false),
        .reserved = .{ 0, 0, 0 },
    }, .owner = owned, .hir_result = hir_result };
    result.summary.has_syntax_errors = @intFromBool(
        resultHasPhase(result, .scanner) or resultHasPhase(result, .parser),
    );
    result.summary.has_semantic_errors = @intFromBool(
        resultHasPhase(result, .binder) or resultHasPhase(result, .resolver) or
            resultHasPhase(result, .types) or resultHasPhase(result, .checker),
    );
    result.summary.has_project_errors = @intFromBool(resultHasPhase(result, .project));
    result.summary.has_module_failures = @intFromBool(resultHasPhase(result, .module_host));
    result.summary.is_partial = @intFromBool(
        result.summary.has_syntax_errors != 0 or
            result.summary.has_semantic_errors != 0 or
            result.summary.has_project_errors != 0 or
            result.summary.has_module_failures != 0,
    );
    owned.result_ready = true;
    out_result[0] = @ptrCast(result);
    return .OK;
}

pub fn projectResultSummary(result: ?*const Vizg_ProjectResult, out_summary: ?*Vizg_ProjectResultSummary) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_summary orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectResultSummary, output, 1) or
        !inputOutsideWorkspace(owned.owner, output, @sizeOf(Vizg_ProjectResultSummary))) return .INVALID_ARGUMENT;
    output.* = owned.summary;
    return .OK;
}

pub fn projectResultModule(result: ?*const Vizg_ProjectResult, index: usize, out_module: ?*Vizg_ProjectModuleInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_module orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectModuleInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectModuleInfo))) return .INVALID_ARGUMENT;
    const modules = owned.owner.project.modulesView();
    if (index >= modules.len) return .INVALID_ARGUMENT;
    const module = modules[index];
    const logical_name = if (module.source) |source| source.logical_name else "";
    output.* = .{
        .module_id = module.id.value(),
        .logical_name_ptr = if (logical_name.len == 0) null else logical_name.ptr,
        .logical_name_len = logical_name.len,
        .state = @intFromEnum(module.state),
        .is_root = @intFromBool(module.is_root),
        .has_source = @intFromBool(module.source != null),
        .reserved = .{ 0, 0 },
    };
    return .OK;
}

pub fn projectResultDiagnostic(result: ?*const Vizg_ProjectResult, index: usize, out_diagnostic: ?*Vizg_ProjectDiagnostic) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_diagnostic orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectDiagnostic, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectDiagnostic))) return .INVALID_ARGUMENT;
    const diagnostics = owned.owner.project.diagnostics();
    if (index >= diagnostics.len) return .INVALID_ARGUMENT;
    const item = diagnostics[index];
    output.* = .{
        .module_id = if (item.module_id) |value| value.value() else 0,
        .has_module_id = @intFromBool(item.module_id != null),
        .severity = diagnosticSeverity(item.severity),
        .phase = diagnosticPhase(item.phase),
        .reserved = 0,
        .code = diagnosticCode(item.code),
        .message_ptr = if (item.message.len == 0) null else item.message.ptr,
        .message_len = item.message.len,
        .logical_name_ptr = if (item.logical_name.len == 0) null else item.logical_name.ptr,
        .logical_name_len = item.logical_name.len,
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultEdge(result: ?*const Vizg_ProjectResult, index: usize, out_edge: ?*Vizg_ProjectEdgeInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_edge orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectEdgeInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectEdgeInfo))) return .INVALID_ARGUMENT;
    const edges = owned.owner.project.edges();
    if (index >= edges.len) return .INVALID_ARGUMENT;
    const item = edges[index];
    output.* = .{
        .request_id = item.request_id.value(),
        .importer_module_id = item.importer.value(),
        .target_module_id = if (item.target) |value| value.value() else 0,
        .external_module_id = if (item.external_target) |value| value.value() else 0,
        .specifier_ptr = if (item.raw_specifier.len == 0) null else item.raw_specifier.ptr,
        .specifier_len = item.raw_specifier.len,
        .request_operation = @intFromEnum(item.operation),
        .state = @intFromEnum(item.state),
        .type_only = @intFromBool(item.type_only),
        .has_target_module = @intFromBool(item.target != null),
        .has_external_target = @intFromBool(item.external_target != null),
        .reserved = 0,
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultImport(result: ?*const Vizg_ProjectResult, index: usize, out_import: ?*Vizg_ProjectImportInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_import orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectImportInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectImportInfo))) return .INVALID_ARGUMENT;
    const semantic = projectSemantic(owned) orelse return .INVALID_STATE;
    if (index >= semantic.imports.len) return .INVALID_ARGUMENT;
    const item = semantic.imports[index];
    output.* = .{
        .module_id = item.module_id,
        .target_module_id = item.target_module_id orelse 0,
        .external_module_id = item.external_module_id orelse 0,
        .edge_index = item.edge_index orelse 0,
        .target_type_id = if (item.target) |target| target.type_id else 0,
        .link_state = @intFromEnum(item.state),
        .request_operation = @intFromEnum(item.request_operation),
        .local_name_ptr = if (item.local_name.len == 0) null else item.local_name.ptr,
        .local_name_len = item.local_name.len,
        .imported_name_ptr = if (item.imported_name.len == 0) null else item.imported_name.ptr,
        .imported_name_len = item.imported_name.len,
        .specifier_ptr = if (item.specifier.len == 0) null else item.specifier.ptr,
        .specifier_len = item.specifier.len,
        .type_only = @intFromBool(item.type_only),
        .runtime_binding = @intFromBool(item.runtime_binding),
        .has_target_module = @intFromBool(item.target_module_id != null),
        .has_external_target = @intFromBool(item.external_module_id != null),
        .has_edge_index = @intFromBool(item.edge_index != null),
        .has_semantic_target = @intFromBool(item.target != null),
        .reserved = .{ 0, 0 },
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultExport(result: ?*const Vizg_ProjectResult, index: usize, out_export: ?*Vizg_ProjectExportInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_export orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectExportInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectExportInfo))) return .INVALID_ARGUMENT;
    const semantic = projectSemantic(owned) orelse return .INVALID_STATE;
    if (index >= semantic.exports.len) return .INVALID_ARGUMENT;
    const item = semantic.exports[index];
    const source_edge = if (item.edge_index) |edge_index|
        if (edge_index < owned.owner.project.edges().len) owned.owner.project.edges()[edge_index] else return .INTERNAL_ERROR
    else
        null;
    output.* = .{
        .module_id = item.module_id,
        .target_module_id = if (source_edge) |edge| if (edge.target) |target| target.value() else 0 else 0,
        .external_module_id = if (source_edge) |edge| if (edge.external_target) |target| target.value() else 0 else 0,
        .edge_index = item.edge_index orelse 0,
        .target_type_id = item.identity.type_id,
        .name_ptr = if (item.name.len == 0) null else item.name.ptr,
        .name_len = item.name.len,
        .type_only = @intFromBool(item.type_only),
        .re_export = @intFromBool(item.re_export),
        .has_target_module = @intFromBool(if (source_edge) |edge| edge.target != null else false),
        .has_external_target = @intFromBool(if (source_edge) |edge| edge.external_target != null else false),
        .has_edge_index = @intFromBool(item.edge_index != null),
        .reserved = .{ 0, 0, 0 },
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultDestroy(result: ?*Vizg_ProjectResult) callconv(.c) void {
    const handle = result orelse return;
    if (!validAlignedHostObject(OwnedProjectResult, handle)) return;
    const owned: *OwnedProjectResult = @ptrCast(@alignCast(handle));
    if (owned.magic != result_magic or owned.destroyed) return;
    const owner_handle: *Vizg_Project = @ptrCast(owned.owner);
    const owner = ownedProject(owner_handle) orelse return;
    if (owner != owned.owner or !rangeInsideWorkspace(owner, handle, @sizeOf(OwnedProjectResult))) return;
    const owns_owner = owned.owns_owner;
    if (owned.hir_result) |*value| value.deinit();
    owned.hir_result = null;
    owned.destroyed = true;
    if (owns_owner) owner.deinit();
}

pub fn hirApiVersion() callconv(.c) u32 {
    return VIZG_HIR_API_VERSION;
}

fn hirOwned(result: ?*const Vizg_ProjectResult, requested_version: u32) ?*const OwnedProjectResult {
    if (requested_version == 0 or requested_version > VIZG_HIR_API_VERSION) return null;
    const owned = ownedResult(result) orelse return null;
    if (owned.hir_result == null) return null;
    return owned;
}

fn idIndex(id: anytype) u64 {
    return id.index() orelse std.math.maxInt(u32);
}

fn optionalId(id: anytype) u64 {
    return if (id) |value| idIndex(value) else VIZG_HIR_ID_NONE;
}

fn effectBits(effects: vizg.hir.EffectSet) u8 {
    return @as(u8, @intFromBool(effects.pure)) |
        (@as(u8, @intFromBool(effects.may_throw)) << 1) |
        (@as(u8, @intFromBool(effects.may_call_user_code)) << 2) |
        (@as(u8, @intFromBool(effects.reads_state)) << 3) |
        (@as(u8, @intFromBool(effects.writes_state)) << 4) |
        (@as(u8, @intFromBool(effects.may_suspend)) << 5) |
        (@as(u8, @intFromBool(effects.creates_identity)) << 6);
}

pub fn hirSummary(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    out_summary: ?*Vizg_HirSummary,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_summary orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirSummary, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirSummary))) return .INVALID_ARGUMENT;
    const project = owned.hir_result.?.project;
    var block_count: usize = 0;
    var instruction_count: usize = 0;
    var binding_count: usize = 0;
    for (project.functions) |function| {
        block_count += function.blocks.len;
        binding_count += function.bindings.len;
        for (function.blocks) |block| instruction_count += block.instructions.len;
    }
    output.* = .{
        .module_count = project.modules.len,
        .external_declaration_count = project.external_declarations.len,
        .function_count = project.functions.len,
        .block_count = block_count,
        .instruction_count = instruction_count,
        .binding_count = binding_count,
        .type_count = owned.hir_result.?.typeCount(),
        .origin_count = project.origins.records.len,
    };
    return .OK;
}

fn emptyHirRecord(kind: Vizg_HirEntityKind) Vizg_HirRecord {
    return std.mem.zeroInit(Vizg_HirRecord, .{ .kind = kind });
}

fn hirOriginFlags(requested_version: u32, type_id: ?u32) u8 {
    return if (requested_version >= 2 and type_id != null) 1 else 0;
}

pub fn hirRecordAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    kind: Vizg_HirEntityKind,
    index: usize,
    out_record: ?*Vizg_HirRecord,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_record orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirRecord, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirRecord))) return .INVALID_ARGUMENT;
    const hir_result = &owned.hir_result.?;
    const project = hir_result.project;
    output.* = emptyHirRecord(kind);
    switch (kind) {
        .MODULE => {
            if (index >= project.modules.len) return .INVALID_ARGUMENT;
            const item = project.modules[index];
            output.id = item.module_id.value();
            output.module_id = item.module_id.value();
            output.secondary_id = idIndex(item.initialization);
            output.origin_id = @intCast(idIndex(item.origin));
            output.name_ptr = item.logical_name.ptr;
            output.name_len = item.logical_name.len;
            output.child_count = item.entities.len;
        },
        .EXTERNAL_DECLARATION => {
            if (index >= project.external_declarations.len) return .INVALID_ARGUMENT;
            const item = project.external_declarations[index];
            output.id = item.symbol_id.value();
            output.parent_id = item.module_id.value();
            output.tag = @intFromEnum(item.kind);
            output.type_id = item.type_id;
            output.effect_bits = @bitCast(item.effects);
            output.name_ptr = item.exported_name.ptr;
            output.name_len = item.exported_name.len;
        },
        .FUNCTION => {
            if (index >= project.functions.len) return .INVALID_ARGUMENT;
            const item = project.functions[index];
            output.id = idIndex(item.id);
            output.module_id = item.module_id.value();
            output.tag = @intFromEnum(item.kind);
            output.type_id = item.signature_type;
            output.origin_id = @intCast(idIndex(item.origin));
            output.child_count = item.blocks.len;
        },
        .BLOCK, .INSTRUCTION, .BINDING => {
            var current: usize = 0;
            for (project.functions) |function| {
                if (kind == .BINDING) for (function.bindings) |item| {
                    if (current == index) {
                        output.id = idIndex(item.id);
                        output.parent_id = idIndex(function.id);
                        output.module_id = function.module_id.value();
                        output.tag = hirBindingKind(item.kind);
                        output.type_id = item.type_id;
                        output.flags = @intFromBool(item.mutable);
                        output.origin_id = @intCast(idIndex(item.origin));
                        output.name_ptr = item.name.ptr;
                        output.name_len = item.name.len;
                        return .OK;
                    }
                    current += 1;
                };
                for (function.blocks) |block| {
                    if (kind == .BLOCK) {
                        if (current == index) {
                            output.id = idIndex(block.id);
                            output.parent_id = idIndex(function.id);
                            output.module_id = function.module_id.value();
                            output.tag = @intFromEnum(std.meta.activeTag(block.terminator));
                            output.origin_id = @intCast(idIndex(block.origin));
                            output.child_count = block.instructions.len;
                            return .OK;
                        }
                        current += 1;
                    } else if (kind == .INSTRUCTION) for (block.instructions) |item| {
                        if (current == index) {
                            output.id = idIndex(item.id);
                            output.parent_id = idIndex(block.id);
                            output.secondary_id = if (requested_version == 1)
                                idIndex(function.id)
                            else
                                optionalId(item.result);
                            output.module_id = function.module_id.value();
                            output.tag = @intFromEnum(std.meta.activeTag(item.operation));
                            output.type_id = item.result_type orelse 0;
                            output.effect_bits = effectBits(item.effects);
                            output.flags = @intFromBool(item.result != null);
                            output.origin_id = @intCast(idIndex(item.origin));
                            return .OK;
                        }
                        current += 1;
                    };
                }
            }
            return .INVALID_ARGUMENT;
        },
        .TYPE => {
            const item = hir_result.typeAt(index) orelse return .INVALID_ARGUMENT;
            output.id = item.id;
            output.tag = @intFromEnum(std.meta.activeTag(item.kind));
        },
        .ORIGIN => {
            if (index >= project.origins.records.len) return .INVALID_ARGUMENT;
            const item = project.origins.records[index];
            output.id = index;
            output.module_id = item.module_id.value();
            output.tag = @intFromEnum(item.lowering_rule);
            output.type_id = item.type_id orelse 0;
            output.flags = hirOriginFlags(requested_version, item.type_id);
            output.secondary_id = item.primary_span.start;
            output.child_count = item.ast_nodes.len;
        },
    }
    return .OK;
}

pub fn hirDetailApiVersion() callconv(.c) u32 {
    return VIZG_HIR_DETAIL_API_VERSION;
}

fn hirDetailOwned(result: ?*const Vizg_ProjectResult, requested_version: u32) ?*const OwnedProjectResult {
    if (requested_version != VIZG_HIR_DETAIL_API_VERSION) return null;
    const owned = ownedResult(result) orelse return null;
    if (owned.hir_result == null) return null;
    return owned;
}

fn hirFunctionFlags(flags: vizg.hir.model.HirFunctionFlags) u16 {
    return @as(u16, @intFromBool(flags.lexical_this)) |
        (@as(u16, @intFromBool(flags.dynamic_this)) << 1) |
        (@as(u16, @intFromBool(flags.constructor)) << 2) |
        (@as(u16, @intFromBool(flags.getter)) << 3) |
        (@as(u16, @intFromBool(flags.setter)) << 4) |
        (@as(u16, @intFromBool(flags.async_)) << 5) |
        (@as(u16, @intFromBool(flags.generator)) << 6) |
        (@as(u16, @intFromBool(flags.async_generator)) << 7) |
        (@as(u16, @intFromBool(flags.uses_super)) << 8) |
        (@as(u16, @intFromBool(flags.uses_new_target)) << 9);
}

fn hirRegionKind(kind: vizg.hir.model.HirRegionKind) u32 {
    return switch (kind) {
        .catch_ => VIZG_HIR_REGION_CATCH,
        .finally => VIZG_HIR_REGION_FINALLY,
        .iterator_close => VIZG_HIR_REGION_ITERATOR_CLOSE,
    };
}

fn hirBindingKind(kind: vizg.hir.model.HirBindingKind) u32 {
    return switch (kind) {
        .var_ => VIZG_HIR_BINDING_KIND_VAR,
        .let_ => VIZG_HIR_BINDING_KIND_LET,
        .const_ => VIZG_HIR_BINDING_KIND_CONST,
        .parameter => VIZG_HIR_BINDING_KIND_PARAMETER,
        .import => VIZG_HIR_BINDING_KIND_IMPORT,
        .catch_ => VIZG_HIR_BINDING_KIND_CATCH,
        .function => VIZG_HIR_BINDING_KIND_FUNCTION,
        .class => VIZG_HIR_BINDING_KIND_CLASS,
        .enum_ => VIZG_HIR_BINDING_KIND_ENUM,
        .synthetic => VIZG_HIR_BINDING_KIND_SYNTHETIC,
        .temporary => VIZG_HIR_BINDING_KIND_TEMPORARY,
    };
}

test "HIR binding kinds have explicit stable ABI tags" {
    const kinds = [_]vizg.hir.model.HirBindingKind{
        .var_,
        .let_,
        .const_,
        .parameter,
        .import,
        .catch_,
        .function,
        .class,
        .enum_,
        .synthetic,
        .temporary,
    };
    const expected = [_]u32{
        VIZG_HIR_BINDING_KIND_VAR,
        VIZG_HIR_BINDING_KIND_LET,
        VIZG_HIR_BINDING_KIND_CONST,
        VIZG_HIR_BINDING_KIND_PARAMETER,
        VIZG_HIR_BINDING_KIND_IMPORT,
        VIZG_HIR_BINDING_KIND_CATCH,
        VIZG_HIR_BINDING_KIND_FUNCTION,
        VIZG_HIR_BINDING_KIND_CLASS,
        VIZG_HIR_BINDING_KIND_ENUM,
        VIZG_HIR_BINDING_KIND_SYNTHETIC,
        VIZG_HIR_BINDING_KIND_TEMPORARY,
    };
    try std.testing.expectEqual(@typeInfo(vizg.hir.model.HirBindingKind).@"enum".fields.len, kinds.len);
    for (kinds, expected, 0..) |kind, public_tag, index| {
        try std.testing.expectEqual(public_tag, hirBindingKind(kind));
        for (expected[index + 1 ..]) |other| {
            try std.testing.expect(public_tag != other);
        }
    }
}

test "HIR region kinds have explicit stable ABI tags" {
    try std.testing.expectEqual(VIZG_HIR_REGION_CATCH, hirRegionKind(.catch_));
    try std.testing.expectEqual(VIZG_HIR_REGION_FINALLY, hirRegionKind(.finally));
    try std.testing.expectEqual(VIZG_HIR_REGION_ITERATOR_CLOSE, hirRegionKind(.iterator_close));
}

fn hirSignatureFlags(flags: anytype) u8 {
    return @as(u8, @intFromBool(flags.is_async)) |
        (@as(u8, @intFromBool(flags.is_generator)) << 1) |
        (@as(u8, @intFromBool(flags.is_constructor)) << 2);
}

fn hirParameterFlags(optional: bool, has_default: bool, rest: bool, parameter_property: bool) u8 {
    return @as(u8, @intFromBool(optional)) |
        (@as(u8, @intFromBool(has_default)) << 1) |
        (@as(u8, @intFromBool(rest)) << 2) |
        (@as(u8, @intFromBool(parameter_property)) << 3);
}

fn hirBlockAtIndex(project: vizg.hir.HirProject, index: usize) ?vizg.hir.HirBlock {
    var current: usize = 0;
    for (project.functions) |function| {
        for (function.blocks) |block| {
            if (current == index) return block;
            current += 1;
        }
    }
    return null;
}

fn hirBindingAtIndex(project: vizg.hir.HirProject, index: usize) ?vizg.hir.HirBinding {
    var current: usize = 0;
    for (project.functions) |function| {
        for (function.bindings) |binding| {
            if (current == index) return binding;
            current += 1;
        }
    }
    return null;
}

fn hirSemanticIdentity(identity: vizg.hir.model.HirSemanticIdentity) Vizg_HirSemanticIdentity {
    return .{
        .declaration_module_id = identity.declaration.module_id,
        .external_module_id = if (identity.external_module_id) |id| id.value() else VIZG_HIR_ID_NONE,
        .external_symbol_id = if (identity.external_symbol_id) |id| id.value() else VIZG_HIR_ID_NONE,
        .symbol_id = identity.symbol_id orelse VIZG_HIR_U32_NONE,
        .declaration_id = identity.declaration.declaration_id,
        .type_id = identity.type_id,
        .namespace_kind = @intFromEnum(identity.namespace),
        .declaration_external = @intFromBool(identity.declaration.external),
        .has_host_binding_id = @intFromBool(identity.host_binding_id != null),
        .reserved = .{ 0, 0, 0, 0, 0, 0 },
        .host_binding_id = identity.host_binding_id orelse 0,
    };
}

fn hirTypeKind(kind: std.meta.Tag(vizg.types.TypeKind)) u32 {
    return switch (kind) {
        .primitive => VIZG_HIR_TYPE_PRIMITIVE,
        .function => VIZG_HIR_TYPE_FUNCTION,
        .promise => VIZG_HIR_TYPE_PROMISE,
        .generator => VIZG_HIR_TYPE_GENERATOR,
        .literal => VIZG_HIR_TYPE_LITERAL,
        .union_type => VIZG_HIR_TYPE_UNION,
        .intersection => VIZG_HIR_TYPE_INTERSECTION,
        .array => VIZG_HIR_TYPE_ARRAY,
        .tuple => VIZG_HIR_TYPE_TUPLE,
        .object => VIZG_HIR_TYPE_OBJECT,
        .class => VIZG_HIR_TYPE_CLASS,
        .class_constructor => VIZG_HIR_TYPE_CLASS_CONSTRUCTOR,
        .interface => VIZG_HIR_TYPE_INTERFACE,
        .enum_type => VIZG_HIR_TYPE_ENUM,
        .type_parameter => VIZG_HIR_TYPE_PARAMETER,
        .applied_generic => VIZG_HIR_TYPE_APPLIED_GENERIC,
    };
}

test "HIR type kinds use explicit public ABI tags" {
    const expected = [_]u32{
        VIZG_HIR_TYPE_PRIMITIVE,
        VIZG_HIR_TYPE_FUNCTION,
        VIZG_HIR_TYPE_PROMISE,
        VIZG_HIR_TYPE_GENERATOR,
        VIZG_HIR_TYPE_LITERAL,
        VIZG_HIR_TYPE_UNION,
        VIZG_HIR_TYPE_INTERSECTION,
        VIZG_HIR_TYPE_ARRAY,
        VIZG_HIR_TYPE_TUPLE,
        VIZG_HIR_TYPE_OBJECT,
        VIZG_HIR_TYPE_CLASS,
        VIZG_HIR_TYPE_CLASS_CONSTRUCTOR,
        VIZG_HIR_TYPE_INTERFACE,
        VIZG_HIR_TYPE_ENUM,
        VIZG_HIR_TYPE_PARAMETER,
        VIZG_HIR_TYPE_APPLIED_GENERIC,
    };
    const tags = [_]std.meta.Tag(vizg.types.TypeKind){
        .primitive,
        .function,
        .promise,
        .generator,
        .literal,
        .union_type,
        .intersection,
        .array,
        .tuple,
        .object,
        .class,
        .class_constructor,
        .interface,
        .enum_type,
        .type_parameter,
        .applied_generic,
    };
    for (tags, expected) |tag, public_tag| {
        try std.testing.expectEqual(public_tag, hirTypeKind(tag));
    }
}

pub fn hirTypeDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    index: usize,
    out_detail: ?*Vizg_HirTypeDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirTypeDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirTypeDetail))) return .INVALID_ARGUMENT;
    const item = owned.hir_result.?.typeAt(index) orelse return .INVALID_ARGUMENT;
    output.* = .{
        .id = item.id,
        .kind = hirTypeKind(std.meta.activeTag(item.kind)),
        .builtin_kind = switch (item.kind) {
            .primitive => |kind| @intFromEnum(kind),
            else => VIZG_HIR_BUILTIN_NONE,
        },
        .reserved = 0,
    };
    return .OK;
}

pub fn hirFunctionSignature(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    type_id: u32,
    out_signature: ?*Vizg_HirFunctionSignature,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_signature orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirFunctionSignature, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirFunctionSignature))) return .INVALID_ARGUMENT;
    const signature = owned.hir_result.?.lookupFunctionSignature(type_id) orelse return .INVALID_ARGUMENT;
    output.* = .{
        .type_id = signature.id,
        .return_type_id = signature.return_type,
        .type_parameter_count = signature.type_parameter_count,
        .flags = hirSignatureFlags(signature.flags),
        .reserved = .{ 0, 0, 0 },
        .parameter_count = signature.parameters.len,
    };
    return .OK;
}

pub fn hirFunctionCompletionType(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    type_id: u32,
    out_type_id: ?*u32,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_type_id orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(u32, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(u32))) return .INVALID_ARGUMENT;
    const hir_result = &owned.hir_result.?;
    const signature = hir_result.lookupFunctionSignature(type_id) orelse return .INVALID_ARGUMENT;

    var completion_type = signature.return_type;
    if (signature.flags.is_generator) {
        const wrapped = hir_result.lookupType(completion_type) orelse return .INVALID_STATE;
        if (wrapped.kind != .generator) return .INVALID_STATE;
        completion_type = wrapped.kind.generator.return_type;
    }
    if (signature.flags.is_async) {
        const wrapped = hir_result.lookupType(completion_type) orelse return .INVALID_STATE;
        if (wrapped.kind != .promise) return .INVALID_STATE;
        completion_type = wrapped.kind.promise.value_type;
    }
    output.* = completion_type;
    return .OK;
}

pub fn hirSignatureParameterAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    type_id: u32,
    parameter_index: usize,
    out_parameter: ?*Vizg_HirSignatureParameter,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_parameter orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirSignatureParameter, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirSignatureParameter))) return .INVALID_ARGUMENT;
    const signature = owned.hir_result.?.lookupFunctionSignature(type_id) orelse return .INVALID_ARGUMENT;
    if (parameter_index >= signature.parameters.len) return .INVALID_ARGUMENT;
    const parameter = signature.parameters[parameter_index];
    output.* = .{
        .name_ptr = if (parameter.name.len == 0) null else parameter.name.ptr,
        .name_len = parameter.name.len,
        .type_id = parameter.type_id,
        .flags = hirParameterFlags(parameter.optional, parameter.has_default, parameter.rest, false),
        .reserved = .{ 0, 0, 0 },
    };
    return .OK;
}

pub fn hirFunctionDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    function_index: usize,
    out_detail: ?*Vizg_HirFunctionDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirFunctionDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirFunctionDetail))) return .INVALID_ARGUMENT;
    const functions = owned.hir_result.?.project.functions;
    if (function_index >= functions.len) return .INVALID_ARGUMENT;
    const function = functions[function_index];
    output.* = .{
        .id = idIndex(function.id),
        .entry_block_id = idIndex(function.entry),
        .parameter_count = function.parameters.len,
        .flags = hirFunctionFlags(function.flags),
        .reserved = .{ 0, 0, 0, 0, 0, 0 },
    };
    return .OK;
}

pub fn hirFunctionParameterAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    function_index: usize,
    parameter_index: usize,
    out_parameter: ?*Vizg_HirFunctionParameter,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_parameter orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirFunctionParameter, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirFunctionParameter))) return .INVALID_ARGUMENT;
    const functions = owned.hir_result.?.project.functions;
    if (function_index >= functions.len) return .INVALID_ARGUMENT;
    const function = functions[function_index];
    if (parameter_index >= function.parameters.len) return .INVALID_ARGUMENT;
    const parameter = function.parameters[parameter_index];
    output.* = .{
        .binding_id = idIndex(parameter.binding),
        .type_id = parameter.type_id,
        .argument_index = parameter.argument_index,
        .origin_id = @intCast(idIndex(parameter.origin)),
        .flags = hirParameterFlags(parameter.optional, parameter.has_default, parameter.rest, parameter.parameter_property),
        .reserved = .{ 0, 0, 0 },
    };
    return .OK;
}

pub fn hirBlockDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    block_index: usize,
    out_detail: ?*Vizg_HirBlockDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirBlockDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirBlockDetail))) return .INVALID_ARGUMENT;
    const block = hirBlockAtIndex(owned.hir_result.?.project, block_index) orelse return .INVALID_ARGUMENT;
    output.* = .{ .id = idIndex(block.id), .parameter_count = block.parameters.len };
    return .OK;
}

pub fn hirBlockParameterAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    block_index: usize,
    parameter_index: usize,
    out_parameter: ?*Vizg_HirBlockParameter,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_parameter orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirBlockParameter, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirBlockParameter))) return .INVALID_ARGUMENT;
    const block = hirBlockAtIndex(owned.hir_result.?.project, block_index) orelse return .INVALID_ARGUMENT;
    if (parameter_index >= block.parameters.len) return .INVALID_ARGUMENT;
    const parameter = block.parameters[parameter_index];
    output.* = .{
        .value_id = idIndex(parameter.value),
        .type_id = parameter.type_id,
        .origin_id = @intCast(idIndex(parameter.origin)),
    };
    return .OK;
}

pub fn hirOriginDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    origin_index: usize,
    out_detail: ?*Vizg_HirOriginDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirOriginDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirOriginDetail))) return .INVALID_ARGUMENT;
    const records = owned.hir_result.?.project.origins.records;
    if (origin_index >= records.len) return .INVALID_ARGUMENT;
    const origin = records[origin_index];
    var detail = std.mem.zeroes(Vizg_HirOriginDetail);
    detail.id = @intCast(origin_index);
    detail.module_id = origin.module_id.value();
    detail.span_start = origin.primary_span.start;
    detail.span_end = origin.primary_span.end;
    detail.original_syntax = @intFromEnum(origin.original_syntax);
    detail.lowering_rule = @intFromEnum(origin.lowering_rule);
    if (origin.symbol) |symbol| {
        detail.flags |= VIZG_HIR_ORIGIN_HAS_SYMBOL;
        detail.symbol_module_id = symbol.module_id;
        detail.symbol_declaration_id = symbol.declaration_id;
        detail.symbol_external = @intFromBool(symbol.external);
    }
    if (origin.type_id) |type_id| {
        detail.flags |= VIZG_HIR_ORIGIN_HAS_TYPE;
        detail.type_id = type_id;
    }
    if (origin.parent) |parent| {
        detail.flags |= VIZG_HIR_ORIGIN_HAS_PARENT;
        detail.parent_id = @intCast(idIndex(parent));
    }
    if (origin.synthetic_reason) |reason| {
        detail.flags |= VIZG_HIR_ORIGIN_HAS_SYNTHETIC_REASON;
        detail.synthetic_reason = @intFromEnum(reason);
    }
    output.* = detail;
    return .OK;
}

pub fn hirModuleDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    module_index: usize,
    out_detail: ?*Vizg_HirModuleDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirModuleDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirModuleDetail))) return .INVALID_ARGUMENT;
    const modules = owned.hir_result.?.project.modules;
    if (module_index >= modules.len) return .INVALID_ARGUMENT;
    const module = modules[module_index];
    output.* = .{
        .module_id = module.module_id.value(),
        .initialization_function_id = idIndex(module.initialization),
        .dependency_count = module.dependencies.len,
        .import_count = module.imports.len,
        .export_count = module.exports.len,
    };
    return .OK;
}

pub fn hirModuleDependencyAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    module_index: usize,
    dependency_index: usize,
    out_dependency: ?*Vizg_HirModuleDependency,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_dependency orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirModuleDependency, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirModuleDependency))) return .INVALID_ARGUMENT;
    const modules = owned.hir_result.?.project.modules;
    if (module_index >= modules.len) return .INVALID_ARGUMENT;
    const dependencies = modules[module_index].dependencies;
    if (dependency_index >= dependencies.len) return .INVALID_ARGUMENT;
    const dependency = dependencies[dependency_index];
    output.* = .{
        .module_id = dependency.module_id.value(),
        .initialization_required = @intFromBool(dependency.initialization_required),
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
    };
    return .OK;
}

pub fn hirModuleImportAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    module_index: usize,
    import_index: usize,
    out_import: ?*Vizg_HirModuleImport,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_import orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirModuleImport, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirModuleImport))) return .INVALID_ARGUMENT;
    const modules = owned.hir_result.?.project.modules;
    if (module_index >= modules.len) return .INVALID_ARGUMENT;
    const imports = modules[module_index].imports;
    if (import_index >= imports.len) return .INVALID_ARGUMENT;
    const item = imports[import_index];
    const source_kind: u32, const source_id: u64 = switch (item.source) {
        .source => |id| .{ VIZG_HIR_MODULE_REFERENCE_SOURCE, id.value() },
        .external => |id| .{ VIZG_HIR_MODULE_REFERENCE_EXTERNAL, id.value() },
    };
    output.* = .{
        .local_binding_id = optionalId(item.local),
        .source_id = source_id,
        .exported_name_ptr = if (item.exported_name.len == 0) null else item.exported_name.ptr,
        .exported_name_len = item.exported_name.len,
        .target = hirSemanticIdentity(item.target),
        .source_kind = source_kind,
        .type_only = @intFromBool(item.type_only),
        .reserved = .{ 0, 0, 0 },
    };
    return .OK;
}

pub fn hirModuleExportAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    module_index: usize,
    export_index: usize,
    out_export: ?*Vizg_HirModuleExport,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_export orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirModuleExport, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirModuleExport))) return .INVALID_ARGUMENT;
    const modules = owned.hir_result.?.project.modules;
    if (module_index >= modules.len) return .INVALID_ARGUMENT;
    const exports = modules[module_index].exports;
    if (export_index >= exports.len) return .INVALID_ARGUMENT;
    const item = exports[export_index];
    output.* = .{
        .binding_id = optionalId(item.binding),
        .entity_id = optionalId(item.entity),
        .exported_name_ptr = if (item.exported_name.len == 0) null else item.exported_name.ptr,
        .exported_name_len = item.exported_name.len,
        .target = hirSemanticIdentity(item.target),
        .type_only = @intFromBool(item.type_only),
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
    };
    return .OK;
}

pub fn hirBindingDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    binding_index: usize,
    out_detail: ?*Vizg_HirBindingDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirBindingDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirBindingDetail))) return .INVALID_ARGUMENT;
    const binding = hirBindingAtIndex(owned.hir_result.?.project, binding_index) orelse return .INVALID_ARGUMENT;
    var detail = std.mem.zeroes(Vizg_HirBindingDetail);
    detail.id = idIndex(binding.id);
    detail.declaration_id = VIZG_HIR_U32_NONE;
    detail.initial_state = @intFromEnum(binding.initial_state);
    detail.has_host_binding_id = @intFromBool(binding.host_binding_id != null);
    detail.host_binding_id = binding.host_binding_id orelse 0;
    if (binding.declaration) |declaration| {
        detail.declaration_id = declaration.declaration_id;
        detail.declaration_module_id = declaration.module_id;
        detail.declaration_external = @intFromBool(declaration.external);
    }
    output.* = detail;
    return .OK;
}

pub fn hirFunctionStorageDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    function_index: usize,
    out_detail: ?*Vizg_HirFunctionStorageDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirFunctionStorageDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirFunctionStorageDetail))) return .INVALID_ARGUMENT;
    const functions = owned.hir_result.?.project.functions;
    if (function_index >= functions.len) return .INVALID_ARGUMENT;
    const function = functions[function_index];
    output.* = .{ .id = idIndex(function.id), .capture_count = function.captures.len };
    return .OK;
}

pub fn hirFunctionCaptureAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    function_index: usize,
    capture_index: usize,
    out_capture: ?*Vizg_HirFunctionCapture,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_capture orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirFunctionCapture, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirFunctionCapture))) return .INVALID_ARGUMENT;
    const functions = owned.hir_result.?.project.functions;
    if (function_index >= functions.len) return .INVALID_ARGUMENT;
    const captures = functions[function_index].captures;
    if (capture_index >= captures.len) return .INVALID_ARGUMENT;
    const capture = captures[capture_index];
    output.* = .{
        .local_binding_id = idIndex(capture.local),
        .source_binding_id = switch (capture.source) {
            .binding => |id| idIndex(id),
            else => VIZG_HIR_ID_NONE,
        },
        .source_kind = @intFromEnum(std.meta.activeTag(capture.source)),
        .mode = @intFromEnum(capture.mode),
    };
    return .OK;
}

pub fn hirRegionCount(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    out_count: ?*usize,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_count orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(usize, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(usize))) return .INVALID_ARGUMENT;
    output.* = owned.hir_result.?.project.regions.len;
    return .OK;
}

pub fn hirRegionDetailAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    region_index: usize,
    out_detail: ?*Vizg_HirRegionDetail,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_detail orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirRegionDetail, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirRegionDetail))) return .INVALID_ARGUMENT;
    const regions = owned.hir_result.?.project.regions;
    if (region_index >= regions.len) return .INVALID_ARGUMENT;
    const region = regions[region_index];
    output.* = .{
        .id = idIndex(region.id),
        .function_id = idIndex(region.function),
        .parent_region_id = optionalId(region.parent),
        .handler_block_id = idIndex(region.handler),
        .continuation_block_id = optionalId(region.continuation),
        .origin_id = @intCast(idIndex(region.origin)),
        .kind = hirRegionKind(region.kind),
        .protected_block_count = region.protected_blocks.len,
        .flags = @as(u8, @intFromBool(region.parent != null)) |
            (@as(u8, @intFromBool(region.continuation != null)) << 1),
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
    };
    return .OK;
}

pub fn hirRegionProtectedBlockAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    region_index: usize,
    protected_block_index: usize,
    out_block_id: ?*u64,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirDetailOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_block_id orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(u64, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(u64))) return .INVALID_ARGUMENT;
    const regions = owned.hir_result.?.project.regions;
    if (region_index >= regions.len) return .INVALID_ARGUMENT;
    const protected_blocks = regions[region_index].protected_blocks;
    if (protected_block_index >= protected_blocks.len) return .INVALID_ARGUMENT;
    output.* = idIndex(protected_blocks[protected_block_index]);
    return .OK;
}

pub fn hirPayloadApiVersion() callconv(.c) u32 {
    return VIZG_HIR_PAYLOAD_API_VERSION;
}

fn hirPayloadOwned(result: ?*const Vizg_ProjectResult, requested_version: u32) ?*const OwnedProjectResult {
    if (requested_version != VIZG_HIR_PAYLOAD_API_VERSION) return null;
    const owned = ownedResult(result) orelse return null;
    if (owned.hir_result == null) return null;
    return owned;
}

fn hirInstructionAt(project: vizg.hir.HirProject, index: usize) ?vizg.hir.HirInstruction {
    var current: usize = 0;
    for (project.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (current == index) return instruction;
                current += 1;
            }
        }
    }
    return null;
}

fn hirTerminatorAtIndex(project: vizg.hir.HirProject, index: usize) ?vizg.hir.HirTerminator {
    var current: usize = 0;
    for (project.functions) |function| {
        for (function.blocks) |block| {
            if (current == index) return block.terminator;
            current += 1;
        }
    }
    return null;
}

fn setString0(output: anytype, value: []const u8) void {
    output.string0_ptr = if (value.len == 0) null else value.ptr;
    output.string0_len = value.len;
}

fn setString1(output: anytype, value: []const u8) void {
    output.string1_ptr = if (value.len == 0) null else value.ptr;
    output.string1_len = value.len;
}

fn setPropertyKey(output: *Vizg_HirPayload, key: vizg.hir.model.PropertyKey) void {
    output.tag1 = @intFromEnum(std.meta.activeTag(key));
    switch (key) {
        .static => |name| setString0(output, name),
        .computed => |value| output.operand3 = idIndex(value),
        .private => |declaration| {
            output.flags |= @as(u32, @intFromBool(declaration.external)) << 8;
            output.operand2 = declaration.module_id;
            output.operand3 = declaration.declaration_id;
        },
    }
}

fn setConstant(output: *Vizg_HirPayload, constant: vizg.hir.HirConstant) void {
    output.tag0 = @intFromEnum(std.meta.activeTag(constant));
    switch (constant) {
        .undefined, .null_ => {},
        .boolean => |value| output.operand0 = @intFromBool(value),
        .number => |value| output.operand0 = @bitCast(value),
        .bigint, .string => |value| setString0(output, value),
    }
}

fn operationPayload(operation: vizg.hir.HirOperation) Vizg_HirPayload {
    var output = std.mem.zeroes(Vizg_HirPayload);
    output.tag = @intFromEnum(std.meta.activeTag(operation));
    switch (operation) {
        .constant => |value| setConstant(&output, value),
        .copy => |value| output.operand0 = idIndex(value),
        .load_binding => |binding| output.operand0 = idIndex(binding),
        .initialize_binding => |value| {
            output.operand0 = idIndex(value.binding);
            output.operand1 = idIndex(value.value);
        },
        .store_binding => |value| {
            output.operand0 = idIndex(value.binding);
            output.operand1 = idIndex(value.value);
        },
        .load_this, .load_super => {},
        .load_meta => |kind| output.tag0 = @intFromEnum(kind),
        .make_binding_place => |value| {
            output.operand0 = idIndex(value.result);
            output.operand1 = idIndex(value.binding);
        },
        .make_property_place => |value| {
            output.operand0 = idIndex(value.result);
            output.operand1 = idIndex(value.base);
            setPropertyKey(&output, value.key);
        },
        .make_element_place => |value| {
            output.operand0 = idIndex(value.result);
            output.operand1 = idIndex(value.base);
            output.operand2 = idIndex(value.key);
        },
        .make_super_place => |value| {
            output.operand0 = idIndex(value.result);
            output.operand1 = idIndex(value.receiver);
            setPropertyKey(&output, value.key);
        },
        .load_place, .delete_place => |place| output.operand0 = idIndex(place),
        .store_place => |value| {
            output.operand0 = idIndex(value.place);
            output.operand1 = idIndex(value.value);
        },
        .to_boolean, .is_nullish, .typeof_value, .void_value => |value| output.operand0 = idIndex(value),
        .unary => |value| {
            output.tag0 = @intFromEnum(value.operator);
            output.tag1 = @intFromEnum(value.mode);
            output.operand0 = idIndex(value.operand);
        },
        .binary => |value| {
            output.tag0 = @intFromEnum(value.operator);
            output.tag1 = @intFromEnum(value.mode);
            output.operand0 = idIndex(value.left);
            output.operand1 = idIndex(value.right);
        },
        .add => |value| {
            output.tag0 = @intFromEnum(value.mode);
            output.operand0 = idIndex(value.left);
            output.operand1 = idIndex(value.right);
        },
        .call, .construct => |value| {
            output.operand0 = idIndex(value.callee);
            output.item_count = value.arguments.len;
        },
        .call_method, .call_super_method => |value| {
            output.flags = @intFromBool(value.callee != null);
            output.operand0 = optionalId(value.callee);
            output.operand1 = idIndex(value.receiver);
            setPropertyKey(&output, value.key);
            output.item_count = value.arguments.len;
        },
        .call_super_constructor => |arguments| output.item_count = arguments.len,
        .tagged_template_call => |value| {
            output.flags = @intFromBool(value.receiver != null);
            output.operand0 = idIndex(value.tag);
            output.operand1 = optionalId(value.receiver);
            output.operand2 = idIndex(value.template_site);
            output.item_count = value.substitutions.len;
        },
        .dynamic_import => |value| {
            output.flags = @intFromBool(value.options != null);
            output.operand0 = idIndex(value.source);
            output.operand1 = optionalId(value.options);
            output.item_count = value.attributes.len;
        },
        .create_object, .create_array => {},
        .create_closure => |function| output.operand0 = idIndex(function),
        .create_class => |value| {
            output.flags = @intFromBool(value.base != null);
            output.operand0 = idIndex(value.entity);
            output.operand1 = optionalId(value.base);
        },
        .create_enum_object => |entity| output.operand0 = idIndex(entity),
        .create_regexp => |value| {
            output.operand0 = idIndex(value.source_site);
            setString0(&output, value.pattern);
            setString1(&output, value.flags);
        },
        .create_template_site => |value| {
            output.operand0 = idIndex(value.source_site);
            output.item_count = value.raw.len;
        },
        .define_property => |value| {
            output.operand0 = idIndex(value.object);
            output.operand1 = idIndex(value.value);
            setPropertyKey(&output, value.key);
        },
        .define_method => |value| {
            output.tag0 = @intFromEnum(value.kind);
            output.flags = @intFromBool(value.is_static);
            output.operand0 = idIndex(value.object);
            output.operand1 = idIndex(value.function);
            setPropertyKey(&output, value.key);
        },
        .copy_object_properties => |value| {
            output.operand0 = idIndex(value.target);
            output.operand1 = idIndex(value.source);
        },
        .array_append => |value| {
            output.operand0 = idIndex(value.array);
            output.operand1 = idIndex(value.value);
        },
        .array_append_hole => |array| output.operand0 = idIndex(array),
        .array_append_iterable => |value| {
            output.operand0 = idIndex(value.array);
            output.operand1 = idIndex(value.iterable);
        },
        .build_string => |parts| output.item_count = parts.len,
        .to_string,
        .get_iterator,
        .get_async_iterator,
        .iterator_next,
        .iterator_done,
        .iterator_value,
        .iterator_close,
        .enumerate_properties,
        .enumerator_next,
        .enumerator_done,
        .enumerator_value,
        .await_,
        .yield_,
        .yield_delegate,
        => |value| output.operand0 = idIndex(value),
        .collect_rest_arguments, .read_argument => |argument_index| output.operand0 = argument_index,
        .create_arguments_object, .debugger_trap => {},
    }
    return output;
}

fn callArgumentItem(argument: vizg.hir.model.CallArgument) Vizg_HirPayloadItem {
    var output = std.mem.zeroes(Vizg_HirPayloadItem);
    output.tag = @intFromEnum(std.meta.activeTag(argument));
    output.operand0 = idIndex(argument.operand());
    return output;
}

fn operationPayloadItem(operation: vizg.hir.HirOperation, index: usize) ?Vizg_HirPayloadItem {
    var output = std.mem.zeroes(Vizg_HirPayloadItem);
    switch (operation) {
        .call, .construct => |value| {
            if (index >= value.arguments.len) return null;
            return callArgumentItem(value.arguments[index]);
        },
        .call_method, .call_super_method => |value| {
            if (index >= value.arguments.len) return null;
            return callArgumentItem(value.arguments[index]);
        },
        .call_super_constructor => |arguments| {
            if (index >= arguments.len) return null;
            return callArgumentItem(arguments[index]);
        },
        .tagged_template_call => |value| {
            if (index >= value.substitutions.len) return null;
            output.operand0 = idIndex(value.substitutions[index]);
        },
        .dynamic_import => |value| {
            if (index >= value.attributes.len) return null;
            setString0(&output, value.attributes[index].key);
            setString1(&output, value.attributes[index].value);
        },
        .create_template_site => |value| {
            if (index >= value.raw.len or index >= value.cooked.len) return null;
            output.flags = @intFromBool(value.cooked[index] != null);
            if (value.cooked[index]) |cooked| setString0(&output, cooked);
            setString1(&output, value.raw[index]);
        },
        .build_string => |parts| {
            if (index >= parts.len) return null;
            output.tag = @intFromEnum(std.meta.activeTag(parts[index]));
            switch (parts[index]) {
                .text => |value| setString0(&output, value),
                .value => |value| output.operand0 = idIndex(value),
            }
        },
        else => return null,
    }
    return output;
}

fn terminatorPayload(terminator: vizg.hir.HirTerminator) Vizg_HirPayload {
    var output = std.mem.zeroes(Vizg_HirPayload);
    output.tag = @intFromEnum(std.meta.activeTag(terminator));
    switch (terminator) {
        .jump => |value| {
            output.operand0 = idIndex(value.target);
            output.item_count = value.arguments.len;
        },
        .branch => |value| {
            output.operand0 = idIndex(value.condition);
            output.operand1 = idIndex(value.true_target);
            output.operand2 = idIndex(value.false_target);
        },
        .return_ => |value| {
            output.flags = @intFromBool(value != null);
            output.operand0 = optionalId(value);
        },
        .throw => |value| output.operand0 = idIndex(value),
        .unreachable_, .resume_completion => {},
        .leave_region => |value| {
            output.operand0 = idIndex(value.region);
            output.operand1 = idIndex(value.cleanup);
            output.tag0 = @intFromEnum(std.meta.activeTag(value.completion));
            switch (value.completion) {
                .normal => |target| {
                    output.flags = @intFromBool(target != null);
                    output.operand2 = optionalId(target);
                },
                .return_ => |result| {
                    output.flags = @intFromBool(result != null);
                    output.operand2 = optionalId(result);
                },
                .throw => |result| output.operand2 = idIndex(result),
                .break_, .continue_ => |target| output.operand2 = idIndex(target),
            }
        },
    }
    return output;
}

fn terminatorPayloadItem(terminator: vizg.hir.HirTerminator, index: usize) ?Vizg_HirPayloadItem {
    var output = std.mem.zeroes(Vizg_HirPayloadItem);
    switch (terminator) {
        .jump => |value| {
            if (index >= value.arguments.len) return null;
            output.operand0 = idIndex(value.arguments[index]);
        },
        else => return null,
    }
    return output;
}

pub fn hirOperationAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    index: usize,
    out_payload: ?*Vizg_HirPayload,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirPayloadOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_payload orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirPayload, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirPayload))) return .INVALID_ARGUMENT;
    const instruction = hirInstructionAt(owned.hir_result.?.project, index) orelse return .INVALID_ARGUMENT;
    output.* = operationPayload(instruction.operation);
    return .OK;
}

pub fn hirOperationItemAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    operation_index: usize,
    item_index: usize,
    out_item: ?*Vizg_HirPayloadItem,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirPayloadOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_item orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirPayloadItem, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirPayloadItem))) return .INVALID_ARGUMENT;
    const instruction = hirInstructionAt(owned.hir_result.?.project, operation_index) orelse return .INVALID_ARGUMENT;
    output.* = operationPayloadItem(instruction.operation, item_index) orelse return .INVALID_ARGUMENT;
    return .OK;
}

pub fn hirTerminatorAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    index: usize,
    out_payload: ?*Vizg_HirPayload,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirPayloadOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_payload orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirPayload, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirPayload))) return .INVALID_ARGUMENT;
    const terminator = hirTerminatorAtIndex(owned.hir_result.?.project, index) orelse return .INVALID_ARGUMENT;
    output.* = terminatorPayload(terminator);
    return .OK;
}

pub fn hirTerminatorItemAt(
    result: ?*const Vizg_ProjectResult,
    requested_version: u32,
    terminator_index: usize,
    item_index: usize,
    out_item: ?*Vizg_HirPayloadItem,
) callconv(.c) Vizg_ProjectStatus {
    const owned = hirPayloadOwned(result, requested_version) orelse return .INVALID_STATE;
    const output = out_item orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_HirPayloadItem, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_HirPayloadItem))) return .INVALID_ARGUMENT;
    const terminator = hirTerminatorAtIndex(owned.hir_result.?.project, terminator_index) orelse return .INVALID_ARGUMENT;
    output.* = terminatorPayloadItem(terminator, item_index) orelse return .INVALID_ARGUMENT;
    return .OK;
}

pub fn projectAnalyzeSource(
    config: ?*const Vizg_ProjectConfig,
    input: ?*const Vizg_ProjectSource,
    out_result: [*c]?*Vizg_ProjectResult,
) callconv(.c) Vizg_ProjectStatus {
    if (!validAlignedMutableHostArray(?*Vizg_ProjectResult, out_result, 1)) return .INVALID_ARGUMENT;
    const config_args = config orelse return .INVALID_ARGUMENT;
    const input_args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectConfig, config_args) or
        !validAlignedHostObject(Vizg_ProjectSource, input_args)) return .INVALID_ARGUMENT;
    out_result[0] = null;
    var project: ?*Vizg_Project = null;
    const create_status = projectCreate(config_args, &project);
    if (create_status != .OK) return create_status;
    const handle = project orelse return .INTERNAL_ERROR;
    const add_status = projectAddSource(handle, input_args);
    if (add_status != .OK) {
        projectDestroy(handle);
        return add_status;
    }
    var step_output = std.mem.zeroes(Vizg_ProjectStep);
    const step_status = projectStep(handle, &step_output);
    if (step_status != .OK) {
        projectDestroy(handle);
        return step_status;
    }
    if (step_output.kind != 0) {
        projectDestroy(handle);
        return .INVALID_STATE;
    }
    const finish_status = projectFinish(handle, out_result);
    if (finish_status != .OK) {
        projectDestroy(handle);
    } else {
        const result: *OwnedProjectResult = @ptrCast(@alignCast(out_result[0].?));
        result.owns_owner = true;
    }
    return finish_status;
}

comptime {
    @export(&abiVersion, .{ .name = "vizg_abi_version" });
    @export(&projectWorkspaceAlignment, .{ .name = "vizg_project_workspace_alignment" });
    @export(&projectWorkspaceOverhead, .{ .name = "vizg_project_workspace_overhead" });
    @export(&projectCreate, .{ .name = "vizg_project_create" });
    @export(&projectDestroy, .{ .name = "vizg_project_destroy" });
    @export(&projectLimitKind, .{ .name = "vizg_project_limit_kind" });
    @export(&projectAddSource, .{ .name = "vizg_project_add_source" });
    @export(&projectAddGlobalRoot, .{ .name = "vizg_project_add_global_root" });
    @export(&projectRegisterAmbientGlobals, .{ .name = "vizg_project_register_ambient_globals" });
    @export(&projectRegisterAmbientGlobalsV2, .{ .name = "vizg_project_register_ambient_globals_v2" });
    @export(&projectRegisterSourceHostBindings, .{ .name = "vizg_project_register_source_host_bindings" });
    @export(&projectStep, .{ .name = "vizg_project_step" });
    @export(&projectRespondSource, .{ .name = "vizg_project_respond_source" });
    @export(&projectRespondExternal, .{ .name = "vizg_project_respond_external" });
    @export(&externalModuleApiVersion, .{ .name = "vizg_external_module_api_version" });
    @export(&projectRespondExternalV2, .{ .name = "vizg_project_respond_external_v2" });
    @export(&projectRespondFailure, .{ .name = "vizg_project_respond_failure" });
    @export(&projectFinish, .{ .name = "vizg_project_finish" });
    @export(&projectResultSummary, .{ .name = "vizg_project_result_summary" });
    @export(&projectResultModule, .{ .name = "vizg_project_result_module" });
    @export(&projectResultDiagnostic, .{ .name = "vizg_project_result_diagnostic" });
    @export(&projectResultEdge, .{ .name = "vizg_project_result_edge" });
    @export(&projectResultImport, .{ .name = "vizg_project_result_import" });
    @export(&projectResultExport, .{ .name = "vizg_project_result_export" });
    @export(&projectResultDestroy, .{ .name = "vizg_project_result_destroy" });
    @export(&projectAnalyzeSource, .{ .name = "vizg_project_analyze_source" });
    @export(&hirApiVersion, .{ .name = "vizg_hir_api_version" });
    @export(&hirSummary, .{ .name = "vizg_hir_summary" });
    @export(&hirRecordAt, .{ .name = "vizg_hir_record_at" });
    @export(&hirDetailApiVersion, .{ .name = "vizg_hir_detail_api_version" });
    @export(&hirTypeDetailAt, .{ .name = "vizg_hir_type_detail_at" });
    @export(&hirFunctionSignature, .{ .name = "vizg_hir_function_signature" });
    @export(&hirFunctionCompletionType, .{ .name = "vizg_hir_function_completion_type" });
    @export(&hirSignatureParameterAt, .{ .name = "vizg_hir_signature_parameter_at" });
    @export(&hirFunctionDetailAt, .{ .name = "vizg_hir_function_detail_at" });
    @export(&hirFunctionParameterAt, .{ .name = "vizg_hir_function_parameter_at" });
    @export(&hirBlockDetailAt, .{ .name = "vizg_hir_block_detail_at" });
    @export(&hirBlockParameterAt, .{ .name = "vizg_hir_block_parameter_at" });
    @export(&hirOriginDetailAt, .{ .name = "vizg_hir_origin_detail_at" });
    @export(&hirModuleDetailAt, .{ .name = "vizg_hir_module_detail_at" });
    @export(&hirModuleDependencyAt, .{ .name = "vizg_hir_module_dependency_at" });
    @export(&hirModuleImportAt, .{ .name = "vizg_hir_module_import_at" });
    @export(&hirModuleExportAt, .{ .name = "vizg_hir_module_export_at" });
    @export(&hirBindingDetailAt, .{ .name = "vizg_hir_binding_detail_at" });
    @export(&hirFunctionStorageDetailAt, .{ .name = "vizg_hir_function_storage_detail_at" });
    @export(&hirFunctionCaptureAt, .{ .name = "vizg_hir_function_capture_at" });
    @export(&hirRegionCount, .{ .name = "vizg_hir_region_count" });
    @export(&hirRegionDetailAt, .{ .name = "vizg_hir_region_detail_at" });
    @export(&hirRegionProtectedBlockAt, .{ .name = "vizg_hir_region_protected_block_at" });
    @export(&hirPayloadApiVersion, .{ .name = "vizg_hir_payload_api_version" });
    @export(&hirOperationAt, .{ .name = "vizg_hir_operation_at" });
    @export(&hirOperationItemAt, .{ .name = "vizg_hir_operation_item_at" });
    @export(&hirTerminatorAt, .{ .name = "vizg_hir_terminator_at" });
    @export(&hirTerminatorItemAt, .{ .name = "vizg_hir_terminator_item_at" });
}

test "HIR origin flags distinguish absent type from TypeId zero in v2" {
    try std.testing.expectEqual(@as(u8, 0), hirOriginFlags(1, null));
    try std.testing.expectEqual(@as(u8, 0), hirOriginFlags(1, 0));
    try std.testing.expectEqual(@as(u8, 0), hirOriginFlags(2, null));
    try std.testing.expectEqual(@as(u8, 1), hirOriginFlags(2, 0));
    try std.testing.expectEqual(@as(u8, 1), hirOriginFlags(2, 42));
}

test "public diagnostic ABI mappings are stable" {
    try std.testing.expectEqual(@as(u8, 0), diagnosticSeverity(.@"error"));
    try std.testing.expectEqual(@as(u8, 6), diagnosticPhase(.module_host));
    try std.testing.expectEqual(@as(u32, 1001), diagnosticCode(.invalid_character));
    try std.testing.expectEqual(@as(u32, 2003), diagnosticCode(.parse_recursion_limit_reached));
    try std.testing.expectEqual(@as(u32, 5001), diagnosticCode(.module_not_found));
    try std.testing.expectEqual(@as(u32, 5004), diagnosticCode(.module_access_denied));
    try std.testing.expectEqual(@as(u32, 5005), diagnosticCode(.module_host_failed));
    try std.testing.expectEqual(@as(u32, 6009), diagnosticCode(.invalid_argument_type));
    try std.testing.expectEqual(@as(u32, 8001), diagnosticCode(.global_ambient_collision));
}

test "public limit ABI values and exact error mappings are stable" {
    try std.testing.expectEqual(@as(usize, std.math.maxInt(u32)), VIZG_MAX_SOURCE_LENGTH);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Vizg_LimitKind.NONE));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Vizg_LimitKind.SOURCE_BYTES));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Vizg_LimitKind.TOTAL_SOURCE_BYTES));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Vizg_LimitKind.MODULES));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Vizg_LimitKind.REQUESTS));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Vizg_LimitKind.EDGES));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(Vizg_LimitKind.GRAPH_DEPTH));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(Vizg_LimitKind.DIAGNOSTICS));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(Vizg_LimitKind.SEMANTIC_GROWTH));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(Vizg_LimitKind.PARSE_DEPTH));

    const mappings = [_]struct { err: anyerror, kind: Vizg_LimitKind }{
        .{ .err = error.SourceLimitExceeded, .kind = .SOURCE_BYTES },
        .{ .err = error.TotalSourceLimitExceeded, .kind = .TOTAL_SOURCE_BYTES },
        .{ .err = error.ModuleLimitExceeded, .kind = .MODULES },
        .{ .err = error.RequestLimitExceeded, .kind = .REQUESTS },
        .{ .err = error.RequestIdExhausted, .kind = .REQUESTS },
        .{ .err = error.EdgeLimitExceeded, .kind = .EDGES },
        .{ .err = error.GraphDepthLimitExceeded, .kind = .GRAPH_DEPTH },
        .{ .err = error.DiagnosticLimitExceeded, .kind = .DIAGNOSTICS },
        .{ .err = error.SemanticTypeLimitExceeded, .kind = .SEMANTIC_GROWTH },
        .{ .err = error.TypeComplexityLimit, .kind = .SEMANTIC_GROWTH },
        .{ .err = error.ParseRecursionLimitReached, .kind = .PARSE_DEPTH },
    };
    for (mappings) |mapping| try std.testing.expectEqual(mapping.kind, limitKindFromError(mapping.err).?);
    try std.testing.expect(limitKindFromError(error.OutOfMemory) == null);
}

test "external response conversion uses reclaimable workspace scratch" {
    const workspace_bytes = 2 * 1024 * 1024;
    const c_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(c_words);
    const direct_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(direct_words);

    const limits = .{
        .max_source_bytes = 1024 * 1024,
        .max_total_source_bytes = 1024 * 1024,
        .max_modules = 32,
        .max_requests = 128,
        .max_edges = 128,
        .max_diagnostics = 1024,
        .max_graph_depth = 32,
        .max_semantic_types = 16 * 1024,
    };
    var c_config = Vizg_ProjectConfig{
        .workspace_ptr = @ptrCast(c_words.ptr),
        .workspace_len = workspace_bytes,
        .max_source_bytes = limits.max_source_bytes,
        .max_total_source_bytes = limits.max_total_source_bytes,
        .max_modules = limits.max_modules,
        .max_requests = limits.max_requests,
        .max_edges = limits.max_edges,
        .max_diagnostics = limits.max_diagnostics,
        .max_graph_depth = limits.max_graph_depth,
        .max_semantic_types = limits.max_semantic_types,
    };
    var direct_config = c_config;
    direct_config.workspace_ptr = @ptrCast(direct_words.ptr);
    var c_handle: ?*Vizg_Project = null;
    var direct_handle: ?*Vizg_Project = null;
    try std.testing.expectEqual(.OK, projectCreate(&c_config, &c_handle));
    defer projectDestroy(c_handle);
    try std.testing.expectEqual(.OK, projectCreate(&direct_config, &direct_handle));
    defer projectDestroy(direct_handle);

    const logical_name = "root.ts";
    const source_text = "import { log } from 'runtime';";
    var source = Vizg_ProjectSource{
        .module_id = 1,
        .logical_name_ptr = logical_name.ptr,
        .logical_name_len = logical_name.len,
        .source_ptr = source_text.ptr,
        .source_len = source_text.len,
        .kind = 1,
        .is_root = 1,
        .reserved = .{ 0, 0, 0 },
    };
    try std.testing.expectEqual(.OK, projectAddSource(c_handle, &source));
    try std.testing.expectEqual(.OK, projectAddSource(direct_handle, &source));
    var c_step = std.mem.zeroes(Vizg_ProjectStep);
    var direct_step = std.mem.zeroes(Vizg_ProjectStep);
    try std.testing.expectEqual(.OK, projectStep(c_handle, &c_step));
    try std.testing.expectEqual(.OK, projectStep(direct_handle, &direct_step));
    try std.testing.expectEqual(c_step.request_id, direct_step.request_id);

    const export_name = "log";
    var c_export = Vizg_ExternalExport{
        .name_ptr = export_name.ptr,
        .name_len = export_name.len,
        .kind = 0,
        .namespace_flags = VIZG_EXTERNAL_NAMESPACE_VALUE,
        .has_type_metadata = 0,
        .reserved = .{ 0, 0 },
        .type_metadata = 0,
    };
    var c_external = Vizg_ExternalModule{
        .external_module_id = 80,
        .logical_name_ptr = "runtime".ptr,
        .logical_name_len = "runtime".len,
        .exports_ptr = &c_export,
        .export_count = 1,
    };
    try std.testing.expectEqual(.OK, projectRespondExternal(c_handle, c_step.request_id, &c_external));

    const direct_exports = [_]vizg.ExternalExportDescriptor{.{ .name = export_name }};
    const direct_owned = ownedProject(direct_handle).?;
    try direct_owned.project.respondExternalModule(.init(direct_step.request_id), .{
        .id = .init(80),
        .logical_name = "runtime",
        .exports = &direct_exports,
    });
    try std.testing.expectEqual(direct_owned.fba.end_index, ownedProject(c_handle).?.fba.end_index);
}

fn allocationFailureAbiSnapshot(allocator: std.mem.Allocator) !void {
    const workspace_capacity = projectWorkspaceOverhead() + 4 * 1024 * 1024;
    const word_count = (workspace_capacity + @sizeOf(u64) - 1) / @sizeOf(u64);
    const storage = try allocator.alloc(u64, word_count);
    const storage_bytes = std.mem.sliceAsBytes(storage);
    const owned: *OwnedProject = @ptrCast(@alignCast(storage.ptr));
    owned.* = .{
        .fba = .init(storage_bytes[projectWorkspaceOverhead()..]),
        .project = undefined,
        .workspace_len = storage_bytes.len,
    };
    owned.project = .init(owned.fba.allocator());
    defer {
        owned.deinit();
        allocator.free(storage);
    }

    try owned.project.addRoot(.{
        .id = .init(1),
        .logical_name = "fault:abi-snapshot",
        .bytes = "export const value: number = 1;",
    });
    try std.testing.expectEqual(vizg.ProjectStep.complete, try owned.project.step());

    var result: ?*Vizg_ProjectResult = @ptrFromInt(1);
    const status = projectFinish(@ptrCast(owned), &result);
    if (status == .OUT_OF_MEMORY) {
        try std.testing.expect(result == null);
        try std.testing.expect(!owned.result_ready);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(Vizg_ProjectStatus.OK, status);
    try std.testing.expect(result != null);
    try std.testing.expect(owned.result_ready);
}

test "ABI snapshot preparation publishes no result at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureAbiSnapshot, .{});
}
