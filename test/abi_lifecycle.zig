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

    var module: c.Vizg_ProjectModuleInfo = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_module(first, 0, &module));
    try std.testing.expectEqual(@as(u64, 1), module.module_id);

    var late = projectSource(2, "late.ts", "export {};", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_add_source(project, &late));

    c.vizg_project_destroy(project);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_result_summary(first, &summary));
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
    try std.testing.expectEqual(@as(usize, 8), summary.diagnostic_count);

    var host_codes = [_]u32{ 0, 0, 0 };
    var project_count: usize = 0;
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
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, &host_codes);
    try std.testing.expectEqual(@as(usize, 1), project_count);
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
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(depth_handle, step.request_id, &deep));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(depth_handle, &step));
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STEP_COMPLETE), step.kind);
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_finish(depth_handle, &result));
    try std.testing.expectEqual(@as(u32, c.VIZG_LIMIT_GRAPH_DEPTH), c.vizg_project_limit_kind(depth_handle));
}
