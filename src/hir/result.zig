const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
const semantics = @import("../semantics/root.zig");

/// Project-owned HIR output. After `initEmpty` succeeds, callers may only read
/// it until `deinit`. The borrowed semantic result must outlive this value;
/// HirResult neither mutates nor destroys semantic storage.
pub const HirResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    identity_domain: *ids.IdentityDomain,
    semantic_result: *const semantics.BorrowedProjectSemanticResult,
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
        return self.semantic_result;
    }

    pub fn makeId(self: *const HirResult, comptime IdType: type, index: u32) !IdType {
        return IdType.init(self.identity_domain, index);
    }

    /// Debug/verifier boundary for rejecting IDs created by another HirResult.
    pub fn requireOwnedId(self: *const HirResult, id: anytype) error{ForeignId}!void {
        if (!id.isValidFor(self.identity_domain)) return error.ForeignId;
    }
};
