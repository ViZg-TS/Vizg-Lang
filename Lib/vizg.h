#ifndef VIZG_H
#define VIZG_H

/* ViZG official C ABI v1. Link against libvizg.a. */

#include <stddef.h>
#include <stdint.h>

#define VIZG_ABI_VERSION 1u

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
};

typedef struct Vizg_ProjectConfig {
    void *workspace_ptr;
    size_t workspace_len;
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
    size_t source_len;
    Vizg_ProjectSourceKind kind;
    uint8_t is_root;
    uint8_t reserved[3];
} Vizg_ProjectSource;

typedef struct Vizg_ProjectSpan {
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

typedef struct Vizg_ProjectResultSummary {
    size_t module_count;
    size_t diagnostic_count;
    size_t edge_count;
    size_t import_count;
    size_t export_count;
    uint8_t is_partial;
    uint8_t has_syntax_errors;
    uint8_t has_semantic_errors;
    uint8_t has_module_failures;
    uint8_t reserved[4];
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
 * owned by the project and remain valid until vizg_project_destroy.
 * INVALID_STATE rejects ordering; LIMIT_EXCEEDED and OUT_OF_MEMORY are not
 * transactional retry guarantees. On exhaustion or INTERNAL_ERROR, destroy
 * and restart. A successful finish can report an inspectable partial result
 * through is_partial and has_module_failures. */
uint32_t vizg_abi_version(void);
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
Vizg_ProjectStatus vizg_project_step(
    Vizg_Project *project, Vizg_ProjectStep *out_step);
Vizg_ProjectStatus vizg_project_respond_source(
    Vizg_Project *project, uint64_t request_id,
    const Vizg_ProjectSource *source);
Vizg_ProjectStatus vizg_project_respond_external(
    Vizg_Project *project, uint64_t request_id,
    const Vizg_ExternalModule *external_module);
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

#ifdef __cplusplus
}
#endif

#endif
