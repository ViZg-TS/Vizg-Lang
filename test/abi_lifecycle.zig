const std = @import("std");
const c = @cImport(@cInclude("vizg.h"));

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
                .type_only = 0,
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


test "official ABI v1 enforces request edge and root graph-depth limits" {
    var workspace = try Workspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    config.max_requests = 1;
    config.max_edges = 1;
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const handle = project orelse return error.MissingProject;
    var root = projectSource(1, "root.ts", "import './a'; import './b';", true);
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(handle, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(u32, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(handle, &step));
    c.vizg_project_destroy(handle);

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
}
