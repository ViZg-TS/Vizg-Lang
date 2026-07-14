#include "vizg.h"
#include <stddef.h>

#define LAYOUT(type) \
    size_t vizg_c_sizeof_##type(void) { return sizeof(type); } \
    size_t vizg_c_alignof_##type(void) { return _Alignof(type); }

LAYOUT(Vizg_ProjectStatus)
LAYOUT(Vizg_ProjectSourceKind)
LAYOUT(Vizg_ProjectStepKind)
LAYOUT(Vizg_ProjectRequestKind)
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

#define F(type, field, weight) (offsetof(type, field) * (weight))

size_t vizg_c_fields_Vizg_ProjectConfig(void) {
    return F(Vizg_ProjectConfig, workspace_ptr, 1) + F(Vizg_ProjectConfig, workspace_len, 2) +
        F(Vizg_ProjectConfig, max_source_bytes, 3) + F(Vizg_ProjectConfig, max_modules, 4) +
        F(Vizg_ProjectConfig, max_diagnostics, 5) + F(Vizg_ProjectConfig, max_graph_depth, 6) +
        F(Vizg_ProjectConfig, max_semantic_types, 7);
}
size_t vizg_c_fields_Vizg_ProjectSource(void) {
    return F(Vizg_ProjectSource, module_id, 1) + F(Vizg_ProjectSource, logical_name_ptr, 2) +
        F(Vizg_ProjectSource, logical_name_len, 3) + F(Vizg_ProjectSource, source_ptr, 4) +
        F(Vizg_ProjectSource, source_len, 5) + F(Vizg_ProjectSource, kind, 6) +
        F(Vizg_ProjectSource, is_root, 7) + F(Vizg_ProjectSource, reserved, 8) +
        F(Vizg_ProjectSource, revision, 9);
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
        F(Vizg_ProjectStep, specifier_len, 5) + F(Vizg_ProjectStep, request_kind, 6) +
        F(Vizg_ProjectStep, attributes_ptr, 7) + F(Vizg_ProjectStep, attribute_count, 8) +
        F(Vizg_ProjectStep, span, 9);
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
    return F(Vizg_ProjectResultSummary, module_count, 1) + F(Vizg_ProjectResultSummary, has_failures, 2) +
        F(Vizg_ProjectResultSummary, reserved, 3);
}

uint32_t vizg_c_value_project_status_internal_error(void) { return VIZG_PROJECT_STATUS_INTERNAL_ERROR; }
uint32_t vizg_c_value_project_request_re_export(void) { return VIZG_PROJECT_REQUEST_RE_EXPORT; }
uint32_t vizg_c_value_external_type_object(void) { return VIZG_EXTERNAL_TYPE_OBJECT; }
