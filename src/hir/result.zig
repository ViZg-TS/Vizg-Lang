const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
const consumer_index = @import("consumer_index.zig");
const reachability = @import("reachability.zig");
const semantics = @import("../semantics/root.zig");
const types = @import("../types/root.zig");

/// Project-owned HIR output. After `initEmpty` succeeds, callers may only read
/// it until `deinit`. Construction temporarily borrows semantic state; `seal`
/// snapshots the complete type store and removes that lifetime dependency.
pub const HirResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    identity_domain: *ids.IdentityDomain,
    semantic_result: ?*const semantics.BorrowedProjectSemanticResult,
    type_store: ?types.TypeStore = null,
    project: model.HirProject,
    consumer_index: ?consumer_index.Index = null,

    pub fn initEmpty(
        allocator: std.mem.Allocator,
        semantic_result: *const semantics.BorrowedProjectSemanticResult,
    ) !HirResult {
        const identity_domain = try allocator.create(ids.IdentityDomain);
        errdefer allocator.destroy(identity_domain);
        identity_domain.* = .{};

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .identity_domain = identity_domain,
            .semantic_result = semantic_result,
            .project = .{},
        };
    }

    pub fn deinit(self: *HirResult) void {
        if (self.consumer_index) |*index| index.deinit();
        self.consumer_index = null;
        self.arena.deinit();
        self.allocator.destroy(self.identity_domain);
        self.* = undefined;
    }

    pub fn ownedAllocator(self: *HirResult) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn semanticResult(self: *const HirResult) *const semantics.BorrowedProjectSemanticResult {
        return self.semantic_result orelse unreachable;
    }

    pub fn seal(self: *HirResult) !void {
        if (self.type_store != null) return error.AlreadySealed;
        self.type_store = try self.semanticResult().type_store.cloneReadOnly(self.ownedAllocator());
        self.consumer_index = try consumer_index.Index.build(self.allocator, self.identity_domain, self.project);
        self.semantic_result = null;
    }

    pub fn consumerIndex(self: *const HirResult) *const consumer_index.Index {
        return if (self.consumer_index) |*index| index else unreachable;
    }

    pub fn artifactReachabilityScratchSize(self: *const HirResult) !usize {
        if (self.type_store == null) return error.UnsealedResult;
        return reachability.scratchSize(self.project, self.consumerIndex());
    }

    /// Stateless artifact-rooted semantic closure over immutable canonical HIR.
    /// All root-dependent storage is caller-owned; immutable result views remain
    /// safe to query in parallel as required by the public C ABI contract.
    pub fn analyzeArtifactReachability(
        self: *const HirResult,
        scratch: []align(@alignOf(u64)) u8,
        request: reachability.Request,
        output: reachability.Output,
    ) !reachability.Summary {
        const store = if (self.type_store) |*value| value else return error.UnsealedResult;
        return reachability.analyze(
            scratch,
            self.project,
            store,
            self.consumerIndex(),
            request,
            output,
        );
    }

    pub fn lookupType(self: *const HirResult, id: types.TypeId) ?types.Type {
        return if (self.type_store) |*store| store.lookup(id) else null;
    }

    pub fn typeCount(self: *const HirResult) usize {
        return if (self.type_store) |*store| store.definedCount() else 0;
    }

    pub fn typeAt(self: *const HirResult, ordinal: usize) ?types.Type {
        return if (self.type_store) |*store| store.typeAt(ordinal) else null;
    }

    pub fn lookupFunctionSignature(self: *const HirResult, id: types.TypeId) ?types.FunctionSignature {
        return if (self.type_store) |*store| store.lookupFunctionSignature(id) else null;
    }

    /// Resolve one applied generic to its canonical substituted target. This
    /// remains a read-only HIR detail query; ordinary types return themselves.
    pub fn resolveAppliedTarget(self: *const HirResult, id: types.TypeId) !types.TypeId {
        return if (self.type_store) |*store| store.resolveAppliedTarget(id) else error.UnsealedResult;
    }

    pub fn makeId(self: *const HirResult, comptime IdType: type, index: u32) !IdType {
        return IdType.init(self.identity_domain, index);
    }

    /// Debug/verifier boundary for rejecting IDs created by another HirResult.
    pub fn requireOwnedId(self: *const HirResult, id: anytype) error{ForeignId}!void {
        if (!id.isValidFor(self.identity_domain)) return error.ForeignId;
    }
};
