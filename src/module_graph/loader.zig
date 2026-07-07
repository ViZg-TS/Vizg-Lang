const std = @import("std");
const Io = std.Io;

const frontend = @import("../frontend/frontend.zig");

pub const max_source_bytes = 64 * 1024 * 1024;

pub const BuildOptions = struct {
    collect_comments: bool = false,
    recover_errors: bool = true,
    max_source_bytes: usize = max_source_bytes,
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
    });

    return .{
        .text = text,
        .result = result,
    };
}
