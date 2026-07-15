#include "vizg.h"
#include <stddef.h>

#define LAYOUT(type) \
    size_t vizg_c_sizeof_##type(void) { return sizeof(type); } \
    size_t vizg_c_alignof_##type(void) { return _Alignof(type); }

LAYOUT(Vizg_ProjectStatus)
LAYOUT(Vizg_LimitKind)
LAYOUT(Vizg_ProjectSourceKind)
LAYOUT(Vizg_ProjectStepKind)
LAYOUT(Vizg_ProjectRequestOperation)
LAYOUT(Vizg_ProjectFailureKind)
LAYOUT(Vizg_ExternalExportKind)
LAYOUT(Vizg_ExternalNamespaceFlags)
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
        F(Vizg_ProjectConfig, max_source_bytes, 3) + F(Vizg_ProjectConfig, max_total_source_bytes, 4) +
        F(Vizg_ProjectConfig, max_modules, 5) + F(Vizg_ProjectConfig, max_requests, 6) +
        F(Vizg_ProjectConfig, max_edges, 7) + F(Vizg_ProjectConfig, max_diagnostics, 8) +
        F(Vizg_ProjectConfig, max_graph_depth, 9) + F(Vizg_ProjectConfig, max_semantic_types, 10);
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
        F(Vizg_ExternalExport, kind, 3) + F(Vizg_ExternalExport, namespace_flags, 4) +
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
        F(Vizg_ProjectResultSummary, has_project_errors, 9) + F(Vizg_ProjectResultSummary, has_module_failures, 10) +
        F(Vizg_ProjectResultSummary, reserved, 11);
}
size_t vizg_c_fields_Vizg_ProjectDiagnostic(void) {
    return F(Vizg_ProjectDiagnostic, module_id, 1) + F(Vizg_ProjectDiagnostic, has_module_id, 2) +
        F(Vizg_ProjectDiagnostic, severity, 3) + F(Vizg_ProjectDiagnostic, phase, 4) +
        F(Vizg_ProjectDiagnostic, reserved, 5) + F(Vizg_ProjectDiagnostic, code, 6) +
        F(Vizg_ProjectDiagnostic, message_ptr, 7) + F(Vizg_ProjectDiagnostic, message_len, 8) +
        F(Vizg_ProjectDiagnostic, logical_name_ptr, 9) + F(Vizg_ProjectDiagnostic, logical_name_len, 10) +
        F(Vizg_ProjectDiagnostic, span, 11);
}
size_t vizg_c_fields_Vizg_ProjectEdgeInfo(void) {
    return F(Vizg_ProjectEdgeInfo, request_id, 1) + F(Vizg_ProjectEdgeInfo, importer_module_id, 2) +
        F(Vizg_ProjectEdgeInfo, target_module_id, 3) + F(Vizg_ProjectEdgeInfo, external_module_id, 4) +
        F(Vizg_ProjectEdgeInfo, specifier_ptr, 5) + F(Vizg_ProjectEdgeInfo, specifier_len, 6) +
        F(Vizg_ProjectEdgeInfo, request_operation, 7) + F(Vizg_ProjectEdgeInfo, state, 8) +
        F(Vizg_ProjectEdgeInfo, type_only, 9) + F(Vizg_ProjectEdgeInfo, has_target_module, 10) +
        F(Vizg_ProjectEdgeInfo, has_external_target, 11) + F(Vizg_ProjectEdgeInfo, reserved, 12) +
        F(Vizg_ProjectEdgeInfo, span, 13);
}
size_t vizg_c_fields_Vizg_ProjectImportInfo(void) {
    return F(Vizg_ProjectImportInfo, module_id, 1) + F(Vizg_ProjectImportInfo, target_module_id, 2) +
        F(Vizg_ProjectImportInfo, external_module_id, 3) + F(Vizg_ProjectImportInfo, edge_index, 4) +
        F(Vizg_ProjectImportInfo, target_type_id, 5) + F(Vizg_ProjectImportInfo, link_state, 6) +
        F(Vizg_ProjectImportInfo, request_operation, 7) + F(Vizg_ProjectImportInfo, local_name_ptr, 8) +
        F(Vizg_ProjectImportInfo, local_name_len, 9) + F(Vizg_ProjectImportInfo, imported_name_ptr, 10) +
        F(Vizg_ProjectImportInfo, imported_name_len, 11) + F(Vizg_ProjectImportInfo, specifier_ptr, 12) +
        F(Vizg_ProjectImportInfo, specifier_len, 13) + F(Vizg_ProjectImportInfo, type_only, 14) +
        F(Vizg_ProjectImportInfo, runtime_binding, 15) + F(Vizg_ProjectImportInfo, has_target_module, 16) +
        F(Vizg_ProjectImportInfo, has_external_target, 17) + F(Vizg_ProjectImportInfo, has_edge_index, 18) +
        F(Vizg_ProjectImportInfo, has_semantic_target, 19) + F(Vizg_ProjectImportInfo, reserved, 20) +
        F(Vizg_ProjectImportInfo, span, 21);
}
size_t vizg_c_fields_Vizg_ProjectExportInfo(void) {
    return F(Vizg_ProjectExportInfo, module_id, 1) + F(Vizg_ProjectExportInfo, target_module_id, 2) +
        F(Vizg_ProjectExportInfo, external_module_id, 3) + F(Vizg_ProjectExportInfo, edge_index, 4) +
        F(Vizg_ProjectExportInfo, target_type_id, 5) + F(Vizg_ProjectExportInfo, name_ptr, 6) +
        F(Vizg_ProjectExportInfo, name_len, 7) + F(Vizg_ProjectExportInfo, type_only, 8) +
        F(Vizg_ProjectExportInfo, re_export, 9) + F(Vizg_ProjectExportInfo, has_target_module, 10) +
        F(Vizg_ProjectExportInfo, has_external_target, 11) + F(Vizg_ProjectExportInfo, has_edge_index, 12) +
        F(Vizg_ProjectExportInfo, reserved, 13) + F(Vizg_ProjectExportInfo, span, 14);
}

uint32_t vizg_c_value_project_status_internal_error(void) { return VIZG_PROJECT_STATUS_INTERNAL_ERROR; }
uint32_t vizg_c_value_limit_semantic_growth(void) { return VIZG_LIMIT_SEMANTIC_GROWTH; }
uint32_t vizg_c_value_limit_parse_depth(void) { return VIZG_LIMIT_PARSE_DEPTH; }
uint32_t vizg_c_value_project_request_re_export(void) { return VIZG_PROJECT_REQUEST_RE_EXPORT; }
uint32_t vizg_c_value_external_type_object(void) { return VIZG_EXTERNAL_TYPE_OBJECT; }
uint8_t vizg_c_value_external_namespace_value(void) { return VIZG_EXTERNAL_NAMESPACE_VALUE; }
uint8_t vizg_c_value_external_namespace_type(void) { return VIZG_EXTERNAL_NAMESPACE_TYPE; }
uint8_t vizg_c_value_external_namespace_both(void) { return VIZG_EXTERNAL_NAMESPACE_BOTH; }
