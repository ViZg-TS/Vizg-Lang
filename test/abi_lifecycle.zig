const std = @import("std");
const builtin = @import("builtin");
const c = @cImport(@cInclude("vizg.h"));

const VizgStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    io_error = 2,
    out_of_memory = 3,
    internal_error = 4,
    file_too_large = 5,
};

const VizgResult = extern struct {
    token_count: c_uint,
    diagnostic_count: c_uint,
    tokens_ptr: ?*const anyopaque,
    diagnostics_ptr: ?*const anyopaque,
};

const VizgSourceInput = extern struct {
    text_ptr: [*c]const u8,
    text_len: usize,
    path_ptr: [*c]const u8,
    path_len: usize,
};

extern fn vizg_analyze_source_ex(input: ?*const VizgSourceInput, out_result: ?*?*VizgResult) callconv(.c) VizgStatus;
extern fn vizg_analyze_file(path_ptr: [*c]const u8, path_len: usize, text_ptr: [*c]const u8, text_len: usize) callconv(.c) ?*VizgResult;
extern fn vizg_free_result(result: ?*VizgResult) callconv(.c) void;
extern fn vizg_abi_version() callconv(.c) u32;

test "header ABI version matches runtime library" {
    try std.testing.expectEqual(@as(u32, c.VIZG_ABI_VERSION), vizg_abi_version());
}

fn analyze(source: []const u8) !*VizgResult {
    const input: VizgSourceInput = .{
        .text_ptr = source.ptr,
        .text_len = source.len,
        .path_ptr = null,
        .path_len = 0,
    };
    var result: ?*VizgResult = null;
    try std.testing.expectEqual(VizgStatus.ok, vizg_analyze_source_ex(&input, &result));
    return result orelse error.MissingResult;
}

test "C ABI analyzes valid, invalid, and empty source" {
    const valid = try analyze("const answer: number = 42;");
    defer vizg_free_result(valid);
    try std.testing.expect(valid.token_count > 0);
    try std.testing.expectEqual(@as(c_uint, 0), valid.diagnostic_count);

    const invalid = try analyze("const answer = ;");
    defer vizg_free_result(invalid);
    try std.testing.expect(invalid.token_count > 0);
    try std.testing.expect(invalid.diagnostic_count > 0);

    const empty = try analyze("");
    defer vizg_free_result(empty);
    try std.testing.expect(empty.token_count > 0);
    try std.testing.expectEqual(@as(c_uint, 0), empty.diagnostic_count);
}

test "C ABI analyzes a real zero-byte file" {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.ts", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, "empty.ts", std.testing.allocator);
    defer std.testing.allocator.free(path);

    const result = vizg_analyze_file(path.ptr, path.len, null, 0) orelse return error.MissingResult;
    defer vizg_free_result(result);

    try std.testing.expectEqual(@as(c_uint, 1), result.token_count);
    try std.testing.expectEqual(@as(c_uint, 0), result.diagnostic_count);
    const tokens: [*]const c.Vizg_Token = @ptrCast(@alignCast(result.tokens_ptr orelse return error.MissingTokens));
    try std.testing.expectEqual(@as(c_uint, c.VIZG_TOKEN_END_OF_FILE), tokens[0].kind);
}

test "C ABI supports null free, simultaneous results, and reverse cleanup" {
    vizg_free_result(null);

    const sources = [_][]const u8{
        "const one = 1;",
        "const two = 2 + 2;",
        "function three() { return 3; }",
    };
    var results: [sources.len]*VizgResult = undefined;
    for (sources, 0..) |source, i| results[i] = try analyze(source);

    try std.testing.expect(results[0].token_count > 0);
    try std.testing.expect(results[1].token_count > results[0].token_count);
    try std.testing.expect(results[2].token_count > results[1].token_count);
    try std.testing.expectEqual(@as(c_uint, 0), results[0].diagnostic_count);

    var i = results.len;
    while (i > 0) {
        i -= 1;
        vizg_free_result(results[i]);
    }
}

test "C ABI survives many analyze/free cycles" {
    for (0..500) |_| {
        const result = try analyze("let value = 7;");
        try std.testing.expect(result.token_count > 0);
        try std.testing.expectEqual(@as(c_uint, 0), result.diagnostic_count);
        vizg_free_result(result);
    }
}

test "C ABI rejects invalid pointer-length pairs" {
    var result: ?*VizgResult = @ptrFromInt(@alignOf(VizgResult));
    const bad_text: VizgSourceInput = .{
        .text_ptr = null,
        .text_len = 1,
        .path_ptr = null,
        .path_len = 0,
    };
    try std.testing.expectEqual(VizgStatus.invalid_argument, vizg_analyze_source_ex(&bad_text, &result));
    try std.testing.expectEqual(@as(?*VizgResult, null), result);

    const source = "const x = 1;";
    const bad_path: VizgSourceInput = .{
        .text_ptr = source.ptr,
        .text_len = source.len,
        .path_ptr = null,
        .path_len = 1,
    };
    try std.testing.expectEqual(VizgStatus.invalid_argument, vizg_analyze_source_ex(&bad_path, &result));
    try std.testing.expectEqual(@as(?*VizgResult, null), result);
    try std.testing.expectEqual(VizgStatus.invalid_argument, vizg_analyze_source_ex(null, &result));
    try std.testing.expectEqual(VizgStatus.invalid_argument, vizg_analyze_source_ex(&bad_path, null));
}

fn threadWorker() !void {
    for (0..50) |_| {
        const result = try analyze("const threaded = 9;");
        if (result.token_count == 0 or result.diagnostic_count != 0) return error.InvalidAnalysis;
        vizg_free_result(result);
    }
}

test "C ABI supports parallel analysis" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, threadWorker, .{});
    for (threads) |thread| thread.join();
}
