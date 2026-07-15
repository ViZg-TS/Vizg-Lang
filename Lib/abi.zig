//! Official ViZG C ABI v1: memory-first, host-driven project analysis.

const std = @import("std");
const builtin = @import("builtin");
const vizg = @import("vizg-impl");

pub const VIZG_ABI_VERSION: u32 = 1;
pub const Vizg_ExternalNamespaceFlags = u8;
pub const VIZG_EXTERNAL_NAMESPACE_VALUE: Vizg_ExternalNamespaceFlags = 1;
pub const VIZG_EXTERNAL_NAMESPACE_TYPE: Vizg_ExternalNamespaceFlags = 2;
pub const VIZG_EXTERNAL_NAMESPACE_BOTH: Vizg_ExternalNamespaceFlags = 3;

pub const Vizg_ProjectStatus = enum(u32) {
    OK = 0,
    INVALID_ARGUMENT = 1,
    OUT_OF_MEMORY = 2,
    INVALID_STATE = 3,
    LIMIT_EXCEEDED = 4,
    INTERNAL_ERROR = 5,
};

pub const Vizg_LimitKind = enum(u32) {
    NONE = 0,
    SOURCE_BYTES = 1,
    TOTAL_SOURCE_BYTES = 2,
    MODULES = 3,
    REQUESTS = 4,
    EDGES = 5,
    GRAPH_DEPTH = 6,
    DIAGNOSTICS = 7,
    SEMANTIC_GROWTH = 8,
};

pub const Vizg_ProjectConfig = extern struct {
    workspace_ptr: [*c]u8,
    workspace_len: usize,
    max_source_bytes: usize,
    max_total_source_bytes: usize,
    max_modules: usize,
    max_requests: usize,
    max_edges: usize,
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
    request_operation: u32,
    type_only: u8,
    reserved: [3]u8,
    attributes_ptr: [*c]const Vizg_ProjectRequestAttribute,
    attribute_count: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ExternalExport = extern struct {
    name_ptr: [*c]const u8,
    name_len: usize,
    kind: u32,
    namespace_flags: Vizg_ExternalNamespaceFlags,
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
    diagnostic_count: usize,
    edge_count: usize,
    import_count: usize,
    export_count: usize,
    is_partial: u8,
    has_syntax_errors: u8,
    has_semantic_errors: u8,
    has_module_failures: u8,
    reserved: [4]u8,
};

pub const Vizg_ProjectModuleInfo = extern struct {
    module_id: u64,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    state: u32,
    is_root: u8,
    has_source: u8,
    reserved: [2]u8,
};

pub const Vizg_ProjectDiagnostic = extern struct {
    module_id: u64,
    has_module_id: u8,
    severity: u8,
    phase: u8,
    reserved: u8,
    code: u32,
    message_ptr: [*c]const u8,
    message_len: usize,
    logical_name_ptr: [*c]const u8,
    logical_name_len: usize,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectEdgeInfo = extern struct {
    request_id: u64,
    importer_module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    request_operation: u32,
    state: u32,
    type_only: u8,
    has_target_module: u8,
    has_external_target: u8,
    reserved: u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectImportInfo = extern struct {
    module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    edge_index: usize,
    target_type_id: u32,
    link_state: u32,
    request_operation: u32,
    local_name_ptr: [*c]const u8,
    local_name_len: usize,
    imported_name_ptr: [*c]const u8,
    imported_name_len: usize,
    specifier_ptr: [*c]const u8,
    specifier_len: usize,
    type_only: u8,
    runtime_binding: u8,
    has_target_module: u8,
    has_external_target: u8,
    has_edge_index: u8,
    has_semantic_target: u8,
    reserved: [2]u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_ProjectExportInfo = extern struct {
    module_id: u64,
    target_module_id: u64,
    external_module_id: u64,
    edge_index: usize,
    target_type_id: u32,
    name_ptr: [*c]const u8,
    name_len: usize,
    type_only: u8,
    re_export: u8,
    has_target_module: u8,
    has_external_target: u8,
    has_edge_index: u8,
    reserved: [3]u8,
    span: Vizg_ProjectSpan,
};

pub const Vizg_Project = opaque {};
pub const Vizg_ProjectResult = opaque {};

const OwnedProject = struct {
    magic: u64 = project_magic,
    fba: std.heap.FixedBufferAllocator,
    project: vizg.Project,
    step_attributes: std.ArrayList(Vizg_ProjectRequestAttribute) = .empty,
    workspace_len: usize,
    last_limit: Vizg_LimitKind = .NONE,
    result_view: OwnedProjectResult = undefined,
    result_ready: bool = false,
    destroyed: bool = false,

    fn deinit(self: *OwnedProject) void {
        if (self.destroyed) return;
        const allocator = self.fba.allocator();
        self.step_attributes.deinit(allocator);
        self.project.deinit();
        if (self.result_ready) self.result_view.magic = 0;
        self.result_ready = false;
        self.destroyed = true;
    }
};

const OwnedProjectResult = struct {
    magic: u64 = result_magic,
    summary: Vizg_ProjectResultSummary,
    owner: *OwnedProject,
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

fn checkedByteLen(comptime T: type, count: usize) ?usize {
    return std.math.mul(usize, @sizeOf(T), count) catch null;
}

fn validAlignedHostObject(comptime T: type, ptr: anytype) bool {
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    return validHostRange(ptr, @sizeOf(T));
}

fn validAlignedHostArray(comptime T: type, ptr: [*c]const T, count: usize) bool {
    if (count == 0) return true;
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    const byte_len = checkedByteLen(T, count) orelse return false;
    return validHostRange(ptr, byte_len);
}

fn validAlignedMutableHostArray(comptime T: type, ptr: [*c]T, count: usize) bool {
    if (count == 0) return true;
    const address = @intFromPtr(ptr);
    if (address == 0 or address % @alignOf(T) != 0) return false;
    const byte_len = checkedByteLen(T, count) orelse return false;
    return validHostRange(ptr, byte_len);
}

fn rangesOverlap(a_ptr: anytype, a_len: usize, b_ptr: anytype, b_len: usize) bool {
    if (a_len == 0 or b_len == 0) return false;
    const a_start = @intFromPtr(a_ptr);
    const b_start = @intFromPtr(b_ptr);
    const a_end = std.math.add(usize, a_start, a_len) catch return true;
    const b_end = std.math.add(usize, b_start, b_len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn ownedProject(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    if (!validAlignedHostObject(OwnedProject, handle)) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic or owned.destroyed) return null;
    return owned;
}

fn ownedProjectForDestroy(project: ?*Vizg_Project) ?*OwnedProject {
    const handle = project orelse return null;
    if (!validAlignedHostObject(OwnedProject, handle)) return null;
    const owned: *OwnedProject = @ptrCast(@alignCast(handle));
    if (owned.magic != project_magic) return null;
    return owned;
}

fn ownedResult(result: ?*const Vizg_ProjectResult) ?*const OwnedProjectResult {
    const handle = result orelse return null;
    if (!validAlignedHostObject(OwnedProjectResult, handle)) return null;
    const owned: *const OwnedProjectResult = @ptrCast(@alignCast(handle));
    if (owned.magic != result_magic) return null;
    const owner_handle: *Vizg_Project = @ptrCast(owned.owner);
    const owner = ownedProject(owner_handle) orelse return null;
    if (owner != owned.owner or !rangeInsideWorkspace(owner, handle, @sizeOf(OwnedProjectResult))) return null;
    return owned;
}

fn workspace(config: *const Vizg_ProjectConfig) ?[]u8 {
    if (config.workspace_ptr == null or config.workspace_len < projectWorkspaceOverhead()) return null;
    if (!validAlignedMutableHostArray(u8, config.workspace_ptr, config.workspace_len)) return null;
    if (@intFromPtr(config.workspace_ptr) % projectWorkspaceAlignment() != 0) return null;
    if (config.max_source_bytes == 0 or config.max_total_source_bytes == 0 or
        config.max_modules == 0 or config.max_diagnostics == 0 or
        config.max_requests == 0 or config.max_edges == 0 or config.max_graph_depth == 0 or
        config.max_semantic_types == 0) return null;
    return config.workspace_ptr[0..config.workspace_len];
}

fn inputOutsideWorkspace(owned: *const OwnedProject, ptr: anytype, len: usize) bool {
    if (len == 0) return true;
    if (!validHostRange(ptr, len)) return false;
    return !rangesOverlap(ptr, len, owned, owned.workspace_len);
}

fn rangeInsideWorkspace(owned: *const OwnedProject, ptr: anytype, len: usize) bool {
    if (!validHostRange(ptr, len)) return false;
    const start = @intFromPtr(ptr);
    const end = std.math.add(usize, start, len) catch return false;
    const workspace_start = @intFromPtr(owned);
    const workspace_end = std.math.add(usize, workspace_start, owned.workspace_len) catch return false;
    return start >= workspace_start and end <= workspace_end;
}

fn sourceInputsOutsideWorkspace(owned: *const OwnedProject, input: *const Vizg_ProjectSource) bool {
    return inputOutsideWorkspace(owned, input.logical_name_ptr, input.logical_name_len) and
        inputOutsideWorkspace(owned, input.source_ptr, input.source_len);
}

fn diagnosticSeverity(value: vizg.diagnostics.Severity) u8 {
    return switch (value) {
        .@"error" => 0,
        .warning => 1,
        .info => 2,
        .hint => 3,
    };
}

fn diagnosticPhase(value: vizg.ProjectDiagnosticPhase) u8 {
    return @intFromEnum(value);
}

fn diagnosticCode(value: vizg.diagnostics.DiagnosticCode) u32 {
    return switch (value) {
        .invalid_character => 1001,
        .unterminated_string => 1002,
        .unterminated_block_comment => 1003,
        .invalid_number => 1004,
        .invalid_escape_sequence => 1005,
        .unterminated_regexp => 1006,
        .invalid_regexp => 1007,
        .invalid_utf8 => 1008,
        .unexpected_token => 2001,
        .expected_token => 2002,
        .parse_recursion_limit_reached => 2003,
        .unsupported_syntax => 2004,
        .unsupported_ts_syntax => 2005,
        .unsupported_jsx => 2006,
        .duplicate_declaration => 3001,
        .duplicate_export => 3002,
        .cannot_find_name => 4001,
        .module_not_found => 5001,
        .module_access_denied => 5004,
        .module_host_failed => 5005,
        .missing_export => 5002,
        .circular_import => 5003,
        .unknown_type_name => 6004,
        .type_mismatch => 6005,
        .unknown_property => 6006,
        .invalid_index => 6007,
        .invalid_argument_count => 6008,
        .invalid_argument_type => 6009,
    };
}

fn diagnosticCount(owned: *const OwnedProject) usize {
    return owned.project.diagnostics().len;
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

fn requestOperation(value: vizg.project.RequestOperation) u32 {
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
    if (!validAlignedHostArray(u8, input.logical_name_ptr, input.logical_name_len) or
        !validAlignedHostArray(u8, input.source_ptr, input.source_len) or
        input.is_root > 1 or input.reserved[0] != 0 or input.reserved[1] != 0 or input.reserved[2] != 0)
    {
        return null;
    }
    return .{
        .id = .init(input.module_id),
        .logical_name = bytes(input.logical_name_ptr, input.logical_name_len),
        .bytes = bytes(input.source_ptr, input.source_len),
        .kind = sourceKind(input.kind) orelse return null,
    };
}

fn statusFromError(owned: *OwnedProject, err: anyerror) Vizg_ProjectStatus {
    if (limitKindFromError(err)) |kind| return limitStatus(owned, kind);
    return switch (err) {
        error.OutOfMemory => .OUT_OF_MEMORY,
        error.ParseRecursionLimitReached => .LIMIT_EXCEEDED,
        error.PendingRequests,
        error.IncompleteModules,
        error.ForeignRequest,
        error.InvalidResponseOrder,
        error.DuplicateResponse,
        error.DuplicateModule,
        error.UnknownImporter,
        error.UnknownModule,
        error.SourceNotSupplied,
        error.ModuleNotAnalyzed,
        error.ProjectFinished,
        => .INVALID_STATE,
        error.InvalidExternalExport,
        error.DuplicateExternalExport,
        error.ExternalDescriptorConflict,
        => .INVALID_ARGUMENT,
        else => .INTERNAL_ERROR,
    };
}

fn limitKindFromError(err: anyerror) ?Vizg_LimitKind {
    return switch (err) {
        error.SourceLimitExceeded => .SOURCE_BYTES,
        error.TotalSourceLimitExceeded => .TOTAL_SOURCE_BYTES,
        error.ModuleLimitExceeded => .MODULES,
        error.RequestLimitExceeded, error.RequestIdExhausted => .REQUESTS,
        error.EdgeLimitExceeded => .EDGES,
        error.GraphDepthLimitExceeded => .GRAPH_DEPTH,
        error.DiagnosticLimitExceeded => .DIAGNOSTICS,
        error.SemanticTypeLimitExceeded, error.TypeComplexityLimit => .SEMANTIC_GROWTH,
        else => null,
    };
}

fn limitStatus(owned: *OwnedProject, kind: Vizg_LimitKind) Vizg_ProjectStatus {
    owned.last_limit = kind;
    return .LIMIT_EXCEEDED;
}

fn beginProjectCall(owned: *OwnedProject) void {
    owned.last_limit = .NONE;
}

pub fn abiVersion() callconv(.c) u32 {
    return VIZG_ABI_VERSION;
}

fn projectSemantic(owned: *const OwnedProjectResult) ?*const vizg.semantics.BorrowedProjectSemanticResult {
    return owned.owner.project.semanticResult();
}

fn resultHasPhase(owned: *const OwnedProjectResult, phase: vizg.ProjectDiagnosticPhase) bool {
    for (owned.owner.project.diagnostics()) |item| {
        if (item.severity == .@"error" and item.phase == phase) return true;
    }
    return false;
}

fn outputOutsideWorkspace(owned: *const OwnedProjectResult, ptr: anytype, len: usize) bool {
    return validHostRange(ptr, len) and inputOutsideWorkspace(owned.owner, ptr, len);
}

pub fn projectWorkspaceAlignment() callconv(.c) usize {
    return @alignOf(OwnedProject);
}

pub fn projectWorkspaceOverhead() callconv(.c) usize {
    return std.mem.alignForward(usize, @sizeOf(OwnedProject), @alignOf(OwnedProject));
}

pub fn projectCreate(config: ?*const Vizg_ProjectConfig, out_project: [*c]?*Vizg_Project) callconv(.c) Vizg_ProjectStatus {
    const args = config orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectConfig, args) or
        !validAlignedMutableHostArray(?*Vizg_Project, out_project, 1) or
        rangesOverlap(args, @sizeOf(Vizg_ProjectConfig), out_project, @sizeOf(?*Vizg_Project)))
    {
        return .INVALID_ARGUMENT;
    }
    const storage = workspace(args) orelse return .INVALID_ARGUMENT;
    if (rangesOverlap(args, @sizeOf(Vizg_ProjectConfig), storage.ptr, storage.len) or
        rangesOverlap(out_project, @sizeOf(?*Vizg_Project), storage.ptr, storage.len)) return .INVALID_ARGUMENT;
    out_project[0] = null;
    const owned: *OwnedProject = @ptrCast(@alignCast(storage.ptr));
    owned.magic = project_magic;
    owned.fba = .init(storage[projectWorkspaceOverhead()..]);
    owned.step_attributes = .empty;
    owned.workspace_len = storage.len;
    owned.last_limit = .NONE;
    owned.result_ready = false;
    owned.destroyed = false;
    owned.project = .initWithLimits(owned.fba.allocator(), .{
        .max_source_bytes = args.max_source_bytes,
        .max_total_source_bytes = args.max_total_source_bytes,
        .max_modules = args.max_modules,
        .max_requests = args.max_requests,
        .max_edges = args.max_edges,
        .max_diagnostics = args.max_diagnostics,
        .max_graph_depth = args.max_graph_depth,
        .max_semantic_types = args.max_semantic_types,
    });
    out_project[0] = @ptrCast(owned);
    return .OK;
}

pub fn projectDestroy(project: ?*Vizg_Project) callconv(.c) void {
    const owned = ownedProjectForDestroy(project) orelse return;
    owned.deinit();
}

pub fn projectLimitKind(project: ?*Vizg_Project) callconv(.c) Vizg_LimitKind {
    const owned = ownedProject(project) orelse return .NONE;
    return owned.last_limit;
}

pub fn projectAddSource(project: ?*Vizg_Project, input: ?*const Vizg_ProjectSource) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectSource, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource)) or
        !sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    if (args.is_root == 1) {
        owned.project.addRoot(source) catch |err| return statusFromError(owned, err);
    } else {
        owned.project.supplySource(source) catch |err| return statusFromError(owned, err);
    }
    return .OK;
}

pub fn projectStep(project: ?*Vizg_Project, out_step: ?*Vizg_ProjectStep) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    beginProjectCall(owned);
    const output = out_step orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectStep, output, 1) or
        !inputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectStep))) return .INVALID_ARGUMENT;
    output.* = std.mem.zeroes(Vizg_ProjectStep);
    const next = owned.project.step() catch |err| return statusFromError(owned, err);
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
                .request_operation = requestOperation(request.operation),
                .type_only = @intFromBool(request.type_only),
                .reserved = .{ 0, 0, 0 },
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
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ProjectSource, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ProjectSource)) or
        !sourceInputsOutsideWorkspace(owned, args)) return .INVALID_ARGUMENT;
    if (args.is_root != 0) return .INVALID_ARGUMENT;
    const source = moduleSource(args) orelse return .INVALID_ARGUMENT;
    owned.project.respondSource(.init(request_id), source) catch |err| return statusFromError(owned, err);
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

fn validExternalExport(owned: *const OwnedProject, item: *const Vizg_ExternalExport) bool {
    if (!validAlignedHostArray(u8, item.name_ptr, item.name_len) or
        !inputOutsideWorkspace(owned, item.name_ptr, item.name_len) or
        item.namespace_flags == 0 or
        item.namespace_flags & ~@as(Vizg_ExternalNamespaceFlags, VIZG_EXTERNAL_NAMESPACE_BOTH) != 0 or
        item.has_type_metadata > 1 or
        item.reserved[0] != 0 or item.reserved[1] != 0 or
        exportKind(item.kind) == null)
    {
        return false;
    }
    return item.has_type_metadata == 0 or externalType(item.type_metadata) != null;
}

pub fn projectRespondExternal(project: ?*Vizg_Project, request_id: u64, input: ?*const Vizg_ExternalModule) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    beginProjectCall(owned);
    const args = input orelse return .INVALID_ARGUMENT;
    if (!validAlignedHostObject(Vizg_ExternalModule, args) or
        !inputOutsideWorkspace(owned, args, @sizeOf(Vizg_ExternalModule))) return .INVALID_ARGUMENT;
    if (!validAlignedHostArray(u8, args.logical_name_ptr, args.logical_name_len) or
        !validAlignedHostArray(Vizg_ExternalExport, args.exports_ptr, args.export_count)) return .INVALID_ARGUMENT;

    const exports_bytes = checkedByteLen(Vizg_ExternalExport, args.export_count) orelse return .INVALID_ARGUMENT;
    if (!inputOutsideWorkspace(owned, args.logical_name_ptr, args.logical_name_len) or
        !inputOutsideWorkspace(owned, args.exports_ptr, exports_bytes)) return .INVALID_ARGUMENT;
    if (args.export_count != 0) {
        for (args.exports_ptr[0..args.export_count]) |*item| {
            if (!validExternalExport(owned, item)) return .INVALID_ARGUMENT;
        }
    }

    const descriptor_bytes = checkedByteLen(vizg.ExternalExportDescriptor, args.export_count) orelse return .OUT_OF_MEMORY;
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
        output.* = .{
            .name = bytes(item.name_ptr, item.name_len),
            .kind = exportKind(item.kind).?,
            .namespace = .{
                .value = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_VALUE != 0,
                .type = item.namespace_flags & VIZG_EXTERNAL_NAMESPACE_TYPE != 0,
            },
            .type_metadata = if (item.has_type_metadata == 1)
                externalType(item.type_metadata).?
            else
                null,
        };
    }
    owned.project.respondExternalModule(.init(request_id), .{
        .id = .init(args.external_module_id),
        .logical_name = bytes(args.logical_name_ptr, args.logical_name_len),
        .exports = exports,
    }) catch |err| return statusFromError(owned, err);
    return .OK;
}

pub fn projectRespondFailure(project: ?*Vizg_Project, request_id: u64, failure_kind: u32) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    beginProjectCall(owned);
    switch (failure_kind) {
        0 => owned.project.respondNotFound(.init(request_id)) catch |err| return statusFromError(owned, err),
        1 => owned.project.respondDenied(.init(request_id)) catch |err| return statusFromError(owned, err),
        2 => owned.project.respondFailed(.init(request_id)) catch |err| return statusFromError(owned, err),
        else => return .INVALID_ARGUMENT,
    }
    return .OK;
}

pub fn projectFinish(project: ?*Vizg_Project, out_result: [*c]?*Vizg_ProjectResult) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedProject(project) orelse return .INVALID_ARGUMENT;
    beginProjectCall(owned);
    if (!validAlignedMutableHostArray(?*Vizg_ProjectResult, out_result, 1) or
        !inputOutsideWorkspace(owned, out_result, @sizeOf(?*Vizg_ProjectResult))) return .INVALID_ARGUMENT;
    out_result[0] = null;
    const finished = owned.project.finish() catch |err| return statusFromError(owned, err);
    if (owned.result_ready) {
        out_result[0] = @ptrCast(&owned.result_view);
        return .OK;
    }
    const result = &owned.result_view;
    const semantic_result = owned.project.semanticResult();
    const canonical_diagnostic_count = diagnosticCount(owned);
    result.* = .{ .magic = result_magic, .summary = .{
        .module_count = finished.module_count,
        .diagnostic_count = canonical_diagnostic_count,
        .edge_count = owned.project.edges().len,
        .import_count = if (semantic_result) |value| value.imports.len else 0,
        .export_count = if (semantic_result) |value| value.exports.len else 0,
        .is_partial = @intFromBool(finished.has_failures or if (semantic_result) |value| value.is_partial else false),
        .has_syntax_errors = @intFromBool(false),
        .has_semantic_errors = @intFromBool(false),
        .has_module_failures = @intFromBool(finished.has_failures),
        .reserved = .{ 0, 0, 0, 0 },
    }, .owner = owned };
    result.summary.has_syntax_errors = @intFromBool(
        resultHasPhase(result, .scanner) or resultHasPhase(result, .parser),
    );
    result.summary.has_semantic_errors = @intFromBool(
        resultHasPhase(result, .binder) or resultHasPhase(result, .resolver) or
            resultHasPhase(result, .types) or resultHasPhase(result, .checker),
    );
    owned.result_ready = true;
    out_result[0] = @ptrCast(result);
    return .OK;
}

pub fn projectResultSummary(result: ?*const Vizg_ProjectResult, out_summary: ?*Vizg_ProjectResultSummary) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_summary orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectResultSummary, output, 1) or
        !inputOutsideWorkspace(owned.owner, output, @sizeOf(Vizg_ProjectResultSummary))) return .INVALID_ARGUMENT;
    output.* = owned.summary;
    return .OK;
}

pub fn projectResultModule(result: ?*const Vizg_ProjectResult, index: usize, out_module: ?*Vizg_ProjectModuleInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_module orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectModuleInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectModuleInfo))) return .INVALID_ARGUMENT;
    const modules = owned.owner.project.modulesView();
    if (index >= modules.len) return .INVALID_ARGUMENT;
    const module = modules[index];
    const logical_name = if (module.source) |source| source.logical_name else "";
    output.* = .{
        .module_id = module.id.value(),
        .logical_name_ptr = if (logical_name.len == 0) null else logical_name.ptr,
        .logical_name_len = logical_name.len,
        .state = @intFromEnum(module.state),
        .is_root = @intFromBool(module.is_root),
        .has_source = @intFromBool(module.source != null),
        .reserved = .{ 0, 0 },
    };
    return .OK;
}

pub fn projectResultDiagnostic(result: ?*const Vizg_ProjectResult, index: usize, out_diagnostic: ?*Vizg_ProjectDiagnostic) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_diagnostic orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectDiagnostic, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectDiagnostic))) return .INVALID_ARGUMENT;
    const diagnostics = owned.owner.project.diagnostics();
    if (index >= diagnostics.len) return .INVALID_ARGUMENT;
    const item = diagnostics[index];
    output.* = .{
        .module_id = if (item.module_id) |value| value.value() else 0,
        .has_module_id = @intFromBool(item.module_id != null),
        .severity = diagnosticSeverity(item.severity),
        .phase = diagnosticPhase(item.phase),
        .reserved = 0,
        .code = diagnosticCode(item.code),
        .message_ptr = if (item.message.len == 0) null else item.message.ptr,
        .message_len = item.message.len,
        .logical_name_ptr = if (item.logical_name.len == 0) null else item.logical_name.ptr,
        .logical_name_len = item.logical_name.len,
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultEdge(result: ?*const Vizg_ProjectResult, index: usize, out_edge: ?*Vizg_ProjectEdgeInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_edge orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectEdgeInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectEdgeInfo))) return .INVALID_ARGUMENT;
    const edges = owned.owner.project.edges();
    if (index >= edges.len) return .INVALID_ARGUMENT;
    const item = edges[index];
    output.* = .{
        .request_id = item.request_id.value(),
        .importer_module_id = item.importer.value(),
        .target_module_id = if (item.target) |value| value.value() else 0,
        .external_module_id = if (item.external_target) |value| value.value() else 0,
        .specifier_ptr = if (item.raw_specifier.len == 0) null else item.raw_specifier.ptr,
        .specifier_len = item.raw_specifier.len,
        .request_operation = @intFromEnum(item.operation),
        .state = @intFromEnum(item.state),
        .type_only = @intFromBool(item.type_only),
        .has_target_module = @intFromBool(item.target != null),
        .has_external_target = @intFromBool(item.external_target != null),
        .reserved = 0,
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultImport(result: ?*const Vizg_ProjectResult, index: usize, out_import: ?*Vizg_ProjectImportInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_import orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectImportInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectImportInfo))) return .INVALID_ARGUMENT;
    const semantic = projectSemantic(owned) orelse return .INVALID_STATE;
    if (index >= semantic.imports.len) return .INVALID_ARGUMENT;
    const item = semantic.imports[index];
    if (item.edge_index >= owned.owner.project.edges().len) return .INTERNAL_ERROR;
    const edge = owned.owner.project.edges()[item.edge_index];
    output.* = .{
        .module_id = item.module_id,
        .target_module_id = if (edge.target) |target| target.value() else 0,
        .external_module_id = if (edge.external_target) |target| target.value() else 0,
        .edge_index = item.edge_index,
        .target_type_id = if (item.target) |target| target.type_id else 0,
        .link_state = @intFromEnum(item.state),
        .request_operation = @intFromEnum(edge.operation),
        .local_name_ptr = if (item.local_name.len == 0) null else item.local_name.ptr,
        .local_name_len = item.local_name.len,
        .imported_name_ptr = if (item.imported_name.len == 0) null else item.imported_name.ptr,
        .imported_name_len = item.imported_name.len,
        .specifier_ptr = if (edge.raw_specifier.len == 0) null else edge.raw_specifier.ptr,
        .specifier_len = edge.raw_specifier.len,
        .type_only = @intFromBool(item.type_only),
        .runtime_binding = @intFromBool(item.runtime_binding),
        .has_target_module = @intFromBool(edge.target != null),
        .has_external_target = @intFromBool(edge.external_target != null),
        .has_edge_index = 1,
        .has_semantic_target = @intFromBool(item.target != null),
        .reserved = .{ 0, 0 },
        .span = span(item.span),
    };
    return .OK;
}

pub fn projectResultExport(result: ?*const Vizg_ProjectResult, index: usize, out_export: ?*Vizg_ProjectExportInfo) callconv(.c) Vizg_ProjectStatus {
    const owned = ownedResult(result) orelse return .INVALID_ARGUMENT;
    const output = out_export orelse return .INVALID_ARGUMENT;
    if (!validAlignedMutableHostArray(Vizg_ProjectExportInfo, output, 1) or
        !outputOutsideWorkspace(owned, output, @sizeOf(Vizg_ProjectExportInfo))) return .INVALID_ARGUMENT;
    const semantic = projectSemantic(owned) orelse return .INVALID_STATE;
    if (index >= semantic.exports.len) return .INVALID_ARGUMENT;
    const item = semantic.exports[index];
    const source_edge = if (item.edge_index) |edge_index|
        if (edge_index < owned.owner.project.edges().len) owned.owner.project.edges()[edge_index] else return .INTERNAL_ERROR
    else
        null;
    output.* = .{
        .module_id = item.module_id,
        .target_module_id = if (source_edge) |edge| if (edge.target) |target| target.value() else 0 else 0,
        .external_module_id = if (source_edge) |edge| if (edge.external_target) |target| target.value() else 0 else 0,
        .edge_index = item.edge_index orelse 0,
        .target_type_id = item.identity.type_id,
        .name_ptr = if (item.name.len == 0) null else item.name.ptr,
        .name_len = item.name.len,
        .type_only = @intFromBool(item.type_only),
        .re_export = @intFromBool(item.re_export),
        .has_target_module = @intFromBool(if (source_edge) |edge| edge.target != null else false),
        .has_external_target = @intFromBool(if (source_edge) |edge| edge.external_target != null else false),
        .has_edge_index = @intFromBool(item.edge_index != null),
        .reserved = .{ 0, 0, 0 },
        .span = span(item.span),
    };
    return .OK;
}

comptime {
    @export(&abiVersion, .{ .name = "vizg_abi_version" });
    @export(&projectWorkspaceAlignment, .{ .name = "vizg_project_workspace_alignment" });
    @export(&projectWorkspaceOverhead, .{ .name = "vizg_project_workspace_overhead" });
    @export(&projectCreate, .{ .name = "vizg_project_create" });
    @export(&projectDestroy, .{ .name = "vizg_project_destroy" });
    @export(&projectLimitKind, .{ .name = "vizg_project_limit_kind" });
    @export(&projectAddSource, .{ .name = "vizg_project_add_source" });
    @export(&projectStep, .{ .name = "vizg_project_step" });
    @export(&projectRespondSource, .{ .name = "vizg_project_respond_source" });
    @export(&projectRespondExternal, .{ .name = "vizg_project_respond_external" });
    @export(&projectRespondFailure, .{ .name = "vizg_project_respond_failure" });
    @export(&projectFinish, .{ .name = "vizg_project_finish" });
    @export(&projectResultSummary, .{ .name = "vizg_project_result_summary" });
    @export(&projectResultModule, .{ .name = "vizg_project_result_module" });
    @export(&projectResultDiagnostic, .{ .name = "vizg_project_result_diagnostic" });
    @export(&projectResultEdge, .{ .name = "vizg_project_result_edge" });
    @export(&projectResultImport, .{ .name = "vizg_project_result_import" });
    @export(&projectResultExport, .{ .name = "vizg_project_result_export" });
}

test "public diagnostic ABI mappings are stable" {
    try std.testing.expectEqual(@as(u8, 0), diagnosticSeverity(.@"error"));
    try std.testing.expectEqual(@as(u8, 6), diagnosticPhase(.module_host));
    try std.testing.expectEqual(@as(u32, 1001), diagnosticCode(.invalid_character));
    try std.testing.expectEqual(@as(u32, 2003), diagnosticCode(.parse_recursion_limit_reached));
    try std.testing.expectEqual(@as(u32, 5001), diagnosticCode(.module_not_found));
    try std.testing.expectEqual(@as(u32, 5004), diagnosticCode(.module_access_denied));
    try std.testing.expectEqual(@as(u32, 5005), diagnosticCode(.module_host_failed));
    try std.testing.expectEqual(@as(u32, 6009), diagnosticCode(.invalid_argument_type));
}

test "public limit ABI values and exact error mappings are stable" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(Vizg_LimitKind.NONE));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Vizg_LimitKind.SOURCE_BYTES));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Vizg_LimitKind.TOTAL_SOURCE_BYTES));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Vizg_LimitKind.MODULES));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Vizg_LimitKind.REQUESTS));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(Vizg_LimitKind.EDGES));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(Vizg_LimitKind.GRAPH_DEPTH));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(Vizg_LimitKind.DIAGNOSTICS));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(Vizg_LimitKind.SEMANTIC_GROWTH));

    const mappings = [_]struct { err: anyerror, kind: Vizg_LimitKind }{
        .{ .err = error.SourceLimitExceeded, .kind = .SOURCE_BYTES },
        .{ .err = error.TotalSourceLimitExceeded, .kind = .TOTAL_SOURCE_BYTES },
        .{ .err = error.ModuleLimitExceeded, .kind = .MODULES },
        .{ .err = error.RequestLimitExceeded, .kind = .REQUESTS },
        .{ .err = error.RequestIdExhausted, .kind = .REQUESTS },
        .{ .err = error.EdgeLimitExceeded, .kind = .EDGES },
        .{ .err = error.GraphDepthLimitExceeded, .kind = .GRAPH_DEPTH },
        .{ .err = error.DiagnosticLimitExceeded, .kind = .DIAGNOSTICS },
        .{ .err = error.SemanticTypeLimitExceeded, .kind = .SEMANTIC_GROWTH },
        .{ .err = error.TypeComplexityLimit, .kind = .SEMANTIC_GROWTH },
    };
    for (mappings) |mapping| try std.testing.expectEqual(mapping.kind, limitKindFromError(mapping.err).?);
    try std.testing.expect(limitKindFromError(error.OutOfMemory) == null);
}

test "external response conversion uses reclaimable workspace scratch" {
    const workspace_bytes = 2 * 1024 * 1024;
    const c_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(c_words);
    const direct_words = try std.testing.allocator.alloc(u64, workspace_bytes / @sizeOf(u64));
    defer std.testing.allocator.free(direct_words);

    const limits = .{
        .max_source_bytes = 1024 * 1024,
        .max_total_source_bytes = 1024 * 1024,
        .max_modules = 32,
        .max_requests = 128,
        .max_edges = 128,
        .max_diagnostics = 1024,
        .max_graph_depth = 32,
        .max_semantic_types = 16 * 1024,
    };
    var c_config = Vizg_ProjectConfig{
        .workspace_ptr = @ptrCast(c_words.ptr),
        .workspace_len = workspace_bytes,
        .max_source_bytes = limits.max_source_bytes,
        .max_total_source_bytes = limits.max_total_source_bytes,
        .max_modules = limits.max_modules,
        .max_requests = limits.max_requests,
        .max_edges = limits.max_edges,
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
        .namespace_flags = VIZG_EXTERNAL_NAMESPACE_VALUE,
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

fn allocationFailureAbiSnapshot(allocator: std.mem.Allocator) !void {
    const word_count = (projectWorkspaceOverhead() + @sizeOf(u64) - 1) / @sizeOf(u64);
    const storage = try allocator.alloc(u64, word_count);
    const storage_bytes = std.mem.sliceAsBytes(storage);
    const owned: *OwnedProject = @ptrCast(@alignCast(storage.ptr));
    owned.* = .{
        .fba = .init(storage_bytes[projectWorkspaceOverhead()..projectWorkspaceOverhead()]),
        .project = .init(allocator),
        .workspace_len = storage_bytes.len,
    };
    defer {
        owned.deinit();
        allocator.free(storage);
    }

    try owned.project.addRoot(.{
        .id = .init(1),
        .logical_name = "fault:abi-snapshot",
        .bytes = "export const value: number = 1;",
    });
    try std.testing.expectEqual(vizg.ProjectStep.complete, try owned.project.step());

    var result: ?*Vizg_ProjectResult = @ptrFromInt(1);
    const status = projectFinish(@ptrCast(owned), &result);
    if (status == .OUT_OF_MEMORY) {
        try std.testing.expect(result == null);
        try std.testing.expect(!owned.result_ready);
        return error.OutOfMemory;
    }
    try std.testing.expectEqual(Vizg_ProjectStatus.OK, status);
    try std.testing.expect(result != null);
    try std.testing.expect(owned.result_ready);
}

test "ABI snapshot preparation publishes no result at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureAbiSnapshot, .{});
}
