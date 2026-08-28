const std = @import("std");
const c = @cImport(@cInclude("vizg.h"));

extern fn vizg_test_create_misaligned_config(
    config: *const c.Vizg_ProjectConfig,
    out_project: [*c]?*c.Vizg_Project,
) callconv(.c) c.Vizg_ProjectStatus;
extern fn vizg_test_create_misaligned_output(
    config: *const c.Vizg_ProjectConfig,
) callconv(.c) c.Vizg_ProjectStatus;
extern fn vizg_test_step_misaligned_output(
    project: *c.Vizg_Project,
) callconv(.c) c.Vizg_ProjectStatus;
extern fn vizg_test_finish_misaligned_output(
    project: *c.Vizg_Project,
) callconv(.c) c.Vizg_ProjectStatus;
extern fn vizg_test_summary_misaligned_output(
    result: *const c.Vizg_ProjectResult,
) callconv(.c) c.Vizg_ProjectStatus;
extern fn vizg_test_destroy_misaligned_handle() callconv(.c) void;
extern fn vizg_test_limit_kind_misaligned_handle() callconv(.c) u32;
extern fn vizg_test_add_oversized_source(
    project: *c.Vizg_Project,
) callconv(.c) c.Vizg_ProjectStatus;

fn projectSource(id: u64, name: []const u8, source: []const u8, is_root: bool) c.Vizg_ProjectSource {
    return .{
        .module_id = id,
        .logical_name_ptr = if (name.len == 0) null else name.ptr,
        .logical_name_len = name.len,
        .source_ptr = if (source.len == 0) null else source.ptr,
        .source_len = source.len,
        .kind = c.VIZG_PROJECT_SOURCE_MODULE,
        .is_root = @intFromBool(is_root),
        .reserved = .{ 0, 0, 0 },
    };
}

fn stepSpecifier(step: *const c.Vizg_ProjectStep) []const u8 {
    return if (step.specifier_len == 0) "" else step.specifier_ptr[0..step.specifier_len];
}

const Workspace = struct {
    words: []u64,

    fn init(bytes_len: usize) !Workspace {
        return .{ .words = try std.testing.allocator.alloc(u64, (bytes_len + 7) / 8) };
    }

    fn deinit(self: Workspace) void {
        std.testing.allocator.free(self.words);
    }

    fn config(self: Workspace) c.Vizg_ProjectConfig {
        return .{
            .workspace_ptr = @ptrCast(self.words.ptr),
            .workspace_len = self.words.len * @sizeOf(u64),
            .max_source_bytes = 1024 * 1024,
            .max_total_source_bytes = 16 * 1024 * 1024,
            .max_modules = 256,
            .max_requests = 1024,
            .max_edges = 1024,
            .max_diagnostics = 4096,
            .max_graph_depth = 128,
            .max_semantic_types = 65536,
        };
    }
};

fn createProject(workspace: Workspace) !*c.Vizg_Project {
    var config = workspace.config();
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    return project orelse error.MissingProject;
}

fn finishProject(project: *c.Vizg_Project) !*c.Vizg_ProjectResult {
    while (true) {
        var step: c.Vizg_ProjectStep = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
        if (step.kind == c.VIZG_PROJECT_STEP_COMPLETE) break;
        return error.UnexpectedRequest;
    }
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    return result orelse error.MissingProjectResult;
}

fn expectInvalid(status: c.Vizg_ProjectStatus) !void {
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), status);
}

test "official ABI v1 exposes version and a project-owned terminal result" {
    try std.testing.expectEqual(@as(u32, c.VIZG_ABI_VERSION), c.vizg_abi_version());
    try std.testing.expectEqual(@as(u32, c.VIZG_EXTERNAL_MODULE_API_VERSION), c.vizg_external_module_api_version());

    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);

    var root = projectSource(1, "root.ts", "export const value = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_COMPLETE), step.kind);

    var first: ?*c.Vizg_ProjectResult = null;
    var second: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &first));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &second));
    try std.testing.expectEqual(first, second);

    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(first, &summary));
    try std.testing.expectEqual(@as(usize, 1), summary.module_count);
    try std.testing.expectEqual(@as(usize, 1), summary.export_count);
    try std.testing.expectEqual(@as(u8, 0), summary.is_partial);
    try std.testing.expectEqual(@as(u8, 0), summary.has_syntax_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_semantic_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_project_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_module_failures);

    var module: c.Vizg_ProjectModuleInfo = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_module(first, 0, &module));
    try std.testing.expectEqual(@as(u64, 1), module.module_id);

    var late = projectSource(2, "late.ts", "export {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_add_source(project, &late));

    c.vizg_project_destroy(project);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_result_summary(first, &summary));
}

test "external module V4 preserves intrinsic identity under import renaming" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(
        1,
        "root.ts",
        "import { missing as renamed } from 'core'; export const value = renamed();",
        true,
    );
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqualStrings("core", stepSpecifier(&step));

    const undefined_ref: c.Vizg_ExternalTypeReferenceV3 = .{
        .kind = c.VIZG_EXTERNAL_TYPE_REFERENCE_BUILTIN,
        .builtin_type = c.VIZG_EXTERNAL_TYPE_UNDEFINED,
        .external_type_id = 0,
    };
    var export_desc: c.Vizg_ExternalExportV4 = .{
        .name_ptr = "missing".ptr,
        .name_len = "missing".len,
        .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
        .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
        .has_type_reference = 0,
        .has_function = 1,
        .has_intrinsic_id = 1,
        .reserved = 0,
        .type_reference = undefined_ref,
        .declaration_kind = c.VIZG_EXTERNAL_DECLARATION_FUNCTION,
        .effect_flags = 0,
        .reserved2 = 0,
        .external_symbol_id = 0x1001,
        .intrinsic_id = 0x0001,
        .function = .{
            .parameters_ptr = null,
            .parameter_count = 0,
            .return_type = undefined_ref,
            .type_parameter_count = 0,
            .is_async = 0,
            .is_generator = 0,
            .is_constructor = 0,
            .reserved = 0,
        },
    };
    var external: c.Vizg_ExternalModuleV4 = .{
        .external_module_id = 2,
        .logical_name_ptr = "core".ptr,
        .logical_name_len = "core".len,
        .exports_ptr = @ptrCast(&export_desc),
        .export_count = 1,
        .types_ptr = null,
        .type_count = 0,
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_external_v4(project, step.request_id, &external),
    );

    const result = try finishProject(project);
    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary));
    var found = false;
    for (0..summary.instruction_count) |index| {
        var payload: c.Vizg_HirPayload = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_operation_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, &payload),
        );
        if (payload.tag != c.VIZG_HIR_OPERATION_INTRINSIC_CALL) continue;
        try std.testing.expectEqual(@as(u64, 0x0001), payload.operand0);
        try std.testing.expectEqual(@as(usize, 0), payload.item_count);
        found = true;
    }
    try std.testing.expect(found);
}

test "ambient-global API v2 preserves recursive host identity" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const name = "globalThis";
    const host_binding_id: u64 = 0x4754;
    var member: c.Vizg_AmbientMember = .{
        .name_ptr = name.ptr,
        .name_len = name.len,
        .has_type_metadata = 0,
        .optional = 0,
        .readonly = 1,
        .self_reference = 1,
        .type_metadata = c.VIZG_EXTERNAL_TYPE_UNKNOWN,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    var global: c.Vizg_AmbientGlobalV2 = .{
        .name_ptr = name.ptr,
        .name_len = name.len,
        .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
        .has_type_metadata = 1,
        .type_metadata = c.VIZG_EXTERNAL_TYPE_OBJECT,
        .host_binding_id = host_binding_id,
        .members_ptr = &member,
        .member_count = 1,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_register_ambient_globals_v2(project, &global, 1),
    );

    var root = projectSource(1, "ambient.ts", "globalThis.globalThis;", true);
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_add_source(project, &root),
    );
    const result = try finishProject(project);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );
    var saw_host_binding = false;
    for (0..summary.binding_count) |index| {
        var binding: c.Vizg_HirBindingDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_binding_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &binding),
        );
        if (binding.has_host_binding_id != 0) {
            try std.testing.expectEqual(host_binding_id, binding.host_binding_id);
            saw_host_binding = true;
        }
    }
    try std.testing.expect(saw_host_binding);
}

test "source host binding C API preserves source declaration identity" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const name = "hostValue";
    const host_binding_id: u64 = 0x434f4e53;
    var binding: c.Vizg_SourceHostBinding = .{
        .name_ptr = name.ptr,
        .name_len = name.len,
        .host_binding_id = host_binding_id,
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_register_source_host_bindings(project, &binding, 1),
    );

    var root = projectSource(
        2,
        "source-host-binding.ts",
        "interface HostValue { invoke(value: number): void; } const hostValue: HostValue; hostValue;",
        true,
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_add_source(project, &root),
    );
    const result = try finishProject(project);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );
    var saw_host_binding = false;
    for (0..summary.binding_count) |index| {
        var detail: c.Vizg_HirBindingDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_binding_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        if (detail.has_host_binding_id != 0 and detail.host_binding_id == host_binding_id) {
            saw_host_binding = true;
        }
    }
    try std.testing.expect(saw_host_binding);
}

test "source language item C API resolves versioned deterministic HIR identities" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const name = "MovedSequence";
    var items = [_]c.Vizg_SourceLanguageItem{
        .{ .language_item_id = 2, .module_id = 52, .exported_name_ptr = name.ptr, .exported_name_len = name.len, .namespace_kind = c.VIZG_LANGUAGE_ITEM_NAMESPACE_TYPE, .reserved = .{ 0, 0, 0, 0 } },
        .{ .language_item_id = 1, .module_id = 52, .exported_name_ptr = name.ptr, .exported_name_len = name.len, .namespace_kind = c.VIZG_LANGUAGE_ITEM_NAMESPACE_VALUE, .reserved = .{ 0, 0, 0, 0 } },
    };
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_register_source_language_items(project, &items, items.len));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_register_source_language_items(project, &items[1], 1));

    var root = projectSource(52, "moved/std.ts", "export class MovedSequence<T> {}", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    const result = try finishProject(project);

    var count: usize = 0;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_hir_language_item_count(result, 4, &count));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_language_item_count(result, c.VIZG_HIR_DETAIL_API_VERSION, &count));
    try std.testing.expectEqual(@as(usize, 2), count);
    for (0..count) |index| {
        var item: c.Vizg_HirLanguageItem = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_language_item_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &item));
        try std.testing.expectEqual(@as(u64, index + 1), item.language_item_id);
        try std.testing.expectEqual(@as(u64, 52), item.target.declaration_module_id);
        try std.testing.expectEqualStrings(name, item.exported_name_ptr[0..item.exported_name_len]);
        var function_id: u64 = 0;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
            c.vizg_hir_language_item_function(result, 6, item.language_item_id, &function_id),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_language_item_function(result, c.VIZG_HIR_DETAIL_API_VERSION, item.language_item_id, &function_id),
        );
        try std.testing.expectEqual(c.VIZG_HIR_ID_NONE, function_id);
    }
}

test "HIR detail v7 exposes executable value language-item function identity" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const export_name = "definitelyNotNamedMaterializeSequence";
    var item = [_]c.Vizg_SourceLanguageItem{.{
        .language_item_id = 0x101,
        .module_id = 54,
        .exported_name_ptr = export_name.ptr,
        .exported_name_len = export_name.len,
        .namespace_kind = c.VIZG_LANGUAGE_ITEM_NAMESPACE_VALUE,
        .reserved = .{ 0, 0, 0, 0 },
    }};
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_register_source_language_items(project, &item, item.len),
    );
    var root = projectSource(
        54,
        "std/internal/array_protocol.ts",
        "export function definitelyNotNamedMaterializeSequence(value: number[]): number[] { return value; }",
        true,
    );
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    const result = try finishProject(project);

    var function_id: u64 = c.VIZG_HIR_ID_NONE;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_language_item_function(result, c.VIZG_HIR_DETAIL_API_VERSION, 0x101, &function_id),
    );
    try std.testing.expect(function_id != c.VIZG_HIR_ID_NONE);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );
    var found = false;
    for (0..summary.function_count) |index| {
        var record: c.Vizg_HirRecord = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_FUNCTION, index, &record),
        );
        if (record.id != function_id) continue;
        found = true;
        try std.testing.expectEqualStrings(export_name, record.name_ptr[0..record.name_len]);
    }
    try std.testing.expect(found);
}

test "missing source language item fails closed with a stable project diagnostic" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const name = "Missing";
    var item: c.Vizg_SourceLanguageItem = .{
        .language_item_id = 1,
        .module_id = 53,
        .exported_name_ptr = name.ptr,
        .exported_name_len = name.len,
        .namespace_kind = c.VIZG_LANGUAGE_ITEM_NAMESPACE_VALUE,
        .reserved = .{ 0, 0, 0, 0 },
    };
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_register_source_language_items(project, &item, 1));
    var root = projectSource(53, "invalid-std.ts", "export const Other = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    const result = try finishProject(project);

    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 1), summary.has_project_errors);
    var diagnostic: c.Vizg_ProjectDiagnostic = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_diagnostic(result, 0, &diagnostic));
    try std.testing.expectEqual(@as(u32, 8002), diagnostic.code);
    var count: usize = 0;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_hir_language_item_count(result, c.VIZG_HIR_DETAIL_API_VERSION, &count));
}

test "versioned C HIR consumer reads immutable result records" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var source = projectSource(
        17,
        "hir-consumer.ts",
        "const captured = 1; const values = [1, 2]; const holder = { values }; export function answer(value: number): number { const nested = () => captured + value; return holder.values[0] + nested(); }",
        true,
    );
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_analyze_source(&config, &source, &result),
    );
    defer c.vizg_project_result_destroy(result);

    try std.testing.expectEqual(@as(u32, c.VIZG_HIR_API_VERSION), c.vizg_hir_api_version());
    try std.testing.expectEqual(@as(u32, c.VIZG_HIR_PAYLOAD_API_VERSION), c.vizg_hir_payload_api_version());
    try std.testing.expectEqual(@as(u32, c.VIZG_HIR_DETAIL_API_VERSION), c.vizg_hir_detail_api_version());
    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );
    var legacy_summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, 1, &legacy_summary),
    );
    try std.testing.expectEqual(summary.instruction_count, legacy_summary.instruction_count);
    try std.testing.expectEqual(@as(usize, 1), summary.module_count);
    try std.testing.expect(summary.function_count > 0);
    try std.testing.expect(summary.block_count > 0);
    try std.testing.expect(summary.instruction_count > 0);
    try std.testing.expect(summary.binding_count > 0);
    try std.testing.expect(summary.type_count > 0);

    var record: c.Vizg_HirRecord = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_MODULE, 0, &record),
    );
    try std.testing.expectEqual(@as(c.Vizg_HirEntityKind, c.VIZG_HIR_ENTITY_MODULE), record.kind);
    try std.testing.expectEqual(@as(u64, 17), record.module_id);
    try std.testing.expectEqualStrings("hir-consumer.ts", record.name_ptr[0..record.name_len]);
    var module_detail: c.Vizg_HirModuleDetail = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_module_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, 0, &module_detail),
    );
    try std.testing.expectEqual(record.id, module_detail.module_id);
    try std.testing.expectEqual(@as(usize, 0), module_detail.dependency_count);
    try std.testing.expectEqual(@as(usize, 0), module_detail.import_count);
    try std.testing.expect(module_detail.export_count > 0);
    for (0..module_detail.export_count) |export_index| {
        var module_export: c.Vizg_HirModuleExport = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_module_export_at(result, c.VIZG_HIR_DETAIL_API_VERSION, 0, export_index, &module_export),
        );
        try std.testing.expect(module_export.exported_name_len > 0);
    }
    var function_signature_count: usize = 0;
    var rich_type_count: usize = 0;
    for (0..summary.type_count) |index| {
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_TYPE, index, &record),
        );
        try std.testing.expectEqual(@as(c.Vizg_HirEntityKind, c.VIZG_HIR_ENTITY_TYPE), record.kind);

        var detail: c.Vizg_HirTypeDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        try std.testing.expectEqual(@as(u32, @intCast(record.id)), detail.id);
        if (detail.kind == c.VIZG_HIR_TYPE_PRIMITIVE) {
            try std.testing.expect(detail.builtin_kind != c.VIZG_HIR_BUILTIN_NONE);
        } else if (detail.kind == c.VIZG_HIR_TYPE_FUNCTION) {
            var signature: c.Vizg_HirFunctionSignature = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_function_signature(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &signature),
            );
            try std.testing.expectEqual(detail.id, signature.type_id);
            for (0..signature.parameter_count) |parameter_index| {
                var parameter: c.Vizg_HirSignatureParameter = undefined;
                try std.testing.expectEqual(
                    @as(u32, c.VIZG_PROJECT_STATUS_OK),
                    c.vizg_hir_signature_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, parameter_index, &parameter),
                );
            }
            function_signature_count += 1;
        } else {
            try std.testing.expect(detail.kind >= c.VIZG_HIR_TYPE_PROMISE);
            try std.testing.expect(detail.kind <= c.VIZG_HIR_TYPE_APPLIED_GENERIC);
            try std.testing.expectEqual(@as(u32, c.VIZG_HIR_BUILTIN_NONE), detail.builtin_kind);
            rich_type_count += 1;
        }
    }
    try std.testing.expect(function_signature_count > 0);
    try std.testing.expect(rich_type_count > 0);
    for (0..summary.binding_count) |index| {
        var binding_detail: c.Vizg_HirBindingDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_binding_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &binding_detail),
        );
        try std.testing.expect(binding_detail.initial_state <= c.VIZG_HIR_BINDING_STATE_LIVE_IMPORT);
    }
    var saw_live_capture = false;
    var saw_named_answer = false;
    for (0..summary.function_count) |index| {
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_FUNCTION, index, &record),
        );
        if (std.mem.eql(u8, record.name_ptr[0..record.name_len], "answer")) saw_named_answer = true;
        var detail: c.Vizg_HirFunctionDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        try std.testing.expectEqual(record.id, detail.id);
        var storage: c.Vizg_HirFunctionStorageDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_storage_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &storage),
        );
        try std.testing.expectEqual(record.id, storage.id);
        for (0..storage.capture_count) |capture_index| {
            var capture: c.Vizg_HirFunctionCapture = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_function_capture_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, capture_index, &capture),
            );
            if (capture.source_kind == c.VIZG_HIR_CAPTURE_SOURCE_BINDING) {
                try std.testing.expect(capture.source_binding_id != c.VIZG_HIR_ID_NONE);
                try std.testing.expectEqual(@as(u32, c.VIZG_HIR_CAPTURE_MODE_LIVE_BINDING), capture.mode);
                saw_live_capture = true;
            }
        }

        for (0..detail.parameter_count) |parameter_index| {
            var parameter: c.Vizg_HirFunctionParameter = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_function_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, parameter_index, &parameter),
            );
            try std.testing.expect(parameter.argument_index < detail.parameter_count);
        }
    }
    try std.testing.expect(saw_named_answer);
    try std.testing.expect(saw_live_capture);
    var legacy_record: c.Vizg_HirRecord = undefined;
    for (0..summary.origin_count) |index| {
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_ORIGIN, index, &record),
        );
        if (record.flags & 1 == 0) {
            try std.testing.expectEqual(@as(u32, 0), record.type_id);
        }
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, 1, c.VIZG_HIR_ENTITY_ORIGIN, index, &legacy_record),
        );
        try std.testing.expectEqual(@as(u8, 0), legacy_record.flags);

        var detail: c.Vizg_HirOriginDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_origin_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        try std.testing.expectEqual(@as(u32, @intCast(index)), detail.id);
        try std.testing.expectEqual(record.module_id, detail.module_id);
        try std.testing.expect(detail.span_end >= detail.span_start);
        try std.testing.expectEqual(record.secondary_id, detail.span_start);
        try std.testing.expectEqual(record.type_id != 0, detail.flags & c.VIZG_HIR_ORIGIN_HAS_TYPE != 0);
    }
    var payload: c.Vizg_HirPayload = undefined;
    var item: c.Vizg_HirPayloadItem = undefined;
    for (0..summary.instruction_count) |index| {
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_INSTRUCTION, index, &record),
        );
        if (record.flags & 1 != 0) {
            try std.testing.expect(record.secondary_id != c.VIZG_HIR_ID_NONE);
        } else {
            try std.testing.expectEqual(@as(u64, c.VIZG_HIR_ID_NONE), record.secondary_id);
        }
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, 1, c.VIZG_HIR_ENTITY_INSTRUCTION, index, &legacy_record),
        );
        try std.testing.expect(legacy_record.secondary_id != c.VIZG_HIR_ID_NONE);
        try std.testing.expectEqual(record.parent_id, legacy_record.parent_id);
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_operation_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, &payload),
        );
        try std.testing.expectEqual(record.tag, payload.tag);
        for (0..payload.item_count) |item_index| {
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_operation_item_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, item_index, &item),
            );
        }
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
            c.vizg_hir_operation_item_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, payload.item_count, &item),
        );
    }
    for (0..summary.block_count) |index| {
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_BLOCK, index, &record),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_terminator_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, &payload),
        );
        try std.testing.expectEqual(record.tag, payload.tag);
        var detail: c.Vizg_HirBlockDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_block_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        try std.testing.expectEqual(record.id, detail.id);
        for (0..detail.parameter_count) |parameter_index| {
            var parameter: c.Vizg_HirBlockParameter = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_block_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, parameter_index, &parameter),
            );
        }
        for (0..payload.item_count) |item_index| {
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_terminator_item_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, item_index, &item),
            );
        }
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
            c.vizg_hir_terminator_item_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, index, payload.item_count, &item),
        );
    }
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_MODULE, summary.module_count, &record),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION + 1, &summary),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_summary(result, 0, &summary),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_operation_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION + 1, 0, &payload),
    );
    var detail: c.Vizg_HirTypeDetail = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, summary.type_count, &detail),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION + 1, 0, &detail),
    );
}

test "HIR detail v6 exposes ordered semantic class composition" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var source = projectSource(
        71,
        "class-detail.ts",
        \\export class Box {
        \\  value: number = 1;
        \\  static tag: number = 2;
        \\  constructor(value: number) { this.value = value; }
        \\  read(): number { return this.value; }
        \\  static create(): number { return 1; }
        \\  get current(): number { return this.value; }
        \\}
    ,
        true,
    );
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_analyze_source(&config, &source, &result),
    );
    defer c.vizg_project_result_destroy(result);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );
    var entity_id: ?u64 = null;
    for (0..summary.instruction_count) |instruction_index| {
        var operation: c.Vizg_HirPayload = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_operation_at(result, c.VIZG_HIR_PAYLOAD_API_VERSION, instruction_index, &operation),
        );
        if (operation.tag == c.VIZG_HIR_OPERATION_CREATE_CLASS) entity_id = operation.operand0;
    }
    const class_entity = entity_id orelse return error.MissingClassEntity;

    var detail: c.Vizg_HirClassDetail = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_class_detail(result, 5, class_entity, &detail),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_class_detail(result, c.VIZG_HIR_DETAIL_API_VERSION, class_entity, &detail),
    );
    try std.testing.expectEqual(class_entity, detail.entity_id);
    try std.testing.expectEqual(@as(u64, 71), detail.module_id);
    try std.testing.expect(detail.constructor_function_id != c.VIZG_HIR_ID_NONE);
    try std.testing.expect(detail.instance_initializer_function_id != c.VIZG_HIR_ID_NONE);
    try std.testing.expect(detail.static_initializer_function_id != c.VIZG_HIR_ID_NONE);
    try std.testing.expectEqual(@as(usize, 3), detail.method_count);

    const expected_names = [_][]const u8{ "read", "create", "current" };
    const expected_kinds = [_]u32{
        c.VIZG_HIR_FUNCTION_METHOD,
        c.VIZG_HIR_FUNCTION_METHOD,
        c.VIZG_HIR_FUNCTION_GETTER,
    };
    for (expected_names, expected_kinds, 0..) |expected_name, expected_kind, method_index| {
        var method: c.Vizg_HirClassMethod = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_class_method_at(result, c.VIZG_HIR_DETAIL_API_VERSION, class_entity, method_index, &method),
        );
        try std.testing.expectEqualStrings(expected_name, method.name_ptr[0..method.name_len]);
        try std.testing.expectEqual(expected_kind, method.kind);
        try std.testing.expect(method.function_id != c.VIZG_HIR_ID_NONE);
        try std.testing.expectEqual(@as(u8, @intFromBool(method_index == 1)), method.flags & 1);
    }
    var method: c.Vizg_HirClassMethod = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_hir_class_method_at(result, c.VIZG_HIR_DETAIL_API_VERSION, class_entity, detail.method_count, &method),
    );
}

test "HIR detail ABI exposes async and generator body completion types" {
    const Helpers = struct {
        fn typeKind(
            result: ?*const c.Vizg_ProjectResult,
            count: usize,
            type_id: u32,
        ) !u32 {
            for (0..count) |index| {
                var detail: c.Vizg_HirTypeDetail = undefined;
                try std.testing.expectEqual(
                    @as(u32, c.VIZG_PROJECT_STATUS_OK),
                    c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
                );
                if (detail.id == type_id) return detail.kind;
            }
            return error.MissingType;
        }
    };

    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var source = projectSource(
        18,
        "completion-types.ts",
        "async function wait(value: any): any { return await value; } function* sequence(value: any): any { yield value; return value; } async function* combined(value: any): any { yield await value; return value; }",
        true,
    );
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_analyze_source(&config, &source, &result),
    );
    defer c.vizg_project_result_destroy(result);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary),
    );

    var suspension_signatures: usize = 0;
    var first_suspension_type: ?u32 = null;
    for (0..summary.type_count) |index| {
        var detail: c.Vizg_HirTypeDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail),
        );
        if (detail.kind != c.VIZG_HIR_TYPE_FUNCTION) continue;

        var signature: c.Vizg_HirFunctionSignature = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_signature(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &signature),
        );
        const is_async = signature.flags & c.VIZG_HIR_SIGNATURE_ASYNC != 0;
        const is_generator = signature.flags & c.VIZG_HIR_SIGNATURE_GENERATOR != 0;
        if (!is_async and !is_generator) continue;

        var completion_type: u32 = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_completion_type(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &completion_type),
        );
        try std.testing.expect(completion_type != signature.return_type_id);
        try std.testing.expectEqual(
            @as(u32, c.VIZG_HIR_TYPE_PRIMITIVE),
            try Helpers.typeKind(result, summary.type_count, completion_type),
        );
        try std.testing.expectEqual(
            @as(u32, if (is_generator) c.VIZG_HIR_TYPE_GENERATOR else c.VIZG_HIR_TYPE_PROMISE),
            try Helpers.typeKind(result, summary.type_count, signature.return_type_id),
        );
        first_suspension_type = first_suspension_type orelse detail.id;
        suspension_signatures += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), suspension_signatures);

    try expectInvalid(c.vizg_hir_function_completion_type(
        result,
        c.VIZG_HIR_DETAIL_API_VERSION,
        first_suspension_type.?,
        null,
    ));
    var completion_type: u32 = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_function_completion_type(result, c.VIZG_HIR_DETAIL_API_VERSION + 1, first_suspension_type.?, &completion_type),
    );
}

test "HIR detail ABI exposes structured exception regions" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var source = projectSource(
        223,
        "exception-regions.ts",
        \\export function guarded(flag: boolean): number {
        \\  try {
        \\    if (flag) throw 1;
        \\    return 2;
        \\  } catch (caughtValue) {
        \\    throw caughtValue;
        \\  } finally {
        \\    if (flag) return 3;
        \\  }
        \\}
    ,
        true,
    );
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_analyze_source(&config, &source, &result),
    );
    defer c.vizg_project_result_destroy(result);

    var region_count: usize = 0;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_region_count(result, c.VIZG_HIR_DETAIL_API_VERSION, &region_count),
    );
    try std.testing.expect(region_count >= 2);

    var saw_catch = false;
    var saw_finally = false;
    for (0..region_count) |region_index| {
        var detail: c.Vizg_HirRegionDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_region_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, region_index, &detail),
        );
        try std.testing.expect(detail.id != c.VIZG_HIR_ID_NONE);
        try std.testing.expect(detail.function_id != c.VIZG_HIR_ID_NONE);
        try std.testing.expect(detail.handler_block_id != c.VIZG_HIR_ID_NONE);
        try std.testing.expect(detail.protected_block_count > 0);
        try std.testing.expectEqual(
            detail.flags & c.VIZG_HIR_REGION_HAS_PARENT != 0,
            detail.parent_region_id != c.VIZG_HIR_ID_NONE,
        );
        try std.testing.expectEqual(
            detail.flags & c.VIZG_HIR_REGION_HAS_CONTINUATION != 0,
            detail.continuation_block_id != c.VIZG_HIR_ID_NONE,
        );
        switch (detail.kind) {
            c.VIZG_HIR_REGION_CATCH => saw_catch = true,
            c.VIZG_HIR_REGION_FINALLY => saw_finally = true,
            c.VIZG_HIR_REGION_ITERATOR_CLOSE => {},
            else => return error.UnknownRegionKind,
        }
        for (0..detail.protected_block_count) |protected_index| {
            var block_id: u64 = c.VIZG_HIR_ID_NONE;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_region_protected_block_at(result, c.VIZG_HIR_DETAIL_API_VERSION, region_index, protected_index, &block_id),
            );
            try std.testing.expect(block_id != c.VIZG_HIR_ID_NONE);
        }
        var invalid_block_id: u64 = 0;
        try expectInvalid(c.vizg_hir_region_protected_block_at(
            result,
            c.VIZG_HIR_DETAIL_API_VERSION,
            region_index,
            detail.protected_block_count,
            &invalid_block_id,
        ));
    }
    try std.testing.expect(saw_catch);
    try std.testing.expect(saw_finally);

    var invalid_detail: c.Vizg_HirRegionDetail = undefined;
    try expectInvalid(c.vizg_hir_region_detail_at(
        result,
        c.VIZG_HIR_DETAIL_API_VERSION,
        region_count,
        &invalid_detail,
    ));
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_region_count(result, c.VIZG_HIR_DETAIL_API_VERSION + 1, &region_count),
    );
}

test "official ABI v1 drives source and external host responses" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const root_text =
        \\import { x } from "./dep";
        \\import { log } from "runtime";
        \\export const y = x;
    ;
    var root = projectSource(1, "root.ts", root_text, true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    while (true) {
        var next: c.Vizg_ProjectStep = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &next));
        if (next.kind == c.VIZG_PROJECT_STEP_COMPLETE) break;
        const specifier = stepSpecifier(&next);
        if (std.mem.eql(u8, specifier, "./dep")) {
            var dep = projectSource(2, "dep.ts", "export const x: number = 1;", false);
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(project, next.request_id, &dep));
        } else if (std.mem.eql(u8, specifier, "runtime")) {
            const export_name = "log";
            var export_desc: c.Vizg_ExternalExport = .{
                .name_ptr = export_name.ptr,
                .name_len = export_name.len,
                .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
                .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
                .has_type_metadata = 1,
                .reserved = .{ 0, 0 },
                .type_metadata = c.VIZG_EXTERNAL_TYPE_UNKNOWN,
            };
            var external: c.Vizg_ExternalModule = .{
                .external_module_id = 80,
                .logical_name_ptr = "runtime".ptr,
                .logical_name_len = "runtime".len,
                .exports_ptr = &export_desc,
                .export_count = 1,
            };
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(project, next.request_id, &external));
        } else return error.UnexpectedRequest;
    }

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(usize, 2), summary.module_count);
    try std.testing.expect(summary.edge_count >= 2);
}

test "external-module API v2 publishes stable function declarations to HIR" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import { log } from 'runtime'; export const value = log(1);", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    try std.testing.expectEqualStrings("runtime", stepSpecifier(&step));

    const parameter_name = "value";
    var parameter: c.Vizg_ExternalParameterV2 = .{
        .name_ptr = parameter_name.ptr,
        .name_len = parameter_name.len,
        .type_metadata = c.VIZG_EXTERNAL_TYPE_NUMBER,
        .optional = 0,
        .has_default = 0,
        .rest = 0,
        .reserved = 0,
    };
    const export_name = "log";
    var export_desc: c.Vizg_ExternalExportV2 = .{
        .name_ptr = export_name.ptr,
        .name_len = export_name.len,
        .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
        .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
        .has_type_metadata = 0,
        .has_function = 1,
        .reserved = 0,
        .type_metadata = c.VIZG_EXTERNAL_TYPE_UNKNOWN,
        .declaration_kind = c.VIZG_EXTERNAL_DECLARATION_FUNCTION,
        .effect_flags = c.VIZG_EXTERNAL_EFFECT_ALLOCATES | c.VIZG_EXTERNAL_EFFECT_IO | c.VIZG_EXTERNAL_EFFECT_ASYNC,
        .reserved2 = 0,
        .external_symbol_id = 0x7100,
        .function = .{
            .parameters_ptr = &parameter,
            .parameter_count = 1,
            .return_type = c.VIZG_EXTERNAL_TYPE_VOID,
            .type_parameter_count = 0,
            .is_async = 0,
            .is_generator = 0,
            .is_constructor = 0,
            .reserved = 0,
        },
    };
    var external: c.Vizg_ExternalModuleV2 = .{
        .external_module_id = 80,
        .logical_name_ptr = "runtime".ptr,
        .logical_name_len = "runtime".len,
        .exports_ptr = &export_desc,
        .export_count = 1,
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_external_v2(project, step.request_id, &external),
    );

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 0), summary.is_partial);

    var hir_summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &hir_summary),
    );
    try std.testing.expectEqual(@as(usize, 1), hir_summary.external_declaration_count);
    var declaration: c.Vizg_HirRecord = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_EXTERNAL_DECLARATION, 0, &declaration),
    );
    try std.testing.expectEqual(@as(u16, (1 << 3) | (1 << 4) | (1 << 5)), declaration.effect_bits);

    var external_detail: c.Vizg_HirExternalDeclarationDetail = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_external_declaration_detail_at(result, 3, 0, &external_detail),
    );
    try std.testing.expectEqual(@as(u64, 80), external_detail.module_id);
    try std.testing.expectEqual(@as(u64, 0x7100), external_detail.symbol_id);
    try std.testing.expectEqual(@as(u64, 0), external_detail.intrinsic_id);
    try std.testing.expectEqual(@as(u8, 0), external_detail.flags);
    try std.testing.expectEqualStrings("log", external_detail.exported_name_ptr[0..external_detail.exported_name_len]);
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_external_declaration_detail_at(result, 2, 0, &external_detail),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
        c.vizg_hir_external_declaration_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION + 1, 0, &external_detail),
    );
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_hir_external_declaration_detail_at(result, 3, 1, &external_detail),
    );

    var module_detail: c.Vizg_HirModuleDetail = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_module_detail_at(result, 2, 0, &module_detail),
    );
    try std.testing.expect(module_detail.import_count > 0);
    var saw_external_live_import = false;
    for (0..module_detail.import_count) |import_index| {
        var module_import: c.Vizg_HirModuleImport = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_module_import_at(result, c.VIZG_HIR_DETAIL_API_VERSION, 0, import_index, &module_import),
        );
        if (module_import.source_kind != c.VIZG_HIR_MODULE_REFERENCE_EXTERNAL) continue;
        try std.testing.expectEqual(@as(u64, 80), module_import.source_id);
        try std.testing.expectEqual(@as(u64, 80), module_import.target.external_module_id);
        try std.testing.expectEqual(@as(u64, 0x7100), module_import.target.external_symbol_id);
        try std.testing.expect(module_import.local_binding_id != c.VIZG_HIR_U32_NONE);
        for (0..hir_summary.binding_count) |binding_index| {
            var binding: c.Vizg_HirBindingDetail = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_binding_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, binding_index, &binding),
            );
            if (binding.id == module_import.local_binding_id) {
                try std.testing.expectEqual(@as(u8, c.VIZG_HIR_BINDING_STATE_LIVE_IMPORT), binding.initial_state);
                saw_external_live_import = true;
            }
        }
    }
    try std.testing.expect(saw_external_live_import);
}

test "external-module API v3 publishes ordered structural record types and signature references" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(
        1,
        "root.ts",
        "import { Fade } from 'raylib.h'; export const faded = Fade({ r: 1, g: 2, b: 3, a: 255 }, 0.5);",
        true,
    );
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqualStrings("raylib.h", stepSpecifier(&step));

    const number_ref: c.Vizg_ExternalTypeReferenceV3 = .{
        .kind = c.VIZG_EXTERNAL_TYPE_REFERENCE_BUILTIN,
        .builtin_type = c.VIZG_EXTERNAL_TYPE_NUMBER,
        .external_type_id = 0,
    };
    const color_ref: c.Vizg_ExternalTypeReferenceV3 = .{
        .kind = c.VIZG_EXTERNAL_TYPE_REFERENCE_DECLARED,
        .builtin_type = c.VIZG_EXTERNAL_TYPE_UNKNOWN,
        .external_type_id = 0xC010,
    };
    var members = [_]c.Vizg_ExternalTypeMemberV3{
        .{ .name_ptr = "r".ptr, .name_len = 1, .type_reference = number_ref, .optional = 0, .readonly = 0, .reserved = .{ 0, 0, 0, 0, 0, 0 } },
        .{ .name_ptr = "g".ptr, .name_len = 1, .type_reference = number_ref, .optional = 0, .readonly = 0, .reserved = .{ 0, 0, 0, 0, 0, 0 } },
        .{ .name_ptr = "b".ptr, .name_len = 1, .type_reference = number_ref, .optional = 0, .readonly = 0, .reserved = .{ 0, 0, 0, 0, 0, 0 } },
        .{ .name_ptr = "a".ptr, .name_len = 1, .type_reference = number_ref, .optional = 0, .readonly = 0, .reserved = .{ 0, 0, 0, 0, 0, 0 } },
    };
    var types_ = [_]c.Vizg_ExternalTypeV3{.{
        .external_type_id = 0xC010,
        .name_ptr = "Color".ptr,
        .name_len = "Color".len,
        .members_ptr = &members,
        .member_count = members.len,
    }};
    var parameters = [_]c.Vizg_ExternalParameterV3{
        .{ .name_ptr = "color".ptr, .name_len = "color".len, .type_reference = color_ref, .optional = 0, .has_default = 0, .rest = 0, .reserved = .{ 0, 0, 0, 0, 0 } },
        .{ .name_ptr = "alpha".ptr, .name_len = "alpha".len, .type_reference = number_ref, .optional = 0, .has_default = 0, .rest = 0, .reserved = .{ 0, 0, 0, 0, 0 } },
    };
    const no_function = std.mem.zeroes(c.Vizg_ExternalFunctionV3);
    var exports = [_]c.Vizg_ExternalExportV3{
        .{
            .name_ptr = "Color".ptr,
            .name_len = "Color".len,
            .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
            .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_TYPE,
            .has_type_reference = 1,
            .has_function = 0,
            .reserved = 0,
            .type_reference = color_ref,
            .declaration_kind = c.VIZG_EXTERNAL_DECLARATION_TYPE,
            .effect_flags = c.VIZG_EXTERNAL_EFFECT_UNKNOWN,
            .reserved2 = 0,
            .external_symbol_id = 0xC011,
            .function = no_function,
        },
        .{
            .name_ptr = "Fade".ptr,
            .name_len = "Fade".len,
            .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
            .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
            .has_type_reference = 0,
            .has_function = 1,
            .reserved = 0,
            .type_reference = number_ref,
            .declaration_kind = c.VIZG_EXTERNAL_DECLARATION_FUNCTION,
            .effect_flags = c.VIZG_EXTERNAL_EFFECT_UNKNOWN,
            .reserved2 = 0,
            .external_symbol_id = 0xFADE,
            .function = .{
                .parameters_ptr = &parameters,
                .parameter_count = parameters.len,
                .return_type = color_ref,
                .type_parameter_count = 0,
                .is_async = 0,
                .is_generator = 0,
                .is_constructor = 0,
                .reserved = 0,
            },
        },
    };
    var external: c.Vizg_ExternalModuleV3 = .{
        .external_module_id = 81,
        .logical_name_ptr = "raylib.h".ptr,
        .logical_name_len = "raylib.h".len,
        .exports_ptr = &exports,
        .export_count = exports.len,
        .types_ptr = &types_,
        .type_count = types_.len,
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_external_v3(project, step.request_id, &external),
    );

    const result = try finishProject(project);
    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary));
    var found_color = false;
    for (0..summary.type_count) |index| {
        var detail: c.Vizg_HirTypeDetail = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail));
        if (detail.kind != c.VIZG_HIR_TYPE_OBJECT) continue;
        var member_count: usize = 0;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_type_member_count(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &member_count));
        if (member_count != members.len) continue;
        var identity: c.Vizg_HirExternalTypeIdentity = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_external_type_identity(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &identity),
        );
        try std.testing.expectEqual(detail.id, identity.type_id);
        try std.testing.expectEqual(@as(u32, c.VIZG_HIR_EXTERNAL_TYPE_HAS_IDENTITY), identity.flags);
        try std.testing.expectEqual(@as(u64, 81), identity.external_module_id);
        try std.testing.expectEqual(@as(u64, 0xC010), identity.external_type_id);
        const expected_names = [_][]const u8{ "r", "g", "b", "a" };
        for (expected_names, 0..) |expected, member_index| {
            var member: c.Vizg_HirTypeMember = undefined;
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_type_member_at(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, member_index, &member));
            try std.testing.expectEqualStrings(expected, member.name_ptr[0..member.name_len]);
            try std.testing.expectEqual(@as(u8, 0), member.flags);
        }
        found_color = true;
        break;
    }
    try std.testing.expect(found_color);
}

test "HIR detail publishes narrowed default parameter values and rest array elements" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(
        1,
        "parameters.ts",
        "export function power(value: number, exponent = 2, ...rest: number[]): number { return value ** exponent; }",
        true,
    );
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    const result = try finishProject(project);
    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary));

    var found = false;
    for (0..summary.function_count) |function_index| {
        var detail: c.Vizg_HirFunctionDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, function_index, &detail),
        );
        if (detail.parameter_count != 3) continue;
        var function_record: c.Vizg_HirRecord = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_record_at(result, c.VIZG_HIR_API_VERSION, c.VIZG_HIR_ENTITY_FUNCTION, function_index, &function_record),
        );
        var signature_parameter: c.Vizg_HirSignatureParameter = undefined;
        var value_parameter: c.Vizg_HirFunctionParameter = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_signature_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, function_record.type_id, 1, &signature_parameter),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, function_index, 1, &value_parameter),
        );
        try std.testing.expect(signature_parameter.flags & (1 << 1) != 0);
        try std.testing.expect(value_parameter.flags & (1 << 1) != 0);
        try std.testing.expectEqual(signature_parameter.type_id, value_parameter.type_id);

        var rest_parameter: c.Vizg_HirFunctionParameter = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_function_parameter_at(result, c.VIZG_HIR_DETAIL_API_VERSION, function_index, 2, &rest_parameter),
        );
        var element_type_id: u32 = 0;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_array_element_type(result, c.VIZG_HIR_DETAIL_API_VERSION, rest_parameter.type_id, &element_type_id),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
            c.vizg_hir_array_element_type(result, c.VIZG_HIR_DETAIL_API_VERSION, value_parameter.type_id, &element_type_id),
        );

        var saw_default_number = false;
        var saw_element_number = false;
        for (0..summary.type_count) |type_index| {
            var type_detail: c.Vizg_HirTypeDetail = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, type_index, &type_detail),
            );
            if (type_detail.id == value_parameter.type_id)
                saw_default_number = type_detail.kind == c.VIZG_HIR_TYPE_PRIMITIVE and type_detail.builtin_kind == c.VIZG_HIR_BUILTIN_NUMBER;
            if (type_detail.id == element_type_id)
                saw_element_number = type_detail.kind == c.VIZG_HIR_TYPE_PRIMITIVE and type_detail.builtin_kind == c.VIZG_HIR_BUILTIN_NUMBER;
        }
        try std.testing.expect(saw_default_number);
        try std.testing.expect(saw_element_number);
        found = true;
        break;
    }
    try std.testing.expect(found);
}

test "HIR detail ABI preserves source module initialization and live imports" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import { value } from './dep'; export const answer = value;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    try std.testing.expectEqualStrings("./dep", stepSpecifier(&step));
    var dependency = projectSource(2, "dep.ts", "export let value: number = 1;", false);
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_source(project, step.request_id, &dependency),
    );

    const result = try finishProject(project);
    var hir_summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &hir_summary),
    );
    try std.testing.expectEqual(@as(usize, 2), hir_summary.module_count);

    var saw_source_import = false;
    var saw_initialization_dependency = false;
    var saw_live_import = false;
    for (0..hir_summary.module_count) |module_index| {
        var detail: c.Vizg_HirModuleDetail = undefined;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_OK),
            c.vizg_hir_module_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, module_index, &detail),
        );
        for (0..detail.dependency_count) |dependency_index| {
            var module_dependency: c.Vizg_HirModuleDependency = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_module_dependency_at(result, c.VIZG_HIR_DETAIL_API_VERSION, module_index, dependency_index, &module_dependency),
            );
            saw_initialization_dependency = saw_initialization_dependency or module_dependency.initialization_required != 0;
        }
        for (0..detail.import_count) |import_index| {
            var module_import: c.Vizg_HirModuleImport = undefined;
            try std.testing.expectEqual(
                @as(u32, c.VIZG_PROJECT_STATUS_OK),
                c.vizg_hir_module_import_at(result, c.VIZG_HIR_DETAIL_API_VERSION, module_index, import_index, &module_import),
            );
            if (module_import.source_kind != c.VIZG_HIR_MODULE_REFERENCE_SOURCE) continue;
            try std.testing.expectEqual(@as(u64, 2), module_import.source_id);
            saw_source_import = true;
            for (0..hir_summary.binding_count) |binding_index| {
                var binding: c.Vizg_HirBindingDetail = undefined;
                try std.testing.expectEqual(
                    @as(u32, c.VIZG_PROJECT_STATUS_OK),
                    c.vizg_hir_binding_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, binding_index, &binding),
                );
                if (binding.id == module_import.local_binding_id) {
                    try std.testing.expectEqual(@as(u8, c.VIZG_HIR_BINDING_STATE_LIVE_IMPORT), binding.initial_state);
                    saw_live_import = true;
                }
            }
        }
    }
    try std.testing.expect(saw_source_import);
    try std.testing.expect(saw_initialization_dependency);
    try std.testing.expect(saw_live_import);
}

test "external-module API v2 accepts null pointers for empty arrays" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import 'empty'; export const value = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    try std.testing.expectEqualStrings("empty", stepSpecifier(&step));

    var external: c.Vizg_ExternalModuleV2 = .{
        .external_module_id = 81,
        .logical_name_ptr = "empty".ptr,
        .logical_name_len = "empty".len,
        .exports_ptr = null,
        .export_count = 0,
    };
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_external_v2(project, step.request_id, &external),
    );

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 0), summary.is_partial);
}

test "official ABI v1 reports unresolved modules through the result" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import value from 'missing'; export default value;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(project, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 1), summary.has_module_failures);
    try std.testing.expect(summary.diagnostic_count > 0);
}

test "official ABI v1 marks a failed side-effect import partial" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import './missing';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    try std.testing.expectEqualStrings("./missing", stepSpecifier(&step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(project, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND));

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 1), summary.has_module_failures);
    try std.testing.expectEqual(@as(u8, 1), summary.is_partial);
    try std.testing.expectEqual(@as(u8, 0), summary.has_syntax_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_semantic_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_project_errors);
}

test "official ABI v1 syntax and checker errors set their exact summary groups" {
    const cases = [_]struct {
        source: []const u8,
        syntax: u8,
        semantic: u8,
    }{
        .{ .source = "@", .syntax = 1, .semantic = 0 },
        .{ .source = "const x: string = 1;", .syntax = 0, .semantic = 1 },
    };
    for (cases, 0..) |fixture, index| {
        var workspace = try Workspace.init(8 * 1024 * 1024);
        defer workspace.deinit();
        const project = try createProject(workspace);
        defer c.vizg_project_destroy(project);

        var root = projectSource(index + 1, "summary.ts", fixture.source, true);
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
        const result = try finishProject(project);
        var summary: c.Vizg_ProjectResultSummary = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
        try std.testing.expectEqual(fixture.syntax, summary.has_syntax_errors);
        try std.testing.expectEqual(fixture.semantic, summary.has_semantic_errors);
        try std.testing.expectEqual(@as(u8, 0), summary.has_project_errors);
        try std.testing.expectEqual(@as(u8, 0), summary.has_module_failures);
        try std.testing.expectEqual(@as(u8, 1), summary.is_partial);
    }
}

test "official ABI v1 project linking error sets only the project summary group" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(3, "root.ts", "import { requested } from 'external'; export { requested };", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_REQUEST), step.kind);
    var external: c.Vizg_ExternalModule = .{
        .external_module_id = 81,
        .logical_name_ptr = "external".ptr,
        .logical_name_len = "external".len,
        .exports_ptr = null,
        .export_count = 0,
    };
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(project, step.request_id, &external));

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(u8, 0), summary.has_syntax_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_semantic_errors);
    try std.testing.expectEqual(@as(u8, 1), summary.has_project_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_module_failures);
    try std.testing.expectEqual(@as(u8, 1), summary.is_partial);
}

test "official ABI v1 exposes only reachable modules and explicit import export provenance" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const root_text =
        \\import { nativeValue } from "runtime";
        \\export { value as forwarded } from "./dep";
        \\export { nativeValue as externalForwarded } from "runtime-reexport";
        \\export const local = nativeValue;
    ;
    var root = projectSource(1, "root.ts", root_text, true);
    var unused = projectSource(99, "unused.ts", "import './never'; export {};", false);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &unused));

    while (true) {
        var step: c.Vizg_ProjectStep = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
        if (step.kind == c.VIZG_PROJECT_STEP_COMPLETE) break;
        const specifier = stepSpecifier(&step);
        if (std.mem.eql(u8, specifier, "runtime")) {
            var native_export: c.Vizg_ExternalExport = .{
                .name_ptr = "nativeValue".ptr,
                .name_len = "nativeValue".len,
                .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
                .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
                .has_type_metadata = 0,
                .reserved = .{ 0, 0 },
                .type_metadata = 0,
            };
            var external: c.Vizg_ExternalModule = .{
                .external_module_id = 77,
                .logical_name_ptr = "runtime".ptr,
                .logical_name_len = "runtime".len,
                .exports_ptr = &native_export,
                .export_count = 1,
            };
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(project, step.request_id, &external));
        } else if (std.mem.eql(u8, specifier, "runtime-reexport")) {
            var native_export: c.Vizg_ExternalExport = .{
                .name_ptr = "nativeValue".ptr,
                .name_len = "nativeValue".len,
                .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
                .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
                .has_type_metadata = 0,
                .reserved = .{ 0, 0 },
                .type_metadata = 0,
            };
            var external: c.Vizg_ExternalModule = .{
                .external_module_id = 78,
                .logical_name_ptr = "runtime-reexport".ptr,
                .logical_name_len = "runtime-reexport".len,
                .exports_ptr = &native_export,
                .export_count = 1,
            };
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(project, step.request_id, &external));
        } else if (std.mem.eql(u8, specifier, "./dep")) {
            var dep = projectSource(2, "dep.ts", "export const value = 1;", false);
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(project, step.request_id, &dep));
        } else return error.UnexpectedRequest;
    }

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    const view = result orelse return error.MissingProjectResult;
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(view, &summary));
    try std.testing.expectEqual(@as(usize, 2), summary.module_count);
    try std.testing.expectEqual(@as(u8, 0), summary.has_module_failures);

    for (0..summary.module_count) |index| {
        var module: c.Vizg_ProjectModuleInfo = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_module(view, index, &module));
        try std.testing.expect(module.module_id != 99);
    }
    for (0..summary.diagnostic_count) |index| {
        var diagnostic: c.Vizg_ProjectDiagnostic = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_diagnostic(view, index, &diagnostic));
        try std.testing.expect(diagnostic.has_module_id == 0 or diagnostic.module_id != 99);
    }
    for (0..summary.edge_count) |index| {
        var edge: c.Vizg_ProjectEdgeInfo = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_edge(view, index, &edge));
        try std.testing.expect(edge.importer_module_id != 99);
    }

    var saw_external_import = false;
    for (0..summary.import_count) |index| {
        var item: c.Vizg_ProjectImportInfo = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_import(view, index, &item));
        try std.testing.expect(item.module_id != 99);
        if (!std.mem.eql(u8, item.local_name_ptr[0..item.local_name_len], "nativeValue")) continue;
        try std.testing.expectEqual(@as(u8, 0), item.has_target_module);
        try std.testing.expectEqual(@as(u8, 1), item.has_external_target);
        try std.testing.expectEqual(@as(u64, 77), item.external_module_id);
        try std.testing.expectEqual(@as(u8, 1), item.has_edge_index);
        try std.testing.expect(item.edge_index < summary.edge_count);
        var source_edge: c.Vizg_ProjectEdgeInfo = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_edge(view, item.edge_index, &source_edge));
        try std.testing.expectEqual(@as(u64, 1), source_edge.importer_module_id);
        try std.testing.expectEqual(@as(u8, 1), source_edge.has_external_target);
        try std.testing.expectEqual(@as(u64, 77), source_edge.external_module_id);
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_REQUEST_STATIC_IMPORT), source_edge.request_operation);
        try std.testing.expectEqualStrings("runtime", source_edge.specifier_ptr[0..source_edge.specifier_len]);
        saw_external_import = true;
    }
    try std.testing.expect(saw_external_import);

    var saw_local_re_export = false;
    var saw_external_re_export = false;
    for (0..summary.export_count) |index| {
        var item: c.Vizg_ProjectExportInfo = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_export(view, index, &item));
        try std.testing.expect(item.module_id != 99);
        if (item.module_id != 1) continue;
        if (std.mem.eql(u8, item.name_ptr[0..item.name_len], "forwarded")) {
            try std.testing.expectEqual(@as(u8, 1), item.re_export);
            try std.testing.expectEqual(@as(u8, 1), item.has_target_module);
            try std.testing.expectEqual(@as(u64, 2), item.target_module_id);
            try std.testing.expectEqual(@as(u8, 0), item.has_external_target);
            try std.testing.expectEqual(@as(u8, 1), item.has_edge_index);
            try std.testing.expect(item.edge_index < summary.edge_count);
            var source_edge: c.Vizg_ProjectEdgeInfo = undefined;
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_edge(view, item.edge_index, &source_edge));
            try std.testing.expectEqual(@as(u64, 1), source_edge.importer_module_id);
            try std.testing.expectEqual(@as(u8, 1), source_edge.has_target_module);
            try std.testing.expectEqual(@as(u64, 2), source_edge.target_module_id);
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_REQUEST_RE_EXPORT), source_edge.request_operation);
            try std.testing.expectEqualStrings("./dep", source_edge.specifier_ptr[0..source_edge.specifier_len]);
            saw_local_re_export = true;
        } else if (std.mem.eql(u8, item.name_ptr[0..item.name_len], "externalForwarded")) {
            try std.testing.expectEqual(@as(u8, 1), item.re_export);
            try std.testing.expectEqual(@as(u8, 0), item.has_target_module);
            try std.testing.expectEqual(@as(u8, 1), item.has_external_target);
            try std.testing.expectEqual(@as(u64, 78), item.external_module_id);
            try std.testing.expectEqual(@as(u8, 1), item.has_edge_index);
            try std.testing.expect(item.edge_index < summary.edge_count);
            var source_edge: c.Vizg_ProjectEdgeInfo = undefined;
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_edge(view, item.edge_index, &source_edge));
            try std.testing.expectEqual(@as(u64, 1), source_edge.importer_module_id);
            try std.testing.expectEqual(@as(u8, 0), source_edge.has_target_module);
            try std.testing.expectEqual(@as(u8, 1), source_edge.has_external_target);
            try std.testing.expectEqual(@as(u64, 78), source_edge.external_module_id);
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_REQUEST_RE_EXPORT), source_edge.request_operation);
            try std.testing.expectEqualStrings("runtime-reexport", source_edge.specifier_ptr[0..source_edge.specifier_len]);
            saw_external_re_export = true;
        }
    }
    try std.testing.expect(saw_local_re_export);
    try std.testing.expect(saw_external_re_export);
}

test "official ABI v1 exposes every source diagnostic phase with explicit module identity" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const invalid_utf8 = [_]u8{0xff};
    const fixtures = [_]struct {
        id: u64,
        source: []const u8,
    }{
        .{ .id = 101, .source = &invalid_utf8 },
        .{ .id = 102, .source = "const value = ;" },
        .{ .id = 103, .source = "let value = 1; let value = 2;" },
        .{ .id = 104, .source = "missingName;" },
        .{ .id = 105, .source = "let value: MissingType;" },
        .{ .id = 106, .source = "const value: number = \"text\";" },
    };
    for (fixtures) |fixture| {
        var source = projectSource(fixture.id, "duplicate.ts", fixture.source, true);
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &source));
    }

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));

    var found = [_]bool{false} ** 6;
    for (0..summary.diagnostic_count) |index| {
        var item: c.Vizg_ProjectDiagnostic = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_diagnostic(result, index, &item));
        if (item.phase >= found.len) continue;
        const phase: usize = @intCast(item.phase);
        try std.testing.expectEqual(@as(u8, 1), item.has_module_id);
        try std.testing.expectEqualStrings("duplicate.ts", item.logical_name_ptr[0..item.logical_name_len]);
        if (item.module_id == @as(u64, 101) + phase) found[phase] = true;
    }
    for (found) |present| try std.testing.expect(present);
}

test "official ABI v1 reports distinct canonical host and project diagnostics once" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const root_text =
        \\import notFound from "missing";
        \\import denied from "denied";
        \\import failed from "failed";
        \\import { requested } from "external";
        \\export { notFound, denied, failed, requested };
    ;
    var root = projectSource(201, "root.ts", root_text, true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    while (true) {
        var step: c.Vizg_ProjectStep = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
        if (step.kind == c.VIZG_PROJECT_STEP_COMPLETE) break;
        const specifier = stepSpecifier(&step);
        if (std.mem.eql(u8, specifier, "missing")) {
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(project, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND));
        } else if (std.mem.eql(u8, specifier, "denied")) {
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(project, step.request_id, c.VIZG_PROJECT_FAILURE_DENIED));
        } else if (std.mem.eql(u8, specifier, "failed")) {
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(project, step.request_id, c.VIZG_PROJECT_FAILURE_FAILED));
        } else if (std.mem.eql(u8, specifier, "external")) {
            var external: c.Vizg_ExternalModule = .{
                .external_module_id = 80,
                .logical_name_ptr = "external".ptr,
                .logical_name_len = "external".len,
                .exports_ptr = null,
                .export_count = 0,
            };
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(project, step.request_id, &external));
        } else return error.UnexpectedRequest;
    }

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(usize, 4), summary.diagnostic_count);
    try std.testing.expectEqual(@as(u8, 1), summary.has_project_errors);
    try std.testing.expectEqual(@as(u8, 1), summary.has_module_failures);
    try std.testing.expectEqual(@as(u8, 1), summary.is_partial);

    var host_codes = [_]u32{ 0, 0, 0 };
    var project_count: usize = 0;
    var unsupported_count: usize = 0;
    for (0..summary.diagnostic_count) |index| {
        var item: c.Vizg_ProjectDiagnostic = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_diagnostic(result, index, &item));
        try std.testing.expectEqual(@as(u8, 1), item.has_module_id);
        try std.testing.expectEqual(@as(u64, 201), item.module_id);
        if (item.phase == c.VIZG_DIAGNOSTIC_PHASE_MODULE_HOST) {
            if (item.code == c.VIZG_DIAGNOSTIC_MODULE_NOT_FOUND) host_codes[0] += 1;
            if (item.code == c.VIZG_DIAGNOSTIC_MODULE_ACCESS_DENIED) host_codes[1] += 1;
            if (item.code == c.VIZG_DIAGNOSTIC_MODULE_HOST_FAILED) host_codes[2] += 1;
        } else if (item.phase == c.VIZG_DIAGNOSTIC_PHASE_PROJECT and item.code == c.VIZG_DIAGNOSTIC_MISSING_EXPORT) {
            project_count += 1;
        } else if (item.code == c.VIZG_DIAGNOSTIC_UNSUPPORTED_SYNTAX) {
            unsupported_count += 1;
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &host_codes);
    try std.testing.expectEqual(@as(usize, 1), project_count);
    try std.testing.expectEqual(@as(usize, 0), unsupported_count);
}

test "official ABI v1 rejects malformed arguments and workspace aliases" {
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_create(null, null));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_step(null, null));

    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var malformed = projectSource(1, "bad.ts", "x", true);
    malformed.source_ptr = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, &malformed));
    malformed = projectSource(1, "bad.ts", "x", true);
    malformed.reserved[1] = 1;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, &malformed));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_respond_failure(project, 1, 99));
}

test "official ABI v1 enforces the uint32 source representation boundary before access" {
    const max_source_length: usize = c.VIZG_MAX_SOURCE_LENGTH;
    try std.testing.expectEqual(std.math.maxInt(u32), max_source_length);

    var boundary_workspace = try Workspace.init(8 * 1024 * 1024);
    defer boundary_workspace.deinit();
    var boundary_config = boundary_workspace.config();
    boundary_config.max_source_bytes = max_source_length;
    var boundary_project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(
        @as(u32, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_create(&boundary_config, &boundary_project),
    );
    c.vizg_project_destroy(boundary_project);

    if (std.math.maxInt(usize) > max_source_length) {
        var over_project: ?*c.Vizg_Project = null;
        boundary_config.max_source_bytes = max_source_length + 1;
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED),
            c.vizg_project_create(&boundary_config, &over_project),
        );
        try std.testing.expect(over_project != null);
        try std.testing.expectEqual(
            @as(u32, c.VIZG_LIMIT_SOURCE_BYTES),
            c.vizg_project_limit_kind(over_project),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE),
            c.vizg_project_add_source(over_project, null),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_LIMIT_SOURCE_BYTES),
            c.vizg_project_limit_kind(over_project),
        );
        c.vizg_project_destroy(over_project);

        var source_workspace = try Workspace.init(8 * 1024 * 1024);
        defer source_workspace.deinit();
        const source_project = try createProject(source_workspace);
        defer c.vizg_project_destroy(source_project);
        try std.testing.expectEqual(
            @as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED),
            vizg_test_add_oversized_source(source_project),
        );
        try std.testing.expectEqual(
            @as(u32, c.VIZG_LIMIT_SOURCE_BYTES),
            c.vizg_project_limit_kind(source_project),
        );
    }
}

test "official ABI v1 validates create ranges alignment and aliases before writing" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var project: ?*c.Vizg_Project = @ptrFromInt(8);

    try expectInvalid(c.vizg_project_create(null, &project));
    try std.testing.expect(project != null);
    try expectInvalid(c.vizg_project_create(&config, null));

    try expectInvalid(vizg_test_create_misaligned_config(&config, &project));
    try expectInvalid(vizg_test_create_misaligned_output(&config));

    const overflow_address = std.math.maxInt(usize) & ~(@as(usize, @alignOf(c.Vizg_ProjectConfig)) - 1);
    const overflow_config: [*c]const c.Vizg_ProjectConfig = @ptrFromInt(overflow_address);
    try expectInvalid(c.vizg_project_create(overflow_config, &project));

    const original_workspace = config.workspace_ptr;
    const overlapping_output: [*c]?*c.Vizg_Project = @ptrCast(&config);
    try expectInvalid(c.vizg_project_create(&config, overlapping_output));
    try std.testing.expectEqual(original_workspace, config.workspace_ptr);

    const config_in_workspace: *c.Vizg_ProjectConfig = @ptrCast(@alignCast(workspace.words.ptr));
    config_in_workspace.* = workspace.config();
    try expectInvalid(c.vizg_project_create(config_in_workspace, &project));

    config = workspace.config();
    const output_words = workspace.words[workspace.words.len - 2 ..];
    const output_in_workspace: [*c]?*c.Vizg_Project = @ptrCast(output_words.ptr);
    output_in_workspace[0] = @ptrFromInt(8);
    try expectInvalid(c.vizg_project_create(&config, output_in_workspace));
    try std.testing.expect(output_in_workspace[0] != null);
}

test "official ABI v1 rejects hostile source step finish and result pointers without state mutation" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "export const value = 1;", true);
    try expectInvalid(c.vizg_project_add_source(null, &root));
    try expectInvalid(c.vizg_project_add_source(project, null));
    root.source_ptr = @ptrFromInt(std.math.maxInt(usize));
    root.source_len = 2;
    try expectInvalid(c.vizg_project_add_source(project, &root));

    root = projectSource(1, "root.ts", "export const value = 1;", true);
    const workspace_source: *c.Vizg_ProjectSource = @ptrCast(@alignCast(workspace.words.ptr + workspace.words.len - 16));
    workspace_source.* = root;
    try expectInvalid(c.vizg_project_add_source(project, workspace_source));
    root.source_ptr = @ptrCast(workspace.words.ptr + workspace.words.len - 1);
    root.source_len = 1;
    try expectInvalid(c.vizg_project_add_source(project, &root));

    root = projectSource(1, "root.ts", "export const value = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));

    try expectInvalid(c.vizg_project_step(project, null));
    var null_handle_step: c.Vizg_ProjectStep = undefined;
    try expectInvalid(c.vizg_project_step(null, &null_handle_step));
    try expectInvalid(vizg_test_step_misaligned_output(project));
    const workspace_step: [*c]c.Vizg_ProjectStep = @ptrCast(workspace.words.ptr + workspace.words.len - 32);
    try expectInvalid(c.vizg_project_step(project, workspace_step));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_COMPLETE), step.kind);

    try expectInvalid(c.vizg_project_finish(project, null));
    var null_handle_result: ?*c.Vizg_ProjectResult = null;
    try expectInvalid(c.vizg_project_finish(null, &null_handle_result));
    try expectInvalid(vizg_test_finish_misaligned_output(project));
    const workspace_result: [*c]?*c.Vizg_ProjectResult = @ptrCast(workspace.words.ptr + workspace.words.len - 2);
    try expectInvalid(c.vizg_project_finish(project, workspace_result));

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(project, &result));
    const view = result orelse return error.MissingProjectResult;
    var null_handle_summary: c.Vizg_ProjectResultSummary = undefined;
    try expectInvalid(c.vizg_project_result_summary(null, &null_handle_summary));
    try expectInvalid(c.vizg_project_result_summary(view, null));
    try expectInvalid(vizg_test_summary_misaligned_output(view));
    const workspace_summary: [*c]c.Vizg_ProjectResultSummary = @ptrCast(workspace.words.ptr + workspace.words.len - 8);
    try expectInvalid(c.vizg_project_result_summary(view, workspace_summary));

    try expectInvalid(c.vizg_project_result_module(view, 0, null));
    try expectInvalid(c.vizg_project_result_diagnostic(view, 0, null));
    try expectInvalid(c.vizg_project_result_edge(view, 0, null));
    try expectInvalid(c.vizg_project_result_import(view, 0, null));
    try expectInvalid(c.vizg_project_result_export(view, 0, null));
    var module: c.Vizg_ProjectModuleInfo = undefined;
    var diagnostic: c.Vizg_ProjectDiagnostic = undefined;
    var edge: c.Vizg_ProjectEdgeInfo = undefined;
    var import_info: c.Vizg_ProjectImportInfo = undefined;
    var export_info: c.Vizg_ProjectExportInfo = undefined;
    try expectInvalid(c.vizg_project_result_module(null, 0, &module));
    try expectInvalid(c.vizg_project_result_diagnostic(null, 0, &diagnostic));
    try expectInvalid(c.vizg_project_result_edge(null, 0, &edge));
    try expectInvalid(c.vizg_project_result_import(null, 0, &import_info));
    try expectInvalid(c.vizg_project_result_export(null, 0, &export_info));

    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(view, &summary));
    try std.testing.expectEqual(@as(usize, 1), summary.module_count);

    vizg_test_destroy_misaligned_handle();
    const overflow_handle: ?*c.Vizg_Project = @ptrFromInt(std.math.maxInt(usize) & ~(@as(usize, 7)));
    c.vizg_project_destroy(overflow_handle);
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), c.vizg_project_limit_kind(null));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), c.vizg_project_limit_kind(overflow_handle));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), vizg_test_limit_kind_misaligned_handle());
}

test "official ABI v1 validates response descriptors before consuming a request" {
    var source_workspace = try Workspace.init(8 * 1024 * 1024);
    defer source_workspace.deinit();
    const source_project = try createProject(source_workspace);
    defer c.vizg_project_destroy(source_project);
    var root = projectSource(1, "root.ts", "import './dep';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(source_project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(source_project, &step));
    var dep = projectSource(2, "dep.ts", "export {};", false);
    try expectInvalid(c.vizg_project_respond_source(null, step.request_id, &dep));
    try expectInvalid(c.vizg_project_respond_source(source_project, step.request_id, null));
    dep.source_ptr = @ptrFromInt(std.math.maxInt(usize));
    dep.source_len = 2;
    try expectInvalid(c.vizg_project_respond_source(source_project, step.request_id, &dep));
    dep = projectSource(2, "dep.ts", "export {};", false);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(source_project, step.request_id, &dep));

    var external_workspace = try Workspace.init(8 * 1024 * 1024);
    defer external_workspace.deinit();
    const external_project = try createProject(external_workspace);
    defer c.vizg_project_destroy(external_project);
    root = projectSource(1, "root.ts", "import { value } from 'pkg';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(external_project, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(external_project, &step));

    var external: c.Vizg_ExternalModule = .{
        .external_module_id = 80,
        .logical_name_ptr = "pkg".ptr,
        .logical_name_len = 3,
        .exports_ptr = @ptrFromInt(@alignOf(c.Vizg_ExternalExport)),
        .export_count = std.math.maxInt(usize),
    };
    try expectInvalid(c.vizg_project_respond_external(null, step.request_id, &external));
    try expectInvalid(c.vizg_project_respond_external(external_project, step.request_id, null));
    try expectInvalid(c.vizg_project_respond_external(external_project, step.request_id, &external));

    var export_desc: c.Vizg_ExternalExport = .{
        .name_ptr = @ptrFromInt(std.math.maxInt(usize)),
        .name_len = 2,
        .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
        .namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE,
        .has_type_metadata = 0,
        .reserved = .{ 0, 0 },
        .type_metadata = 0,
    };
    external.exports_ptr = &export_desc;
    external.export_count = 1;
    try expectInvalid(c.vizg_project_respond_external(external_project, step.request_id, &external));

    export_desc.name_ptr = "value".ptr;
    export_desc.name_len = 5;
    export_desc.namespace_flags = 0;
    try expectInvalid(c.vizg_project_respond_external(external_project, step.request_id, &external));
    export_desc.namespace_flags = c.VIZG_EXTERNAL_NAMESPACE_VALUE;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(external_project, step.request_id, &external));

    var failure_workspace = try Workspace.init(8 * 1024 * 1024);
    defer failure_workspace.deinit();
    const failure_project = try createProject(failure_workspace);
    defer c.vizg_project_destroy(failure_project);
    root = projectSource(1, "root.ts", "import 'missing';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(failure_project, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(failure_project, &step));
    try expectInvalid(c.vizg_project_respond_failure(null, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND));
    try expectInvalid(c.vizg_project_respond_failure(failure_project, step.request_id, 99));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_failure(failure_project, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND));
}

test "official ABI v1 enforces request edge and root graph-depth limits" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    config.max_requests = 1;
    config.max_edges = 2;
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const handle = project orelse return error.MissingProject;
    var root = projectSource(1, "root.ts", "import './a'; import './b';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(handle, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_REQUESTS), c.vizg_project_limit_kind(handle));
    c.vizg_project_destroy(handle);

    var edge_workspace = try Workspace.init(8 * 1024 * 1024);
    defer edge_workspace.deinit();
    config = edge_workspace.config();
    config.max_requests = 2;
    config.max_edges = 1;
    project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const edge_handle = project orelse return error.MissingProject;
    root = projectSource(1, "root.ts", "import './a'; import './b';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(edge_handle, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(edge_handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_EDGES), c.vizg_project_limit_kind(edge_handle));
    c.vizg_project_destroy(edge_handle);

    var depth_workspace = try Workspace.init(8 * 1024 * 1024);
    defer depth_workspace.deinit();
    config = depth_workspace.config();
    config.max_graph_depth = 1;
    project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const depth_handle = project orelse return error.MissingProject;
    defer c.vizg_project_destroy(depth_handle);
    root = projectSource(1, "root.ts", "import './dep';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(depth_handle, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(depth_handle, &step));
    var dep = projectSource(2, "dep.ts", "import './deep';", false);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(depth_handle, step.request_id, &dep));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(depth_handle, &step));
    var deep = projectSource(3, "deep.ts", "export {};", false);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_respond_source(depth_handle, step.request_id, &deep));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_GRAPH_DEPTH), c.vizg_project_limit_kind(depth_handle));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_respond_source(depth_handle, step.request_id, null));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), c.vizg_project_limit_kind(depth_handle));
    root.is_root = 0;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(depth_handle, step.request_id, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), c.vizg_project_limit_kind(depth_handle));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(depth_handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_COMPLETE), step.kind);
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(depth_handle, &result));
}

test "official ABI v1 reports first-module diagnostic and semantic-growth limits exactly" {
    var semantic_workspace = try Workspace.init(8 * 1024 * 1024);
    defer semantic_workspace.deinit();
    var config = semantic_workspace.config();
    config.max_semantic_types = 1;
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const semantic_handle = project orelse return error.MissingProject;
    defer c.vizg_project_destroy(semantic_handle);
    var root = projectSource(1, "types.ts", "type Box = { value: number }; const box: Box = { value: 1 };", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(semantic_handle, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(semantic_handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_SEMANTIC_GROWTH), c.vizg_project_limit_kind(semantic_handle));

    var diagnostic_workspace = try Workspace.init(8 * 1024 * 1024);
    defer diagnostic_workspace.deinit();
    config = diagnostic_workspace.config();
    config.max_diagnostics = 1;
    project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const diagnostic_handle = project orelse return error.MissingProject;
    defer c.vizg_project_destroy(diagnostic_handle);
    root = projectSource(2, "diagnostics.ts", "const first: number = 'wrong'; const second: number = 'wrong';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(diagnostic_handle, &root));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(diagnostic_handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_DIAGNOSTICS), c.vizg_project_limit_kind(diagnostic_handle));
}

test "official ABI v1 reports parse-depth limit exactly and clears stale kinds" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    const nesting = 1025;
    const source = try std.testing.allocator.alloc(u8, "const value = ".len + nesting + "value;".len);
    defer std.testing.allocator.free(source);
    @memcpy(source[0.."const value = ".len], "const value = ");
    @memset(source["const value = ".len .. "const value = ".len + nesting], '!');
    @memcpy(source["const value = ".len + nesting ..], "value;");

    var root = projectSource(1, "deep.ts", source, true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_PARSE_DEPTH), c.vizg_project_limit_kind(project));

    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, null));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_NONE), c.vizg_project_limit_kind(project));
}

// ---------------------------------------------------------------------------
// Goal 013 — ABI lifecycle coverage for vizg_project_add_global_root.
//
// The additive `vizg_project_add_global_root` entry point designates source
// modules whose named exports are visible as globals in application
// modules. These tests exercise the happy path (global root + app root →
// finish OK), the lifecycle ordering invariants (late registration after a
// source, duplicate root identity, and post-finish are rejected), and the
// host-input validation that must reject hostile pointers without state
// mutation. They mirror the existing `vizg_project_add_source` coverage.
// ---------------------------------------------------------------------------

test "official ABI v1 add_global_root: global root exports reach an application root" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var global_root = projectSource(0, "std.ts",
        \\export const console = {
        \\    log: (value: number) => { /* native bridge */ },
        \\};
    , true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_global_root(project, &global_root));

    var app_root = projectSource(1, "main.ts", "console.log(42);", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &app_root));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_COMPLETE), step.kind);

    const result = try finishProject(project);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    // Both the global source module and the application module are analyzed.
    try std.testing.expectEqual(@as(usize, 2), summary.module_count);
    // The application module has no exports; the global root's `console`
    // export is a source global, not a project export. Reachability is proven
    // by the absence of failures: `console` resolved without `cannot_find_name`.
    try std.testing.expectEqual(@as(u8, 0), summary.is_partial);
    try std.testing.expectEqual(@as(u8, 0), summary.has_syntax_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_semantic_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_project_errors);
    try std.testing.expectEqual(@as(u8, 0), summary.has_module_failures);

    // Both modules are present in the result, ordered by analysis (global root
    // is analyzed before application roots).
    var first: c.Vizg_ProjectModuleInfo = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_module(result, 0, &first));
    try std.testing.expectEqual(@as(u64, 0), first.module_id);
    var second: c.Vizg_ProjectModuleInfo = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_module(result, 1, &second));
    try std.testing.expectEqual(@as(u64, 1), second.module_id);
}

test "official ABI v1 add_global_root: late registration after add_source is rejected" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    // An application root must be added after the global root. Supplying any
    // source first makes the global root a late registration.
    var app_root = projectSource(1, "main.ts", "export {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &app_root));

    var global_root = projectSource(0, "std.ts", "export const console = {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_add_global_root(project, &global_root));
}

test "official ABI v1 add_global_root: multiple roots work and duplicate identity is rejected" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var global_root = projectSource(0, "std.ts", "export const console = {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_global_root(project, &global_root));

    var duplicate = projectSource(5, "other.ts", "export const other = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_global_root(project, &duplicate));
    duplicate = projectSource(5, "duplicate.ts", "export const duplicate = 2;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_add_global_root(project, &duplicate));
}

test "official ABI v1 add_global_root: rejected after finish" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var global_root = projectSource(0, "std.ts", "export const console = {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_global_root(project, &global_root));
    var app_root = projectSource(1, "main.ts", "export {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &app_root));
    _ = try finishProject(project);

    var late = projectSource(7, "late.ts", "export const late = 1;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_add_global_root(project, &late));
}

test "official ABI v1 add_global_root: validates hostile inputs without state mutation" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var global_root = projectSource(0, "std.ts", "export const console = {};", true);
    try expectInvalid(c.vizg_project_add_global_root(null, &global_root));
    try expectInvalid(c.vizg_project_add_global_root(project, null));

    // A source descriptor placed inside the workspace must be rejected. The
    // shared alignment/range validation is also exercised for `add_source`
    // and the misaligned-input case is covered in the wasm ABI host test.
    const workspace_source: *c.Vizg_ProjectSource = @ptrCast(@alignCast(workspace.words.ptr + workspace.words.len - 32));
    workspace_source.* = global_root;
    try expectInvalid(c.vizg_project_add_global_root(project, workspace_source));

    // Out-of-bounds nested source bytes must be rejected without state change.
    global_root.source_ptr = @ptrFromInt(std.math.maxInt(usize));
    global_root.source_len = 2;
    try expectInvalid(c.vizg_project_add_global_root(project, &global_root));

    // After all hostile inputs, a valid global root still succeeds.
    global_root = projectSource(0, "std.ts", "export const console = {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_global_root(project, &global_root));
}

test "HIR detail v7 resolves applied generic targets without spelling knowledge" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    const project = try createProject(workspace);
    defer c.vizg_project_destroy(project);

    var root = projectSource(61, "generic-array.ts", "type Sequence<T> = T[]; type Via = Sequence<number>; const value: Via = [1, 2]; value;", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    const result = try finishProject(project);

    var summary: c.Vizg_HirSummary = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_summary(result, c.VIZG_HIR_API_VERSION, &summary));
    var saw_applied = false;
    for (0..summary.type_count) |index| {
        var detail: c.Vizg_HirTypeDetail = undefined;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, index, &detail));
        if (detail.kind != c.VIZG_HIR_TYPE_APPLIED_GENERIC) continue;
        saw_applied = true;
        var target: u32 = 0;
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_hir_applied_generic_target(result, 6, detail.id, &target));
        try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_applied_generic_target(result, c.VIZG_HIR_DETAIL_API_VERSION, detail.id, &target));
        var found_target = false;
        for (0..summary.type_count) |target_index| {
            var target_detail: c.Vizg_HirTypeDetail = undefined;
            try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_hir_type_detail_at(result, c.VIZG_HIR_DETAIL_API_VERSION, target_index, &target_detail));
            if (target_detail.id != target) continue;
            found_target = true;
            try std.testing.expectEqual(@as(u32, c.VIZG_HIR_TYPE_ARRAY), target_detail.kind);
            break;
        }
        try std.testing.expect(found_target);
    }
    try std.testing.expect(saw_applied);
}
