const std = @import("std");
const cfg = @import("../frontend/cfg.zig");

pub const FactKey = struct {
    symbol: u32,
    /// Null for a block state. Set for a fact captured at a reference/program
    /// point, so consumers can distinguish two uses in the same block.
    reference: ?u32 = null,
};

pub const Fact = struct {
    key: FactKey,
    value: u32,
};

pub const State = []const Fact;

pub const BlockState = struct {
    block_id: cfg.BasicBlockId,
    entry: ?State = null,
    exit: ?State = null,
};

pub const StateBuilder = struct {
    allocator: std.mem.Allocator,
    facts: std.ArrayList(Fact) = .empty,

    pub fn initFrom(allocator: std.mem.Allocator, state: State) !StateBuilder {
        var result: StateBuilder = .{ .allocator = allocator };
        try result.facts.appendSlice(allocator, state);
        return result;
    }

    pub fn deinit(self: *StateBuilder) void {
        self.facts.deinit(self.allocator);
    }

    pub fn get(self: *const StateBuilder, key: FactKey) ?u32 {
        for (self.facts.items) |fact| if (eqlKey(fact.key, key)) return fact.value;
        return null;
    }

    pub fn set(self: *StateBuilder, key: FactKey, value: u32) !void {
        for (self.facts.items) |*fact| if (eqlKey(fact.key, key)) {
            fact.value = value;
            return;
        };
        try self.facts.append(self.allocator, .{ .key = key, .value = value });
    }

    pub fn remove(self: *StateBuilder, key: FactKey) void {
        for (self.facts.items, 0..) |fact, index| if (eqlKey(fact.key, key)) {
            _ = self.facts.swapRemove(index);
            return;
        };
    }

    pub fn clear(self: *StateBuilder) void {
        self.facts.clearRetainingCapacity();
    }

    fn freeze(self: *StateBuilder) !State {
        std.mem.sort(Fact, self.facts.items, {}, lessThanFact);
        return self.facts.toOwnedSlice(self.allocator);
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    blocks: []BlockState,

    pub fn deinit(self: *Result) void {
        for (self.blocks) |block| {
            if (block.entry) |state| self.allocator.free(state);
            if (block.exit) |state| self.allocator.free(state);
        }
        self.allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn lookup(self: *const Result, block_id: cfg.BasicBlockId) ?BlockState {
        if (@as(usize, @intCast(block_id)) >= self.blocks.len) return null;
        return self.blocks[@intCast(block_id)];
    }
};

/// Solve a reusable forward "may reach" dataflow problem. Context provides:
///
///   transferBlock(block, *StateBuilder)
///   transferEdge(predecessor, successor, *StateBuilder)
///   mergeValues(key, left, right) -> ?u32
///
/// Facts missing from any reachable predecessor are absent after the join.
/// This makes an absent fact the conservative lattice top (the symbol's base
/// type for narrowing) without teaching this engine language-specific rules.
pub fn solve(
    allocator: std.mem.Allocator,
    graph: cfg.ControlFlowGraph,
    initial: State,
    context: anytype,
) !Result {
    var blocks = try allocator.alloc(BlockState, graph.blocks.len);
    for (blocks, 0..) |*block, index| block.* = .{ .block_id = @intCast(index) };
    errdefer {
        for (blocks) |block| {
            if (block.entry) |state| allocator.free(state);
            if (block.exit) |state| allocator.free(state);
        }
        allocator.free(blocks);
    }

    var queued = try allocator.alloc(bool, graph.blocks.len);
    defer allocator.free(queued);
    @memset(queued, false);
    var worklist: std.ArrayList(cfg.BasicBlockId) = .empty;
    defer worklist.deinit(allocator);
    try worklist.append(allocator, graph.entry);
    queued[@intCast(graph.entry)] = true;

    var cursor: usize = 0;
    while (cursor < worklist.items.len) : (cursor += 1) {
        const block_id = worklist.items[cursor];
        queued[@intCast(block_id)] = false;
        const block = graph.blocks[@intCast(block_id)];

        const next_entry = if (block_id == graph.entry)
            try allocator.dupe(Fact, initial)
        else
            try joinPredecessors(allocator, graph, blocks, block, context);
        if (next_entry == null) continue;

        const entry_changed = blocks[@intCast(block_id)].entry == null or
            !eqlState(blocks[@intCast(block_id)].entry.?, next_entry.?);
        if (blocks[@intCast(block_id)].entry) |old| allocator.free(old);
        blocks[@intCast(block_id)].entry = next_entry;

        var output = try StateBuilder.initFrom(allocator, next_entry.?);
        errdefer output.deinit();
        try context.transferBlock(block, &output);
        const next_exit = try output.freeze();
        const exit_changed = blocks[@intCast(block_id)].exit == null or
            !eqlState(blocks[@intCast(block_id)].exit.?, next_exit);
        if (blocks[@intCast(block_id)].exit) |old| allocator.free(old);
        blocks[@intCast(block_id)].exit = next_exit;

        if (entry_changed or exit_changed) for (block.successors) |successor| {
            if (queued[@intCast(successor)]) continue;
            try worklist.append(allocator, successor);
            queued[@intCast(successor)] = true;
        };
    }

    return .{ .allocator = allocator, .blocks = blocks };
}

fn joinPredecessors(allocator: std.mem.Allocator, graph: cfg.ControlFlowGraph, states: []const BlockState, block: cfg.BasicBlock, context: anytype) !?State {
    var joined: ?State = null;
    for (block.predecessors) |predecessor_id| {
        const predecessor_state = states[@intCast(predecessor_id)].exit orelse continue;
        var edge = try StateBuilder.initFrom(allocator, predecessor_state);
        errdefer edge.deinit();
        try context.transferEdge(graph.blocks[@intCast(predecessor_id)], block, &edge);
        const edge_state = try edge.freeze();
        if (joined) |current| {
            const merged = try mergeStates(allocator, current, edge_state, context);
            allocator.free(current);
            allocator.free(edge_state);
            joined = merged;
        } else {
            joined = edge_state;
        }
    }
    return joined;
}

fn mergeStates(allocator: std.mem.Allocator, left: State, right: State, context: anytype) !State {
    var result: std.ArrayList(Fact) = .empty;
    errdefer result.deinit(allocator);
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const order = orderKey(left[left_index].key, right[right_index].key);
        switch (order) {
            .lt => left_index += 1,
            .gt => right_index += 1,
            .eq => {
                if (try context.mergeValues(left[left_index].key, left[left_index].value, right[right_index].value)) |value|
                    try result.append(allocator, .{ .key = left[left_index].key, .value = value });
                left_index += 1;
                right_index += 1;
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

fn eqlState(left: State, right: State) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!eqlKey(a.key, b.key) or a.value != b.value) return false;
    return true;
}

fn eqlKey(left: FactKey, right: FactKey) bool {
    return left.symbol == right.symbol and left.reference == right.reference;
}

fn orderKey(left: FactKey, right: FactKey) std.math.Order {
    if (left.symbol < right.symbol) return .lt;
    if (left.symbol > right.symbol) return .gt;
    if (left.reference == null and right.reference != null) return .lt;
    if (left.reference != null and right.reference == null) return .gt;
    if (left.reference) |left_reference| {
        const right_reference = right.reference.?;
        if (left_reference < right_reference) return .lt;
        if (left_reference > right_reference) return .gt;
    }
    return .eq;
}

fn lessThanFact(_: void, left: Fact, right: Fact) bool {
    return orderKey(left.key, right.key) == .lt;
}

const TestContext = struct {
    visits: []u32,

    fn transferBlock(self: *@This(), block: cfg.BasicBlock, state: *StateBuilder) !void {
        self.visits[@intCast(block.id)] += 1;
        for (block.statements) |statement| switch (statement) {
            100 => try state.set(.{ .symbol = 1 }, 10),
            101 => try state.set(.{ .symbol = 1 }, 20),
            102 => state.remove(.{ .symbol = 1 }),
            else => {},
        };
    }

    fn transferEdge(_: *@This(), _: cfg.BasicBlock, _: cfg.BasicBlock, _: *StateBuilder) !void {}

    fn mergeValues(_: *@This(), _: FactKey, left: u32, right: u32) !?u32 {
        return if (left == right) left else @max(left, right);
    }
};

test "forward solver merges a diamond deterministically" {
    const blocks = [_]cfg.BasicBlock{
        .{ .id = 0, .kind = .entry, .statements = &.{}, .successors = &.{ 1, 2 }, .predecessors = &.{} },
        .{ .id = 1, .statements = &.{100}, .successors = &.{3}, .predecessors = &.{0} },
        .{ .id = 2, .statements = &.{101}, .successors = &.{3}, .predecessors = &.{0} },
        .{ .id = 3, .kind = .exit, .statements = &.{}, .successors = &.{}, .predecessors = &.{ 1, 2 } },
    };
    var visits = [_]u32{0} ** blocks.len;
    var context: TestContext = .{ .visits = &visits };
    var result = try solve(std.testing.allocator, .{ .entry = 0, .exit = 3, .blocks = &blocks }, &.{}, &context);
    defer result.deinit();
    const entry = result.lookup(3).?.entry.?;
    try std.testing.expectEqual(@as(usize, 1), entry.len);
    try std.testing.expectEqual(@as(u32, 20), entry[0].value);
}

test "forward solver converges through a loop and invalidates facts" {
    const blocks = [_]cfg.BasicBlock{
        .{ .id = 0, .kind = .entry, .statements = &.{100}, .successors = &.{1}, .predecessors = &.{} },
        .{ .id = 1, .kind = .condition, .statements = &.{}, .successors = &.{ 2, 3 }, .predecessors = &.{ 0, 2 } },
        .{ .id = 2, .statements = &.{102}, .successors = &.{1}, .predecessors = &.{1} },
        .{ .id = 3, .kind = .exit, .statements = &.{}, .successors = &.{}, .predecessors = &.{1} },
    };
    var visits = [_]u32{0} ** blocks.len;
    var context: TestContext = .{ .visits = &visits };
    var result = try solve(std.testing.allocator, .{ .entry = 0, .exit = 3, .blocks = &blocks }, &.{}, &context);
    defer result.deinit();
    try std.testing.expect(visits[1] >= 2);
    try std.testing.expectEqual(@as(usize, 0), result.lookup(3).?.entry.?.len);
}
