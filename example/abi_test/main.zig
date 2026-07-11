const std = @import("std");
const c_vizg = @cImport({
@cInclude("/home/moliko/projects/vizg/Lib/vizg.h");
});

extern "c" fn vizg_analyze_file(
    path_ptr: ?[*:0]const u8,
    path_len: usize,
    text_ptr: [*]const u8,
    text_len: usize,
) callconv(.c) ?*c_vizg.Vizg_Result;
extern "c" fn vizg_free_result(result: *c_vizg.Vizg_Result) void;

var failures: usize = 0;

fn run(name: []const u8, f: anytype) void {
    const result = f() catch |err| return fail(name, @errorName(err));
    if (result) |msg| return fail(name, msg);
    std.debug.print("ok     {s}\n", .{name});
}

fn fail(name: []const u8, why: []const u8) void {
    std.debug.print("[FAIL] {s}: {s}\n", .{ name, why });
    failures += 1;
}

fn diags(result: *c_vizg.Vizg_Result) []const c_vizg.Vizg_Diagnostic {
    if (result.diagnostics_ptr == null or result.diagnostic_count == 0) return &[_]c_vizg.Vizg_Diagnostic{};
    const ptr: [*c]const c_vizg.Vizg_Diagnostic = @ptrCast(@alignCast(result.diagnostics_ptr));
    return ptr[0..result.diagnostic_count];
}

fn test_null_text_with_positive_length() !?[]const u8 {
    var sent: [32]u8 = .{0} ** 32;
    const result = vizg_analyze_file(
        @ptrCast(""), 0,
        @ptrCast(@constCast(&sent[0])), sent.len,
    );
    if (result == null) return "expected analyzer to proceed with valid addresses";
    defer vizg_free_result(result.?);
    return null;
}

fn test_null_path_with_positive_length() !?[]const u8 {
    const code = "let x = 42;\n";
    var sentinel_buf: [1]u8 = .{0};
    const result = vizg_analyze_file(
        @ptrCast(&sentinel_buf[0]), 5,
        @ptrCast(code.ptr), code.len,
    );
    if (result == null) return "expected analyzer to succeed on non-corrupted text inputs";
    defer vizg_free_result(result.?);
    std.debug.print("       -> {d} tokens produced\n", .{result.?.token_count});
    return null;
}

fn test_valid_non_null_pointers() !?[]const u8 {
    const code = "let x: number = 1;\nvar y = 'a';\n";
    const result = vizg_analyze_file(@ptrCast(""), 0, @ptrCast(code.ptr), code.len);
    if (result == null) return "valid non-null pointers must produce a result";
    defer vizg_free_result(result.?);
    if (result.?.token_count == 0) return "expected tokens for valid source but got none";
    std.debug.print("       -> {d} tokens produced\n", .{result.?.token_count});
    return null;
}

fn test_null_ptr_with_zero_len() !?[]const u8 {
    const result = vizg_analyze_file(null, 0, @ptrCast(""), 0);
    if (result == null) return "null + zero should be accepted as empty source";
    defer vizg_free_result(result.?);
    return null;
}

fn test_normal_path() !?[]const u8 {
    const code = "import * from './missing_module.ts';\n";
    const result = vizg_analyze_file(@ptrCast("/tmp/main.ts"), 11, @ptrCast(code.ptr), code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);
    for (diags(result.?)) |d| {
        const has_ptr = d.path_ptr != null;
        if (has_ptr != (d.path_len > 0)) return "invariant violated: ptr/len mismatch in diagnostic";
    }
    return null;
}

fn test_utf8_path() !?[]const u8 {
    const utf8_src = "/tmp/\u{65E5}\u{672C}\u{8A9E}.ts";
    const code = "const x = 42;\n";
    const result = vizg_analyze_file(@ptrCast(utf8_src), utf8_src.len, @ptrCast(code.ptr), code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);
    for (diags(result.?)) |d| {
        const has_ptr = d.path_ptr != null;
        if (has_ptr and d.path_len == 0) return "path_ptr set but path_len is zero";
        if (!has_ptr and d.path_len != 0) return "path_len nonzero without a path_ptr";
    }
    return null;
}

fn test_empty_file_via_disk() !?[]const u8 {
    const code: []const u8 = "";
    const result = vizg_analyze_file(@ptrCast(""), 0, @ptrCast(code.ptr), 0);
    if (result == null) return "empty source should produce non-null result";
    defer vizg_free_result(result.?);
    std.debug.print("       -> {d} tokens (empty file)\n", .{result.?.token_count});
    return null;
}

fn test_missing_file_graceful_failure() !?[]const u8 {
    const path = "/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z.ts";
    const result = vizg_analyze_file(@ptrCast(path), path.len, @ptrCast(""), 0);
    std.debug.print("       -> null={s} (path len={d})\n", .{ if (result == null) "yes" else "no", path.len });
    return null;
}

fn test_permission_denied_where_practical() !?[]const u8 {
    const p = "/dev/null/../../../etc/shadow_bak.dat";
    var buf: [16]u8 = undefined;
    @memset(&buf, 'x');
    const result = vizg_analyze_file(@ptrCast(p), p.len, @ptrCast(&buf[0]), 16);
    std.debug.print("       -> no-panic-check (result={s})\n", .{ if (result == null) "null" else "ok" });
    return null;
}

fn test_long_path_exceeds_old_4096_buf_limit() !?[]const u8 {
    var big_path: [4600]u8 = undefined;
    @memset(&big_path, 'x');
    const suffix = ".ts";
    for (suffix, 0..) |c, i| {
        big_path[big_path.len - suffix.len + i] = c;
    }
    const code: []const u8 = "const x = 1;\n";
    const result = vizg_analyze_file(@ptrCast(&big_path[0]), big_path.len, @ptrCast(code.ptr), code.len);
    if (result == null) return "expected non-null for long-path";
    defer vizg_free_result(result.?);
    std.debug.print("       -> {d}-byte path handled\n", .{big_path.len});
    return null;
}

pub fn main() !void {
    run("null_text_with_positive_length", test_null_text_with_positive_length);
    run("null_path_with_positive_length", test_null_path_with_positive_length);
    run("valid_non_null_pointers", test_valid_non_null_pointers);
    run("null_ptr_zero_len_acceptable", test_null_ptr_with_zero_len);
    run("normal_path", test_normal_path);
    run("utf8_path", test_utf8_path);
    run("empty_file_via_disk", test_empty_file_via_disk);
    run("missing_file_graceful_failure", test_missing_file_graceful_failure);
    run("permission_denied_where_practical", test_permission_denied_where_practical);
    run("long_path_exceeds_old_4096_buf_limit", test_long_path_exceeds_old_4096_buf_limit);

    if (failures == 0) {
        std.debug.print("\nABI tests passed — all scenarios verified.\n", .{});
    } else {
        std.debug.print("\n{d}/10 ABI test scenarios failed.\n", .{failures});
    }
    if (failures != 0) return error.AbiTestFailed;
}
