// Module graph and linker behavior tests — extracted from `src/main.zig` so the
// CLI file stays focused on command parsing and diagnostic formatting. Each test
// here exercises build(), LinkedImport fields, or VZG5xxx diagnostics; if a future
// task changes any of those shapes it lands in this file, not under CLI helpers.

const std = @import("std");
const Io = std.Io;

const modules_mod = @import("root.zig");
const core = @import("vizg-core");
const frontend = core.frontend;
const tokens = core.tokens;
const diagnostics = core.diagnostics;

// Keep the constant here so this file is self-contained — `max_source_bytes` in
// src/main.zig keeps its original declaration for readers of that code path.
const max_source_bytes: usize = 64 * 1024 * 1024;

fn projectRoot(allocator: std.mem.Allocator) ![:0]u8 {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    return Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
}

test "linked_imports: named import links to target symbol" {
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/main.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    // Graph must contain at least one linked import (from the named "./a" import).
    try std.testing.expect(graph.linked_imports.len > 0);

    const named = graph.linked_imports[0];
    try std.testing.expect(named.kind == .named);

    // Edge specifier for this link must be the local module path.
    var edge_found: bool = false;
    for (graph.imports) |e| {
        if (e.id == named.import_edge) {
            try std.testing.expect(std.mem.eql(u8, "./a", e.specifier));
            edge_found = true;
            break;
        }
    }
    try std.testing.expect(edge_found);

    // Local name is 'x' (no alias in `import { x } from "./a"`).
    try std.testing.expect(std.mem.eql(u8, "x", named.local_name));
    try std.testing.expect(std.mem.eql(u8, "x", named.imported_name));

    // Target module must be the file exporting `x`.
    const target = graph.modules[named.target_module.?];
    try std.testing.expectEqualStrings("a.ts", std.fs.path.basename(target.path));
}

test "linked_imports: aliased import links to exported target symbol" {
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/aliased_main.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    try std.testing.expect(graph.linked_imports.len > 0);

    // The only specifier from the aliased import is the one we care about.
    const aliased = graph.linked_imports[0];
    try std.testing.expect(std.mem.eql(u8, "localSrc", aliased.local_name));
    try std.testing.expect(std.mem.eql(u8, "source", aliased.imported_name));

    // Target module should be ./aliased_target which exports `source`.
    const target = graph.modules[aliased.target_module.?];
    try std.testing.expectEqualStrings("aliased_target.ts", std.fs.path.basename(target.path));
}

test "linked_imports: external import has kind=external and no target" {
    // success.ts imports from both a local "./dep" (exporting `value`) and the
    // external "node:fs". We pick the link whose imported_name matches an external.
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/success.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    var found_external: ?usize = null;
    for (graph.linked_imports, 0..) |link, i| {
        if (std.mem.eql(u8, link.imported_name, "readFile")) found_external = @intCast(i);
    }
    try std.testing.expect(found_external != null);

    const ext = graph.linked_imports[found_external.?];
    try std.testing.expect(ext.kind == .external);
    try std.testing.expect(ext.target_module == null);
    try std.testing.expect(ext.target_symbol == null);
}

test "linked_imports: missing export remains unresolved and VZG5002 is emitted" {
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    // missing-export.ts imports `missing` from dep, which only exports `value`.
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/missing-export.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    try std.testing.expect(graph.linked_imports.len > 0);
    const unres = graph.linked_imports[0];
    try std.testing.expect(unres.kind == .unresolved);
    try std.testing.expect(std.mem.eql(u8, "missing", unres.imported_name));
    try std.testing.expect(unres.target_symbol == null);

    // VZG5002 missing_export should exist in diagnostics.
    var found_vzg5002 = false;
    for (graph.diagnostics) |diag| {
        if (diag.code == .missing_export) found_vzg5002 = true;
    }
    try std.testing.expect(found_vzg5002);
}

// ---------------------------------------------------------------------------
// Test diagnostics for valid imports. The fixture `import_valid.ts` has one
// import (from "./a") which is a real, exporting module; expected: zero VZG5xxx.
test "diagnostics: missing module -> exactly one VZG5001" {
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/missing-module.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    var vzg5001_count: usize = 0;
    var vzg5002_count: usize = 0;
    for (graph.diagnostics) |diag| {
        switch (diag.code) {
            .module_not_found => vzg5001_count += 1,
            .missing_export => vzg5002_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), vzg5001_count);
    // Missing module must NOT cascade into missing-export for the same import.
    try std.testing.expectEqual(@as(usize, 0), vzg5002_count);

    // The edge is recorded as missing; no linked_import target should exist.
    var any_linked_local = false;
    for (graph.linked_imports) |link| {
        if (link.target_module != null) any_linked_local = true;
    }
    try std.testing.expect(!any_linked_local);
}

test "diagnostics: missing export -> exactly one VZG5002" {
    // missing-export.ts imports ONE missing specifier from a real module.
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/missing-export.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    var vzg5001_count: usize = 0;
    var vzg5002_count: usize = 0;
    for (graph.diagnostics) |diag| {
        switch (diag.code) {
            .module_not_found => vzg5001_count += 1,
            .missing_export => vzg5002_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), vzg5001_count);
    try std.testing.expectEqual(@as(usize, 1), vzg5002_count);

    // Link is created but unresolved: target_symbol == null.
    var any_unresolved = false;
    for (graph.linked_imports) |link| {
        if (std.mem.eql(u8, link.imported_name, "missing")) {
            try std.testing.expect(link.kind == .unresolved);
            try std.testing.expect(link.target_symbol == null);
            any_unresolved = true;
        }
    }
    try std.testing.expect(any_unresolved);
}

test "diagnostics: external import -> zero VZG5xxx diagnostics" {
    // external_only.ts imports only from an external specifier ("node:fs").
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/external_only.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    for (graph.diagnostics) |diag| {
        if (diag.code == .module_not_found or diag.code == .missing_export or diag.code == .circular_import) {
            try std.testing.expect(false); // unexpected VZG5xxx diagnostic
        }
    }

    // No linked import should carry a target module — externals are standalone.
    for (graph.linked_imports) |link| {
        try std.testing.expect(link.kind == .external);
        try std.testing.expect(link.target_module == null);
    }

    var saw_external = false;
    for (graph.imports) |e| {
        if (std.mem.eql(u8, e.specifier, "node:fs")) {
            try std.testing.expectEqual(@as(modules_mod.ImportStatus, .external), e.status);
            saw_external = true;
        }
    }
    try std.testing.expect(saw_external);
}

test "diagnostics: valid import -> zero diagnostics" {
    // import_valid.ts:  import { x } from "./a";  (./a exports `x`)
    const cwd = try projectRoot(std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test/frontend/modules/manual/import_valid.ts", .{cwd});
    defer std.testing.allocator.free(path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const graph = modules_mod.build(allocator, io, path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null) catch |err| {
        std.log.err("build failed: {s}", .{@errorName(err)});
        return error.TestFail;
    };

    for (graph.diagnostics) |diag| {
        try std.testing.expect(
            diag.code != .module_not_found and
                diag.code != .missing_export and
                diag.code != .circular_import,
        );
    }

    // Linked import should exist with a target_module AND a target_symbol.
    var saw_x = false;
    for (graph.linked_imports) |link| {
        if (std.mem.eql(u8, link.imported_name, "x")) {
            try std.testing.expect(link.target_module != null);
            try std.testing.expect(link.target_symbol != null);
            saw_x = true;
        }
    }
    try std.testing.expect(saw_x);
}

test "module graph resolves relative imports inside a standard temporary directory" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "main.ts",
        .data = "import { value } from \"./dependency\";\nexport const result = value;\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "dependency.ts",
        .data = "export const value = 42;\n",
    });

    const entry_path = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(entry_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const graph = try modules_mod.build(arena.allocator(), io, entry_path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null);

    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqualStrings("dependency.ts", std.fs.path.basename(graph.modules[1].path));
    try std.testing.expectEqual(@as(usize, 1), graph.imports.len);
    try std.testing.expectEqual(modules_mod.ImportStatus.local, graph.imports[0].status);
    try std.testing.expect(graph.linked_imports[0].target_module != null);
    try std.testing.expect(graph.linked_imports[0].target_symbol != null);
}

test "module graph excludes dynamic imports from static edges" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import { value } from "./static";
        \\const lazy = import("./dynamic");
        \\export const result = value;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "static.ts", .data = "export const value = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dynamic.ts", .data = "export const value = 2;\n" });
    const entry_path = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(entry_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const graph = try modules_mod.build(arena.allocator(), io, entry_path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null);
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(@as(usize, 1), graph.imports.len);
    try std.testing.expectEqualStrings("./static", graph.imports[0].specifier);
}

test "module graph records complete import forms" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import foo from "./default";
        \\import * as ns from "./namespace";
        \\import "./side-effect";
        \\import type { Foo } from "./types";
        \\import main, { bar } from "./mixed";
    });
    inline for (.{ "default.ts", "namespace.ts", "side-effect.ts", "types.ts", "mixed.ts" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "export default function value() {} export const Foo = 1; export const bar = 2;\n" });
    }

    const entry_path = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(entry_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const graph = try modules_mod.build(arena.allocator(), io, entry_path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null);

    try std.testing.expectEqual(@as(usize, 5), graph.imports.len);
    try std.testing.expectEqual(.default, graph.imports[0].kind);
    try std.testing.expectEqual(.namespace, graph.imports[1].kind);
    try std.testing.expectEqual(.side_effect, graph.imports[2].kind);
    try std.testing.expectEqual(.named, graph.imports[3].kind);
    try std.testing.expect(graph.imports[3].type_only);
    try std.testing.expectEqual(.mixed, graph.imports[4].kind);
    for (graph.imports) |edge| {
        try std.testing.expect(edge.specifier.len > 0);
        try std.testing.expectEqual(modules_mod.ImportStatus.local, edge.status);
    }
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 5), graph.linked_imports.len);
    try std.testing.expectEqual(modules_mod.LinkedImportKind.default, graph.linked_imports[0].kind);
    try std.testing.expectEqual(modules_mod.LinkedImportKind.namespace, graph.linked_imports[1].kind);
    try std.testing.expectEqual(modules_mod.LinkedImportKind.named, graph.linked_imports[2].kind);
    try std.testing.expectEqual(modules_mod.LinkedImportKind.default, graph.linked_imports[3].kind);
    try std.testing.expectEqual(modules_mod.LinkedImportKind.named, graph.linked_imports[4].kind);
}

test "module graph records re-export sources" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\export * from "./all";
        \\export { value as renamed } from "./named";
        \\export type { Foo } from "./types";
    });
    inline for (.{ "all.ts", "named.ts", "types.ts" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "export const value = 1; export const Foo = 2;\n" });
    }

    const entry_path = try tmp.dir.realPathFileAlloc(io, "main.ts", std.testing.allocator);
    defer std.testing.allocator.free(entry_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const graph = try modules_mod.build(arena.allocator(), io, entry_path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = max_source_bytes,
    }, null);

    try std.testing.expectEqual(@as(usize, 3), graph.imports.len);
    try std.testing.expectEqual(@as(usize, 4), graph.modules.len);
    try std.testing.expectEqualStrings("./all", graph.imports[0].specifier);
    try std.testing.expectEqualStrings("./named", graph.imports[1].specifier);
    try std.testing.expectEqualStrings("./types", graph.imports[2].specifier);
    try std.testing.expect(graph.imports[0].re_export);
    try std.testing.expect(graph.imports[1].re_export);
    try std.testing.expect(graph.imports[2].re_export);
    try std.testing.expect(graph.imports[2].type_only);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.len);
}

test {
    _ = @import("graph.zig");
    _ = core.modules.linker;
    _ = @import("loader.zig");
    _ = @import("resolver.zig");
    _ = core.ast;
    _ = core.tokens;
}
