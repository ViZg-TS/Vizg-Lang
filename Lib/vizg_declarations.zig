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

test "public header versions match the declaration companion" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), VIZG_ABI_VERSION);
    try std.testing.expectEqual(@as(u32, 2), VIZG_EXTERNAL_MODULE_API_VERSION);
    try std.testing.expectEqual(@as(u32, 2), VIZG_HIR_API_VERSION);
    try std.testing.expectEqual(@as(u32, 1), VIZG_HIR_PAYLOAD_API_VERSION);
    try std.testing.expectEqual(@as(u32, 2), VIZG_HIR_DETAIL_API_VERSION);
}
