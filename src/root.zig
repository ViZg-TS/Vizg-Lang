// By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const ast = @import("frontend/ast.zig");
pub const binder = @import("frontend/binder.zig");
pub const cfg = @import("frontend/cfg.zig");
pub const diagnostics = @import("diagnostics/root.zig");
pub const frontend = @import("frontend/frontend.zig");
pub const modules = @import("modules/root.zig");
pub const parser = @import("frontend/parser.zig");
pub const resolver = @import("frontend/resolver.zig");
pub const scanner = @import("frontend/scanner.zig");
pub const tokens = @import("frontend/tokens.zig");

pub const semantics = @import("semantics/root.zig");
pub const project = @import("project/root.zig");
pub const hir = @import("hir/root.zig");

// Official portable project contracts. These identities are distinct from the
// semantic analysis graph records exported through `modules`.
pub const ModuleId = project.ModuleId;
pub const RequestId = project.RequestId;
pub const ExternalModuleId = project.ExternalModuleId;
pub const ExternalSymbolId = project.ExternalSymbolId;
pub const ModuleSource = project.ModuleSource;
pub const ModuleRequest = project.ModuleRequest;
pub const ModuleRequestInput = project.ModuleRequestInput;
pub const ExternalExportKind = project.ExternalExportKind;
pub const ExternalType = project.ExternalType;
pub const ExternalNamespace = project.ExternalNamespace;
pub const ExternalDeclarationKind = project.ExternalDeclarationKind;
pub const ExternalParameterDescriptor = project.ExternalParameterDescriptor;
pub const ExternalFunctionDescriptor = project.ExternalFunctionDescriptor;
pub const ExternalEffectSet = project.ExternalEffectSet;
pub const ExternalExportDescriptor = project.ExternalExportDescriptor;
pub const ExternalModuleDescriptor = project.ExternalModuleDescriptor;
pub const ModuleState = project.ModuleState;
pub const Project = project.Project;
pub const ProjectLimits = project.ProjectLimits;
pub const ProjectStep = project.ProjectStep;
pub const ProjectFinishResult = project.ProjectFinishResult;
pub const ProjectDiagnosticPhase = project.ProjectDiagnosticPhase;
pub const ProjectDiagnostic = project.ProjectDiagnostic;

// Moved: type model now lives under `types/` so the frontend stays focused on
// syntax and single-file structural analysis. Callers can reach the same
// types via vizg.types.TypeId, vizg.types.Type, vizg.types.Builtins, etc.
pub const types = @import("types/root.zig");

test {
    _ = diagnostics;
    _ = binder;
    _ = cfg;
    _ = parser;
    _ = resolver;
    _ = scanner;
    _ = frontend;
    _ = tokens;
    _ = project;
    _ = hir;
    _ = @import("modules/graph.zig");
    _ = @import("modules/root.zig");
    // Keep semantics layer wired in so its tests register alongside the rest.
    _ = @import("semantics/root.zig");
    _ = @import("semantics/type_info.zig");
    _ = @import("semantics/type_collector_test.zig");
    _ = @import("frontend/syntax_corpus_test.zig");
    _ = @import("frontend/tests.zig");
}
