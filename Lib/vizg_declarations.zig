//! Declaration-only Zig companion for the official ViZG C ABI.
//!
//! Importing this module translates the public header. It deliberately does
//! not import `vizg-impl`, `abi.zig`, or any other implementation source.

pub const c = @cImport({
    @cInclude("vizg.h");
});

pub const VIZG_ABI_VERSION: u32 = c.VIZG_ABI_VERSION;
pub const VIZG_EXTERNAL_MODULE_API_VERSION: u32 = c.VIZG_EXTERNAL_MODULE_API_VERSION;
pub const VIZG_HIR_API_VERSION: u32 = c.VIZG_HIR_API_VERSION;
pub const VIZG_HIR_PAYLOAD_API_VERSION: u32 = c.VIZG_HIR_PAYLOAD_API_VERSION;
pub const VIZG_HIR_DETAIL_API_VERSION: u32 = c.VIZG_HIR_DETAIL_API_VERSION;
pub const VIZG_HIR_REACHABILITY_API_VERSION: u32 = c.VIZG_HIR_REACHABILITY_API_VERSION;
pub const VIZG_HIR_CONSUMER_API_VERSION: u32 = c.VIZG_HIR_CONSUMER_API_VERSION;
pub const VIZG_HIR_REACH_TRIGGER_CANONICAL_ARRAY_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_CANONICAL_ARRAY_BASE;
pub const VIZG_HIR_REACH_TRIGGER_PLACE_DELETED: u32 = c.VIZG_HIR_REACH_TRIGGER_PLACE_DELETED;
pub const VIZG_HIR_REACH_TRIGGER_PRIMITIVE_STRING_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_PRIMITIVE_STRING_BASE;
pub const VIZG_HIR_REACH_TRIGGER_PRIMITIVE_NUMBER_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_PRIMITIVE_NUMBER_BASE;
pub const VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BOOLEAN_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BOOLEAN_BASE;
pub const VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BIGINT_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BIGINT_BASE;
pub const VIZG_HIR_REACH_TRIGGER_PRIMITIVE_SYMBOL_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_PRIMITIVE_SYMBOL_BASE;
pub const VIZG_HIR_REACH_TRIGGER_FUNCTION_BASE: u32 = c.VIZG_HIR_REACH_TRIGGER_FUNCTION_BASE;
pub const VIZG_HIR_REACH_TRIGGER_STRING_CONCAT_ADD: u32 = c.VIZG_HIR_REACH_TRIGGER_STRING_CONCAT_ADD;
pub const VIZG_INTRINSIC_CONTRACT_VERSION: u32 = c.VIZG_INTRINSIC_CONTRACT_VERSION;
pub const VIZG_LANGUAGE_ITEM_CONTRACT_VERSION: u32 = c.VIZG_LANGUAGE_ITEM_CONTRACT_VERSION;

test "public header versions match the declaration companion" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), VIZG_ABI_VERSION);
    try std.testing.expectEqual(@as(u32, 4), VIZG_EXTERNAL_MODULE_API_VERSION);
    try std.testing.expectEqual(@as(u32, 2), VIZG_HIR_API_VERSION);
    try std.testing.expectEqual(@as(u32, 1), VIZG_HIR_PAYLOAD_API_VERSION);
    try std.testing.expectEqual(@as(u32, 8), VIZG_HIR_DETAIL_API_VERSION);
    try std.testing.expectEqual(@as(u32, 1), VIZG_HIR_REACHABILITY_API_VERSION);
    try std.testing.expectEqual(@as(u32, 1), VIZG_HIR_CONSUMER_API_VERSION);
    try std.testing.expectEqual(@as(u32, 1 << 0), VIZG_HIR_REACH_TRIGGER_CANONICAL_ARRAY_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 1), VIZG_HIR_REACH_TRIGGER_PLACE_DELETED);
    try std.testing.expectEqual(@as(u32, 1 << 2), VIZG_HIR_REACH_TRIGGER_PRIMITIVE_STRING_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 3), VIZG_HIR_REACH_TRIGGER_STRING_CONCAT_ADD);
    try std.testing.expectEqual(@as(u32, 1 << 4), VIZG_HIR_REACH_TRIGGER_PRIMITIVE_NUMBER_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 5), VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BOOLEAN_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 6), VIZG_HIR_REACH_TRIGGER_PRIMITIVE_BIGINT_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 7), VIZG_HIR_REACH_TRIGGER_PRIMITIVE_SYMBOL_BASE);
    try std.testing.expectEqual(@as(u32, 1 << 8), VIZG_HIR_REACH_TRIGGER_FUNCTION_BASE);
    try std.testing.expectEqual(@as(u32, 3), VIZG_INTRINSIC_CONTRACT_VERSION);
    try std.testing.expectEqual(@as(u32, 1), VIZG_LANGUAGE_ITEM_CONTRACT_VERSION);
}
