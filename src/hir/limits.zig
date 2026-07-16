//! Bounded resources shared by HIR lowering, tracing and canonicalization.

const std = @import("std");

pub const LimitKind = enum {
    input_modules,
    input_source_bytes,
    input_ast_nodes,
    entities,
    functions,
    blocks_per_function,
    blocks,
    instructions,
    values,
    bindings,
    places,
    regions,
    region_nesting,
    origins,
    trace_events,
    rewrites,
};

pub const Limits = struct {
    input_modules: usize = 16_384,
    input_source_bytes: usize = 256 * 1024 * 1024,
    input_ast_nodes: usize = 16_000_000,
    entities: usize = 4_000_000,
    functions: usize = 1_000_000,
    blocks_per_function: usize = 1_000_000,
    blocks: usize = 8_000_000,
    instructions: usize = 64_000_000,
    values: usize = 64_000_000,
    bindings: usize = 16_000_000,
    places: usize = 16_000_000,
    regions: usize = 8_000_000,
    region_nesting: usize = 1_024,
    origins: usize = 64_000_000,
    trace_events: usize = 128_000_000,
    rewrites: usize = 64_000_000,

    pub fn value(self: Limits, kind: LimitKind) usize {
        return switch (kind) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }
};

pub const Usage = struct {
    input_modules: usize = 0,
    input_source_bytes: usize = 0,
    input_ast_nodes: usize = 0,
    entities: usize = 0,
    functions: usize = 0,
    blocks_per_function: usize = 0,
    blocks: usize = 0,
    instructions: usize = 0,
    values: usize = 0,
    bindings: usize = 0,
    places: usize = 0,
    regions: usize = 0,
    region_nesting: usize = 0,
    origins: usize = 0,
    trace_events: usize = 0,
    rewrites: usize = 0,

    pub fn value(self: Usage, kind: LimitKind) usize {
        return switch (kind) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    fn valuePtr(self: *Usage, kind: LimitKind) *usize {
        return switch (kind) {
            inline else => |tag| &@field(self, @tagName(tag)),
        };
    }
};

pub const Violation = struct {
    kind: LimitKind,
    limit: usize,
    attempted: usize,
};

pub fn summary(kind: LimitKind) []const u8 {
    return switch (kind) {
        .input_modules => "input module limit reached",
        .input_source_bytes => "input source byte limit reached",
        .input_ast_nodes => "input AST node limit reached",
        .entities => "HIR entity limit reached",
        .functions => "HIR function limit reached",
        .blocks_per_function => "HIR per-function block limit reached",
        .blocks => "HIR project block limit reached",
        .instructions => "HIR instruction limit reached",
        .values => "HIR value limit reached",
        .bindings => "HIR binding limit reached",
        .places => "HIR place limit reached",
        .regions => "HIR region limit reached",
        .region_nesting => "HIR region nesting limit reached",
        .origins => "HIR origin limit reached",
        .trace_events => "HIR trace event limit reached",
        .rewrites => "HIR canonicalization rewrite limit reached",
    };
}

/// Checks a proposed growth without modifying state. Builders must call this
/// before the allocation or insertion represented by `additional`.
pub fn checkGrowth(kind: LimitKind, current: usize, additional: usize, limit: usize) ?Violation {
    const attempted = std.math.add(usize, current, additional) catch return .{
        .kind = kind,
        .limit = limit,
        .attempted = std.math.maxInt(usize),
    };
    if (attempted > limit) return .{ .kind = kind, .limit = limit, .attempted = attempted };
    return null;
}

pub const Budget = struct {
    limits: Limits,
    usage: Usage = .{},

    pub fn init(limits: Limits) Budget {
        return .{ .limits = limits };
    }

    /// Reserves capacity logically. On failure usage is unchanged, permitting
    /// callers to return a controlled diagnostic before allocating or growing.
    pub fn reserve(self: *Budget, kind: LimitKind, additional: usize) ?Violation {
        const slot = self.usage.valuePtr(kind);
        if (checkGrowth(kind, slot.*, additional, self.limits.value(kind))) |violation| return violation;
        slot.* += additional;
        return null;
    }
};

test "budget checks growth before mutating usage" {
    var limits: Limits = .{};
    limits.instructions = 2;
    var budget = Budget.init(limits);
    try std.testing.expect(budget.reserve(.instructions, 2) == null);
    const violation = budget.reserve(.instructions, 1).?;
    try std.testing.expectEqual(LimitKind.instructions, violation.kind);
    try std.testing.expectEqual(@as(usize, 2), budget.usage.instructions);
}
