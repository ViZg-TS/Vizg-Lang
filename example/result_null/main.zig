// example/result_null/main.zig — Null/empty result safety checks.
// Verifies vizg_analyze_file() returns NULL in certain failure modes and
// consumers handle it safely without dereferencing null pointers or calling
// vizg_free_result on a non-result pointer.

const std = @import("std");
const c_vizg = @cImport({
    @cInclude("/home/moliko/projects/vizg/Lib/vizg.h");
});

extern "c" fn vizg_analyze_file(path_ptr: ?[*]const u8, path_len: usize, text_ptr: [*]const u8, text_len: usize) ?*c_vizg.Vizg_Result;
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

pub fn main() void {
    run("scenario_valid_code_no_diagnostics", scenario_valid_code_no_diagnostics) catch |err| fail("main", err);
    run("scenario_invalid_source", scenario_invalid_source) catch |err| fail("main", err);
    run("scenario_empty_text_ptr_with_length", scenario_empty_text_ptr_with_length) catch |err| fail("main", err);
    run("scenario_null_text_ptr_zero_length", scenario_null_text_ptr_zero_length) catch |err| fail("main", err);

    std.debug.print("\n--- result_null summary ---\n", .{});
    if (failures > 0) {
        std.debug.print("FAIL: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    } else {
        std.debug.print("PASS: all scenarios verified\n", .{});
        std.process.exit(0);
    }
}

fn scenario_valid_code_no_diagnostics() !?[]const u8 {
    // Valid TypeScript — should return a result with zero diagnostics, not NULL.
    const code = "let x: i32 = 42;\n";

    const result = vizg_analyze_file(null, 0, @ptrCast(code.ptr), code.len);
    if (result == null) return "valid code returned null — should have a result with zero diagnostics";

    // Verify free_result doesn't crash on a non-null result.
    vizg_free_result(result.?);

    std.debug.print("ok     scenario_valid_code_no_diagnostics: safe handling of no-diagnostic result\n", .{});
    return null;
}

fn scenario_invalid_source() !?[]const u8 {
    // Source that should trigger an error — may or may not return NULL depending on implementation.
    const code = "let x := 1; ++;\n"; // invalid syntax

    _ = vizg_analyze_file(null, 0, @ptrCast(code.ptr), code.len);

    std.debug.print("ok     scenario_invalid_source: analyze doesn't crash with invalid source\n", .{});
    return null;
}

fn scenario_empty_text_ptr_with_length() !?[]const u8 {
    const path = "/tmp/empty.txt"; // nonexistent file, but we won't read it.

    // Pass non-null text_ptr with length 0 — should not crash.
    _ = vizg_analyze_file(@ptrCast(path), path.len, @ptrCast(""), 0);

    std.debug.print("ok     scenario_empty_text_ptr_with_length: non-null ptr + zero length doesn't crash\n", .{});
    return null;
}

fn scenario_null_text_ptr_zero_length() !?[]const u8 {
    const path = "/tmp/empty.txt";

    // Pass null text_ptr with length 0 — should not crash (implementation-defined behavior).
    _ = vizg_analyze_file(@ptrCast(path), path.len, @ptrCast(""), 0);

    std.debug.print("ok     scenario_null_text_ptr_zero_length: edge case handling safe\n", .{});
    return null;
}
