const std = @import("std");

/// One allocation owned by a HirResult. Its address is the result-local
/// identity domain; numeric ID equality is meaningful only inside that domain.
pub const IdentityDomain = struct {
    marker: u8 = 0,
};

fn Id(comptime debug_name_: []const u8) type {
    return struct {
        const Self = @This();

        domain: ?*const IdentityDomain,
        raw_index: u32,

        pub const debug_name = debug_name_;
        pub const invalid: Self = .{
            .domain = null,
            .raw_index = std.math.maxInt(u32),
        };

        pub fn init(domain_: *const IdentityDomain, index_: u32) error{InvalidId}!Self {
            if (index_ == std.math.maxInt(u32)) return error.InvalidId;
            return .{ .domain = domain_, .raw_index = index_ };
        }

        pub fn index(self: Self) ?u32 {
            if (self.domain == null or self.raw_index == std.math.maxInt(u32)) return null;
            return self.raw_index;
        }

        pub fn isValidFor(self: Self, expected_domain: *const IdentityDomain) bool {
            return self.index() != null and self.domain.? == expected_domain;
        }

        pub fn eql(left: Self, right: Self) bool {
            return left.domain == right.domain and left.raw_index == right.raw_index;
        }
    };
}

pub const EntityId = Id("EntityId");
pub const FunctionId = Id("FunctionId");
pub const BlockId = Id("BlockId");
pub const InstructionId = Id("InstructionId");
pub const ValueId = Id("ValueId");
pub const BindingId = Id("BindingId");
pub const PlaceId = Id("PlaceId");
pub const RegionId = Id("RegionId");
pub const OriginId = Id("OriginId");
pub const SourceSiteId = Id("SourceSiteId");
