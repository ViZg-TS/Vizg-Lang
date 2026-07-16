//! Structural validation for exception and cleanup regions.

const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");

pub const Error = error{InvalidRegion};

pub fn validateFunction(
    allocator: std.mem.Allocator,
    function: *const model.HirFunction,
    all_regions: []const model.HirRegion,
) (Error || std.mem.Allocator.Error)!void {
    for (function.regions, 0..) |region_id, index| {
        const region = findRegion(all_regions, region_id) orelse return error.InvalidRegion;
        if (!ids.FunctionId.eql(region.function, function.id)) return error.InvalidRegion;
        for (function.regions[0..index]) |prior| {
            if (ids.RegionId.eql(prior, region_id)) return error.InvalidRegion;
        }
        try validateRegionShape(function, region);
    }

    for (function.regions) |region_id| {
        const region = findRegion(all_regions, region_id).?;
        if (region.parent) |parent_id| {
            const parent = listedRegion(function, all_regions, parent_id) orelse return error.InvalidRegion;
            if (ids.RegionId.eql(parent.id, region.id)) return error.InvalidRegion;
            if (!containsAll(parent.protected_blocks, region.protected_blocks) or
                !containsBlock(parent.protected_blocks, region.handler)) return error.InvalidRegion;
        }
        try validateParentChain(function, all_regions, region);
    }

    for (function.regions, 0..) |left_id, left_index| {
        const left = findRegion(all_regions, left_id).?;
        for (function.regions[left_index + 1 ..]) |right_id| {
            const right = findRegion(all_regions, right_id).?;
            if (regionsOverlap(left, right) and
                !isAncestor(function, all_regions, left.id, right.id) and
                !isAncestor(function, all_regions, right.id, left.id)) return error.InvalidRegion;
        }
    }

    for (function.blocks) |block| {
        try validateTerminator(function, all_regions, &block);
        try validateProtectedEntries(function, all_regions, &block);
        try validateCatchInitializers(function, all_regions, &block);
    }
    try validateCatchBindings(function, all_regions);
    try validateResumeSites(allocator, function, all_regions);
}

fn validateRegionShape(function: *const model.HirFunction, region: *const model.HirRegion) Error!void {
    if (region.protected_blocks.len == 0) return error.InvalidRegion;
    if (findBlock(function, region.handler) == null or containsBlock(region.protected_blocks, region.handler))
        return error.InvalidRegion;
    if (region.continuation) |continuation| {
        if (findBlock(function, continuation) == null or containsBlock(region.protected_blocks, continuation))
            return error.InvalidRegion;
    }
    for (region.protected_blocks, 0..) |block_id, index| {
        if (findBlock(function, block_id) == null) return error.InvalidRegion;
        for (region.protected_blocks[0..index]) |prior| {
            if (ids.BlockId.eql(prior, block_id)) return error.InvalidRegion;
        }
    }
    const handler = findBlock(function, region.handler).?;
    switch (region.kind) {
        .catch_ => if (handler.parameters.len > 1) return error.InvalidRegion,
        .finally, .iterator_close => if (handler.parameters.len != 0) return error.InvalidRegion,
    }
}

fn validateParentChain(function: *const model.HirFunction, all_regions: []const model.HirRegion, start: *const model.HirRegion) Error!void {
    var current = start;
    var depth: usize = 0;
    while (current.parent) |parent_id| {
        current = listedRegion(function, all_regions, parent_id) orelse return error.InvalidRegion;
        depth += 1;
        if (depth > function.regions.len) return error.InvalidRegion;
    }
}

fn validateTerminator(function: *const model.HirFunction, all_regions: []const model.HirRegion, block: *const model.HirBlock) Error!void {
    switch (block.terminator) {
        .jump => |jump| if (findBlock(function, jump.target) == null) return error.InvalidRegion,
        .branch => |branch| {
            if (findBlock(function, branch.true_target) == null or findBlock(function, branch.false_target) == null)
                return error.InvalidRegion;
        },
        .leave_region => |leave| {
            const region = listedRegion(function, all_regions, leave.region) orelse return error.InvalidRegion;
            if (!containsBlock(region.protected_blocks, block.id) or !ids.BlockId.eql(region.handler, leave.cleanup))
                return error.InvalidRegion;
            switch (leave.completion) {
                .normal => |target| {
                    if (target) |block_id| {
                        if (findBlock(function, block_id) == null or containsBlock(region.protected_blocks, block_id))
                            return error.InvalidRegion;
                        const continuation = region.continuation orelse return error.InvalidRegion;
                        if (!ids.BlockId.eql(continuation, block_id)) return error.InvalidRegion;
                    }
                },
                .break_, .continue_ => |target| {
                    if (findBlock(function, target) == null or containsBlock(region.protected_blocks, target))
                        return error.InvalidRegion;
                },
                .return_, .throw => {},
            }
        },
        else => {},
    }
}

fn validateProtectedEntries(function: *const model.HirFunction, all_regions: []const model.HirRegion, block: *const model.HirBlock) Error!void {
    switch (block.terminator) {
        .jump => |jump| try validateEdge(function, all_regions, block.id, jump.target),
        .branch => |branch| {
            try validateEdge(function, all_regions, block.id, branch.true_target);
            try validateEdge(function, all_regions, block.id, branch.false_target);
        },
        else => {},
    }
}

fn validateEdge(function: *const model.HirFunction, all_regions: []const model.HirRegion, source: ids.BlockId, target: ids.BlockId) Error!void {
    for (function.regions) |region_id| {
        const region = findRegion(all_regions, region_id).?;
        if (containsBlock(region.protected_blocks, source) or !containsBlock(region.protected_blocks, target)) continue;
        if (!ids.BlockId.eql(region.protected_blocks[0], target)) return error.InvalidRegion;
    }
}

fn validateCatchInitializers(function: *const model.HirFunction, all_regions: []const model.HirRegion, block: *const model.HirBlock) Error!void {
    for (block.instructions) |instruction| switch (instruction.operation) {
        .initialize_binding => |initialize| {
            const binding = findBinding(function, initialize.binding) orelse continue;
            if (binding.kind != .catch_) continue;
            const region = catchRegionForHandler(function, all_regions, block.id) orelse return error.InvalidRegion;
            if (block.parameters.len != 1 or !ids.ValueId.eql(block.parameters[0].value, initialize.value))
                return error.InvalidRegion;
            _ = region;
        },
        else => {},
    };
}

fn validateCatchBindings(function: *const model.HirFunction, all_regions: []const model.HirRegion) Error!void {
    for (function.bindings) |binding| {
        if (binding.kind != .catch_) continue;
        var count: usize = 0;
        for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.operation) {
            .initialize_binding => |initialize| if (ids.BindingId.eql(initialize.binding, binding.id)) {
                if (catchRegionForHandler(function, all_regions, block.id) == null) return error.InvalidRegion;
                count += 1;
            },
            else => {},
        };
        if (count != 1) return error.InvalidRegion;
    }
}

fn validateResumeSites(allocator: std.mem.Allocator, function: *const model.HirFunction, all_regions: []const model.HirRegion) !void {
    for (function.blocks) |block| {
        if (block.terminator != .resume_completion) continue;
        var valid = false;
        for (function.regions) |region_id| {
            const region = findRegion(all_regions, region_id).?;
            if (region.kind == .catch_) continue;
            if (try reachableWithoutProtected(allocator, function, region, block.id)) {
                valid = true;
                break;
            }
        }
        if (!valid) return error.InvalidRegion;
    }
}

fn reachableWithoutProtected(allocator: std.mem.Allocator, function: *const model.HirFunction, region: *const model.HirRegion, goal: ids.BlockId) !bool {
    var pending: std.ArrayList(ids.BlockId) = .empty;
    defer pending.deinit(allocator);
    var visited = try allocator.alloc(bool, function.blocks.len);
    defer allocator.free(visited);
    @memset(visited, false);
    try pending.append(allocator, region.handler);
    while (pending.pop()) |block_id| {
        const index = blockIndex(function, block_id) orelse return error.InvalidRegion;
        if (visited[index]) continue;
        visited[index] = true;
        if (ids.BlockId.eql(block_id, goal)) return true;
        if (containsBlock(region.protected_blocks, block_id)) continue;
        if (region.continuation) |continuation| if (ids.BlockId.eql(block_id, continuation)) continue;
        switch (function.blocks[index].terminator) {
            .jump => |jump| try pending.append(allocator, jump.target),
            .branch => |branch| {
                try pending.append(allocator, branch.true_target);
                try pending.append(allocator, branch.false_target);
            },
            else => {},
        }
    }
    return false;
}

fn findRegion(all_regions: []const model.HirRegion, id: ids.RegionId) ?*const model.HirRegion {
    const raw = id.index() orelse return null;
    const index: usize = @intCast(raw);
    if (index >= all_regions.len or !ids.RegionId.eql(all_regions[index].id, id)) return null;
    return &all_regions[index];
}

fn listedRegion(function: *const model.HirFunction, all_regions: []const model.HirRegion, id: ids.RegionId) ?*const model.HirRegion {
    for (function.regions) |listed| if (ids.RegionId.eql(listed, id)) return findRegion(all_regions, id);
    return null;
}

fn findBlock(function: *const model.HirFunction, id: ids.BlockId) ?*const model.HirBlock {
    const index = blockIndex(function, id) orelse return null;
    return &function.blocks[index];
}

fn blockIndex(function: *const model.HirFunction, id: ids.BlockId) ?usize {
    for (function.blocks, 0..) |block, index| if (ids.BlockId.eql(block.id, id)) return index;
    return null;
}

fn findBinding(function: *const model.HirFunction, id: ids.BindingId) ?*const model.HirBinding {
    for (function.bindings) |*binding| if (ids.BindingId.eql(binding.id, id)) return binding;
    return null;
}

fn catchRegionForHandler(function: *const model.HirFunction, all_regions: []const model.HirRegion, block: ids.BlockId) ?*const model.HirRegion {
    for (function.regions) |region_id| {
        const region = findRegion(all_regions, region_id) orelse continue;
        if (region.kind == .catch_ and ids.BlockId.eql(region.handler, block)) return region;
    }
    return null;
}

fn containsBlock(items: []const ids.BlockId, target: ids.BlockId) bool {
    for (items) |item| if (ids.BlockId.eql(item, target)) return true;
    return false;
}

fn containsAll(parent: []const ids.BlockId, child: []const ids.BlockId) bool {
    for (child) |item| if (!containsBlock(parent, item)) return false;
    return true;
}

fn regionsOverlap(left: *const model.HirRegion, right: *const model.HirRegion) bool {
    for (left.protected_blocks) |block| if (containsBlock(right.protected_blocks, block)) return true;
    return false;
}

fn isAncestor(function: *const model.HirFunction, all_regions: []const model.HirRegion, ancestor: ids.RegionId, child: ids.RegionId) bool {
    var current = listedRegion(function, all_regions, child) orelse return false;
    var depth: usize = 0;
    while (current.parent) |parent_id| {
        if (ids.RegionId.eql(parent_id, ancestor)) return true;
        current = listedRegion(function, all_regions, parent_id) orelse return false;
        depth += 1;
        if (depth > function.regions.len) return false;
    }
    return false;
}
