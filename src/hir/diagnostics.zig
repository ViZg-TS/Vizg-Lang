//! Stable HIR/lowering diagnostics in the reserved VZG7xxx range.

const limits = @import("limits.zig");
const tokens = @import("../frontend/tokens.zig");

pub const Code = enum {
    not_eligible,
    unsupported_executable_syntax,
    missing_semantic_identity,
    invalid_semantic_reference,
    illegal_operation,
    invalid_cfg,
    invalid_value_binding_or_place,
    invalid_region,
    canonicalization_budget,
    resource_limit,
    internal_invariant,
};

pub fn codeId(code: Code) []const u8 {
    return switch (code) {
        .not_eligible => "VZG7001",
        .unsupported_executable_syntax => "VZG7002",
        .missing_semantic_identity => "VZG7003",
        .invalid_semantic_reference => "VZG7004",
        .illegal_operation => "VZG7005",
        .invalid_cfg => "VZG7006",
        .invalid_value_binding_or_place => "VZG7007",
        .invalid_region => "VZG7008",
        .canonicalization_budget => "VZG7009",
        .resource_limit => "VZG7010",
        .internal_invariant => "VZG7011",
    };
}

pub fn summary(code: Code) []const u8 {
    return switch (code) {
        .not_eligible => "module is not eligible for HIR lowering",
        .unsupported_executable_syntax => "unsupported executable syntax reached HIR lowering",
        .missing_semantic_identity => "semantic identity required by HIR lowering is missing",
        .invalid_semantic_reference => "HIR lowering input has an invalid type, symbol or module reference",
        .illegal_operation => "illegal HIR operation survived legalization",
        .invalid_cfg => "HIR control-flow graph is invalid",
        .invalid_value_binding_or_place => "HIR value, binding or place use is invalid",
        .invalid_region => "HIR exception or cleanup region is invalid",
        .canonicalization_budget => "HIR canonicalization did not converge within its budget",
        .resource_limit => "HIR resource limit reached",
        .internal_invariant => "internal HIR lowering invariant failed",
    };
}

pub const Diagnostic = struct {
    code: Code,
    module_id: ?u64 = null,
    path: ?[]const u8 = null,
    span: ?tokens.Span = null,
    limit: ?limits.Violation = null,

    pub fn message(self: Diagnostic) []const u8 {
        if (self.limit) |violation| return limits.summary(violation.kind);
        return summary(self.code);
    }

    pub fn fromLimit(violation: limits.Violation) Diagnostic {
        return .{ .code = .resource_limit, .limit = violation };
    }
};

comptime {
    if (@typeInfo(Code).@"enum".fields.len != 11) @compileError("VZG7xxx allocation must stay exhaustive");
}
