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
        .revision = 0,
    };
}

fn stepSpecifier(step: *const c.Vizg_ProjectStep) []const u8 {
    if (step.specifier_len == 0) return "";
    return step.specifier_ptr[0..step.specifier_len];
}

const OfficialWorkspace = struct {
    words: []u64,

    fn init(bytes_len: usize) !OfficialWorkspace {
        return .{ .words = try std.testing.allocator.alloc(u64, (bytes_len + 7) / 8) };
    }

    fn deinit(self: OfficialWorkspace) void {
        std.testing.allocator.free(self.words);
    }

    fn config(self: OfficialWorkspace) c.Vizg_ProjectConfig {
        return .{
            .workspace_ptr = @ptrCast(self.words.ptr),
            .workspace_len = self.words.len * @sizeOf(u64),
            .max_source_bytes = 1024 * 1024,
            .max_modules = 256,
            .max_diagnostics = 4096,
            .max_graph_depth = 128,
            .max_semantic_types = 65536,
        };
    }
};

fn workspaceTail(comptime T: type, workspace: OfficialWorkspace) *T {
    const start = @intFromPtr(workspace.words.ptr);
    const end = start + workspace.words.len * @sizeOf(u64);
    return @ptrFromInt(std.mem.alignBackward(usize, end - @sizeOf(T), @alignOf(T)));
}

const ParallelAnalysis = struct {
    words: []u64,
    ok: bool = false,
};

fn runParallelAnalysis(work: *ParallelAnalysis) void {
    const workspace = OfficialWorkspace{ .words = work.words };
    var config = workspace.config();
    var source = projectSource(1, "parallel.ts", "export const value = 1;", true);
    var result: ?*c.Vizg_ProjectResult = null;
    if (c.vizg_project_analyze_source(&config, &source, &result) != c.VIZG_PROJECT_STATUS_OK) return;
    defer c.vizg_project_result_destroy(result);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    if (c.vizg_project_result_summary(result, &summary) != c.VIZG_PROJECT_STATUS_OK) return;
    work.ok = summary.module_count == 1 and summary.has_failures == 0;
}

test "official ABI v1 drives source and external host responses" {
    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const handle = project orelse return error.MissingProject;

    const root_text =
        \\import { x } from "./dep";
        \\import { log } from "runtime";
        \\export const y = x;
    ;
    var root = projectSource(1, "root.ts", root_text, true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(handle, &root));

    var supplied_dep = false;
    var supplied_external = false;
    while (true) {
        var next: c.Vizg_ProjectStep = undefined;
        try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(handle, &next));
        if (next.kind == c.VIZG_PROJECT_STEP_COMPLETE) break;
        try std.testing.expectEqual(@as(c.Vizg_ProjectStepKind, c.VIZG_PROJECT_STEP_REQUEST), next.kind);
        try std.testing.expectEqual(@as(u64, 1), next.importer_module_id);

        const specifier = stepSpecifier(&next);
        if (std.mem.eql(u8, specifier, "./dep")) {
            var dep = projectSource(2, "dep.ts", "export const x: number = 1;", false);
            try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(handle, next.request_id, &dep));
            supplied_dep = true;
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
            const logical_name = "runtime";
            var external: c.Vizg_ExternalModule = .{
                .external_module_id = 80,
                .logical_name_ptr = logical_name.ptr,
                .logical_name_len = logical_name.len,
                .exports_ptr = &export_desc,
                .export_count = 1,
            };
            try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_external(handle, next.request_id, &external));
            supplied_external = true;
        } else return error.UnexpectedRequest;
    }
    try std.testing.expect(supplied_dep);
    try std.testing.expect(supplied_external);

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(handle, &result));
    const result_handle = result orelse return error.MissingResult;

    // Results are independent snapshots and remain valid after project cleanup.
    c.vizg_project_destroy(handle);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result_handle, &summary));
    try std.testing.expectEqual(@as(usize, 2), summary.module_count);
    try std.testing.expectEqual(@as(u8, 0), summary.has_failures);
    try std.testing.expectEqual([_]u8{ 0, 0, 0, 0, 0, 0, 0 }, summary.reserved);
    c.vizg_project_result_destroy(result_handle);
}

test "official ABI v1 failure response and source convenience use same engine" {
    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    const text = "import value from \"missing\"; export default value;";
    var source = projectSource(7, "entry.ts", text, true);
    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_analyze_source(&config, &source, &result));
    defer c.vizg_project_result_destroy(result);

    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_result_summary(result, &summary));
    try std.testing.expectEqual(@as(usize, 1), summary.module_count);
    try std.testing.expectEqual(@as(u8, 1), summary.has_failures);
}

test "official ABI v1 rejects malformed arguments and invalid order" {
    c.vizg_project_destroy(null);
    c.vizg_project_result_destroy(null);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_create(null, null));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_step(null, null));

    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    defer c.vizg_project_destroy(project);

    var malformed = projectSource(1, "bad.ts", "x", true);
    malformed.source_ptr = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, &malformed));
    malformed = projectSource(1, "bad.ts", "x", true);
    malformed.reserved[1] = 1;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, &malformed));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_respond_failure(project, 1, 99));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_respond_failure(project, 999, c.VIZG_PROJECT_FAILURE_NOT_FOUND));

    var pending = projectSource(2, "pending.ts", "import \"pending-dependency\";", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &pending));
    var next: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &next));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStepKind, c.VIZG_PROJECT_STEP_REQUEST), next.kind);

    var output: ?*c.Vizg_ProjectResult = @ptrFromInt(1);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_STATE), c.vizg_project_finish(project, &output));
    try std.testing.expectEqual(@as(?*c.Vizg_ProjectResult, null), output);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_result_summary(null, null));
}

test "official ABI v1 uses isolated reusable caller workspaces" {
    try std.testing.expect(c.vizg_project_workspace_alignment() <= @alignOf(u64));
    try std.testing.expect(c.vizg_project_workspace_overhead() > 0);

    var first_workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer first_workspace.deinit();
    var second_workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer second_workspace.deinit();
    var first_config = first_workspace.config();
    var second_config = second_workspace.config();
    var first_source = projectSource(41, "first.ts", "export const first = 1;", true);
    var second_source = projectSource(42, "second.ts", "export const second = 2;", true);
    var first_result: ?*c.Vizg_ProjectResult = null;
    var second_result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_analyze_source(&first_config, &first_source, &first_result));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_analyze_source(&second_config, &second_source, &second_result));
    c.vizg_project_result_destroy(first_result);
    c.vizg_project_result_destroy(second_result);

    var index: usize = 0;
    while (index < 32) : (index += 1) {
        var result: ?*c.Vizg_ProjectResult = null;
        try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_analyze_source(&first_config, &first_source, &result));
        c.vizg_project_result_destroy(result);
    }
}

test "official ABI v1 analyzes independent workspaces concurrently" {
    var work: [4]ParallelAnalysis = undefined;
    for (&work) |*item| {
        const workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
        item.* = .{ .words = workspace.words };
    }
    defer for (&work) |*item| (OfficialWorkspace{ .words = item.words }).deinit();

    var threads: [4]std.Thread = undefined;
    for (&threads, &work) |*thread, *item| {
        thread.* = try std.Thread.spawn(.{}, runParallelAnalysis, .{item});
    }
    for (&threads) |*thread| thread.join();
    for (&work) |item| try std.testing.expect(item.ok);
}

test "official ABI v1 reports workspace exhaustion and configured limits" {
    var tiny_workspace = try OfficialWorkspace.init(c.vizg_project_workspace_overhead());
    defer tiny_workspace.deinit();
    var tiny_config = tiny_workspace.config();
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&tiny_config, &project));
    var source = projectSource(1, "oom.ts", "export const value = 1;", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OUT_OF_MEMORY), c.vizg_project_add_source(project, &source));
    c.vizg_project_destroy(project);

    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    config.max_source_bytes = 1;
    project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_add_source(project, &source));
    c.vizg_project_destroy(project);

    config = workspace.config();
    config.max_modules = 1;
    project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    var one = projectSource(1, "one.ts", "export {};", true);
    var two = projectSource(2, "two.ts", "export {};", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &one));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_add_source(project, &two));
    c.vizg_project_destroy(project);

    config = workspace.config();
    config.max_semantic_types = 1;
    project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &one));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    var limited_result: ?*c.Vizg_ProjectResult = @ptrFromInt(1);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_finish(project, &limited_result));
    try std.testing.expectEqual(@as(?*c.Vizg_ProjectResult, null), limited_result);
    c.vizg_project_destroy(project);

    config = workspace.config();
    config.max_diagnostics = 1;
    project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    var malformed = projectSource(3, "malformed.ts", "} } }", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &malformed));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_step(project, &step));
    c.vizg_project_destroy(project);
}

test "official ABI v1 bounds graph depth and rejects workspace aliasing" {
    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    var config = workspace.config();
    config.max_graph_depth = 1;
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    defer c.vizg_project_destroy(project);

    var root = projectSource(1, "root.ts", "import \"./dep\";", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(project, &root));
    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    var dep = projectSource(2, "dep.ts", "import \"./deep\";", false);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_respond_source(project, step.request_id, &dep));
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(project, &step));
    var deep = projectSource(3, "deep.ts", "export {};", false);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_LIMIT_EXCEEDED), c.vizg_project_respond_source(project, step.request_id, &deep));

    var aliased = projectSource(9, "aliased.ts", "x", true);
    aliased.source_ptr = @ptrFromInt(@intFromPtr(config.workspace_ptr.?) + c.vizg_project_workspace_overhead());
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT), c.vizg_project_add_source(project, &aliased));
}

test "official ABI v1 rejects aliased structs and stale handles without workspace mutation" {
    var create_workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer create_workspace.deinit();
    const aliased_config = workspaceTail(c.Vizg_ProjectConfig, create_workspace);
    aliased_config.* = create_workspace.config();
    var untouched_project: ?*c.Vizg_Project = @ptrFromInt(1);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_create(aliased_config, &untouched_project),
    );
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(untouched_project.?));

    var config = create_workspace.config();
    const aliased_project_output = workspaceTail(?*c.Vizg_Project, create_workspace);
    aliased_project_output.* = @ptrFromInt(1);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_create(&config, aliased_project_output),
    );
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(aliased_project_output.*.?));

    var workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer workspace.deinit();
    config = workspace.config();
    var project: ?*c.Vizg_Project = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_create(&config, &project));
    const handle = project orelse return error.MissingProject;

    var root = projectSource(1, "root.ts", "import 'external';", true);
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_add_source(handle, &root));

    const aliased_source = workspaceTail(c.Vizg_ProjectSource, workspace);
    aliased_source.* = projectSource(2, "bad.ts", "export {};", false);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_add_source(handle, aliased_source),
    );
    const aliased_step = workspaceTail(c.Vizg_ProjectStep, workspace);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_step(handle, aliased_step),
    );
    const aliased_result_output = workspaceTail(?*c.Vizg_ProjectResult, workspace);
    aliased_result_output.* = @ptrFromInt(1);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_finish(handle, aliased_result_output),
    );
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(aliased_result_output.*.?));

    var step: c.Vizg_ProjectStep = undefined;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(handle, &step));
    const aliased_name = workspaceTail(u8, workspace);
    aliased_name.* = 'x';
    var export_desc: c.Vizg_ExternalExport = .{
        .name_ptr = aliased_name,
        .name_len = 1,
        .kind = c.VIZG_EXTERNAL_EXPORT_NAMED,
        .type_only = 0,
        .has_type_metadata = 0,
        .reserved = .{ 0, 0 },
        .type_metadata = 0,
    };
    var external: c.Vizg_ExternalModule = .{
        .external_module_id = 9,
        .logical_name_ptr = "external".ptr,
        .logical_name_len = "external".len,
        .exports_ptr = &export_desc,
        .export_count = 1,
    };
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_respond_external(handle, step.request_id, &external),
    );
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK),
        c.vizg_project_respond_failure(handle, step.request_id, c.VIZG_PROJECT_FAILURE_NOT_FOUND),
    );
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_step(handle, &step));

    var result: ?*c.Vizg_ProjectResult = null;
    try std.testing.expectEqual(@as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_OK), c.vizg_project_finish(handle, &result));
    const result_handle = result orelse return error.MissingResult;
    const aliased_summary = workspaceTail(c.Vizg_ProjectResultSummary, workspace);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_result_summary(result_handle, aliased_summary),
    );
    c.vizg_project_result_destroy(result_handle);
    var summary: c.Vizg_ProjectResultSummary = undefined;
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_result_summary(result_handle, &summary),
    );
    c.vizg_project_result_destroy(result_handle);
    c.vizg_project_destroy(handle);
    c.vizg_project_destroy(handle);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_step(handle, &step),
    );

    var analyze_workspace = try OfficialWorkspace.init(8 * 1024 * 1024);
    defer analyze_workspace.deinit();
    var analyze_config = analyze_workspace.config();
    var source = projectSource(1, "entry.ts", "export {};", true);
    const analyze_output = workspaceTail(?*c.Vizg_ProjectResult, analyze_workspace);
    analyze_output.* = @ptrFromInt(1);
    try std.testing.expectEqual(
        @as(c.Vizg_ProjectStatus, c.VIZG_PROJECT_STATUS_INVALID_ARGUMENT),
        c.vizg_project_analyze_source(&analyze_config, &source, analyze_output),
    );
    try std.testing.expectEqual(@as(usize, 1), @intFromPtr(analyze_output.*.?));
}
