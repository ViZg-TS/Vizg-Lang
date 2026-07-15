const std = @import("std");
const abi = @import("vizg-abi");

extern fn vizg_c_sizeof_Vizg_ProjectStatus() usize;
extern fn vizg_c_alignof_Vizg_ProjectStatus() usize;
extern fn vizg_c_sizeof_Vizg_ProjectSourceKind() usize;
extern fn vizg_c_alignof_Vizg_ProjectSourceKind() usize;
extern fn vizg_c_sizeof_Vizg_ProjectStepKind() usize;
extern fn vizg_c_alignof_Vizg_ProjectStepKind() usize;
extern fn vizg_c_sizeof_Vizg_ProjectRequestOperation() usize;
extern fn vizg_c_alignof_Vizg_ProjectRequestOperation() usize;
extern fn vizg_c_sizeof_Vizg_ProjectFailureKind() usize;
extern fn vizg_c_alignof_Vizg_ProjectFailureKind() usize;
extern fn vizg_c_sizeof_Vizg_ExternalExportKind() usize;
extern fn vizg_c_alignof_Vizg_ExternalExportKind() usize;
extern fn vizg_c_sizeof_Vizg_ExternalType() usize;
extern fn vizg_c_alignof_Vizg_ExternalType() usize;
extern fn vizg_c_sizeof_Vizg_ProjectConfig() usize;
extern fn vizg_c_alignof_Vizg_ProjectConfig() usize;
extern fn vizg_c_sizeof_Vizg_ProjectSource() usize;
extern fn vizg_c_alignof_Vizg_ProjectSource() usize;
extern fn vizg_c_sizeof_Vizg_ProjectSpan() usize;
extern fn vizg_c_alignof_Vizg_ProjectSpan() usize;
extern fn vizg_c_sizeof_Vizg_ProjectRequestAttribute() usize;
extern fn vizg_c_alignof_Vizg_ProjectRequestAttribute() usize;
extern fn vizg_c_sizeof_Vizg_ProjectStep() usize;
extern fn vizg_c_alignof_Vizg_ProjectStep() usize;
extern fn vizg_c_sizeof_Vizg_ExternalExport() usize;
extern fn vizg_c_alignof_Vizg_ExternalExport() usize;
extern fn vizg_c_sizeof_Vizg_ExternalModule() usize;
extern fn vizg_c_alignof_Vizg_ExternalModule() usize;
extern fn vizg_c_sizeof_Vizg_ProjectResultSummary() usize;
extern fn vizg_c_sizeof_Vizg_ProjectModuleInfo() usize;
extern fn vizg_c_sizeof_Vizg_ProjectDiagnostic() usize;
extern fn vizg_c_sizeof_Vizg_ProjectEdgeInfo() usize;
extern fn vizg_c_sizeof_Vizg_ProjectImportInfo() usize;
extern fn vizg_c_sizeof_Vizg_ProjectExportInfo() usize;
extern fn vizg_c_alignof_Vizg_ProjectResultSummary() usize;
extern fn vizg_c_alignof_Vizg_ProjectModuleInfo() usize;
extern fn vizg_c_alignof_Vizg_ProjectDiagnostic() usize;
extern fn vizg_c_alignof_Vizg_ProjectEdgeInfo() usize;
extern fn vizg_c_alignof_Vizg_ProjectImportInfo() usize;
extern fn vizg_c_alignof_Vizg_ProjectExportInfo() usize;
extern fn vizg_c_fields_Vizg_ProjectConfig() usize;
extern fn vizg_c_fields_Vizg_ProjectSource() usize;
extern fn vizg_c_fields_Vizg_ProjectSpan() usize;
extern fn vizg_c_fields_Vizg_ProjectRequestAttribute() usize;
extern fn vizg_c_fields_Vizg_ProjectStep() usize;
extern fn vizg_c_fields_Vizg_ExternalExport() usize;
extern fn vizg_c_fields_Vizg_ExternalModule() usize;
extern fn vizg_c_fields_Vizg_ProjectResultSummary() usize;
extern fn vizg_c_value_project_status_internal_error() u32;
extern fn vizg_c_value_project_request_re_export() u32;
extern fn vizg_c_value_external_type_object() u32;

fn expectLayout(comptime T: type, size: usize, alignment: usize) !void {
    try std.testing.expectEqual(@sizeOf(T), size);
    try std.testing.expectEqual(@alignOf(T), alignment);
}
fn f(comptime T: type, comptime field: []const u8, weight: usize) usize {
    return @offsetOf(T, field) * weight;
}

test "official ABI v1 C and Zig layouts match" {
    try expectLayout(abi.Vizg_ProjectStatus, vizg_c_sizeof_Vizg_ProjectStatus(), vizg_c_alignof_Vizg_ProjectStatus());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ProjectSourceKind(), vizg_c_alignof_Vizg_ProjectSourceKind());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ProjectStepKind(), vizg_c_alignof_Vizg_ProjectStepKind());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ProjectRequestOperation(), vizg_c_alignof_Vizg_ProjectRequestOperation());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ProjectFailureKind(), vizg_c_alignof_Vizg_ProjectFailureKind());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ExternalExportKind(), vizg_c_alignof_Vizg_ExternalExportKind());
    try expectLayout(u32, vizg_c_sizeof_Vizg_ExternalType(), vizg_c_alignof_Vizg_ExternalType());
    try expectLayout(abi.Vizg_ProjectConfig, vizg_c_sizeof_Vizg_ProjectConfig(), vizg_c_alignof_Vizg_ProjectConfig());
    try expectLayout(abi.Vizg_ProjectSource, vizg_c_sizeof_Vizg_ProjectSource(), vizg_c_alignof_Vizg_ProjectSource());
    try expectLayout(abi.Vizg_ProjectSpan, vizg_c_sizeof_Vizg_ProjectSpan(), vizg_c_alignof_Vizg_ProjectSpan());
    try expectLayout(abi.Vizg_ProjectRequestAttribute, vizg_c_sizeof_Vizg_ProjectRequestAttribute(), vizg_c_alignof_Vizg_ProjectRequestAttribute());
    try expectLayout(abi.Vizg_ProjectStep, vizg_c_sizeof_Vizg_ProjectStep(), vizg_c_alignof_Vizg_ProjectStep());
    try expectLayout(abi.Vizg_ExternalExport, vizg_c_sizeof_Vizg_ExternalExport(), vizg_c_alignof_Vizg_ExternalExport());
    try expectLayout(abi.Vizg_ExternalModule, vizg_c_sizeof_Vizg_ExternalModule(), vizg_c_alignof_Vizg_ExternalModule());
    try expectLayout(abi.Vizg_ProjectResultSummary, vizg_c_sizeof_Vizg_ProjectResultSummary(), vizg_c_alignof_Vizg_ProjectResultSummary());
    try expectLayout(abi.Vizg_ProjectModuleInfo, vizg_c_sizeof_Vizg_ProjectModuleInfo(), vizg_c_alignof_Vizg_ProjectModuleInfo());
    try expectLayout(abi.Vizg_ProjectDiagnostic, vizg_c_sizeof_Vizg_ProjectDiagnostic(), vizg_c_alignof_Vizg_ProjectDiagnostic());
    try expectLayout(abi.Vizg_ProjectEdgeInfo, vizg_c_sizeof_Vizg_ProjectEdgeInfo(), vizg_c_alignof_Vizg_ProjectEdgeInfo());
    try expectLayout(abi.Vizg_ProjectImportInfo, vizg_c_sizeof_Vizg_ProjectImportInfo(), vizg_c_alignof_Vizg_ProjectImportInfo());
    try expectLayout(abi.Vizg_ProjectExportInfo, vizg_c_sizeof_Vizg_ProjectExportInfo(), vizg_c_alignof_Vizg_ProjectExportInfo());

    try std.testing.expectEqual(f(abi.Vizg_ProjectConfig, "workspace_ptr", 1) + f(abi.Vizg_ProjectConfig, "workspace_len", 2) + f(abi.Vizg_ProjectConfig, "max_source_bytes", 3) + f(abi.Vizg_ProjectConfig, "max_modules", 4) + f(abi.Vizg_ProjectConfig, "max_requests", 5) + f(abi.Vizg_ProjectConfig, "max_edges", 6) + f(abi.Vizg_ProjectConfig, "max_diagnostics", 7) + f(abi.Vizg_ProjectConfig, "max_graph_depth", 8) + f(abi.Vizg_ProjectConfig, "max_semantic_types", 9), vizg_c_fields_Vizg_ProjectConfig());
    try std.testing.expectEqual(f(abi.Vizg_ProjectSource, "module_id", 1) + f(abi.Vizg_ProjectSource, "logical_name_ptr", 2) + f(abi.Vizg_ProjectSource, "logical_name_len", 3) + f(abi.Vizg_ProjectSource, "source_ptr", 4) + f(abi.Vizg_ProjectSource, "source_len", 5) + f(abi.Vizg_ProjectSource, "kind", 6) + f(abi.Vizg_ProjectSource, "is_root", 7) + f(abi.Vizg_ProjectSource, "reserved", 8), vizg_c_fields_Vizg_ProjectSource());
    try std.testing.expectEqual(f(abi.Vizg_ProjectSpan, "start", 1) + f(abi.Vizg_ProjectSpan, "end", 2) + f(abi.Vizg_ProjectSpan, "line", 3) + f(abi.Vizg_ProjectSpan, "column", 4), vizg_c_fields_Vizg_ProjectSpan());
    try std.testing.expectEqual(f(abi.Vizg_ProjectRequestAttribute, "key_ptr", 1) + f(abi.Vizg_ProjectRequestAttribute, "key_len", 2) + f(abi.Vizg_ProjectRequestAttribute, "value_ptr", 3) + f(abi.Vizg_ProjectRequestAttribute, "value_len", 4) + f(abi.Vizg_ProjectRequestAttribute, "span", 5), vizg_c_fields_Vizg_ProjectRequestAttribute());
    try std.testing.expectEqual(f(abi.Vizg_ProjectStep, "kind", 1) + f(abi.Vizg_ProjectStep, "request_id", 2) + f(abi.Vizg_ProjectStep, "importer_module_id", 3) + f(abi.Vizg_ProjectStep, "specifier_ptr", 4) + f(abi.Vizg_ProjectStep, "specifier_len", 5) + f(abi.Vizg_ProjectStep, "request_operation", 6) + f(abi.Vizg_ProjectStep, "type_only", 7) + f(abi.Vizg_ProjectStep, "reserved", 8) + f(abi.Vizg_ProjectStep, "attributes_ptr", 9) + f(abi.Vizg_ProjectStep, "attribute_count", 10) + f(abi.Vizg_ProjectStep, "span", 11), vizg_c_fields_Vizg_ProjectStep());
    try std.testing.expectEqual(f(abi.Vizg_ExternalExport, "name_ptr", 1) + f(abi.Vizg_ExternalExport, "name_len", 2) + f(abi.Vizg_ExternalExport, "kind", 3) + f(abi.Vizg_ExternalExport, "type_only", 4) + f(abi.Vizg_ExternalExport, "has_type_metadata", 5) + f(abi.Vizg_ExternalExport, "reserved", 6) + f(abi.Vizg_ExternalExport, "type_metadata", 7), vizg_c_fields_Vizg_ExternalExport());
    try std.testing.expectEqual(f(abi.Vizg_ExternalModule, "external_module_id", 1) + f(abi.Vizg_ExternalModule, "logical_name_ptr", 2) + f(abi.Vizg_ExternalModule, "logical_name_len", 3) + f(abi.Vizg_ExternalModule, "exports_ptr", 4) + f(abi.Vizg_ExternalModule, "export_count", 5), vizg_c_fields_Vizg_ExternalModule());
    try std.testing.expectEqual(f(abi.Vizg_ProjectResultSummary, "module_count", 1) + f(abi.Vizg_ProjectResultSummary, "diagnostic_count", 2) + f(abi.Vizg_ProjectResultSummary, "edge_count", 3) + f(abi.Vizg_ProjectResultSummary, "import_count", 4) + f(abi.Vizg_ProjectResultSummary, "export_count", 5) + f(abi.Vizg_ProjectResultSummary, "is_partial", 6) + f(abi.Vizg_ProjectResultSummary, "has_syntax_errors", 7) + f(abi.Vizg_ProjectResultSummary, "has_semantic_errors", 8) + f(abi.Vizg_ProjectResultSummary, "has_module_failures", 9) + f(abi.Vizg_ProjectResultSummary, "reserved", 10), vizg_c_fields_Vizg_ProjectResultSummary());

    try std.testing.expectEqual(@as(u32, @intFromEnum(abi.Vizg_ProjectStatus.INTERNAL_ERROR)), vizg_c_value_project_status_internal_error());
    try std.testing.expectEqual(@as(u32, 1), vizg_c_value_project_request_re_export());
    try std.testing.expectEqual(@as(u32, 11), vizg_c_value_external_type_object());
}
