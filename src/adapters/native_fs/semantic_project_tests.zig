const std = @import("std");
const Io = std.Io;
const core = @import("vizg-core");

const binder = core.binder;
const diagnostics = core.diagnostics;
const frontend = core.frontend;
const semantics = core.semantics;
const type_info = semantics.type_info;
const types = core.types;

const ProjectSemanticResult = semantics.ProjectSemanticResult;
const ModuleId = semantics.ModuleId;
const SemanticImport = semantics.SemanticImport;
const SemanticLinkState = semantics.SemanticLinkState;
const analyzeModuleGraph = semantics.analyzeModuleGraph;

fn graphModule(graph: *const core.modules.ModuleGraph, id: ModuleId) ?*const core.modules.Module {
    for (graph.modules) |*module| if (module.id == id) return module;
    return null;
}

fn projectModuleIdByBasename(project: *const ProjectSemanticResult, basename: []const u8) ?ModuleId {
    for (project.modules) |module| {
        if (std.mem.eql(u8, std.fs.path.basename(module.path), basename)) return module.id;
    }
    return null;
}

fn projectImportByLocal(project: *const ProjectSemanticResult, module_id: ModuleId, local_name: []const u8) ?SemanticImport {
    for (project.imports) |item| {
        if (item.module_id == module_id and std.mem.eql(u8, item.local_name, local_name)) return item;
    }
    return null;
}

fn projectSymbolByName(project: *const ProjectSemanticResult, module_id: ModuleId, name: []const u8, kind: binder.SymbolKind) ?binder.SymbolId {
    const module = graphModule(&project.graph, module_id) orelse return null;
    for (module.result.bind.symbols) |symbol| {
        if (symbol.kind == kind and std.mem.eql(u8, symbol.name, name)) return symbol.id;
    }
    return null;
}

fn analyzeTemporaryProject(tmp: *std.testing.TmpDir, entry: []const u8) !ProjectSemanticResult {
    const native_fs = @import("root.zig");
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    const entry_path = try tmp.dir.realPathFileAlloc(io, entry, std.testing.allocator);
    defer std.testing.allocator.free(entry_path);
    const graph = try native_fs.build(std.testing.allocator, io, entry_path, .{
        .collect_comments = false,
        .recover_errors = true,
        .max_source_bytes = native_fs.loader.max_source_bytes,
    }, null);
    return analyzeModuleGraph(std.testing.allocator, graph);
}

test "Goal 124 project semantics propagate aliases namespaces defaults reexports and type-only imports" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\export const value: number = 1;
        \\export function add(x: number): number { return x + value; }
        \\export default function make(): number { return value; }
        \\export class Box {}
        \\export enum Kind { A }
        \\export interface Shape {}
        \\export type Count = number;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "relay.ts", .data =
        \\export { value as renamed, add, default as make } from "./dep";
        \\export type { Shape, Count } from "./dep";
        \\export * from "./dep";
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import { renamed as local, add, make } from "./relay";
        \\import * as ns from "./relay";
        \\import type { Shape } from "./relay";
        \\const total: number = add(local);
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const dep_id = projectModuleIdByBasename(&project, "dep.ts") orelse return error.TestExpectedEqual;
    const relay_id = projectModuleIdByBasename(&project, "relay.ts") orelse return error.TestExpectedEqual;
    const dep_value = project.lookupExport(dep_id, "value") orelse return error.TestExpectedEqual;
    const relay_value = project.lookupExport(relay_id, "renamed") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(dep_value.identity, relay_value.identity);

    const local = projectImportByLocal(&project, main_id, "local") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SemanticLinkState.resolved, local.state);
    try std.testing.expectEqual(relay_value.identity, local.target.?);
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(local.target.?.type_id, main_module.type_info.lookupSymbol(local.import_symbol.?).?.effective().?);

    const namespace = projectImportByLocal(&project, main_id, "ns") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SemanticLinkState.namespace, namespace.state);
    try std.testing.expect(namespace.runtime_binding);
    try std.testing.expect(namespace.target != null);
    switch (project.type_store.lookup(namespace.target.?.type_id).?.kind) {
        .object => {},
        else => return error.TestExpectedEqual,
    }

    const shape = projectImportByLocal(&project, main_id, "Shape") orelse return error.TestExpectedEqual;
    try std.testing.expect(shape.type_only);
    try std.testing.expect(!shape.runtime_binding);
    try std.testing.expectEqual(SemanticLinkState.resolved, shape.state);
    try std.testing.expect(project.lookupExport(dep_id, "default") != null);
    try std.testing.expect(project.lookupExport(relay_id, "make") != null);
}

test "Goal 156 namespace imports refresh propagated export types" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "base.ts", .data = "export const value = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\import { value } from "./base";
        \\export const forwarded = value;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import * as ns from "./dep";
        \\export const result = ns.forwarded;
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const result_symbol = projectSymbolByName(&project, main_id, "result", .variable) orelse return error.TestExpectedEqual;
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(project.type_store.builtins.number, main_module.type_info.lookupSymbol(result_symbol).?.effective().?);

    const namespace = projectImportByLocal(&project, main_id, "ns") orelse return error.TestExpectedEqual;
    const shape = project.type_store.lookup(namespace.target.?.type_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(shape.kind == .object);
    var found = false;
    for (shape.kind.object) |property| if (std.mem.eql(u8, property.name, "forwarded")) {
        try std.testing.expectEqual(project.type_store.builtins.number, property.type_id);
        found = true;
    };
    try std.testing.expect(found);
}

test "Goal 124 missing exports remain inspectable partial links" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data = "export const present = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "import { missing } from \"./dep\"; const value = missing;\n" });
    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const missing = projectImportByLocal(&project, main_id, "missing") orelse return error.TestExpectedEqual;
    try std.testing.expect(project.is_partial);
    try std.testing.expect(missing.state == .unresolved or missing.state == .cyclic_partial);
    try std.testing.expect(missing.target == null);
    try std.testing.expect(missing.span.end > missing.span.start);
}

test "Goal 124 cyclic modules terminate with stable qualified identities" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = "import { b } from \"./b\"; export const a: number = 1; export const from_b = b;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data = "import { a } from \"./a\"; export const b: number = a;\n" });
    var project = try analyzeTemporaryProject(&tmp, "a.ts");
    defer project.deinit();
    const a_id = projectModuleIdByBasename(&project, "a.ts") orelse return error.TestExpectedEqual;
    const b_id = projectModuleIdByBasename(&project, "b.ts") orelse return error.TestExpectedEqual;
    const a_export = project.lookupExport(a_id, "a") orelse return error.TestExpectedEqual;
    const b_import = projectImportByLocal(&project, b_id, "a") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(SemanticLinkState.resolved, b_import.state);
    try std.testing.expectEqual(a_export.identity, b_import.target.?);
    try std.testing.expect(project.modules.len == 2);
}

test "Goal 124 repeated project rebuilds do not retain stale semantic storage" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data = "import { value } from \"./dep\"; export const result = value;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data = "export const value: number = 1;\n" });

    var first = try analyzeTemporaryProject(&tmp, "main.ts");
    const first_dep = projectModuleIdByBasename(&first, "dep.ts") orelse return error.TestExpectedEqual;
    const first_type = first.lookupExport(first_dep, "value").?.identity.type_id;
    try std.testing.expectEqual(first.type_store.builtins.number, first_type);
    first.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data = "export const value: string = \"new\";\n" });
    var second = try analyzeTemporaryProject(&tmp, "main.ts");
    defer second.deinit();
    const second_dep = projectModuleIdByBasename(&second, "dep.ts") orelse return error.TestExpectedEqual;
    const second_main = projectModuleIdByBasename(&second, "main.ts") orelse return error.TestExpectedEqual;
    const second_export = second.lookupExport(second_dep, "value") orelse return error.TestExpectedEqual;
    const second_import = projectImportByLocal(&second, second_main, "value") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(second.type_store.builtins.string, second_export.identity.type_id);
    try std.testing.expectEqual(second_export.identity, second_import.target.?);
}

test "Goal 149 imported aliases preserve arrow and function-expression annotations" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\export interface User { name: string; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import type { User as LocalUser } from "./dep";
        \\const arrow = (value: LocalUser): LocalUser => value;
        \\const expression = function(value: LocalUser): LocalUser { return value; };
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const dep_id = projectModuleIdByBasename(&project, "dep.ts") orelse return error.TestExpectedEqual;
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const user = project.lookupExport(dep_id, "User") orelse return error.TestExpectedEqual;
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;

    try std.testing.expect(main_module.type_info.resolved_type_nodes.len >= 4);
    for (main_module.type_info.resolved_type_nodes) |entry|
        try std.testing.expectEqual(user.identity.type_id, entry.type_id);

    for ([_][]const u8{ "arrow", "expression" }) |name| {
        const symbol_id = projectSymbolByName(&project, main_id, name, .variable) orelse return error.TestExpectedEqual;
        const signature_id = main_module.type_info.lookupSymbol(symbol_id).?.effective().?;
        const signature = project.type_store.lookupFunction(signature_id) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(user.identity.type_id, signature.parameters[0].type_id);
        try std.testing.expectEqual(user.identity.type_id, signature.return_type);
    }
}

test "Goal 152 imported generic declarations preserve arity and substitution" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\export interface Box<T> { value: T; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import type { Box } from "./dep";
        \\type Good = Box<number>;
        \\type Value = Good["value"];
        \\type Bad = Box<number, string>;
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;
    const good_symbol = projectSymbolByName(&project, main_id, "Good", .type_alias) orelse return error.TestExpectedEqual;
    const value_symbol = projectSymbolByName(&project, main_id, "Value", .type_alias) orelse return error.TestExpectedEqual;
    const bad_symbol = projectSymbolByName(&project, main_id, "Bad", .type_alias) orelse return error.TestExpectedEqual;
    const good = main_module.type_info.lookupSymbol(good_symbol).?.declared_type.?;
    try std.testing.expect(project.type_store.lookup(good).?.kind == .applied_generic);
    try std.testing.expectEqual(project.type_store.builtins.number, main_module.type_info.lookupSymbol(value_symbol).?.declared_type.?);
    try std.testing.expectEqual(project.type_store.builtins.unknown, main_module.type_info.lookupSymbol(bad_symbol).?.declared_type.?);
    var arity_diagnostics: usize = 0;
    for (project.diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, "type arguments") != null) arity_diagnostics += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), arity_diagnostics);
}

test "Goal 153 imported and inherited shapes support indexed access keyof and typeof" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\export interface Entity { readonly id: number; }
        \\export interface User extends Entity { name?: string; }
        \\export const current: User = { id: 1, name: "A" };
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import { current } from "./dep";
        \\import type { User } from "./dep";
        \\type ImportedName = User["name"];
        \\type ImportedKeys = keyof User;
        \\type ImportedQuery = typeof current;
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;
    const name_symbol = projectSymbolByName(&project, main_id, "ImportedName", .type_alias) orelse return error.TestExpectedEqual;
    const keys_symbol = projectSymbolByName(&project, main_id, "ImportedKeys", .type_alias) orelse return error.TestExpectedEqual;
    const query_symbol = projectSymbolByName(&project, main_id, "ImportedQuery", .type_alias) orelse return error.TestExpectedEqual;
    const user_import = projectImportByLocal(&project, main_id, "User") orelse return error.TestExpectedEqual;
    const expected_name = try project.type_store.unionOf(&.{ project.type_store.builtins.string, project.type_store.builtins.undefined });
    try std.testing.expectEqual(expected_name, main_module.type_info.lookupSymbol(name_symbol).?.declared_type.?);
    try std.testing.expectEqual(user_import.target.?.type_id, main_module.type_info.lookupSymbol(query_symbol).?.declared_type.?);
    const keys_type = main_module.type_info.lookupSymbol(keys_symbol).?.declared_type.?;
    const keys = project.type_store.lookup(keys_type).?.kind.union_type;
    const id_key = try project.type_store.intern(.{ .literal = .{ .string = "id" } });
    const name_key = try project.type_store.intern(.{ .literal = .{ .string = "name" } });
    var saw_id = false;
    var saw_name = false;
    for (keys) |key| {
        saw_id = saw_id or key == id_key;
        saw_name = saw_name or key == name_key;
    }
    try std.testing.expect(saw_id and saw_name);
    try std.testing.expectEqual(@as(usize, 0), project.diagnostics.len);
}

test "Goal 139 and Goal 149 imported type aliases and reexports preserve declaration identity" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.ts", .data =
        \\export interface User { name: string; }
        \\export class Box { value: number; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "relay.ts", .data =
        \\export type { User as Person } from "./dep";
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import type { Person as LocalUser } from "./relay";
        \\import { Box as LocalBox } from "./dep";
        \\let value: LocalUser;
        \\let box: LocalBox;
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const dep_id = projectModuleIdByBasename(&project, "dep.ts") orelse return error.TestExpectedEqual;
    const relay_id = projectModuleIdByBasename(&project, "relay.ts") orelse return error.TestExpectedEqual;
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;
    const user = project.lookupExport(dep_id, "User") orelse return error.TestExpectedEqual;
    const person = project.lookupExport(relay_id, "Person") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(user.identity, person.identity);

    const local_user = projectImportByLocal(&project, main_id, "LocalUser") orelse return error.TestExpectedEqual;
    try std.testing.expect(local_user.type_only);
    try std.testing.expect(!local_user.runtime_binding);
    try std.testing.expectEqual(user.identity, local_user.target.?);
    const user_shape = project.type_store.lookupInterfaceSemanticType(user.identity.declaration) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), user_shape.members.members.len);
    try std.testing.expectEqualStrings("name", user_shape.members.members[0].name);
    try std.testing.expectEqual(project.type_store.builtins.string, user_shape.members.members[0].type_id);
    const main_module = project.lookupModule(main_id) orelse return error.TestExpectedEqual;
    const value_symbol = projectSymbolByName(&project, main_id, "value", .variable) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(user.identity.type_id, main_module.type_info.lookupSymbol(value_symbol).?.declared_type.?);

    const box_import = projectImportByLocal(&project, main_id, "LocalBox") orelse return error.TestExpectedEqual;
    try std.testing.expect(!box_import.type_only);
    try std.testing.expect(box_import.runtime_binding);
    const box_target = box_import.target.?;
    const box_shape = project.type_store.lookupClassSemanticType(box_target.declaration) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), box_shape.instance_members.members.len);
    try std.testing.expectEqualStrings("value", box_shape.instance_members.members[0].name);
    try std.testing.expectEqual(project.type_store.builtins.number, box_shape.instance_members.members[0].type_id);
    const box_symbol = projectSymbolByName(&project, main_id, "box", .variable) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(box_import.target.?.type_id, main_module.type_info.lookupSymbol(box_symbol).?.declared_type.?);
}

test "Goal 139 and Goal 149 cyclic imported annotations terminate with stable placeholders" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data =
        \\import type { B } from "./b";
        \\export type A = B;
        \\let localA: B;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data =
        \\import type { A } from "./a";
        \\export type B = A;
        \\let localB: A;
    });

    var project = try analyzeTemporaryProject(&tmp, "a.ts");
    defer project.deinit();
    try std.testing.expect(project.is_partial);
    const a_id = projectModuleIdByBasename(&project, "a.ts") orelse return error.TestExpectedEqual;
    const b_id = projectModuleIdByBasename(&project, "b.ts") orelse return error.TestExpectedEqual;
    const a_module = project.lookupModule(a_id) orelse return error.TestExpectedEqual;
    const b_module = project.lookupModule(b_id) orelse return error.TestExpectedEqual;
    const local_a = projectSymbolByName(&project, a_id, "localA", .variable) orelse return error.TestExpectedEqual;
    const local_b = projectSymbolByName(&project, b_id, "localB", .variable) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(project.type_store.builtins.unknown, a_module.type_info.lookupSymbol(local_a).?.declared_type.?);
    try std.testing.expectEqual(project.type_store.builtins.unknown, b_module.type_info.lookupSymbol(local_b).?.declared_type.?);
}

test "Goal 136 project nominal identities qualify equal local declaration ids" {
    const io = Io.Threaded.io(Io.Threaded.global_single_threaded);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const declarations =
        \\export class Shared {}
        \\export interface Shape {}
        \\export enum Choice { A }
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data = declarations });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data = declarations });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ts", .data =
        \\import { Shared as AShared, Shape as AShape, Choice as AChoice } from "./a";
        \\import { Shared as BShared, Shape as BShape, Choice as BChoice } from "./b";
    });

    var project = try analyzeTemporaryProject(&tmp, "main.ts");
    defer project.deinit();
    const a_id = projectModuleIdByBasename(&project, "a.ts") orelse return error.TestExpectedEqual;
    const b_id = projectModuleIdByBasename(&project, "b.ts") orelse return error.TestExpectedEqual;
    const main_id = projectModuleIdByBasename(&project, "main.ts") orelse return error.TestExpectedEqual;

    const pairs = [_][2][]const u8{
        .{ "Shared", "AShared" },
        .{ "Shape", "AShape" },
        .{ "Choice", "AChoice" },
    };
    const b_locals = [_][]const u8{ "BShared", "BShape", "BChoice" };
    for (pairs, b_locals) |names, b_local| {
        const a_export = project.lookupExport(a_id, names[0]) orelse return error.TestExpectedEqual;
        const b_export = project.lookupExport(b_id, names[0]) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(
            a_export.identity.declaration.declaration_id,
            b_export.identity.declaration.declaration_id,
        );
        try std.testing.expect(!a_export.identity.declaration.eql(b_export.identity.declaration));
        try std.testing.expect(a_export.identity.type_id != b_export.identity.type_id);
        try std.testing.expectEqual(
            a_export.identity,
            projectImportByLocal(&project, main_id, names[1]).?.target.?,
        );
        try std.testing.expectEqual(
            b_export.identity,
            projectImportByLocal(&project, main_id, b_local).?.target.?,
        );
    }
}

