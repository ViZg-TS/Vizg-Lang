#include "vizg.h"
#include <stdint.h>

int main(void) {
    static uint64_t workspace_words[1024 * 1024];
    const char source_text[] =
        "export function answer(value: number): number { return value + 1; }";
    const char logical_name[] = "consumer.ts";
    Vizg_ProjectConfig config = {
        .workspace_ptr = workspace_words,
        .workspace_len = sizeof(workspace_words),
        .max_source_bytes = sizeof(source_text),
        .max_total_source_bytes = sizeof(source_text),
        .max_modules = 8,
        .max_requests = 8,
        .max_edges = 8,
        .max_diagnostics = 64,
        .max_graph_depth = 8,
        .max_semantic_types = 1024,
    };
    Vizg_ProjectSource source = {
        .module_id = 1,
        .logical_name_ptr = logical_name,
        .logical_name_len = sizeof(logical_name) - 1,
        .source_ptr = source_text,
        .source_len = sizeof(source_text) - 1,
        .kind = VIZG_PROJECT_SOURCE_MODULE,
        .is_root = 1,
    };
    Vizg_ProjectResult *result = 0;
    if (vizg_project_analyze_source(&config, &source, &result) !=
        VIZG_PROJECT_STATUS_OK) return 1;

    Vizg_HirSummary summary;
    if (vizg_hir_summary(result, VIZG_HIR_API_VERSION, &summary) !=
        VIZG_PROJECT_STATUS_OK) {
        vizg_project_result_destroy(result);
        return 2;
    }
    const size_t counts[] = {
        summary.module_count,
        summary.external_declaration_count,
        summary.function_count,
        summary.block_count,
        summary.instruction_count,
        summary.binding_count,
        summary.type_count,
        summary.origin_count,
    };
    if (summary.module_count != 1 || summary.function_count == 0 ||
        summary.block_count == 0 || summary.instruction_count == 0 ||
        summary.binding_count == 0 || summary.type_count == 0) {
        vizg_project_result_destroy(result);
        return 3;
    }
    for (uint32_t kind = VIZG_HIR_ENTITY_MODULE;
         kind <= VIZG_HIR_ENTITY_ORIGIN; ++kind) {
        for (size_t index = 0; index < counts[kind]; ++index) {
            Vizg_HirRecord record;
            if (vizg_hir_record_at(result, VIZG_HIR_API_VERSION, kind, index,
                    &record) != VIZG_PROJECT_STATUS_OK ||
                record.kind != kind) {
                vizg_project_result_destroy(result);
                return 4;
            }
            if (kind == VIZG_HIR_ENTITY_MODULE && record.module_id != 1) {
                vizg_project_result_destroy(result);
                return 5;
            }
        }
    }
    vizg_project_result_destroy(result);
    return 0;
}
