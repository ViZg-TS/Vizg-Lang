//! Portable project API.

pub const contracts = @import("contracts.zig");
pub const graph = @import("graph.zig");
pub const session = @import("session.zig");
pub const state_machine = @import("state_machine.zig");

pub const ModuleId = contracts.ModuleId;
pub const RequestId = contracts.RequestId;
pub const ExternalModuleId = contracts.ExternalModuleId;
pub const SourceKind = contracts.SourceKind;
pub const ModuleSource = contracts.ModuleSource;
pub const RequestKind = contracts.RequestKind;
pub const SourceSpan = contracts.SourceSpan;
pub const RequestAttribute = contracts.RequestAttribute;
pub const ModuleRequest = contracts.ModuleRequest;
pub const ModuleRequestInput = contracts.ModuleRequestInput;
pub const ExternalExportKind = contracts.ExternalExportKind;
pub const ExternalType = contracts.ExternalType;
pub const ExternalExportDescriptor = contracts.ExternalExportDescriptor;
pub const ExternalModuleDescriptor = contracts.ExternalModuleDescriptor;
pub const ModuleState = session.ModuleState;
pub const ProjectModule = session.Module;
pub const Project = session.Project;
pub const Graph = graph.Graph;
pub const GraphEdge = graph.Edge;
pub const GraphDiagnostic = graph.GraphDiagnostic;
pub const ProjectFinishResult = session.FinishResult;
pub const RequestStatus = state_machine.RequestStatus;
pub const ResponseKind = state_machine.ResponseKind;
pub const RequestResolution = state_machine.Resolution;
pub const ProjectStep = state_machine.Step;

test {
    _ = contracts;
    _ = session;
    _ = state_machine;
}
