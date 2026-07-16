//! Frozen read-only HIR v1 consumer surface.

const model = @import("model.zig");
const ids = @import("ids.zig");
const origin = @import("origin.zig");
const project_mod = @import("../project/root.zig");
const result_mod = @import("result.zig");
const types = @import("../types/root.zig");

pub const api_version: u32 = 1;
pub const minimum_api_version: u32 = 1;

pub const Error = error{
    UnsupportedVersion,
    InvalidId,
    ForeignId,
};

/// Immutable borrowed view. The owning HirResult must outlive this value.
pub const View = struct {
    result: *const result_mod.HirResult,

    pub fn open(result: *const result_mod.HirResult, requested_version: u32) Error!View {
        if (requested_version < minimum_api_version or requested_version > api_version)
            return error.UnsupportedVersion;
        return .{ .result = result };
    }

    pub fn version(_: View) u32 {
        return api_version;
    }

    pub fn project(self: View) *const model.HirProject {
        return &self.result.project;
    }

    pub fn modules(self: View) []const model.HirModule {
        return self.result.project.modules;
    }

    pub fn module(self: View, id: project_mod.ModuleId) Error!*const model.HirModule {
        for (self.modules()) |*item| if (item.module_id == id) return item;
        return error.InvalidId;
    }

    pub fn externalDeclarations(self: View) []const model.HirExternalDeclaration {
        return self.result.project.external_declarations;
    }

    pub fn externalDeclaration(
        self: View,
        module_id: project_mod.ExternalModuleId,
        symbol_id: project_mod.ExternalSymbolId,
    ) Error!*const model.HirExternalDeclaration {
        for (self.externalDeclarations()) |*item| {
            if (item.module_id == module_id and item.symbol_id == symbol_id) return item;
        }
        return error.InvalidId;
    }

    pub fn functions(self: View) []const model.HirFunction {
        return self.result.project.functions;
    }

    pub fn function(self: View, id: ids.FunctionId) Error!*const model.HirFunction {
        self.result.requireOwnedId(id) catch return error.ForeignId;
        const index = id.index() orelse return error.InvalidId;
        if (index >= self.result.project.functions.len) return error.InvalidId;
        return &self.result.project.functions[index];
    }

    pub fn block(self: View, function_id: ids.FunctionId, block_id: ids.BlockId) Error!*const model.HirBlock {
        self.result.requireOwnedId(block_id) catch return error.ForeignId;
        const function_record = try self.function(function_id);
        for (function_record.blocks) |*item| if (item.id.eql(block_id)) return item;
        return error.InvalidId;
    }

    pub fn instruction(
        self: View,
        function_id: ids.FunctionId,
        block_id: ids.BlockId,
        instruction_id: ids.InstructionId,
    ) Error!*const model.HirInstruction {
        self.result.requireOwnedId(instruction_id) catch return error.ForeignId;
        const block_record = try self.block(function_id, block_id);
        for (block_record.instructions) |*item| if (item.id.eql(instruction_id)) return item;
        return error.InvalidId;
    }

    pub fn binding(self: View, function_id: ids.FunctionId, binding_id: ids.BindingId) Error!*const model.HirBinding {
        self.result.requireOwnedId(binding_id) catch return error.ForeignId;
        const function_record = try self.function(function_id);
        for (function_record.bindings) |*item| if (item.id.eql(binding_id)) return item;
        return error.InvalidId;
    }

    pub fn typeRecord(self: View, id: types.TypeId) Error!types.Type {
        return self.result.lookupType(id) orelse error.InvalidId;
    }

    pub fn typeCount(self: View) usize {
        return self.result.typeCount();
    }

    pub fn typeAt(self: View, ordinal: usize) Error!types.Type {
        return self.result.typeAt(ordinal) orelse error.InvalidId;
    }

    pub fn functionSignature(self: View, id: types.TypeId) Error!types.FunctionSignature {
        return self.result.lookupFunctionSignature(id) orelse error.InvalidId;
    }

    pub fn originRecord(self: View, id: ids.OriginId) Error!origin.OriginRecord {
        self.result.requireOwnedId(id) catch return error.ForeignId;
        const index = id.index() orelse return error.InvalidId;
        if (index >= self.result.project.origins.records.len) return error.InvalidId;
        return self.result.project.origins.records[index];
    }
};
