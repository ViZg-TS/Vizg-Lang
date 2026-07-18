#include "vizg.h"
#include <stdint.h>

int main(void) {
    static uint64_t workspace_words[1024 * 1024];
    const char source_text[] =
        "const captured = 1; export function answer(value: number): number { "
        "const nested = () => captured + value; return nested(); }";
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
    for (size_t index = 0; index < summary.type_count; ++index) {
        Vizg_HirTypeDetail detail;
        if (vizg_hir_type_detail_at(result, VIZG_HIR_DETAIL_API_VERSION,
                index, &detail) != VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 6;
        }
        if (detail.kind == VIZG_HIR_TYPE_FUNCTION) {
            Vizg_HirFunctionSignature signature;
            if (vizg_hir_function_signature(result,
                    VIZG_HIR_DETAIL_API_VERSION, detail.id, &signature) !=
                VIZG_PROJECT_STATUS_OK) {
                vizg_project_result_destroy(result);
                return 7;
            }
            uint32_t completion_type;
            if (vizg_hir_function_completion_type(result,
                    VIZG_HIR_DETAIL_API_VERSION, detail.id,
                    &completion_type) != VIZG_PROJECT_STATUS_OK) {
                vizg_project_result_destroy(result);
                return 8;
            }
            for (size_t parameter_index = 0;
                 parameter_index < signature.parameter_count;
                 ++parameter_index) {
                Vizg_HirSignatureParameter parameter;
                if (vizg_hir_signature_parameter_at(result,
                        VIZG_HIR_DETAIL_API_VERSION, detail.id,
                        parameter_index, &parameter) !=
                    VIZG_PROJECT_STATUS_OK) {
                    vizg_project_result_destroy(result);
                    return 9;
                }
            }
        }
    }
    for (size_t index = 0; index < summary.function_count; ++index) {
        Vizg_HirFunctionDetail detail;
        if (vizg_hir_function_detail_at(result, VIZG_HIR_DETAIL_API_VERSION,
                index, &detail) != VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 9;
        }
    }
    for (size_t index = 0; index < summary.block_count; ++index) {
        Vizg_HirBlockDetail detail;
        if (vizg_hir_block_detail_at(result, VIZG_HIR_DETAIL_API_VERSION,
                index, &detail) != VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 10;
        }
    }
    for (size_t index = 0; index < summary.origin_count; ++index) {
        Vizg_HirOriginDetail detail;
        if (vizg_hir_origin_detail_at(result, VIZG_HIR_DETAIL_API_VERSION,
                index, &detail) != VIZG_PROJECT_STATUS_OK ||
            detail.span_end < detail.span_start) {
            vizg_project_result_destroy(result);
            return 11;
        }
    }
    Vizg_HirModuleDetail module_detail;
    if (vizg_hir_module_detail_at(result, VIZG_HIR_DETAIL_API_VERSION, 0,
            &module_detail) != VIZG_PROJECT_STATUS_OK ||
        module_detail.module_id != 1 || module_detail.export_count == 0) {
        vizg_project_result_destroy(result);
        return 16;
    }
    for (size_t index = 0; index < module_detail.export_count; ++index) {
        Vizg_HirModuleExport module_export;
        if (vizg_hir_module_export_at(result, VIZG_HIR_DETAIL_API_VERSION, 0,
                index, &module_export) != VIZG_PROJECT_STATUS_OK ||
            module_export.exported_name_len == 0) {
            vizg_project_result_destroy(result);
            return 17;
        }
    }
    for (size_t index = 0; index < summary.binding_count; ++index) {
        Vizg_HirBindingDetail binding;
        if (vizg_hir_binding_detail_at(result, VIZG_HIR_DETAIL_API_VERSION,
                index, &binding) != VIZG_PROJECT_STATUS_OK ||
            binding.initial_state > VIZG_HIR_BINDING_STATE_LIVE_IMPORT) {
            vizg_project_result_destroy(result);
            return 18;
        }
    }
    int saw_live_capture = 0;
    for (size_t index = 0; index < summary.function_count; ++index) {
        Vizg_HirFunctionStorageDetail storage;
        if (vizg_hir_function_storage_detail_at(result,
                VIZG_HIR_DETAIL_API_VERSION, index, &storage) !=
            VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 19;
        }
        for (size_t capture_index = 0;
             capture_index < storage.capture_count; ++capture_index) {
            Vizg_HirFunctionCapture capture;
            if (vizg_hir_function_capture_at(result,
                    VIZG_HIR_DETAIL_API_VERSION, index, capture_index,
                    &capture) != VIZG_PROJECT_STATUS_OK) {
                vizg_project_result_destroy(result);
                return 20;
            }
            if (capture.source_kind == VIZG_HIR_CAPTURE_SOURCE_BINDING &&
                capture.mode == VIZG_HIR_CAPTURE_MODE_LIVE_BINDING) {
                saw_live_capture = 1;
            }
        }
    }
    if (!saw_live_capture) {
        vizg_project_result_destroy(result);
        return 21;
    }
    for (size_t index = 0; index < summary.instruction_count; ++index) {
        Vizg_HirPayload payload;
        if (vizg_hir_operation_at(result, VIZG_HIR_PAYLOAD_API_VERSION,
                index, &payload) != VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 12;
        }
        for (size_t item_index = 0; item_index < payload.item_count;
             ++item_index) {
            Vizg_HirPayloadItem item;
            if (vizg_hir_operation_item_at(result,
                    VIZG_HIR_PAYLOAD_API_VERSION, index, item_index, &item) !=
                VIZG_PROJECT_STATUS_OK) {
                vizg_project_result_destroy(result);
                return 13;
            }
        }
    }
    for (size_t index = 0; index < summary.block_count; ++index) {
        Vizg_HirPayload payload;
        if (vizg_hir_terminator_at(result, VIZG_HIR_PAYLOAD_API_VERSION,
                index, &payload) != VIZG_PROJECT_STATUS_OK) {
            vizg_project_result_destroy(result);
            return 14;
        }
        for (size_t item_index = 0; item_index < payload.item_count;
             ++item_index) {
            Vizg_HirPayloadItem item;
            if (vizg_hir_terminator_item_at(result,
                    VIZG_HIR_PAYLOAD_API_VERSION, index, item_index, &item) !=
                VIZG_PROJECT_STATUS_OK) {
                vizg_project_result_destroy(result);
                return 15;
            }
        }
    }
    vizg_project_result_destroy(result);
    return 0;
}
