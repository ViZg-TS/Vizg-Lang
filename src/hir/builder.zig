//! Allocation and limit-checked insertion for raw HIR construction.

const std = @import("std");
const ids = @import("ids.zig");
const limits_mod = @import("limits.zig");
const model = @import("model.zig");
const origin = @import("origin.zig");
const result_mod = @import("result.zig");
const trace = @import("trace.zig");

pub const Builder = struct {
    result: *result_mod.HirResult,
    allocator: std.mem.Allocator,
    budget: limits_mod.Budget,
    violation: ?limits_mod.Violation = null,
    modules: std.ArrayList(model.HirModule) = .empty,
    entities: std.ArrayList(model.HirEntity) = .empty,
    functions: std.ArrayList(model.HirFunction) = .empty,
    regions: std.ArrayList(model.HirRegion) = .empty,
    source_sites: usize = 0,
    debug_level: origin.DebugLevel = .none,
    origins: std.ArrayList(origin.OriginRecord) = .empty,
    trace_events: std.ArrayList(trace.Event) = .empty,

    pub fn init(result: *result_mod.HirResult, configured_limits: limits_mod.Limits) Builder {
        return initWithDebug(result, configured_limits, .none);
    }

    pub fn initWithDebug(result: *result_mod.HirResult, configured_limits: limits_mod.Limits, debug_level: origin.DebugLevel) Builder {
        return .{
            .result = result,
            .allocator = result.ownedAllocator(),
            .budget = .init(configured_limits),
            .debug_level = debug_level,
        };
    }

    pub fn reserve(self: *Builder, kind: limits_mod.LimitKind, count: usize) error{ResourceLimit}!void {
        if (self.budget.reserve(kind, count)) |violation| {
            self.violation = violation;
            return error.ResourceLimit;
        }
    }

    pub fn copyString(self: *Builder, value: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, value);
    }

    pub fn makeId(self: *Builder, comptime IdType: type, index: usize) !IdType {
        if (index >= std.math.maxInt(u32)) return error.IdOverflow;
        return self.result.makeId(IdType, @intCast(index));
    }

    pub fn nextSourceSite(self: *Builder) !ids.SourceSiteId {
        const id = try self.makeId(ids.SourceSiteId, self.source_sites);
        self.source_sites += 1;
        return id;
    }

    pub fn appendOrigin(self: *Builder, record: origin.OriginRecord) !ids.OriginId {
        try self.reserve(.origins, 1);
        const id = try self.makeId(ids.OriginId, self.origins.items.len);
        try self.origins.append(self.allocator, record);
        return id;
    }

    /// Legacy synthetic sites are filled by the module provenance pass.
    pub fn nextOrigin(_: *Builder) !ids.OriginId {
        return .invalid;
    }

    pub fn appendTrace(self: *Builder, event: trace.Event) !void {
        if (self.debug_level != .full) return;
        try self.reserve(.trace_events, 1);
        try self.trace_events.append(self.allocator, event);
    }

    pub fn appendImportBinding(self: *Builder, bindings: *std.ArrayList(model.HirBinding), binding: model.HirBinding) !void {
        try self.reserve(.bindings, 1);
        try bindings.append(self.allocator, binding);
    }

    pub fn appendBinding(self: *Builder, bindings: *std.ArrayList(model.HirBinding), binding: model.HirBinding) !void {
        try self.reserve(.bindings, 1);
        try bindings.append(self.allocator, binding);
    }

    pub fn appendEntity(self: *Builder, entity: model.HirEntity) !void {
        try self.reserve(.entities, 1);
        try self.entities.append(self.allocator, entity);
    }

    pub fn reserveFunction(self: *Builder, block_count: usize) !void {
        try self.reserve(.functions, 1);
        try self.reserve(.blocks_per_function, block_count);
        try self.reserve(.blocks, block_count);
    }

    pub fn appendFunction(self: *Builder, function: model.HirFunction) !void {
        try self.functions.append(self.allocator, function);
        self.budget.usage.blocks_per_function = 0;
    }

    pub fn replaceFunction(self: *Builder, function: model.HirFunction) !void {
        try self.result.requireOwnedId(function.id);
        const index: usize = @intCast(function.id.index() orelse return error.InvalidFunctionId);
        if (index >= self.functions.items.len) return error.InvalidFunctionId;
        self.functions.items[index] = function;
        self.budget.usage.blocks_per_function = 0;
    }

    pub fn appendModule(self: *Builder, module: model.HirModule) !void {
        try self.modules.append(self.allocator, module);
    }

    pub fn reserveRegion(self: *Builder, function: ids.FunctionId, kind: model.HirRegionKind, nesting_depth: usize) !ids.RegionId {
        try self.reserveRegionNesting(nesting_depth);
        try self.reserve(.regions, 1);
        const id = try self.makeId(ids.RegionId, self.regions.items.len);
        try self.regions.append(self.allocator, .{
            .id = id,
            .function = function,
            .parent = null,
            .kind = kind,
            .protected_blocks = &.{},
            .handler = .invalid,
            .continuation = null,
            .origin = .invalid,
        });
        return id;
    }

    pub fn replaceRegion(self: *Builder, region: model.HirRegion) !void {
        try self.result.requireOwnedId(region.id);
        const index: usize = @intCast(region.id.index() orelse return error.InvalidRegionId);
        if (index >= self.regions.items.len) return error.InvalidRegionId;
        self.regions.items[index] = region;
    }

    /// Records the maximum active cleanup depth before region allocation.
    fn reserveRegionNesting(self: *Builder, depth: usize) !void {
        if (depth <= self.budget.usage.region_nesting) return;
        if (limits_mod.checkGrowth(.region_nesting, 0, depth, self.budget.limits.region_nesting)) |violation| {
            self.violation = violation;
            return error.ResourceLimit;
        }
        self.budget.usage.region_nesting = depth;
    }

    pub fn finish(self: *Builder) !void {
        self.result.project = .{
            .modules = try self.modules.toOwnedSlice(self.allocator),
            .entities = try self.entities.toOwnedSlice(self.allocator),
            .functions = try self.functions.toOwnedSlice(self.allocator),
            .regions = try self.regions.toOwnedSlice(self.allocator),
            .origins = .{ .records = try self.origins.toOwnedSlice(self.allocator) },
            .lowering_trace = if (self.debug_level == .full) .{
                .events = try self.trace_events.toOwnedSlice(self.allocator),
            } else null,
        };
    }
};
