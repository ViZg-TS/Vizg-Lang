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
    /// Imported from an external/ambient module (e.g. `"console"`).
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    _ = try allocator.dupe(u8, "import { x as localX } from \"./a\";\n");
    const edges_buf = try allocator.alloc(ImportEdgeStub, 1);
    edges_buf[0] = .{ .id = @intCast(@as(u32, 0)) };

    var imports_list: std.ArrayListUnmanaged(LinkedImport) = .empty;
    _ = imports_list.append(allocator, .{
        .id = @intCast(imports_list.items.len),
        .from_module = @intCast(@as(u32, 0)),
        .import_edge = edges_buf[0].id,
        .import_symbol = null,
        .local_name = "localX",
        .imported_name = "x",
        .target_module = @intCast(@as(u32, 1)),
        .target_symbol = @intCast(@as(u32, 42)),
        .kind = .named,
        .span = .{ .start = 0, .end = edges_buf[0].id + 50, .line = 0, .column = 0 },
    });

    const imports: []const LinkedImport = try imports_list.toOwnedSlice(allocator);

    var linker = Linker{
        .arena = arena,
        .imports = imports,
    };
    defer linker.deinit();

    try std.testing.expect(linker.imports.len == 1);
    try std.testing.expect(std.mem.eql(u8, linker.imports[0].local_name, "localX"));
    try std.testing.expect(std.mem.eql(u8, linker.imports[0].imported_name, "x"));
}

const ImportEdgeStub = struct { id: graph.ImportEdgeId };
