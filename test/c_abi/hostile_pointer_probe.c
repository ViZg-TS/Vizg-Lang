#include "vizg.h"

#include <stdalign.h>
#include <string.h>

Vizg_ProjectStatus vizg_test_create_misaligned_config(
    const Vizg_ProjectConfig *config,
    Vizg_Project **out_project) {
    alignas(Vizg_ProjectConfig) unsigned char storage[
        sizeof(Vizg_ProjectConfig) + alignof(Vizg_ProjectConfig)];
    memcpy(storage + 1, config, sizeof(Vizg_ProjectConfig));
    return vizg_project_create(
        (const Vizg_ProjectConfig *)(const void *)(storage + 1), out_project);
}

Vizg_ProjectStatus vizg_test_create_misaligned_output(
    const Vizg_ProjectConfig *config) {
    alignas(Vizg_Project *) unsigned char storage[
        sizeof(Vizg_Project *) + alignof(Vizg_Project *)];
    return vizg_project_create(
        config, (Vizg_Project **)(void *)(storage + 1));
}

Vizg_ProjectStatus vizg_test_step_misaligned_output(Vizg_Project *project) {
    alignas(Vizg_ProjectStep) unsigned char storage[
        sizeof(Vizg_ProjectStep) + alignof(Vizg_ProjectStep)];
    return vizg_project_step(
        project, (Vizg_ProjectStep *)(void *)(storage + 1));
}

Vizg_ProjectStatus vizg_test_finish_misaligned_output(Vizg_Project *project) {
    alignas(Vizg_ProjectResult *) unsigned char storage[
        sizeof(Vizg_ProjectResult *) + alignof(Vizg_ProjectResult *)];
    return vizg_project_finish(
        project, (Vizg_ProjectResult **)(void *)(storage + 1));
}

Vizg_ProjectStatus vizg_test_summary_misaligned_output(
    const Vizg_ProjectResult *result) {
    alignas(Vizg_ProjectResultSummary) unsigned char storage[
        sizeof(Vizg_ProjectResultSummary) + alignof(Vizg_ProjectResultSummary)];
    return vizg_project_result_summary(
        result, (Vizg_ProjectResultSummary *)(void *)(storage + 1));
}

void vizg_test_destroy_misaligned_handle(void) {
    alignas(void *) unsigned char storage[sizeof(void *) + alignof(void *)];
    vizg_project_destroy((Vizg_Project *)(void *)(storage + 1));
}

uint32_t vizg_test_limit_kind_misaligned_handle(void) {
    alignas(void *) unsigned char storage[sizeof(void *) + alignof(void *)];
    return (uint32_t)vizg_project_limit_kind(
        (Vizg_Project *)(void *)(storage + 1));
}
