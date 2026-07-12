pub const tokens = @import("tokens.zig");

pub const NodeId = u32;
pub const invalid_node: NodeId = std.math.maxInt(NodeId);

const std = @import("std");

pub const Program = struct {
    statements: []const NodeId,
};

pub const TypeAnnotation = struct {
    name: []const u8,
    span: tokens.Span,
};

pub const BlockStatement = struct {
    statements: []const NodeId,
};

pub const Identifier = struct {
    name: []const u8,
};

pub const Literal = struct {
    value: []const u8,
};

pub const RegExpLiteral = tokens.RegExpValue;

pub const TemplatePart = struct {
    text: []const u8,
    expression: ?NodeId,
    span: tokens.Span,
};

pub const TemplateExpression = struct {
    parts: []const TemplatePart,
};

pub const ImportDeclaration = struct {
    names: []const []const u8,
    specifiers: []const ImportSpecifier = &.{},
    source: []const u8,
    source_span: tokens.Span,
};

pub const ImportSpecifier = struct {
    imported_name: []const u8,
    local_name: []const u8,
    imported_span: tokens.Span,
    local_span: tokens.Span,
};

pub const ExportSpecifier = struct {
    local_name: []const u8,
    exported_name: []const u8,
    local: NodeId = invalid_node,
    exported: NodeId = invalid_node,
};

pub const ExportDeclaration = struct {
    declaration: NodeId = invalid_node,
    specifiers: []const ExportSpecifier = &.{},
    default_name: ?[]const u8 = null,
};

pub const VariableDeclaration = struct {
    kind: tokens.TokenType,
    declarations: []const NodeId,
};

pub const VariableDeclarator = struct {
    name: []const u8,
    init: ?NodeId,
    type_annotation: ?TypeAnnotation = null,
};

pub const FunctionDeclaration = struct {
    name: []const u8,
    params: []const NodeId,
    body: NodeId,
    exported: bool = false,
    return_type: ?TypeAnnotation = null,
};

pub const Parameter = struct {
    name: []const u8,
    type_annotation: ?TypeAnnotation = null,
};

pub const ReturnStatement = struct {
    argument: ?NodeId,
};

pub const ExpressionStatement = struct {
    expression: NodeId,
};

pub const CallExpression = struct {
    callee: NodeId,
    arguments: []const NodeId,
};

pub const MemberExpression = struct {
    object: NodeId,
    property: []const u8,
};

pub const ElementAccessExpression = struct {
    object: NodeId,
    index: NodeId,
};

pub const AsExpression = struct {
    expression: NodeId,
    type_annotation: TypeAnnotation,
};

pub const NonNullExpression = struct {
    expression: NodeId,
};

pub const UnaryExpression = struct {
    operator: tokens.TokenType,
    argument: NodeId,
};

pub const BinaryExpression = struct {
    operator: tokens.TokenType,
    left: NodeId,
    right: NodeId,
};

pub const AssignmentExpression = struct {
    operator: tokens.TokenType,
    left: NodeId,
    right: NodeId,
};

pub const UpdateExpression = struct {
    operator: tokens.TokenType,
    argument: NodeId,
    prefix: bool,
};

pub const IfStatement = struct {
    condition: NodeId,
    consequent: NodeId,
    alternate: ?NodeId,
};

pub const WhileStatement = struct {
    condition: NodeId,
    body: NodeId,
};

pub const ForStatement = struct {
    init: ?NodeId,
    condition: ?NodeId,
    update: ?NodeId,
    body: NodeId,
};

pub const ObjectProperty = struct {
    key: []const u8,
    key_span: tokens.Span,
    value: NodeId,
};

pub const ObjectExpression = struct {
    properties: []const ObjectProperty,
};

pub const ArrayExpression = struct {
    elements: []const NodeId,
};

pub const NodeData = union(enum) {
    Program: Program,
    BlockStatement: BlockStatement,
    ExpressionStatement: ExpressionStatement,
    Identifier: Identifier,
    Literal: Literal,
    RegExpLiteral: RegExpLiteral,
    TemplateExpression: TemplateExpression,
    VariableDeclaration: VariableDeclaration,
    VariableDeclarator: VariableDeclarator,
    FunctionDeclaration: FunctionDeclaration,
    Parameter: Parameter,
    ReturnStatement: ReturnStatement,
    CallExpression: CallExpression,
    MemberExpression: MemberExpression,
    ElementAccessExpression: ElementAccessExpression,
    AsExpression: AsExpression,
    NonNullExpression: NonNullExpression,
    UnaryExpression: UnaryExpression,
    BinaryExpression: BinaryExpression,
    UpdateExpression: UpdateExpression,
    AssignmentExpression: AssignmentExpression,
    IfStatement: IfStatement,
    WhileStatement: WhileStatement,
    ForStatement: ForStatement,
    ImportDeclaration: ImportDeclaration,
    ExportDeclaration: ExportDeclaration,
    ObjectExpression: ObjectExpression,
    ArrayExpression: ArrayExpression,
};

pub const Node = struct {
    span: tokens.Span,
    data: NodeData,
};

pub const Ast = struct {
    nodes: []const Node,
    root: NodeId,

    pub fn node(self: Ast, id: NodeId) Node {
        return self.nodes[@intCast(id)];
    }
};
