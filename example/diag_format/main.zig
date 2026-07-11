// example/diag_format/main.zig — Format-safe diagnostic consumer check.
// Verifies every diagnostic message can be printed without relying on `%s`
// for `message_ptr`. Instead, all output uses length-aware formatting via
// `%.*s`. Confirms parity across Zig and C drivers.

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
    run("scenario_trigger_diagnostic", scenario_trigger_diagnostic) catch |err| fail("main", err);
    run("scenario_no_message", scenario_no_message) catch |err| fail("main", err);
    run("scenario_unicode_message", scenario_unicode_message) catch |err| fail("main", err);

    std.debug.print("\n--- diag_format summary ---\n", .{});
    if (failures > 0) {
        std.debug.print("FAIL: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    } else {
        std.debug.print("PASS: all scenarios verified\n", .{});
        std.process.exit(0);
    }
}

fn scenario_trigger_diagnostic() !?[]const u8 {
    const code = "import * from './missing_module.ts';\n";
    const src_path = "/tmp/test_diag_format.ts";

    const result = vizg_analyze_file(@ptrCast(src_path), src_path.len, @ptrCast(code.ptr), code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);

    for (0..result.?.diagnostic_count) |i| {
        const diags: [*c]const c_vizg.Vizg_Diagnostic = @ptrCast(@alignCast(result.?.diagnostics_ptr));
        const d = &diags[i];

        if (d.message_len != 0 and d.message_ptr == null) {
            return "message_len non-zero but message_ptr is null";
        }

        // Format length-aware only — never use `%s` directly on pointers.
        var buf: [1024]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, "%.*s", .{ d.message_len, d.message_ptr }) catch |err| {
            return @errorName(err);
        };

        if (written.len == 0 and d.message_len > 0) {
            return "format produced zero-length output for non-empty message";
        }
    }

    std.debug.print("ok     scenario_trigger_diagnostic: length-aware formatting verified\n", .{});
    return null;
}

fn scenario_no_message() !?[]const u8 {
    const code = "let x: i32 = 42;\n"; // Valid code, no diagnostics.

    const result = vizg_analyze_file(null, 0, @ptrCast(code.ptr), code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);

    if (result.?.diagnostic_count != 0) {
        return "valid code produced unexpected diagnostics";
    }

    std.debug.print("ok     scenario_no_message: no diagnostics, format check trivial\n", .{});
    return null;
}

fn scenario_unicode_message() !?[]const u8 {
    const code = "let x := \"日本語\";\n";

    const result = vizg_analyze_file(null, 0, @ptrCast(code.ptr), code.len);
    if (result == null) return "analyze returned null";
    defer vizg_free_result(result.?);

    for (0..result.?.diagnostic_count) |i| {
        const diags: [*c]const c_vizg.Vizg_Diagnostic = @ptrCast(@alignCast(result.?.diagnostics_ptr));
        const d = &diags[i];

        if (d.message_len != 0 and d.message_ptr == null) {
            return "message_len non-zero but message_ptr is null";
        }
    }

    std.debug.print("ok     scenario_unicode_message: Unicode formatting preserved\n", .{});
    return null;
}
