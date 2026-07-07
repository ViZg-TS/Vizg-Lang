const std = @import("std");
const modules = @import("modules/root.zig");
const Io = std.Io;

pub fn main() !void {
    var args_iter = std.process.argsInit();
    if (args_iter.next()) |entry_path| {
        _ = entry_path;
    } else {
        std.debug.print("Usage: debug_test <path>\n", .{});
        return;
    }

    const path = "./test/frontend/modules/manual/success.ts";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const graph = modules.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = 1024 * 1024,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return;
    };

    std.debug.print("Modules count: {}\n", .{graph.modules.len});
    for (graph.modules) |m| {
        std.debug.print("  Module {}: '{}' display='{}' path='{}'\n", .{ m.id, m.display_path, m.display_path, m.path });
    }
    std.debug.print("\nImports count: {}\n", .{graph.imports.len});
    for (graph.imports) |e| {
        std.debug.print("  Edge {}: from={} to={:?} spec='{}' status={}\n", .{ e.id, e.from, e.to, e.specifier, @tagName(e.status) });
    }
    std.debug.print("\nLinked imports count: {}\n", .{graph.linked_imports.len});
    for (graph.linked_imports) |li| {
        std.debug.print("  LI {}: from={} edge={} local='{s}' imp='{s}' kind={}\n", .{ li.id, li.from_module, li.import_edge, li.local_name, li.imported_name, @tagName(li.kind) });
    }
}
