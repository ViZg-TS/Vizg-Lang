const std = @import("std");

const graph = @import("graph.zig");
const binder = @import("../frontend/binder.zig");
const tokens = @import("../frontend/tokens.zig");

/// Unique identifier for a `LinkedImport` within one linker instance.
pub const LinkedImportId = u32;

/// How the import was authored — drives downstream linking and diagnostics.
pub const LinkedImportKind = enum {
    /// `import { x } from "./a";`  or  `import { x as y } from "./a";`
    named,
    /// `import a from "./a";`
    default,
    /// `import * as ns from "./a";`
    namespace,
    /// Imported from an external/ambient module (e.g. `"host-service"`).
    external,
    /// No target module or symbol was resolved during linking.
    unresolved,
};

/// One resolved link between a local scope entry and the imported entity it
/// resolves to (or will resolve to after further passes).
pub const LinkedImport = struct {
    id: LinkedImportId,

    from_module: graph.ModuleId,
    import_edge: graph.ImportEdgeId,
    /// Symbol bound in the source module's binder (may be null if not yet bound).
    import_symbol: ?binder.SymbolId,

    local_name: []const u8,
    imported_name: []const u8,

    target_module: ?graph.ModuleId,
    target_symbol: ?binder.SymbolId,

    kind: LinkedImportKind,
    span: tokens.Span,
};

/// Holds all resolved cross-file import links for a single build.
pub const Linker = struct {
    arena: std.heap.ArenaAllocator,
    imports: []const LinkedImport,

    pub fn deinit(self: *Linker) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "linked import model compiles" {
    const allocator = std.testing.allocator;

    var imports_list: std.ArrayListUnmanaged(LinkedImport) = .empty;
    errdefer {
        _ = imports_list.deinit(allocator);
    }
    try imports_list.append(allocator, .{
        .id = @intCast(@as(u32, 0)),
        .from_module = @intCast(@as(u32, 0)),
        .import_edge = @intCast(@as(u32, 0)),
        .import_symbol = null,
        .local_name = "localX",
        .imported_name = "x",
        .target_module = @intCast(@as(u32, 1)),
        .target_symbol = @intCast(@as(u32, 42)),
        .kind = .named,
        .span = .{ .start = 0, .end = 50, .line = 0, .column = 0 },
    });

    const imports: []const LinkedImport = try imports_list.toOwnedSlice(allocator);

    // Construct a Linker backed by its own fresh arena so the ownership story is
    // preserved — but use std.testing.allocator for the *incoming* slice so it can
    // be freed independently of the Linker's lifetime.
    var linker = Linker{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .imports = imports,
    };
    defer {
        // The arena only owns the Linker struct; `imports` was *borrowed* in and must
        // be freed separately before deinit (so we don't free twice on its memory).
        allocator.free(imports);
        linker.deinit();
    }

    try std.testing.expect(linker.imports.len == 1);
    try std.testing.expect(std.mem.eql(u8, "localX", linker.imports[0].local_name));
    try std.testing.expect(std.mem.eql(u8, "x", linker.imports[0].imported_name));
}

const ImportEdgeStub = struct { id: graph.ImportEdgeId };

// ---------------------------------------------------------------------------
// Export -> SymbolId lookup
// ---------------------------------------------------------------------------

/// Given an exported name in `module`, returns the binder `SymbolId` for the
/// local symbol that backs it (i.e. the target of the export). Returns null
/// when no matching export is recorded or its `local_name` has no match in
/// the symbol table. For aliased exports (`export { x as y }`) returns the
/// id bound to the *local* name `x`, not the alias `y`.
pub fn findExportedSymbol(
    module: *const graph.Module,
    exported_name: []const u8,
) ?binder.SymbolId {
    const recs = module.result.bind.module.exports;
    for (recs) |e| {
        if (!std.mem.eql(u8, e.name, exported_name)) continue;

        // Aliased-export path: `e.name` is the alias, `e.local_name` is what
        // the binder actually knows. Resolve through local_name -> symbol table.
        for (module.result.bind.symbols) |sym| {
            if (!std.mem.eql(u8, sym.name, e.local_name)) continue;
            return sym.id;
        }

        // Defensive: an export references a `local_name` the binder has no
        // symbol for (should not happen on well-formed input). Treat as miss.
        return null;
    }
    return null;
}

/// Returns true when `module` records an exported name. Useful for quick
/// membership checks in diagnostics or resolver heuristics.
pub fn hasExport(
    module: *const graph.Module,
    exported_name: []const u8,
) bool {
    for (module.result.bind.module.exports) |e| {
        if (std.mem.eql(u8, e.name, exported_name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "findExportedSymbol resolves direct `export const x = 1`" {
    const scanner = @import("../frontend/scanner.zig");
    const parser = @import("../frontend/parser.zig");
    const frontend_mod = @import("../frontend/frontend.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "export const x = 1;";

    const scan = try scanner.scanAll(alloc, source, true);
    _ = try parser.parse(alloc, scan.tokens, .{});
    const result = try frontend_mod.analyze(
        alloc,
        .{ .path = "(test)", .text = source },
        .{},
    );

    // The bind result owns the backing slices (arena-scoped). Use a tiny
    // stand-in module struct to pass `*const graph.Module` without pulling in
    // loader / io plumbing for this unit test.
    var fake_text: [@max(1, source.len)]u8 = undefined;
    @memcpy(fake_text[0..source.len], source);

    const m = graph.Module{
        .id = 0,
        .path = "(test)",
        .display_path = "(test)",
        .source_path = "(test)",
        .text = fake_text[0..source.len],
        .result = result,
    };

    const got = findExportedSymbol(&m, "x");
    try std.testing.expect(got != null);
    if (got) |sym_id| {
        for (result.bind.symbols) |s| {
            if (s.id == sym_id) {
                try std.testing.expect(std.mem.eql(u8, s.name, "x"));
            }
        }

        // The binder records an ExportRecord with matching name + local_name.
        var saw_export = false;
        for (result.bind.module.exports) |e| {
            if (std.mem.eql(u8, e.name, "x") and std.mem.eql(u8, e.local_name, "x")) {
                saw_export = true;
            }
        }
        try std.testing.expect(saw_export);
    }
}

test "findExportedSymbol resolves direct `export function run() {}`" {
    const scanner = @import("../frontend/scanner.zig");
    const parser = @import("../frontend/parser.zig");
    const frontend_mod = @import("../frontend/frontend.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "export function run() {}";

    const scan = try scanner.scanAll(alloc, source, true);
    _ = try parser.parse(alloc, scan.tokens, .{});
    const result = try frontend_mod.analyze(
        alloc,
        .{ .path = "(test)", .text = source },
        .{},
    );

    var fake_text: [@max(1, source.len)]u8 = undefined;
    @memcpy(fake_text[0..source.len], source);

    const m = graph.Module{
        .id = 0,
        .path = "(test)",
        .display_path = "(test)",
        .source_path = "(test)",
        .text = fake_text[0..source.len],
        .result = result,
    };

    const got = findExportedSymbol(&m, "run");
    try std.testing.expect(got != null);
    if (got) |sym_id| {
        for (result.bind.symbols) |s| {
            if (s.id == sym_id) {
                try std.testing.expect(std.mem.eql(u8, s.name, "run"));
            }
        }

        var saw_export = false;
        for (result.bind.module.exports) |e| {
            if (std.mem.eql(u8, e.name, "run")) saw_export = true;
        }
        try std.testing.expect(saw_export);
    }
}

test "findExportedSymbol resolves aliased `export { localName as exportedName }`" {
    const scanner = @import("../frontend/scanner.zig");
    const parser = @import("../frontend/parser.zig");
    const frontend_mod = @import("../frontend/frontend.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "const localName = \"dev\";\nexport { localName as exportedName };";

    const scan = try scanner.scanAll(alloc, source, true);
    _ = try parser.parse(alloc, scan.tokens, .{});
    const result = try frontend_mod.analyze(
        alloc,
        .{ .path = "(test)", .text = source },
        .{},
    );

    var fake_text: [@max(1, source.len)]u8 = undefined;
    @memcpy(fake_text[0..source.len], source);

    const m = graph.Module{
        .id = 0,
        .path = "(test)",
        .display_path = "(test)",
        .source_path = "(test)",
        .text = fake_text[0..source.len],
        .result = result,
    };

    const got = findExportedSymbol(&m, "exportedName");
    try std.testing.expect(got != null);
    if (got) |sym_id| {
        // The lookup must come through `e.local_name` ("localName"), not the
        // alias, so the returned symbol name has to be "localName".
        for (result.bind.symbols) |s| {
            if (s.id == sym_id) {
                try std.testing.expect(std.mem.eql(u8, s.name, "localName"));
                return; // success path: break out of scan.
            }
        }
        @panic("symbol id did not match any binder symbol");
    }

    // ExportRecord sanity check — the alias is recorded alongside its local.
    var saw_alias = false;
    for (result.bind.module.exports) |e| {
        if (std.mem.eql(u8, e.name, "exportedName") and
            std.mem.eql(u8, e.local_name, "localName"))
        {
            saw_alias = true;
        }
    }
    try std.testing.expect(saw_alias);
}

test "findExportedSymbol returns null for missing export" {
    const scanner = @import("../frontend/scanner.zig");
    const parser = @import("../frontend/parser.zig");
    const frontend_mod = @import("../frontend/frontend.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source = "export const x = 1;";

    const scan = try scanner.scanAll(alloc, source, true);
    _ = try parser.parse(alloc, scan.tokens, .{});
    const result = try frontend_mod.analyze(
        alloc,
        .{ .path = "(test)", .text = source },
        .{},
    );

    var fake_text: [@max(1, source.len)]u8 = undefined;
    @memcpy(fake_text[0..source.len], source);

    const m = graph.Module{
        .id = 0,
        .path = "(test)",
        .display_path = "(test)",
        .source_path = "(test)",
        .text = fake_text[0..source.len],
        .result = result,
    };

    try std.testing.expect(findExportedSymbol(&m, "missing") == null);
    try std.testing.expect(!hasExport(&m, "missing"));
}
