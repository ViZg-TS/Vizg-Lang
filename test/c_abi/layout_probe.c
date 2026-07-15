#include "vizg.h"
#include <stddef.h>

#define LAYOUT(type) \
    size_t vizg_c_sizeof_##type(void) { return sizeof(type); } \
    size_t vizg_c_alignof_##type(void) { return _Alignof(type); }

LAYOUT(Vizg_ProjectStatus)
LAYOUT(Vizg_ProjectSourceKind)
LAYOUT(Vizg_ProjectStepKind)
LAYOUT(Vizg_ProjectRequestOperation)
LAYOUT(Vizg_ProjectFailureKind)
LAYOUT(Vizg_ExternalExportKind)
LAYOUT(Vizg_ExternalType)
LAYOUT(Vizg_ProjectConfig)
LAYOUT(Vizg_ProjectSource)
LAYOUT(Vizg_ProjectSpan)
LAYOUT(Vizg_ProjectRequestAttribute)
LAYOUT(Vizg_ProjectStep)
LAYOUT(Vizg_ExternalExport)
LAYOUT(Vizg_ExternalModule)
LAYOUT(Vizg_ProjectResultSummary)
LAYOUT(Vizg_ProjectModuleInfo)
LAYOUT(Vizg_ProjectDiagnostic)
LAYOUT(Vizg_ProjectEdgeInfo)
LAYOUT(Vizg_ProjectImportInfo)
LAYOUT(Vizg_ProjectExportInfo)

#define F(type, field, weight) (offsetof(type, field) * (weight))

size_t vizg_c_fields_Vizg_ProjectConfig(void) {
    return F(Vizg_ProjectConfig, workspace_ptr, 1) + F(Vizg_ProjectConfig, workspace_len, 2) +
        F(Vizg_ProjectConfig, max_source_bytes, 3) + F(Vizg_ProjectConfig, max_modules, 4) +
        F(Vizg_ProjectConfig, max_requests, 5) + F(Vizg_ProjectConfig, max_edges, 6) +
        F(Vizg_ProjectConfig, max_diagnostics, 7) + F(Vizg_ProjectConfig, max_graph_depth, 8) +
        F(Vizg_ProjectConfig, max_semantic_types, 9);
}
size_t vizg_c_fields_Vizg_ProjectSource(void) {
    return F(Vizg_ProjectSource, module_id, 1) + F(Vizg_ProjectSource, logical_name_ptr, 2) +
        F(Vizg_ProjectSource, logical_name_len, 3) + F(Vizg_ProjectSource, source_ptr, 4) +
        F(Vizg_ProjectSource, source_len, 5) + F(Vizg_ProjectSource, kind, 6) +
        F(Vizg_ProjectSource, is_root, 7) + F(Vizg_ProjectSource, reserved, 8);
}
size_t vizg_c_fields_Vizg_ProjectSpan(void) {
    return F(Vizg_ProjectSpan, start, 1) + F(Vizg_ProjectSpan, end, 2) +
        F(Vizg_ProjectSpan, line, 3) + F(Vizg_ProjectSpan, column, 4);
}
size_t vizg_c_fields_Vizg_ProjectRequestAttribute(void) {
    return F(Vizg_ProjectRequestAttribute, key_ptr, 1) + F(Vizg_ProjectRequestAttribute, key_len, 2) +
        F(Vizg_ProjectRequestAttribute, value_ptr, 3) + F(Vizg_ProjectRequestAttribute, value_len, 4) +
        F(Vizg_ProjectRequestAttribute, span, 5);
}
size_t vizg_c_fields_Vizg_ProjectStep(void) {
    return F(Vizg_ProjectStep, kind, 1) + F(Vizg_ProjectStep, request_id, 2) +
        F(Vizg_ProjectStep, importer_module_id, 3) + F(Vizg_ProjectStep, specifier_ptr, 4) +
        F(Vizg_ProjectStep, specifier_len, 5) + F(Vizg_ProjectStep, request_operation, 6) +
        F(Vizg_ProjectStep, type_only, 7) + F(Vizg_ProjectStep, reserved, 8) +
        F(Vizg_ProjectStep, attributes_ptr, 9) + F(Vizg_ProjectStep, attribute_count, 10) +
        F(Vizg_ProjectStep, span, 11);
}
size_t vizg_c_fields_Vizg_ExternalExport(void) {
    return F(Vizg_ExternalExport, name_ptr, 1) + F(Vizg_ExternalExport, name_len, 2) +
        F(Vizg_ExternalExport, kind, 3) + F(Vizg_ExternalExport, type_only, 4) +
        F(Vizg_ExternalExport, has_type_metadata, 5) + F(Vizg_ExternalExport, reserved, 6) +
        F(Vizg_ExternalExport, type_metadata, 7);
}
size_t vizg_c_fields_Vizg_ExternalModule(void) {
    return F(Vizg_ExternalModule, external_module_id, 1) + F(Vizg_ExternalModule, logical_name_ptr, 2) +
        F(Vizg_ExternalModule, logical_name_len, 3) + F(Vizg_ExternalModule, exports_ptr, 4) +
        F(Vizg_ExternalModule, export_count, 5);
}
size_t vizg_c_fields_Vizg_ProjectResultSummary(void) {
    return F(Vizg_ProjectResultSummary, module_count, 1) + F(Vizg_ProjectResultSummary, diagnostic_count, 2) +
        F(Vizg_ProjectResultSummary, edge_count, 3) + F(Vizg_ProjectResultSummary, import_count, 4) +
        F(Vizg_ProjectResultSummary, export_count, 5) + F(Vizg_ProjectResultSummary, is_partial, 6) +
        F(Vizg_ProjectResultSummary, has_syntax_errors, 7) + F(Vizg_ProjectResultSummary, has_semantic_errors, 8) +
        F(Vizg_ProjectResultSummary, has_module_failures, 9) + F(Vizg_ProjectResultSummary, reserved, 10);
}

uint32_t vizg_c_value_project_status_internal_error(void) { return VIZG_PROJECT_STATUS_INTERNAL_ERROR; }
uint32_t vizg_c_value_project_request_re_export(void) { return VIZG_PROJECT_REQUEST_RE_EXPORT; }
uint32_t vizg_c_value_external_type_object(void) { return VIZG_EXTERNAL_TYPE_OBJECT; }
