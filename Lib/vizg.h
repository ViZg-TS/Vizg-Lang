#ifndef VIZG_H
#define VIZG_H

/* ViZG official C ABI v1. Link against libvizg.a. */

#include <stddef.h>
#include <stdint.h>

#define VIZG_ABI_VERSION 1u
#define VIZG_HIR_API_VERSION 1u

#define VIZG_PROJECT_DEFAULT_WORKSPACE_BYTES (8u * 1024u * 1024u)
#define VIZG_PROJECT_DEFAULT_MAX_SOURCE_BYTES (1u * 1024u * 1024u)
#define VIZG_PROJECT_DEFAULT_MAX_MODULES 256u
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

typedef struct Vizg_ProjectConfig {
    void *workspace_ptr;
    size_t workspace_len;
    size_t max_source_bytes;
    size_t max_modules;
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

typedef uint32_t Vizg_ProjectRequestKind;
enum {
    VIZG_PROJECT_REQUEST_STATIC = 0,
    VIZG_PROJECT_REQUEST_TYPE_ONLY = 1,
    VIZG_PROJECT_REQUEST_DYNAMIC = 2,
    VIZG_PROJECT_REQUEST_RE_EXPORT = 3,
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
    uint64_t revision;
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
    Vizg_ProjectRequestKind request_kind;
    const Vizg_ProjectRequestAttribute *attributes_ptr;
    size_t attribute_count;
    Vizg_ProjectSpan span;
} Vizg_ProjectStep;

typedef struct Vizg_ExternalExport {
    const char *name_ptr;
    size_t name_len;
    Vizg_ExternalExportKind kind;
    uint8_t type_only;
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
    uint8_t has_failures;
    uint8_t reserved[7];
} Vizg_ProjectResultSummary;

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
 * versioned by VIZG_HIR_API_VERSION. String storage is borrowed from result. */
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

#ifdef __cplusplus
extern "C" {
#endif

/* Inputs are borrowed for one call and copied when retained. Step output is
 * borrowed until the next call on that project. The caller owns one aligned,
 * exclusive workspace. The implementation performs no filesystem access,
 * callbacks, libc allocation, or hidden heap allocation. Project handles are
 * single-threaded; independent handles and immutable results may be used in
 * parallel. Destroy each non-null handle exactly once. INVALID_ARGUMENT and
 * INVALID_STATE reject input/ordering; LIMIT_EXCEEDED and OUT_OF_MEMORY are
 * not transactional retry guarantees. On exhaustion or INTERNAL_ERROR,
 * destroy and restart. A successful finish can report an inspectable partial
 * result through has_failures. */
size_t vizg_project_workspace_alignment(void);
size_t vizg_project_workspace_overhead(void);
Vizg_ProjectStatus vizg_project_create(
    const Vizg_ProjectConfig *config, Vizg_Project **out_project);
void vizg_project_destroy(Vizg_Project *project);
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

#ifdef __cplusplus
}
#endif

#endif
