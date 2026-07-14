//! Official ViZG C ABI v1: memory-first, host-driven project analysis.

const std = @import("std");
const builtin = @import("builtin");
const vizg = @import("vizg-impl");

pub const VIZG_ABI_VERSION: u32 = 1;

pub const Vizg_ProjectStatus = enum(u32) {
    OK = 0,
    INVALID_ARGUMENT = 1,
    OUT_OF_MEMORY = 2,
    INVALID_STATE = 3,
    LIMIT_EXCEEDED = 4,
    INTERNAL_ERROR = 5,
};

pub const Vizg_ProjectConfig = extern struct {
    workspace_ptr: [*c]u8,
    workspace_len: usize,
    max_source_bytes: usize,
    max_modules: usize,
    max_diagnostics: usize,
    max_graph_depth: usize,
    max_semantic_types: usize,
};

pub const Vizg_ProjectSource = extern struct {
    module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    source_ptr: [*c]const u8,
    source_len: usize,
    kind: u32,
    is_root: u8,
    reserved: [3]u8,
    revision: u64,
};

pub const Vizg_ProjectSpan = extern struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
};

pub const Vizg_ProjectRequestAttribute = extern struct {
    key_ptr: [*c]const u8,
    key_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectStep = extern struct {
    kind: u32,
    request_id: u64,
    importer_module_id: u64,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    request_kind: u32,
    attributes_ptr: [*c]const Vizg_ProjectRequestAttribute,
    attribute_count: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ExternalExport = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    kind: u32,
    type_only: u8,
    has_type_metadata: u8,
    reserved: [2]u8,
    type_metadata: u32,
};

pub const Vizg_ExternalModule = extern struct {
    external_module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    exports_ptr: [*c]const Vizg_ExternalExport,
    export_count: usize,
};

pub const Vizg_ProjectResultSummary = extern struct {
    module_count: usize,
    has_failures: u8,
    reserved: [7]u8,
};

pub const Vizg_Project = opaque {};
pub const Vizg_ProjectResult = opaque {};

const OwnedProject = struct {
    magic: u64 = project_magic,
    fba: std.heap.FixedBufferAllocator,
    project: vizg.Project,
    step_attributes: std.ArrayList(Vizg_ProjectRequestAttribute) = .empty,
    module_depths: std.ArrayList(ModuleDepth) = .empty,
    limits: Limits,
    workspace_len: usize,
    source_bytes: usize = 0,
    destroyed: bool = false,

    fn deinit(self: *OwnedProject) void {
        if (self.destroyed) return;
        const allocator = self.fba.allocator();
        self.step_attributes.deinit(allocator);
        self.module_depths.deinit(allocator);
        self.project.deinit();
        self.destroyed = true;
    }
};

const OwnedProjectResult = struct {
    magic: u64 = result_magic,
    summary: Vizg_ProjectResultSummary,
    owner: *OwnedProject,
    destroyed: bool = false,
};

const ModuleDepth = struct {
    id: vizg.project.ModuleId,
    depth: usize,
};

const Limits = struct {
    source_bytes: usize,
    modules: usize,
    diagnostics: usize,
    graph_depth: usize,
    semantic_types: usize,
};

const project_magic: u64 = 0x565a_4750_524f_4a31;
const result_magic: u64 = 0x565a_4752_4553_5531;

fn validHostRange(ptr: anytype, len: usize) bool {
    if (len == 0) return true;
    if (@intFromPtr(ptr) == 0) return false;
    const start = @intFromPtr(ptr);
    const end = std.math.add(usize, start, len) catch return false;
    if (comptime builtin.cpu.arch == .wasm32) {
        const memory_bytes = std.math.mul(usize, @wasmMemorySize(0), 64 * 1024) catch return false;
        return end <= memory_bytes;
    }
    return true;
}

fn ownedProject(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    const address = @intFromPtr(handle);
    if (address % @alignOf(OwnedProject) != 0 or !validHostRange(handle, @sizeOf(OwnedProject))) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic or owned.destroyed) return null;
    return owned;
}

fn ownedProjectForDestroy(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    const address = @intFromPtr(handle);
    if (address % @alignOf(OwnedProject) != 0 or !validHostRange(handle, @sizeOf(OwnedProject))) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic) return null;
    return owned;
}

fn ownedResult(result: ?*const Vizg_ProjectResult) ?*const OwnedProjectResult {
    const handle = result orelse return null;
    const address = @intFromPtr(handle);
    if (address % @alignOf(OwnedProjectResult) != 0 or !validHostRange(handle, @sizeOf(OwnedProjectResult))) return null;
    const owned: *const OwnedProjectResult = @ptrCast(@alignCast(handle));
    if (owned.magic != result_magic or owned.destroyed) return null;
    return owned;
}

fn ownedResultForDestroy(result: ?*Vizg_ProjectResult) ?*OwnedProjectResult {
    const handle = result orelse return null;
    const address = @intFromPtr(handle);
    if (address % @alignOf(OwnedProjectResult) != 0 or !validHostRange(handle, @sizeOf(OwnedProjectResult))) return null;
    const owned: *OwnedProjectResult = @ptrCast(@alignCast(handle));
    if (owned.magic != result_magic) return null;
    return owned;
}

fn workspace(config: *const Vizg_ProjectConfig) ?[]u8 {
    if (config.workspace_ptr == null or config.workspace_len < projectWorkspaceOverhead()) return null;
    if (@intFromPtr(config.workspace_ptr) % projectWorkspaceAlignment() != 0) return null;
    if (config.max_source_bytes == 0 or config.max_modules == 0 or config.max_diagnostics == 0 or
        config.max_graph_depth == 0 or config.max_semantic_types == 0) return null;
    return config.workspace_ptr[0..config.workspace_len];
}

fn inputOutsideWorkspace(owned: *const OwnedProject, ptr: anytype, len: usize) bool {
    if (len == 0) return true;
    if (!validHostRange(ptr, len)) return false;
    const input_start = @intFromPtr(ptr);
    const input_end = std.math.add(usize, input_start, len) catch return false;
    const workspace_start = @intFromPtr(owned);
    const workspace_end = std.math.add(usize, workspace_start, owned.workspace_len) catch return false;
    return input_end <= workspace_start or input_start >= workspace_end;
}

fn sourceInputsOutsideWorkspace(owned: *const OwnedProject, input: *const Vizg_ProjectSource) bool {
    return inputOutsideWorkspace(owned, input.logical_name_ptr, input.logical_name_len) and
        inputOutsideWorkspace(owned, input.source_ptr, input.source_len);
}

fn depthOf(owned: *const OwnedProject, id: vizg.project.ModuleId) usize {
    for (owned.module_depths.items) |item| if (item.id.value() == id.value()) return item.depth;
    return 0;
}

fn recordDepth(owned: *OwnedProject, id: vizg.project.ModuleId, depth: usize) !void {
    for (owned.module_depths.items) |*item| {
        if (item.id.value() == id.value()) {
            item.depth = @min(item.depth, depth);
            return;
        }
    }
    try owned.module_depths.append(owned.fba.allocator(), .{ .id = id, .depth = depth });
}

fn diagnosticCount(owned: *const OwnedProject) usize {
    var count = owned.project.graphDiagnostics().len;
    for (owned.module_depths.items) |item| {
        const module = owned.project.lookup(item.id) orelse continue;
        count = std.math.add(usize, count, module.diagnostics().len) catch return std.math.maxInt(usize);
    }
    if (owned.project.semanticResult()) |result| {
        count = std.math.add(usize, count, result.diagnostics.len) catch return std.math.maxInt(usize);
    }
    return count;
}

fn checkGrowthLimits(owned: *const OwnedProject) Vizg_ProjectStatus {
    if (owned.project.moduleCount() > owned.limits.modules) return .LIMIT_EXCEEDED;
    if (diagnosticCount(owned) > owned.limits.diagnostics) return .LIMIT_EXCEEDED;
    if (owned.project.semanticResult()) |result| {
        if (result.type_store.count() > owned.limits.semantic_types) return .LIMIT_EXCEEDED;
    }
    return .OK;
}

fn validPair(ptr: anytype, len: usize) bool {
    return validHostRange(ptr, len);
}

fn bytes(ptr: [*c]const u8, len: usize) []const u8 {
    return if (len == 0) "" else ptr[0..len];
}

fn sourceKind(value: u32) ?vizg.project.SourceKind {
    return switch (value) {
        0 => .script,
        1 => .module,
        else => null,
    };
}

fn requestKind(value: vizg.project.RequestKind) u32 {
    return @intFromEnum(value);
}

fn span(value: vizg.project.SourceSpan) Vizg_ProjectSpan {
    return .{
        .start = value.start,
        .end = value.end,
        .line = value.line,
        .column = value.column,
    };
}

fn moduleSource(input: *const Vizg_ProjectSource) ?vizg.ModuleSource {
    if (!validPair(input.logical_name_ptr, input.logical_name_len) or
        !validPair(input.source_ptr, input.source_len) or
        input.is_root > 1 or input.reserved[0] != 0 or input.reserved[1] != 0 or input.reserved[2] != 0)
    {
        return null;
    }
    return .{
        .id = .init(input.module_id),
        .logical_name = bytes(input.logical_name_ptr, input.logical_name_len),
        .bytes = bytes(input.source_ptr, input.source_len),
        .kind = sourceKind(input.kind) orelse return null,
        .revision = input.revision,
    };
}

fn statusFromError(err: anyerror) Vizg_ProjectStatus {
    return switch (err) {
        error.OutOfMemory => .OUT_OF_MEMORY,
        error.RequestIdExhausted,
        error.TypeComplexityLimit,
        error.ParseRecursionLimitReached,
        => .LIMIT_EXCEEDED,
        error.PendingRequests,
        error.IncompleteModules,
        error.ForeignRequest,
        error.InvalidResponseOrder,
        error.DuplicateResponse,
        error.StaleRequest,
        error.DuplicateModule,
        error.RevisionConflict,
        error.StaleRevision,
        error.UnknownImporter,
        error.UnknownModule,
        error.SourceNotSupplied,
        error.ModuleNotAnalyzed,
        => .INVALID_STATE,
        error.InvalidExternalExport,
        error.DuplicateExternalExport,
        error.ExternalDescriptorConflict,
        => .INVALID_ARGUMENT,
        else => .INTERNAL_ERROR,
    };
}

pub fn projectWorkspaceAlignment() callconv(.c) usize {
    return @alignOf(OwnedProject);
}

pub fn projectWorkspaceOverhead() callconv(.c) usize {
    return std.mem.alignForward(usize, @sizeOf(OwnedProject), @alignOf(OwnedProject));
}

pub fn projectCreate(config: ?*const Vizg_ProjectConfig, out_project: [*c]?*Vizg_Project) callconv(.c) Vizg_ProjectStatus {
    if (!validHostRange(out_project, @sizeOf(?*Vizg_Project))) return .INVALID_ARGUMENT;
    const args = config orelse return .INVALID_ARGUMENT;
    if (!validHostRange(args, @sizeOf(Vizg_ProjectConfig))) return .INVALID_ARGUMENT;
    const storage = workspace(args) orelse return .INVALID_ARGUMENT;
    const storage_start = @intFromPtr(storage.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return .INVALID_ARGUMENT;
    const config_start = @intFromPtr(args);
    const config_end = std.math.add(usize, config_start, @sizeOf(Vizg_ProjectConfig)) catch return .INVALID_ARGUMENT;
    const output_start = @intFromPtr(out_project);
    const output_end = std.math.add(usize, output_start, @sizeOf(?*Vizg_Project)) catch return .INVALID_ARGUMENT;
    if (!(config_end <= storage_start or config_start >= storage_end) or
        !(output_end <= storage_start or output_start >= storage_end)) return .INVALID_ARGUMENT;
    out_project[0] = null;
    const limits: Limits = .{
        .source_bytes = args.max_source_bytes,
        .modules = args.max_modules,
        .diagnostics = args.max_diagnostics,
        .graph_depth = args.max_graph_depth,
        .semantic_types = args.max_semantic_types,
    };
    const owned: *OwnedProject = @ptrCast(@alignCast(storage.ptr));
    owned.magic = project_magic;
    owned.fba = .init(storage[projectWorkspaceOverhead()..]);
    owned.step_attributes = .empty;
    owned.module_depths = .empty;
    owned.limits = limits;
    owned.workspace_len = storage.len;
    owned.source_bytes = 0;
    owned.destroyed = false;
    owned.project = .init(owned.fba.allocator());
    out_project[0] = @ptrCast(owned);
    return .OK;
}

pub fn projectDestroy(project: ?*Vizg_Project) callconv(.c) void {
    const owned = ownedProjectForDestroy(project) orelse return;
    owned.deinit();
}

pub fn projectAddSource(project: ?*Vizg_Project, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validHostRange(args, @sizeOf(Vizg_ProjectSource)) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource))) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    if (!sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const next_source_bytes = std.math.add(usize, owned.source_bytes, args.source_len) catch return .LIMIT_EXCEEDED;
    if (next_source_bytes > owned.limits.source_bytes) return .LIMIT_EXCEEDED;
    if (owned.project.lookup(source.id) == null and owned.project.moduleCount() >= owned.limits.modules) return .LIMIT_EXCEEDED;
    if (args.is_root == 1) {
        owned.project.addRoot(source) catch |err| return statusFromError(err);
    } else {
        owned.project.supplySource(source) catch |err| return statusFromError(err);
    }
    owned.source_bytes = next_source_bytes;
    recordDepth(owned, source.id, 0) catch return .OUT_OF_MEMORY;
    return .OK;
}

pub fn projectStep(project: ?*Vizg_Project, out_step: ?*Vizg_ProjectStep) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    const output = out_step orelse return .INVALID_ARGUMENT;
    if (!validHostRange(output, @sizeOf(Vizg_ProjectStep)) or
        !inputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectStep))) return .INVALID_ARGUMENT;
    output.* = std.mem.zeroes(Vizg_ProjectStep);
    const next = owned.project.step() catch |err| return statusFromError(err);
    const growth_status = checkGrowthLimits(owned);
    if (growth_status != .OK) return growth_status;
    switch (next) {
        .complete => output.kind = 0,
        .request => |request| {
            owned.step_attributes.clearRetainingCapacity();
            owned.step_attributes.ensureTotalCapacity(owned.fba.allocator(), request.attributes.len) catch return .OUT_OF_MEMORY;
            for (request.attributes) |attribute| owned.step_attributes.appendAssumeCapacity(.{
                .key_ptr = if (attribute.key.len == 0) null else attribute.key.ptr,
                .key_len = attribute.key.len,
                .value_ptr = if (attribute.value.len == 0) null else attribute.value.ptr,
                .value_len = attribute.value.len,
                .span = span(attribute.span),
            });
            output.* = .{
                .kind = 1,
                .request_id = request.id.value(),
                .importer_module_id = request.importer.value(),
                .specifier_ptr = if (request.raw_specifier.len == 0) null else request.raw_specifier.ptr,
                .specifier_len = request.raw_specifier.len,
                .request_kind = requestKind(request.kind),
                .attributes_ptr = if (owned.step_attributes.items.len == 0) null else owned.step_attributes.items.ptr,
                .attribute_count = owned.step_attributes.items.len,
                .span = span(request.span),
            };
        },
    }
    return .OK;
}

pub fn projectRespondSource(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validHostRange(args, @sizeOf(Vizg_ProjectSource)) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource))) return .INVALID_ARGUMENT;
    if (args.is_root != 0) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    if (!sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const next_source_bytes = std.math.add(usize, owned.source_bytes, args.source_len) catch return .LIMIT_EXCEEDED;
    if (next_source_bytes > owned.limits.source_bytes) return .LIMIT_EXCEEDED;
    const request = owned.project.lookupRequest(.init(request_id)) orelse return .INVALID_STATE;
    const depth = std.math.add(usize, depthOf(owned, request.request.importer), 1) catch return .LIMIT_EXCEEDED;
    if (depth > owned.limits.graph_depth) return .LIMIT_EXCEEDED;
    if (owned.project.lookup(source.id) == null and owned.project.moduleCount() >= owned.limits.modules) return .LIMIT_EXCEEDED;
    owned.project.respondSource(.init(request_id), source) catch |err| return statusFromError(err);
    owned.source_bytes = next_source_bytes;
    recordDepth(owned, source.id, depth) catch return .OUT_OF_MEMORY;
    return .OK;
}

fn exportKind(value: u32) ?vizg.ExternalExportKind {
    return switch (value) {
        0 => .named,
        1 => .default,
        2 => .namespace,
        else => null,
    };
}

fn externalType(value: u32) ?vizg.ExternalType {
    return switch (value) {
        0 => .unknown,
        1 => .any,
        2 => .never,
        3 => .void,
        4 => .undefined,
        5 => .null_,
        6 => .boolean,
        7 => .number,
        8 => .bigint,
        9 => .string,
        10 => .symbol,
        11 => .object,
        else => null,
    };
}

pub fn projectRespondExternal(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ExternalModule) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validHostRange(args, @sizeOf(Vizg_ExternalModule)) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ExternalModule))) return .INVALID_ARGUMENT;
    if (!validPair(args.logical_name_ptr, args.logical_name_len) or !validPair(args.exports_ptr, args.export_count)) return .INVALID_ARGUMENT;

    const exports_bytes = std.math.mul(usize, args.export_count, @sizeOf(Vizg_ExternalExport)) catch return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, args.logical_name_ptr, args.logical_name_len) or
        !inputOutsideWorkspace(owned, args.exports_ptr, exports_bytes)) return .INVALID_ARGUMENT;

    const descriptor_bytes = std.math.mul(usize, args.export_count, @sizeOf(vizg.ExternalExportDescriptor)) catch return .OUT_OF_MEMORY;
    const buffer = owned.fba.buffer;
    const buffer_start = @intFromPtr(buffer.ptr);
    const buffer_end = std.math.add(usize, buffer_start, buffer.len) catch return .OUT_OF_MEMORY;
    const unaligned_start = std.math.sub(usize, buffer_end, descriptor_bytes) catch return .OUT_OF_MEMORY;
    const scratch_start = std.mem.alignBackward(usize, unaligned_start, @alignOf(vizg.ExternalExportDescriptor));
    const used_end = std.math.add(usize, buffer_start, owned.fba.end_index) catch return .OUT_OF_MEMORY;
    if (scratch_start < used_end) return .OUT_OF_MEMORY;
    const scratch_index = scratch_start - buffer_start;
    owned.fba.buffer = buffer[0..scratch_index];
    defer owned.fba.buffer = buffer;
    const exports_ptr: [*]vizg.ExternalExportDescriptor = @ptrFromInt(scratch_start);
    const exports = exports_ptr[0..args.export_count];
    for (exports, 0..) |*output, index| {
        const item = args.exports_ptr[index];
        if (!validPair(item.name_ptr, item.name_len) or item.type_only > 1 or item.has_type_metadata > 1 or
            item.reserved[0] != 0 or item.reserved[1] != 0)
        {
            return .INVALID_ARGUMENT;
        }
        if (!inputOutsideWorkspace(owned, item.name_ptr, item.name_len)) return .INVALID_ARGUMENT;
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .kind = exportKind(item.kind) orelse return .INVALID_ARGUMENT,
            .type_only = item.type_only == 1,
            .type_metadata = if (item.has_type_metadata == 1)
                (externalType(item.type_metadata) orelse return .INVALID_ARGUMENT)
            else
                null,
        };
    }
    owned.project.respondExternalModule(.init(request_id), .{
        .id = .init(args.external_module_id),
        .logical_name = bytes(args.logical_name_ptr, args.logical_name_len),
        .exports = exports,
    }) catch |err| return statusFromError(err);
    return .OK;
}

pub fn projectRespondFailure(project: ?*Vizg_Project, request_id: u64, failure_kind: u32) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    switch (failure_kind) {
        0 => owned.project.respondNotFound(.init(request_id)) catch |err| return statusFromError(err),
        1 => owned.project.respondDenied(.init(request_id)) catch |err| return statusFromError(err),
        2 => owned.project.respondFailed(.init(request_id)) catch |err| return statusFromError(err),
        else => return .INVALID_ARGUMENT,
    }
    return .OK;
}

pub fn projectFinish(project: ?*Vizg_Project, out_result: [*c]?*Vizg_ProjectResult) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    if (!validHostRange(out_result, @sizeOf(?*Vizg_ProjectResult)) or
        !inputOutsideWorkspace(owned, out_result, @sizeOf(?*Vizg_ProjectResult))) return .INVALID_ARGUMENT;
    out_result[0] = null;
    const finished = owned.project.finish() catch |err| return statusFromError(err);
    const growth_status = checkGrowthLimits(owned);
    if (growth_status != .OK) return growth_status;
    const result = owned.fba.allocator().create(OwnedProjectResult) catch return .OUT_OF_MEMORY;
    result.* = .{ .magic = result_magic, .summary = .{
        .module_count = finished.module_count,
        .has_failures = @intFromBool(finished.has_failures),
        .reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
    }, .owner = owned };
    out_result[0] = @ptrCast(result);
    return .OK;
}

pub fn projectResultSummary(result: ?*const Vizg_ProjectResult, out_summary: ?*Vizg_ProjectResultSummary) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_summary orelse return .INVALID_ARGUMENT;
    if (!validHostRange(output, @sizeOf(Vizg_ProjectResultSummary)) or
        !inputOutsideWorkspace(owned.owner, output, @sizeOf(Vizg_ProjectResultSummary))) return .INVALID_ARGUMENT;
    output.* = owned.summary;
    return .OK;
}

pub fn projectResultDestroy(result: ?*Vizg_ProjectResult) callconv(.c) void {
    const owned = ownedResultForDestroy(result) orelse return;
    owned.destroyed = true;
}

pub fn projectAnalyzeSource(config: ?*const Vizg_ProjectConfig, input: ?*const Vizg_ProjectSource, out_result: [*c]?*Vizg_ProjectResult) callconv(.c) Vizg_ProjectStatus {
    if (!validHostRange(out_result, @sizeOf(?*Vizg_ProjectResult))) return .INVALID_ARGUMENT;
    const config_args = config orelse return .INVALID_ARGUMENT;
    if (!validHostRange(config_args, @sizeOf(Vizg_ProjectConfig))) return .INVALID_ARGUMENT;
    const storage = workspace(config_args) orelse return .INVALID_ARGUMENT;
    const output_start = @intFromPtr(out_result);
    const output_end = std.math.add(usize, output_start, @sizeOf(?*Vizg_ProjectResult)) catch return .INVALID_ARGUMENT;
    const storage_start = @intFromPtr(storage.ptr);
    const storage_end = std.math.add(usize, storage_start, storage.len) catch return .INVALID_ARGUMENT;
    if (!(output_end <= storage_start or output_start >= storage_end)) return .INVALID_ARGUMENT;
    out_result[0] = null;
    const args = input orelse return .INVALID_ARGUMENT;
    if (args.is_root != 1) return .INVALID_ARGUMENT;

    var handle: ?*Vizg_Project = null;
    var status = projectCreate(config, &handle);
    if (status != .OK) return status;
    defer projectDestroy(handle);
    status = projectAddSource(handle, args);
    if (status != .OK) return status;
    while (true) {
        var next = std.mem.zeroes(Vizg_ProjectStep);
        status = projectStep(handle, &next);
        if (status != .OK) return status;
        if (next.kind == 0) break;
        status = projectRespondFailure(handle, next.request_id, 0);
        if (status != .OK) return status;
    }
    return projectFinish(handle, out_result);
}

comptime {
    @export(&projectWorkspaceAlignment, .{ .name = "vizg_project_workspace_alignment" });
    @export(&projectWorkspaceOverhead, .{ .name = "vizg_project_workspace_overhead" });
    @export(&projectCreate, .{ .name = "vizg_project_create" });
    @export(&projectDestroy, .{ .name = "vizg_project_destroy" });
    @export(&projectAddSource, .{ .name = "vizg_project_add_source" });
    @export(&projectStep, .{ .name = "vizg_project_step" });
    @export(&projectRespondSource, .{ .name = "vizg_project_respond_source" });
    @export(&projectRespondExternal, .{ .name = "vizg_project_respond_external" });
    @export(&projectRespondFailure, .{ .name = "vizg_project_respond_failure" });
    @export(&projectFinish, .{ .name = "vizg_project_finish" });
    @export(&projectResultSummary, .{ .name = "vizg_project_result_summary" });
    @export(&projectResultDestroy, .{ .name = "vizg_project_result_destroy" });
    @export(&projectAnalyzeSource, .{ .name = "vizg_project_analyze_source" });
}

test "external response conversion uses reclaimable workspace scratch" {
    const workspace_bytes = 2 * 1024 * 1024;
    const c_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(c_words);
    const direct_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(direct_words);

    const limits = .{
        .max_source_bytes = 1024 * 1024,
        .max_modules = 32,
        .max_diagnostics = 1024,
        .max_graph_depth = 32,
        .max_semantic_types = 16 * 1024,
    };
    var c_config = Vizg_ProjectConfig{
        .workspace_ptr = @ptrCast(c_words.ptr),
        .workspace_len = workspace_bytes,
        .max_source_bytes = limits.max_source_bytes,
        .max_modules = limits.max_modules,
        .max_diagnostics = limits.max_diagnostics,
        .max_graph_depth = limits.max_graph_depth,
        .max_semantic_types = limits.max_semantic_types,
    };
    var direct_config = c_config;
    direct_config.workspace_ptr = @ptrCast(direct_words.ptr);
    var c_handle: ?*Vizg_Project = null;
    var direct_handle: ?*Vizg_Project = null;
    try std.testing.expectEqual(.OK, projectCreate(&c_config, &c_handle));
    defer projectDestroy(c_handle);
    try std.testing.expectEqual(.OK, projectCreate(&direct_config, &direct_handle));
    defer projectDestroy(direct_handle);

    const logical_name = "root.ts";
    const source_text = "import { log } from 'runtime';";
    var source = Vizg_ProjectSource{
        .module_id = 1,
        .logical_name_ptr = logical_name.ptr,
        .logical_name_len = logical_name.len,
        .source_ptr = source_text.ptr,
        .source_len = source_text.len,
        .kind = 1,
        .is_root = 1,
        .reserved = .{ 0, 0, 0 },
        .revision = 0,
    };
    try std.testing.expectEqual(.OK, projectAddSource(c_handle, &source));
    try std.testing.expectEqual(.OK, projectAddSource(direct_handle, &source));
    var c_step = std.mem.zeroes(Vizg_ProjectStep);
    var direct_step = std.mem.zeroes(Vizg_ProjectStep);
    try std.testing.expectEqual(.OK, projectStep(c_handle, &c_step));
    try std.testing.expectEqual(.OK, projectStep(direct_handle, &direct_step));
    try std.testing.expectEqual(c_step.request_id, direct_step.request_id);

    const export_name = "log";
    var c_export = Vizg_ExternalExport{
        .name_ptr = export_name.ptr,
        .name_len = export_name.len,
        .kind = 0,
        .type_only = 0,
        .has_type_metadata = 0,
        .reserved = .{ 0, 0 },
        .type_metadata = 0,
    };
    var c_external = Vizg_ExternalModule{
        .external_module_id = 80,
        .logical_name_ptr = "runtime".ptr,
        .logical_name_len = "runtime".len,
        .exports_ptr = &c_export,
        .export_count = 1,
    };
    try std.testing.expectEqual(.OK, projectRespondExternal(c_handle, c_step.request_id, &c_external));

    const direct_exports = [_]vizg.ExternalExportDescriptor{.{ .name = export_name }};
    const direct_owned = ownedProject(direct_handle).?;
    try direct_owned.project.respondExternalModule(.init(direct_step.request_id), .{
        .id = .init(80),
        .logical_name = "runtime",
        .exports = &direct_exports,
    });
    try std.testing.expectEqual(direct_owned.fba.end_index, ownedProject(c_handle).?.fba.end_index);
}
