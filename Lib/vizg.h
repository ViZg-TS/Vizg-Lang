#ifndef VIZG_H
#define VIZG_H

/* ViZG official C ABI v1. Link against libvizg.a. */

#include <stddef.h>
#include <stdint.h>

#define VIZG_ABI_VERSION 1u
#define VIZG_HIR_API_VERSION 2u
#define VIZG_HIR_PAYLOAD_API_VERSION 1u
#define VIZG_HIR_DETAIL_API_VERSION 2u
#define VIZG_EXTERNAL_MODULE_API_VERSION 2u
#define VIZG_HIR_ID_NONE UINT64_MAX
#define VIZG_HIR_U32_NONE UINT32_MAX
#define VIZG_MAX_SOURCE_LENGTH UINT32_MAX

#define VIZG_HIR_TYPE_PRIMITIVE 0u
#define VIZG_HIR_TYPE_FUNCTION 1u
#define VIZG_HIR_TYPE_PROMISE 2u
#define VIZG_HIR_TYPE_GENERATOR 3u
#define VIZG_HIR_TYPE_LITERAL 4u
#define VIZG_HIR_TYPE_UNION 5u
#define VIZG_HIR_TYPE_INTERSECTION 6u
#define VIZG_HIR_TYPE_ARRAY 7u
#define VIZG_HIR_TYPE_TUPLE 8u
#define VIZG_HIR_TYPE_OBJECT 9u
#define VIZG_HIR_TYPE_CLASS 10u
#define VIZG_HIR_TYPE_CLASS_CONSTRUCTOR 11u
#define VIZG_HIR_TYPE_INTERFACE 12u
#define VIZG_HIR_TYPE_ENUM 13u
#define VIZG_HIR_TYPE_PARAMETER 14u
#define VIZG_HIR_TYPE_APPLIED_GENERIC 15u
#define VIZG_HIR_BUILTIN_NONE UINT32_MAX
#define VIZG_HIR_BUILTIN_ANY 0u
#define VIZG_HIR_BUILTIN_UNKNOWN 1u
#define VIZG_HIR_BUILTIN_NEVER 2u
#define VIZG_HIR_BUILTIN_VOID 3u
#define VIZG_HIR_BUILTIN_UNDEFINED 4u
#define VIZG_HIR_BUILTIN_NULL 5u
#define VIZG_HIR_BUILTIN_BOOLEAN 6u
#define VIZG_HIR_BUILTIN_NUMBER 7u
#define VIZG_HIR_BUILTIN_BIGINT 8u
#define VIZG_HIR_BUILTIN_STRING 9u
#define VIZG_HIR_BUILTIN_SYMBOL 10u
#define VIZG_HIR_BUILTIN_OBJECT 11u

#define VIZG_HIR_FUNCTION_FLAG_LEXICAL_THIS (1u << 0)
#define VIZG_HIR_FUNCTION_FLAG_DYNAMIC_THIS (1u << 1)
#define VIZG_HIR_FUNCTION_FLAG_CONSTRUCTOR (1u << 2)
#define VIZG_HIR_FUNCTION_FLAG_GETTER (1u << 3)
#define VIZG_HIR_FUNCTION_FLAG_SETTER (1u << 4)
#define VIZG_HIR_FUNCTION_FLAG_ASYNC (1u << 5)
#define VIZG_HIR_FUNCTION_FLAG_GENERATOR (1u << 6)
#define VIZG_HIR_FUNCTION_FLAG_ASYNC_GENERATOR (1u << 7)
#define VIZG_HIR_FUNCTION_FLAG_USES_SUPER (1u << 8)
#define VIZG_HIR_FUNCTION_FLAG_USES_NEW_TARGET (1u << 9)
#define VIZG_HIR_SIGNATURE_ASYNC (1u << 0)
#define VIZG_HIR_SIGNATURE_GENERATOR (1u << 1)
#define VIZG_HIR_SIGNATURE_CONSTRUCTOR (1u << 2)
#define VIZG_HIR_PARAMETER_OPTIONAL (1u << 0)
#define VIZG_HIR_PARAMETER_HAS_DEFAULT (1u << 1)
#define VIZG_HIR_PARAMETER_REST (1u << 2)
#define VIZG_HIR_PARAMETER_PROPERTY (1u << 3)
#define VIZG_HIR_ORIGIN_HAS_SYMBOL (1u << 0)
#define VIZG_HIR_ORIGIN_HAS_TYPE (1u << 1)
#define VIZG_HIR_ORIGIN_HAS_PARENT (1u << 2)
#define VIZG_HIR_ORIGIN_HAS_SYNTHETIC_REASON (1u << 3)
#define VIZG_HIR_BINDING_KIND_VAR 0u
#define VIZG_HIR_BINDING_KIND_LET 1u
#define VIZG_HIR_BINDING_KIND_CONST 2u
#define VIZG_HIR_BINDING_KIND_PARAMETER 3u
#define VIZG_HIR_BINDING_KIND_IMPORT 4u
#define VIZG_HIR_BINDING_KIND_CATCH 5u
#define VIZG_HIR_BINDING_KIND_FUNCTION 6u
#define VIZG_HIR_BINDING_KIND_CLASS 7u
#define VIZG_HIR_BINDING_KIND_ENUM 8u
#define VIZG_HIR_BINDING_KIND_SYNTHETIC 9u
#define VIZG_HIR_BINDING_KIND_TEMPORARY 10u
#define VIZG_HIR_MODULE_REFERENCE_SOURCE 0u
#define VIZG_HIR_MODULE_REFERENCE_EXTERNAL 1u
#define VIZG_HIR_SEMANTIC_NAMESPACE_VALUE 0u
#define VIZG_HIR_SEMANTIC_NAMESPACE_TYPE 1u
#define VIZG_HIR_SEMANTIC_NAMESPACE_NAMESPACE 2u
#define VIZG_HIR_BINDING_STATE_HOISTED_UNDEFINED 0u
#define VIZG_HIR_BINDING_STATE_HOISTED_FUNCTION 1u
#define VIZG_HIR_BINDING_STATE_TEMPORAL_DEAD_ZONE 2u
#define VIZG_HIR_BINDING_STATE_INITIALIZED 3u
#define VIZG_HIR_BINDING_STATE_LIVE_IMPORT 4u
#define VIZG_HIR_CAPTURE_SOURCE_BINDING 0u
#define VIZG_HIR_CAPTURE_SOURCE_THIS 1u
#define VIZG_HIR_CAPTURE_SOURCE_ARGUMENTS 2u
#define VIZG_HIR_CAPTURE_SOURCE_SUPER 3u
#define VIZG_HIR_CAPTURE_SOURCE_NEW_TARGET 4u
#define VIZG_HIR_CAPTURE_MODE_LIVE_BINDING 0u
#define VIZG_HIR_CAPTURE_MODE_LEXICAL_VALUE 1u
#define VIZG_HIR_REGION_CATCH 0u
#define VIZG_HIR_REGION_FINALLY 1u
#define VIZG_HIR_REGION_ITERATOR_CLOSE 2u
#define VIZG_HIR_REGION_HAS_PARENT (1u << 0)
#define VIZG_HIR_REGION_HAS_CONTINUATION (1u << 1)

#define VIZG_PROJECT_DEFAULT_WORKSPACE_BYTES (8u * 1024u * 1024u)
#define VIZG_PROJECT_DEFAULT_MAX_SOURCE_BYTES (1u * 1024u * 1024u)
#define VIZG_PROJECT_DEFAULT_MAX_TOTAL_SOURCE_BYTES (16u * 1024u * 1024u)
#define VIZG_PROJECT_DEFAULT_MAX_MODULES 256u
#define VIZG_PROJECT_DEFAULT_MAX_REQUESTS 1024u
#define VIZG_PROJECT_DEFAULT_MAX_EDGES 1024u
#define VIZG_PROJECT_DEFAULT_MAX_DIAGNOSTICS 4096u
#define VIZG_PROJECT_DEFAULT_MAX_GRAPH_DEPTH 128u
#define VIZG_PROJECT_DEFAULT_MAX_SEMANTIC_TYPES 65536u

typedef struct Vizg_Project Vizg_Project;
typedef struct Vizg_ProjectResult Vizg_ProjectResult;

typedef uint32_t Vizg_ProjectStatus;
enum {
    VIZG_PROJECT_STATUS_OK = 0,
    VIZG_PROJECT_STATUS_INVALID_ARGUMENT = 1,
    VIZG_PROJECT_STATUS_OUT_OF_MEMORY = 2,
    VIZG_PROJECT_STATUS_INVALID_STATE = 3,
    VIZG_PROJECT_STATUS_LIMIT_EXCEEDED = 4,
    VIZG_PROJECT_STATUS_INTERNAL_ERROR = 5,
};

typedef uint32_t Vizg_LimitKind;
enum {
    VIZG_LIMIT_NONE = 0,
    VIZG_LIMIT_SOURCE_BYTES = 1,
    VIZG_LIMIT_TOTAL_SOURCE_BYTES = 2,
    VIZG_LIMIT_MODULES = 3,
    VIZG_LIMIT_REQUESTS = 4,
    VIZG_LIMIT_EDGES = 5,
    VIZG_LIMIT_GRAPH_DEPTH = 6,
    VIZG_LIMIT_DIAGNOSTICS = 7,
    VIZG_LIMIT_SEMANTIC_GROWTH = 8,
    VIZG_LIMIT_PARSE_DEPTH = 9,
};

typedef struct Vizg_ProjectConfig {
    void *workspace_ptr;
    size_t workspace_len;
    /* Must be no greater than VIZG_MAX_SOURCE_LENGTH. */
    size_t max_source_bytes;
    size_t max_total_source_bytes;
    size_t max_modules;
    size_t max_requests;
    size_t max_edges;
    size_t max_diagnostics;
    size_t max_graph_depth;
    size_t max_semantic_types;
} Vizg_ProjectConfig;

typedef uint32_t Vizg_ProjectSourceKind;
enum {
    VIZG_PROJECT_SOURCE_SCRIPT = 0,
    VIZG_PROJECT_SOURCE_MODULE = 1,
};

typedef uint32_t Vizg_ProjectStepKind;
enum {
    VIZG_PROJECT_STEP_COMPLETE = 0,
    VIZG_PROJECT_STEP_REQUEST = 1,
};

typedef uint32_t Vizg_ProjectRequestOperation;
enum {
    VIZG_PROJECT_REQUEST_STATIC_IMPORT = 0,
    VIZG_PROJECT_REQUEST_RE_EXPORT = 1,
    VIZG_PROJECT_REQUEST_DYNAMIC_IMPORT = 2,
};

typedef uint32_t Vizg_ProjectFailureKind;
enum {
    VIZG_PROJECT_FAILURE_NOT_FOUND = 0,
    VIZG_PROJECT_FAILURE_DENIED = 1,
    VIZG_PROJECT_FAILURE_FAILED = 2,
};

typedef uint32_t Vizg_ExternalExportKind;
enum {
    VIZG_EXTERNAL_EXPORT_NAMED = 0,
    VIZG_EXTERNAL_EXPORT_DEFAULT = 1,
    VIZG_EXTERNAL_EXPORT_NAMESPACE = 2,
};

typedef uint8_t Vizg_ExternalNamespaceFlags;
enum {
    /* Exactly VALUE, TYPE, or BOTH is required for every external export. */
    VIZG_EXTERNAL_NAMESPACE_VALUE = 1u,
    VIZG_EXTERNAL_NAMESPACE_TYPE = 2u,
    VIZG_EXTERNAL_NAMESPACE_BOTH = 3u,
};

typedef uint32_t Vizg_ExternalDeclarationKind;
enum {
    VIZG_EXTERNAL_DECLARATION_FUNCTION = 0,
    VIZG_EXTERNAL_DECLARATION_GLOBAL = 1,
    VIZG_EXTERNAL_DECLARATION_CONSTANT = 2,
    VIZG_EXTERNAL_DECLARATION_TYPE = 3,
};

typedef uint16_t Vizg_ExternalEffectFlags;
enum {
    VIZG_EXTERNAL_EFFECT_READS_MEMORY = 1u << 0,
    VIZG_EXTERNAL_EFFECT_WRITES_MEMORY = 1u << 1,
    VIZG_EXTERNAL_EFFECT_THROWS = 1u << 2,
    VIZG_EXTERNAL_EFFECT_ALLOCATES = 1u << 3,
    VIZG_EXTERNAL_EFFECT_IO = 1u << 4,
    VIZG_EXTERNAL_EFFECT_ASYNC = 1u << 5,
    VIZG_EXTERNAL_EFFECT_UNKNOWN = 1u << 6,
};


typedef uint32_t Vizg_ProjectModuleState;
enum {
    VIZG_PROJECT_MODULE_UNSEEN = 0,
    VIZG_PROJECT_MODULE_REQUESTED = 1,
    VIZG_PROJECT_MODULE_SUPPLIED = 2,
    VIZG_PROJECT_MODULE_PARSING = 3,
    VIZG_PROJECT_MODULE_ANALYZED = 4,
    VIZG_PROJECT_MODULE_EXTERNAL = 5,
    VIZG_PROJECT_MODULE_FAILED = 6,
    VIZG_PROJECT_MODULE_COMPLETE = 7,
};

typedef uint32_t Vizg_ProjectEdgeState;
enum {
    VIZG_PROJECT_EDGE_UNRESOLVED = 0,
    VIZG_PROJECT_EDGE_RESOLVED = 1,
    VIZG_PROJECT_EDGE_EXTERNAL = 2,
    VIZG_PROJECT_EDGE_NOT_FOUND = 3,
    VIZG_PROJECT_EDGE_DENIED = 4,
    VIZG_PROJECT_EDGE_FAILED = 5,
};

typedef uint32_t Vizg_ProjectLinkState;
enum {
    VIZG_PROJECT_LINK_RESOLVED = 0,
    VIZG_PROJECT_LINK_NAMESPACE = 1,
    VIZG_PROJECT_LINK_EXTERNAL = 2,
    VIZG_PROJECT_LINK_UNRESOLVED = 3,
    VIZG_PROJECT_LINK_CYCLIC_PARTIAL = 4,
};

typedef uint8_t Vizg_DiagnosticSeverity;
enum {
    VIZG_DIAGNOSTIC_ERROR = 0,
    VIZG_DIAGNOSTIC_WARNING = 1,
    VIZG_DIAGNOSTIC_INFO = 2,
    VIZG_DIAGNOSTIC_HINT = 3,
};

typedef uint8_t Vizg_DiagnosticPhase;
enum {
    VIZG_DIAGNOSTIC_PHASE_SCANNER = 0,
    VIZG_DIAGNOSTIC_PHASE_PARSER = 1,
    VIZG_DIAGNOSTIC_PHASE_BINDER = 2,
    VIZG_DIAGNOSTIC_PHASE_RESOLVER = 3,
    VIZG_DIAGNOSTIC_PHASE_TYPES = 4,
    VIZG_DIAGNOSTIC_PHASE_CHECKER = 5,
    VIZG_DIAGNOSTIC_PHASE_MODULE_HOST = 6,
    VIZG_DIAGNOSTIC_PHASE_PROJECT = 7,
};

typedef uint32_t Vizg_DiagnosticCode;
enum {
    VIZG_DIAGNOSTIC_INVALID_CHARACTER = 1001,
    VIZG_DIAGNOSTIC_UNTERMINATED_STRING = 1002,
    VIZG_DIAGNOSTIC_UNTERMINATED_BLOCK_COMMENT = 1003,
    VIZG_DIAGNOSTIC_INVALID_NUMBER = 1004,
    VIZG_DIAGNOSTIC_INVALID_ESCAPE_SEQUENCE = 1005,
    VIZG_DIAGNOSTIC_UNTERMINATED_REGEXP = 1006,
    VIZG_DIAGNOSTIC_INVALID_REGEXP = 1007,
    VIZG_DIAGNOSTIC_INVALID_UTF8 = 1008,
    VIZG_DIAGNOSTIC_UNEXPECTED_TOKEN = 2001,
    VIZG_DIAGNOSTIC_EXPECTED_TOKEN = 2002,
    VIZG_DIAGNOSTIC_PARSE_RECURSION_LIMIT_REACHED = 2003,
    VIZG_DIAGNOSTIC_UNSUPPORTED_SYNTAX = 2004,
    VIZG_DIAGNOSTIC_UNSUPPORTED_TS_SYNTAX = 2005,
    VIZG_DIAGNOSTIC_UNSUPPORTED_JSX = 2006,
    VIZG_DIAGNOSTIC_DUPLICATE_DECLARATION = 3001,
    VIZG_DIAGNOSTIC_DUPLICATE_EXPORT = 3002,
    VIZG_DIAGNOSTIC_CANNOT_FIND_NAME = 4001,
    VIZG_DIAGNOSTIC_MODULE_NOT_FOUND = 5001,
    VIZG_DIAGNOSTIC_MISSING_EXPORT = 5002,
    VIZG_DIAGNOSTIC_CIRCULAR_IMPORT = 5003,
    VIZG_DIAGNOSTIC_MODULE_ACCESS_DENIED = 5004,
    VIZG_DIAGNOSTIC_MODULE_HOST_FAILED = 5005,
    VIZG_DIAGNOSTIC_UNKNOWN_TYPE_NAME = 6004,
    VIZG_DIAGNOSTIC_TYPE_MISMATCH = 6005,
    VIZG_DIAGNOSTIC_UNKNOWN_PROPERTY = 6006,
    VIZG_DIAGNOSTIC_INVALID_INDEX = 6007,
    VIZG_DIAGNOSTIC_INVALID_ARGUMENT_COUNT = 6008,
    VIZG_DIAGNOSTIC_INVALID_ARGUMENT_TYPE = 6009,
};

typedef uint32_t Vizg_ExternalType;
enum {
    VIZG_EXTERNAL_TYPE_UNKNOWN = 0,
    VIZG_EXTERNAL_TYPE_ANY = 1,
    VIZG_EXTERNAL_TYPE_NEVER = 2,
    VIZG_EXTERNAL_TYPE_VOID = 3,
    VIZG_EXTERNAL_TYPE_UNDEFINED = 4,
    VIZG_EXTERNAL_TYPE_NULL = 5,
    VIZG_EXTERNAL_TYPE_BOOLEAN = 6,
    VIZG_EXTERNAL_TYPE_NUMBER = 7,
    VIZG_EXTERNAL_TYPE_BIGINT = 8,
    VIZG_EXTERNAL_TYPE_STRING = 9,
    VIZG_EXTERNAL_TYPE_SYMBOL = 10,
    VIZG_EXTERNAL_TYPE_OBJECT = 11,
};

typedef struct Vizg_ProjectSource {
    uint64_t module_id;
    const char *logical_name_ptr;
    size_t logical_name_len;
    const char *source_ptr;
    /* Must be no greater than VIZG_MAX_SOURCE_LENGTH. */
    size_t source_len;
    Vizg_ProjectSourceKind kind;
    uint8_t is_root;
    uint8_t reserved[3];
} Vizg_ProjectSource;

typedef struct Vizg_ProjectSpan {
    /* Source byte offsets and locations use the ABI's stable uint32_t width. */
    uint32_t start;
    uint32_t end;
    uint32_t line;
    uint32_t column;
} Vizg_ProjectSpan;

typedef struct Vizg_ProjectRequestAttribute {
    const char *key_ptr;
    size_t key_len;
    const char *value_ptr;
    size_t value_len;
    Vizg_ProjectSpan span;
} Vizg_ProjectRequestAttribute;

typedef struct Vizg_ProjectStep {
    Vizg_ProjectStepKind kind;
    uint64_t request_id;
    uint64_t importer_module_id;
    const char *specifier_ptr;
    size_t specifier_len;
    Vizg_ProjectRequestOperation request_operation;
    uint8_t type_only;
    uint8_t reserved[3];
    const Vizg_ProjectRequestAttribute *attributes_ptr;
    size_t attribute_count;
    Vizg_ProjectSpan span;
} Vizg_ProjectStep;

typedef struct Vizg_ExternalExport {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalExportKind kind;
    Vizg_ExternalNamespaceFlags namespace_flags; /* Zero/unknown bits invalid. */
    uint8_t has_type_metadata;
    uint8_t reserved[2];
    Vizg_ExternalType type_metadata;
} Vizg_ExternalExport;

typedef struct Vizg_ExternalModule {
    uint64_t external_module_id;
    const char *logical_name_ptr;
    size_t logical_name_len;
    const Vizg_ExternalExport *exports_ptr;
    size_t export_count;
} Vizg_ExternalModule;

/* External-module API v2 publication data. Names and arrays are borrowed for
 * the duration of vizg_project_respond_external_v2. Stable symbol identities,
 * declarations, signatures and effects remain origin-neutral: no OS, header,
 * library or linker metadata is accepted by this API. */
typedef struct Vizg_ExternalParameterV2 {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalType type_metadata;
    uint8_t optional;
    uint8_t has_default;
    uint8_t rest;
    uint8_t reserved;
} Vizg_ExternalParameterV2;

typedef struct Vizg_ExternalFunctionV2 {
    const Vizg_ExternalParameterV2 *parameters_ptr;
    size_t parameter_count;
    Vizg_ExternalType return_type;
    uint32_t type_parameter_count;
    uint8_t is_async;
    uint8_t is_generator;
    uint8_t is_constructor;
    uint8_t reserved;
} Vizg_ExternalFunctionV2;

typedef struct Vizg_ExternalExportV2 {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalExportKind kind;
    Vizg_ExternalNamespaceFlags namespace_flags;
    uint8_t has_type_metadata;
    uint8_t has_function;
    uint8_t reserved;
    Vizg_ExternalType type_metadata;
    Vizg_ExternalDeclarationKind declaration_kind;
    Vizg_ExternalEffectFlags effect_flags;
    uint16_t reserved2;
    uint64_t external_symbol_id;
    Vizg_ExternalFunctionV2 function;
} Vizg_ExternalExportV2;

typedef struct Vizg_ExternalModuleV2 {
    uint64_t external_module_id;
    const char *logical_name_ptr;
    size_t logical_name_len;
    const Vizg_ExternalExportV2 *exports_ptr;
    size_t export_count;
} Vizg_ExternalModuleV2;

typedef struct Vizg_AmbientGlobal {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalNamespaceFlags namespace_flags;
    uint8_t has_type_metadata;
    Vizg_ExternalType type_metadata;
    uint64_t host_binding_id;
    uint8_t reserved[8];
} Vizg_AmbientGlobal;

typedef struct Vizg_AmbientMember {
    const char *name_ptr;
    size_t name_len;
    uint8_t has_type_metadata;
    uint8_t optional;
    uint8_t readonly;
    uint8_t self_reference;
    Vizg_ExternalType type_metadata;
    uint8_t reserved[8];
} Vizg_AmbientMember;

typedef struct Vizg_AmbientGlobalV2 {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalNamespaceFlags namespace_flags;
    uint8_t has_type_metadata;
    Vizg_ExternalType type_metadata;
    uint64_t host_binding_id;
    const Vizg_AmbientMember *members_ptr;
    size_t member_count;
    uint8_t reserved[8];
} Vizg_AmbientGlobalV2;

typedef struct Vizg_SourceHostBinding {
    const char *name_ptr;
    size_t name_len;
    uint64_t host_binding_id;
    uint8_t reserved[8];
} Vizg_SourceHostBinding;

typedef struct Vizg_ProjectResultSummary {
    size_t module_count;
    size_t diagnostic_count;
    size_t edge_count;
    size_t import_count;
    size_t export_count;
    uint8_t is_partial;
    uint8_t has_syntax_errors;
    uint8_t has_semantic_errors;
    uint8_t has_project_errors;
    uint8_t has_module_failures;
    uint8_t reserved[3];
} Vizg_ProjectResultSummary;

typedef struct Vizg_ProjectModuleInfo {
    uint64_t module_id;
    const char *logical_name_ptr;
    size_t logical_name_len;
    Vizg_ProjectModuleState state;
    uint8_t is_root;
    uint8_t has_source;
    uint8_t reserved[2];
} Vizg_ProjectModuleInfo;

typedef struct Vizg_ProjectDiagnostic {
    uint64_t module_id;
    uint8_t has_module_id;
    Vizg_DiagnosticSeverity severity;
    Vizg_DiagnosticPhase phase;
    uint8_t reserved;
    Vizg_DiagnosticCode code;
    const char *message_ptr;
    size_t message_len;
    const char *logical_name_ptr;
    size_t logical_name_len;
    Vizg_ProjectSpan span;
} Vizg_ProjectDiagnostic;

typedef struct Vizg_ProjectEdgeInfo {
    uint64_t request_id;
    uint64_t importer_module_id;
    uint64_t target_module_id;
    uint64_t external_module_id;
    const char *specifier_ptr;
    size_t specifier_len;
    Vizg_ProjectRequestOperation request_operation;
    Vizg_ProjectEdgeState state;
    uint8_t type_only;
    uint8_t has_target_module;
    uint8_t has_external_target;
    uint8_t reserved;
    Vizg_ProjectSpan span;
} Vizg_ProjectEdgeInfo;

typedef struct Vizg_ProjectImportInfo {
    uint64_t module_id;
    uint64_t target_module_id;
    uint64_t external_module_id;
    size_t edge_index;
    uint32_t target_type_id;
    Vizg_ProjectLinkState link_state;
    Vizg_ProjectRequestOperation request_operation;
    const char *local_name_ptr;
    size_t local_name_len;
    const char *imported_name_ptr;
    size_t imported_name_len;
    const char *specifier_ptr;
    size_t specifier_len;
    uint8_t type_only;
    uint8_t runtime_binding;
    uint8_t has_target_module;
    uint8_t has_external_target;
    uint8_t has_edge_index;
    uint8_t has_semantic_target;
    uint8_t reserved[2];
    Vizg_ProjectSpan span;
} Vizg_ProjectImportInfo;

typedef struct Vizg_ProjectExportInfo {
    uint64_t module_id;
    uint64_t target_module_id;
    uint64_t external_module_id;
    size_t edge_index;
    uint32_t target_type_id;
    const char *name_ptr;
    size_t name_len;
    uint8_t type_only;
    uint8_t re_export;
    uint8_t has_target_module;
    uint8_t has_external_target;
    uint8_t has_edge_index;
    uint8_t reserved[3];
    Vizg_ProjectSpan span;
} Vizg_ProjectExportInfo;

typedef uint32_t Vizg_HirEntityKind;
enum {
    VIZG_HIR_ENTITY_MODULE = 0,
    VIZG_HIR_ENTITY_EXTERNAL_DECLARATION = 1,
    VIZG_HIR_ENTITY_FUNCTION = 2,
    VIZG_HIR_ENTITY_BLOCK = 3,
    VIZG_HIR_ENTITY_INSTRUCTION = 4,
    VIZG_HIR_ENTITY_BINDING = 5,
    VIZG_HIR_ENTITY_TYPE = 6,
    VIZG_HIR_ENTITY_ORIGIN = 7,
};

typedef uint32_t Vizg_HirOperationTag;
enum {
    VIZG_HIR_OPERATION_CONSTANT = 0,
    VIZG_HIR_OPERATION_COPY = 1,
    VIZG_HIR_OPERATION_LOAD_BINDING = 2,
    VIZG_HIR_OPERATION_INITIALIZE_BINDING = 3,
    VIZG_HIR_OPERATION_STORE_BINDING = 4,
    VIZG_HIR_OPERATION_LOAD_THIS = 5,
    VIZG_HIR_OPERATION_LOAD_SUPER = 6,
    VIZG_HIR_OPERATION_LOAD_META = 7,
    VIZG_HIR_OPERATION_MAKE_BINDING_PLACE = 8,
    VIZG_HIR_OPERATION_MAKE_PROPERTY_PLACE = 9,
    VIZG_HIR_OPERATION_MAKE_ELEMENT_PLACE = 10,
    VIZG_HIR_OPERATION_MAKE_SUPER_PLACE = 11,
    VIZG_HIR_OPERATION_LOAD_PLACE = 12,
    VIZG_HIR_OPERATION_STORE_PLACE = 13,
    VIZG_HIR_OPERATION_DELETE_PLACE = 14,
    VIZG_HIR_OPERATION_TO_BOOLEAN = 15,
    VIZG_HIR_OPERATION_IS_NULLISH = 16,
    VIZG_HIR_OPERATION_TYPEOF_VALUE = 17,
    VIZG_HIR_OPERATION_VOID_VALUE = 18,
    VIZG_HIR_OPERATION_UNARY = 19,
    VIZG_HIR_OPERATION_BINARY = 20,
    VIZG_HIR_OPERATION_ADD = 21,
    VIZG_HIR_OPERATION_CALL = 22,
    VIZG_HIR_OPERATION_CALL_METHOD = 23,
    VIZG_HIR_OPERATION_CALL_SUPER_METHOD = 24,
    VIZG_HIR_OPERATION_CALL_SUPER_CONSTRUCTOR = 25,
    VIZG_HIR_OPERATION_CONSTRUCT = 26,
    VIZG_HIR_OPERATION_TAGGED_TEMPLATE_CALL = 27,
    VIZG_HIR_OPERATION_DYNAMIC_IMPORT = 28,
    VIZG_HIR_OPERATION_CREATE_OBJECT = 29,
    VIZG_HIR_OPERATION_CREATE_ARRAY = 30,
    VIZG_HIR_OPERATION_CREATE_CLOSURE = 31,
    VIZG_HIR_OPERATION_CREATE_CLASS = 32,
    VIZG_HIR_OPERATION_CREATE_ENUM_OBJECT = 33,
    VIZG_HIR_OPERATION_CREATE_REGEXP = 34,
    VIZG_HIR_OPERATION_CREATE_TEMPLATE_SITE = 35,
    VIZG_HIR_OPERATION_DEFINE_PROPERTY = 36,
    VIZG_HIR_OPERATION_DEFINE_METHOD = 37,
    VIZG_HIR_OPERATION_COPY_OBJECT_PROPERTIES = 38,
    VIZG_HIR_OPERATION_ARRAY_APPEND = 39,
    VIZG_HIR_OPERATION_ARRAY_APPEND_HOLE = 40,
    VIZG_HIR_OPERATION_ARRAY_APPEND_ITERABLE = 41,
    VIZG_HIR_OPERATION_BUILD_STRING = 42,
    VIZG_HIR_OPERATION_TO_STRING = 43,
    VIZG_HIR_OPERATION_GET_ITERATOR = 44,
    VIZG_HIR_OPERATION_GET_ASYNC_ITERATOR = 45,
    VIZG_HIR_OPERATION_ITERATOR_NEXT = 46,
    VIZG_HIR_OPERATION_ITERATOR_DONE = 47,
    VIZG_HIR_OPERATION_ITERATOR_VALUE = 48,
    VIZG_HIR_OPERATION_ITERATOR_CLOSE = 49,
    VIZG_HIR_OPERATION_ENUMERATE_PROPERTIES = 50,
    VIZG_HIR_OPERATION_ENUMERATOR_NEXT = 51,
    VIZG_HIR_OPERATION_ENUMERATOR_DONE = 52,
    VIZG_HIR_OPERATION_ENUMERATOR_VALUE = 53,
    VIZG_HIR_OPERATION_COLLECT_REST_ARGUMENTS = 54,
    VIZG_HIR_OPERATION_READ_ARGUMENT = 55,
    VIZG_HIR_OPERATION_CREATE_ARGUMENTS_OBJECT = 56,
    VIZG_HIR_OPERATION_AWAIT = 57,
    VIZG_HIR_OPERATION_YIELD = 58,
    VIZG_HIR_OPERATION_YIELD_DELEGATE = 59,
    VIZG_HIR_OPERATION_DEBUGGER_TRAP = 60,
};

typedef uint32_t Vizg_HirTerminatorTag;
enum {
    VIZG_HIR_TERMINATOR_JUMP = 0,
    VIZG_HIR_TERMINATOR_BRANCH = 1,
    VIZG_HIR_TERMINATOR_RETURN = 2,
    VIZG_HIR_TERMINATOR_THROW = 3,
    VIZG_HIR_TERMINATOR_UNREACHABLE = 4,
    VIZG_HIR_TERMINATOR_LEAVE_REGION = 5,
    VIZG_HIR_TERMINATOR_RESUME_COMPLETION = 6,
};

typedef uint32_t Vizg_HirConstantTag;
enum {
    VIZG_HIR_CONSTANT_UNDEFINED = 0,
    VIZG_HIR_CONSTANT_NULL = 1,
    VIZG_HIR_CONSTANT_BOOLEAN = 2,
    VIZG_HIR_CONSTANT_NUMBER = 3,
    VIZG_HIR_CONSTANT_BIGINT = 4,
    VIZG_HIR_CONSTANT_STRING = 5,
};

typedef uint32_t Vizg_HirPropertyKeyTag;
enum {
    VIZG_HIR_PROPERTY_KEY_STATIC = 0,
    VIZG_HIR_PROPERTY_KEY_COMPUTED = 1,
    VIZG_HIR_PROPERTY_KEY_PRIVATE = 2,
};

typedef uint32_t Vizg_HirPayloadItemTag;
enum {
    VIZG_HIR_CALL_ARGUMENT_VALUE = 0,
    VIZG_HIR_CALL_ARGUMENT_SPREAD = 1,
};

enum {
    VIZG_HIR_TEMPLATE_PART_TEXT = 0,
    VIZG_HIR_TEMPLATE_PART_VALUE = 1,
};

typedef uint32_t Vizg_HirCompletionTag;
enum {
    VIZG_HIR_COMPLETION_NORMAL = 0,
    VIZG_HIR_COMPLETION_RETURN = 1,
    VIZG_HIR_COMPLETION_THROW = 2,
    VIZG_HIR_COMPLETION_BREAK = 3,
    VIZG_HIR_COMPLETION_CONTINUE = 4,
};

typedef uint32_t Vizg_HirMetaKind;
enum {
    VIZG_HIR_META_IMPORT_META = 0,
    VIZG_HIR_META_NEW_TARGET = 1,
};

typedef uint32_t Vizg_HirNumericMode;
enum {
    VIZG_HIR_NUMERIC_NUMBER = 0,
    VIZG_HIR_NUMERIC_BIGINT = 1,
    VIZG_HIR_NUMERIC_DYNAMIC = 2,
};

typedef uint32_t Vizg_HirAddMode;
enum {
    VIZG_HIR_ADD_NUMERIC = 0,
    VIZG_HIR_ADD_STRING_CONCAT = 1,
    VIZG_HIR_ADD_DYNAMIC = 2,
};

typedef uint32_t Vizg_HirUnaryOperator;
enum {
    VIZG_HIR_UNARY_PLUS = 0,
    VIZG_HIR_UNARY_NEGATE = 1,
    VIZG_HIR_UNARY_LOGICAL_NOT = 2,
    VIZG_HIR_UNARY_BIT_NOT = 3,
};

typedef uint32_t Vizg_HirBinaryOperator;
enum {
    VIZG_HIR_BINARY_ADD = 0,
    VIZG_HIR_BINARY_SUBTRACT = 1,
    VIZG_HIR_BINARY_MULTIPLY = 2,
    VIZG_HIR_BINARY_DIVIDE = 3,
    VIZG_HIR_BINARY_REMAINDER = 4,
    VIZG_HIR_BINARY_EXPONENTIATE = 5,
    VIZG_HIR_BINARY_BIT_AND = 6,
    VIZG_HIR_BINARY_BIT_OR = 7,
    VIZG_HIR_BINARY_BIT_XOR = 8,
    VIZG_HIR_BINARY_SHIFT_LEFT = 9,
    VIZG_HIR_BINARY_SHIFT_RIGHT = 10,
    VIZG_HIR_BINARY_SHIFT_RIGHT_UNSIGNED = 11,
    VIZG_HIR_BINARY_LESS = 12,
    VIZG_HIR_BINARY_LESS_EQUAL = 13,
    VIZG_HIR_BINARY_GREATER = 14,
    VIZG_HIR_BINARY_GREATER_EQUAL = 15,
    VIZG_HIR_BINARY_EQUAL_LOOSE = 16,
    VIZG_HIR_BINARY_EQUAL_STRICT = 17,
    VIZG_HIR_BINARY_NOT_EQUAL_LOOSE = 18,
    VIZG_HIR_BINARY_NOT_EQUAL_STRICT = 19,
    VIZG_HIR_BINARY_IN = 20,
    VIZG_HIR_BINARY_INSTANCEOF = 21,
};

typedef uint32_t Vizg_HirFunctionKind;
enum {
    VIZG_HIR_FUNCTION_MODULE_INITIALIZATION = 0,
    VIZG_HIR_FUNCTION_ORDINARY = 1,
    VIZG_HIR_FUNCTION_METHOD = 2,
    VIZG_HIR_FUNCTION_CONSTRUCTOR = 3,
    VIZG_HIR_FUNCTION_GETTER = 4,
    VIZG_HIR_FUNCTION_SETTER = 5,
};

typedef struct Vizg_HirSummary {
    size_t module_count;
    size_t external_declaration_count;
    size_t function_count;
    size_t block_count;
    size_t instruction_count;
    size_t binding_count;
    size_t type_count;
    size_t origin_count;
} Vizg_HirSummary;

/* Generic immutable record. Kind-specific tag and id field meanings are
 * versioned by VIZG_HIR_API_VERSION. For instruction records, HIR API v1
 * stores the parent function id in secondary_id; v2 stores the result ValueId
 * or VIZG_HIR_ID_NONE when flags bit 0 is clear. The parent function remains
 * available through the parent block record. For origin records, HIR API v2
 * sets flags bit 0 exactly when type_id is present; v1 leaves it clear. String
 * storage is borrowed from result. */
typedef struct Vizg_HirRecord {
    Vizg_HirEntityKind kind;
    uint32_t tag;
    uint64_t id;
    uint64_t parent_id;
    uint64_t secondary_id;
    uint64_t module_id;
    uint32_t type_id;
    uint16_t effect_bits;
    uint8_t flags;
    uint8_t reserved[1];
    uint32_t origin_id;
    const char *name_ptr;
    size_t name_len;
    size_t child_count;
} Vizg_HirRecord;

/* Versioned operation or terminator payload. The active HIR tag determines
 * the meaning of the generic tag, operand, string and item fields. Borrowed
 * strings remain valid for the lifetime of the result. See
 * docs/hir-payload-api.md for the complete field mapping. */
typedef struct Vizg_HirPayload {
    uint32_t tag;
    uint32_t tag0;
    uint32_t tag1;
    uint32_t flags;
    uint64_t operand0;
    uint64_t operand1;
    uint64_t operand2;
    uint64_t operand3;
    const char *string0_ptr;
    size_t string0_len;
    const char *string1_ptr;
    size_t string1_len;
    size_t item_count;
} Vizg_HirPayload;

/* One variable-length child of a Vizg_HirPayload. */
typedef struct Vizg_HirPayloadItem {
    uint32_t tag;
    uint32_t flags;
    uint64_t operand0;
    uint64_t operand1;
    const char *string0_ptr;
    size_t string0_len;
    const char *string1_ptr;
    size_t string1_len;
} Vizg_HirPayloadItem;

/* Versioned details required by typed SSA consumers. All strings are borrowed
 * from the immutable result. Indexes use the same stable iteration order as
 * Vizg_HirRecord for the corresponding entity kind. */
typedef struct Vizg_HirTypeDetail {
    uint32_t id;
    uint32_t kind;
    uint32_t builtin_kind;
    uint32_t reserved;
} Vizg_HirTypeDetail;

typedef struct Vizg_HirFunctionSignature {
    uint32_t type_id;
    uint32_t return_type_id;
    uint32_t type_parameter_count;
    uint8_t flags;
    uint8_t reserved[3];
    size_t parameter_count;
} Vizg_HirFunctionSignature;

typedef struct Vizg_HirSignatureParameter {
    const char *name_ptr;
    size_t name_len;
    uint32_t type_id;
    uint8_t flags;
    uint8_t reserved[3];
} Vizg_HirSignatureParameter;

typedef struct Vizg_HirFunctionDetail {
    uint64_t id;
    uint64_t entry_block_id;
    size_t parameter_count;
    uint16_t flags;
    uint8_t reserved[6];
} Vizg_HirFunctionDetail;

typedef struct Vizg_HirFunctionParameter {
    uint64_t binding_id;
    uint32_t type_id;
    uint32_t argument_index;
    uint32_t origin_id;
    uint8_t flags;
    uint8_t reserved[3];
} Vizg_HirFunctionParameter;

typedef struct Vizg_HirBlockDetail {
    uint64_t id;
    size_t parameter_count;
} Vizg_HirBlockDetail;

typedef struct Vizg_HirBlockParameter {
    uint64_t value_id;
    uint32_t type_id;
    uint32_t origin_id;
} Vizg_HirBlockParameter;

typedef struct Vizg_HirOriginDetail {
    uint32_t id;
    uint64_t module_id;
    uint32_t span_start;
    uint32_t span_end;
    uint32_t original_syntax;
    uint32_t lowering_rule;
    uint32_t type_id;
    uint32_t parent_id;
    uint32_t synthetic_reason;
    uint64_t symbol_module_id;
    uint32_t symbol_declaration_id;
    uint8_t symbol_external;
    uint8_t flags;
    uint8_t reserved[2];
} Vizg_HirOriginDetail;

typedef struct Vizg_HirSemanticIdentity {
    uint64_t declaration_module_id;
    uint64_t external_module_id;
    uint64_t external_symbol_id;
    uint32_t symbol_id;
    uint32_t declaration_id;
    uint32_t type_id;
    uint32_t namespace_kind;
    uint8_t declaration_external;
    uint8_t has_host_binding_id;
    uint8_t reserved[6];
    uint64_t host_binding_id;
} Vizg_HirSemanticIdentity;

typedef struct Vizg_HirModuleDetail {
    uint64_t module_id;
    uint64_t initialization_function_id;
    size_t dependency_count;
    size_t import_count;
    size_t export_count;
} Vizg_HirModuleDetail;

typedef struct Vizg_HirModuleDependency {
    uint64_t module_id;
    uint8_t initialization_required;
    uint8_t reserved[7];
} Vizg_HirModuleDependency;

typedef struct Vizg_HirModuleImport {
    uint64_t local_binding_id;
    uint64_t source_id;
    const char *exported_name_ptr;
    size_t exported_name_len;
    Vizg_HirSemanticIdentity target;
    uint32_t source_kind;
    uint8_t type_only;
    uint8_t reserved[3];
} Vizg_HirModuleImport;

typedef struct Vizg_HirModuleExport {
    uint64_t binding_id;
    uint64_t entity_id;
    const char *exported_name_ptr;
    size_t exported_name_len;
    Vizg_HirSemanticIdentity target;
    uint8_t type_only;
    uint8_t reserved[7];
} Vizg_HirModuleExport;

typedef struct Vizg_HirBindingDetail {
    uint64_t id;
    uint32_t declaration_id;
    uint32_t initial_state;
    uint64_t declaration_module_id;
    uint8_t declaration_external;
    uint8_t has_host_binding_id;
    uint8_t reserved[6];
    uint64_t host_binding_id;
} Vizg_HirBindingDetail;

typedef struct Vizg_HirFunctionStorageDetail {
    uint64_t id;
    size_t capture_count;
} Vizg_HirFunctionStorageDetail;

typedef struct Vizg_HirFunctionCapture {
    uint64_t local_binding_id;
    uint64_t source_binding_id;
    uint32_t source_kind;
    uint32_t mode;
} Vizg_HirFunctionCapture;

/* Structured exceptional-control-flow metadata. Optional identities use
 * VIZG_HIR_ID_NONE and are paired with the corresponding flag bit. */
typedef struct Vizg_HirRegionDetail {
    uint64_t id;
    uint64_t function_id;
    uint64_t parent_region_id;
    uint64_t handler_block_id;
    uint64_t continuation_block_id;
    uint32_t origin_id;
    uint32_t kind;
    size_t protected_block_count;
    uint8_t flags;
    uint8_t reserved[7];
} Vizg_HirRegionDetail;

#ifdef __cplusplus
extern "C" {
#endif

/* Inputs are borrowed for one call and copied when retained. Every typed input
 * and output requires its C alignment, and every non-empty pointer/length range
 * must be complete and overflow-safe. The caller owns one aligned, exclusive
 * workspace; host input and output may not overlap it, and project creation
 * also forbids config/output overlap. Pointer validation completes before any
 * output write or project mutation, so INVALID_ARGUMENT leaves both unchanged.
 * Step output is borrowed until the next call on that project. The
 * implementation performs no filesystem access, callbacks, libc allocation,
 * or hidden heap allocation. Project handles are single-threaded; independent
 * handles and immutable result views may be used in parallel. Results are
 * owned by the project and remain valid until vizg_project_result_destroy or
 * vizg_project_destroy.
 * INVALID_STATE rejects ordering; LIMIT_EXCEEDED and OUT_OF_MEMORY are not
 * transactional retry guarantees. On exhaustion or INTERNAL_ERROR, destroy
 * and restart. A successful finish can report an inspectable partial result
 * through is_partial and the syntax, semantic, project, and module-host error
 * flags in Vizg_ProjectResultSummary. If creation returns LIMIT_EXCEEDED for
 * max_source_bytes, it returns a destroy-only handle so the caller can inspect
 * VIZG_LIMIT_SOURCE_BYTES. Other failures retain the validation and output
 * behavior documented above. */
uint32_t vizg_abi_version(void);
uint32_t vizg_external_module_api_version(void);
size_t vizg_project_workspace_alignment(void);
size_t vizg_project_workspace_overhead(void);
Vizg_ProjectStatus vizg_project_create(
    const Vizg_ProjectConfig *config, Vizg_Project **out_project);
void vizg_project_destroy(Vizg_Project *project);
/* Exact category for the immediately preceding LIMIT_EXCEEDED result. Other
 * project calls reset this value to VIZG_LIMIT_NONE. */
Vizg_LimitKind vizg_project_limit_kind(Vizg_Project *project);
Vizg_ProjectStatus vizg_project_add_source(
    Vizg_Project *project, const Vizg_ProjectSource *source);
Vizg_ProjectStatus vizg_project_register_ambient_globals(
    Vizg_Project *project, const Vizg_AmbientGlobal *globals, size_t count);
Vizg_ProjectStatus vizg_project_register_ambient_globals_v2(
    Vizg_Project *project, const Vizg_AmbientGlobalV2 *globals, size_t count);
Vizg_ProjectStatus vizg_project_register_source_host_bindings(
    Vizg_Project *project, const Vizg_SourceHostBinding *bindings, size_t count);
Vizg_ProjectStatus vizg_project_step(
    Vizg_Project *project, Vizg_ProjectStep *out_step);
Vizg_ProjectStatus vizg_project_respond_source(
    Vizg_Project *project, uint64_t request_id,
    const Vizg_ProjectSource *source);
Vizg_ProjectStatus vizg_project_respond_external(
    Vizg_Project *project, uint64_t request_id,
    const Vizg_ExternalModule *external_module);
/* V2 requires a stable external_symbol_id and declaration_kind for every
 * export. Function declarations also require a valid function descriptor. */
Vizg_ProjectStatus vizg_project_respond_external_v2(
    Vizg_Project *project, uint64_t request_id,
    const Vizg_ExternalModuleV2 *external_module);
Vizg_ProjectStatus vizg_project_respond_failure(
    Vizg_Project *project, uint64_t request_id,
    Vizg_ProjectFailureKind failure_kind);
Vizg_ProjectStatus vizg_project_finish(
    Vizg_Project *project, Vizg_ProjectResult **out_result);
Vizg_ProjectStatus vizg_project_result_summary(
    const Vizg_ProjectResult *result,
    Vizg_ProjectResultSummary *out_summary);
Vizg_ProjectStatus vizg_project_result_module(
    const Vizg_ProjectResult *result, size_t index,
    Vizg_ProjectModuleInfo *out_module);
Vizg_ProjectStatus vizg_project_result_diagnostic(
    const Vizg_ProjectResult *result, size_t index,
    Vizg_ProjectDiagnostic *out_diagnostic);
Vizg_ProjectStatus vizg_project_result_edge(
    const Vizg_ProjectResult *result, size_t index,
    Vizg_ProjectEdgeInfo *out_edge);
Vizg_ProjectStatus vizg_project_result_import(
    const Vizg_ProjectResult *result, size_t index,
    Vizg_ProjectImportInfo *out_import);
Vizg_ProjectStatus vizg_project_result_export(
    const Vizg_ProjectResult *result, size_t index,
    Vizg_ProjectExportInfo *out_export);
void vizg_project_result_destroy(Vizg_ProjectResult *result);
Vizg_ProjectStatus vizg_project_analyze_source(
    const Vizg_ProjectConfig *config,
    const Vizg_ProjectSource *source,
    Vizg_ProjectResult **out_result);
uint32_t vizg_hir_api_version(void);
Vizg_ProjectStatus vizg_hir_summary(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    Vizg_HirSummary *out_summary);
Vizg_ProjectStatus vizg_hir_record_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    Vizg_HirEntityKind kind, size_t index, Vizg_HirRecord *out_record);
uint32_t vizg_hir_detail_api_version(void);
Vizg_ProjectStatus vizg_hir_type_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t index, Vizg_HirTypeDetail *out_detail);
Vizg_ProjectStatus vizg_hir_function_signature(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    uint32_t type_id, Vizg_HirFunctionSignature *out_signature);
/* Returns the type accepted by return completion inside the function body.
 * Async and generator wrappers remain visible in Vizg_HirFunctionSignature;
 * this accessor unwraps them according to the signature flags. */
Vizg_ProjectStatus vizg_hir_function_completion_type(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    uint32_t type_id, uint32_t *out_type_id);
Vizg_ProjectStatus vizg_hir_signature_parameter_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    uint32_t type_id, size_t parameter_index,
    Vizg_HirSignatureParameter *out_parameter);
Vizg_ProjectStatus vizg_hir_function_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t function_index, Vizg_HirFunctionDetail *out_detail);
Vizg_ProjectStatus vizg_hir_function_parameter_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t function_index, size_t parameter_index,
    Vizg_HirFunctionParameter *out_parameter);
Vizg_ProjectStatus vizg_hir_block_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t block_index, Vizg_HirBlockDetail *out_detail);
Vizg_ProjectStatus vizg_hir_block_parameter_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t block_index, size_t parameter_index,
    Vizg_HirBlockParameter *out_parameter);
Vizg_ProjectStatus vizg_hir_origin_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t origin_index, Vizg_HirOriginDetail *out_detail);
Vizg_ProjectStatus vizg_hir_module_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t module_index, Vizg_HirModuleDetail *out_detail);
Vizg_ProjectStatus vizg_hir_module_dependency_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t module_index, size_t dependency_index,
    Vizg_HirModuleDependency *out_dependency);
Vizg_ProjectStatus vizg_hir_module_import_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t module_index, size_t import_index,
    Vizg_HirModuleImport *out_import);
Vizg_ProjectStatus vizg_hir_module_export_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t module_index, size_t export_index,
    Vizg_HirModuleExport *out_export);
Vizg_ProjectStatus vizg_hir_binding_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t binding_index, Vizg_HirBindingDetail *out_detail);
Vizg_ProjectStatus vizg_hir_function_storage_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t function_index, Vizg_HirFunctionStorageDetail *out_detail);
Vizg_ProjectStatus vizg_hir_function_capture_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t function_index, size_t capture_index,
    Vizg_HirFunctionCapture *out_capture);
Vizg_ProjectStatus vizg_hir_region_count(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t *out_count);
Vizg_ProjectStatus vizg_hir_region_detail_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t region_index, Vizg_HirRegionDetail *out_detail);
Vizg_ProjectStatus vizg_hir_region_protected_block_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t region_index, size_t protected_block_index,
    uint64_t *out_block_id);
uint32_t vizg_hir_payload_api_version(void);
Vizg_ProjectStatus vizg_hir_operation_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t index, Vizg_HirPayload *out_payload);
Vizg_ProjectStatus vizg_hir_operation_item_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t operation_index, size_t item_index, Vizg_HirPayloadItem *out_item);
Vizg_ProjectStatus vizg_hir_terminator_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t index, Vizg_HirPayload *out_payload);
Vizg_ProjectStatus vizg_hir_terminator_item_at(
    const Vizg_ProjectResult *result, uint32_t requested_version,
    size_t terminator_index, size_t item_index, Vizg_HirPayloadItem *out_item);

#ifdef __cplusplus
}
#endif

#endif
