const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
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
        self.semantic_result = null;
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

    pub fn makeId(self: *const HirResult, comptime IdType: type, index: u32) !IdType {
        return IdType.init(self.identity_domain, index);
    }

    /// Debug/verifier boundary for rejecting IDs created by another HirResult.
    pub fn requireOwnedId(self: *const HirResult, id: anytype) error{ForeignId}!void {
        if (!id.isValidFor(self.identity_domain)) return error.ForeignId;
    }
};
