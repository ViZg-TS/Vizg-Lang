const std = @import("std");
const Io = std.Io;

const frontend = @import("vizg-core").frontend;

pub const max_source_bytes = 64 * 1024 * 1024;

pub const BuildOptions = struct {
    collect_comments: bool = false,
    recover_errors: bool = true,
    max_source_bytes: usize = max_source_bytes,
    // Extensions to try for extension-less import specifiers. First entry is the primary;
    // subsequent entries are fallback candidates tried in order (without index-file fallback).
    // When null/empty, resolver defaults to ".ts" only — identical to historical behavior.
    extensions: ?[]const [:0]const u8 = null,
    // Maximum depth allowed for module graph DFS / import-chain traversal before emitting a 
    // diagnostic and failing the build rather than recursing into stack overflow territory. C2 H4.
    max_module_graph_depth: usize = 10_000,
    // Maximum recursive descent depth during parser precedence-climbing (H4). Exceeded parses are
    // rejected with a diagnostic rather than crashing; defaults to 1024 which covers realistic code.
    max_parse_depth: usize = 1024,
};

pub const LoadedModule = struct {
    text: []const u8,
    result: frontend.FrontendResult,
};

pub fn loadAndAnalyze(
    allocator: std.mem.Allocator,
    io: Io,
    canonical_path: []const u8,
    source_path: []const u8,
    options: BuildOptions,
) !LoadedModule {
    const text = try Io.Dir.cwd().readFileAlloc(io, canonical_path, allocator, .limited(options.max_source_bytes));
    const result = try frontend.analyze(allocator, .{
        .path = source_path,
        .text = text,
        .kind = .module,
    }, .{
        .collect_comments = options.collect_comments,
        .recover_errors = options.recover_errors,
        .max_parse_depth = options.max_parse_depth,
    });

    return .{
        .text = text,
        .result = result,
    };
}

test "Goal 158 module loading forwards parser depth limits" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "const value = (((((((1)))))));\n" });
    const path = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseRecursionLimitReached, loadAndAnalyze(
        arena.allocator(),
        io,
        path,
        path,
        .{ .max_parse_depth = 2 },
    ));
}
