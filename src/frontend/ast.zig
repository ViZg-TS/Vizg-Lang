pub const tokens = @import("tokens.zig");

pub const NodeId = u32;
pub const invalid_node: NodeId = std.math.maxInt(NodeId);
pub const TypeNodeId = u32;
pub const invalid_type_node: TypeNodeId = std.math.maxInt(TypeNodeId);

const std = @import("std");

pub const Program = struct {
    statements: []const NodeId,
};

pub const TypeAnnotation = struct {
    root: TypeNodeId,
    span: tokens.Span,
};

pub const NamedType = struct {
    name: []const u8,
    type_arguments: []const TypeNodeId = &.{},
};

pub const LiteralTypeKind = enum { string, number, bigint, boolean, null };

pub const LiteralType = struct {
    kind: LiteralTypeKind,
    spelling: []const u8,
};

pub const TypeMember = struct {
    name: []const u8,
    optional: bool = false,
    readonly: bool = false,
    type_node: TypeNodeId,
    span: tokens.Span,
};

pub const TypeParameter = struct {
    name: []const u8,
    optional: bool = false,
    type_node: TypeNodeId,
    span: tokens.Span,
};

pub const GenericTypeParameter = struct {
    name: []const u8,
    constraint: ?TypeAnnotation = null,
    default_type: ?TypeAnnotation = null,
    span: tokens.Span,
};

pub const TypeNodeData = union(enum) {
    Named: NamedType,
    Literal: LiteralType,
    Array: TypeNodeId,
    Readonly: TypeNodeId,
    IndexedAccess: struct {
        object_type: TypeNodeId,
        index_type: TypeNodeId,
    },
    KeyOf: TypeNodeId,
    TypeQuery: []const u8,
    Union: []const TypeNodeId,
    Intersection: []const TypeNodeId,
    Object: []const TypeMember,
    Function: struct {
        parameters: []const TypeParameter,
        return_type: TypeNodeId,
    },
    Tuple: []const TypeNodeId,
    Parenthesized: TypeNodeId,
};

pub const TypeNode = struct {
    span: tokens.Span,
    data: TypeNodeData,
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
    raw: []const u8,
    cooked: ?[]const u8,
    expression: ?NodeId,
    span: tokens.Span,
};

pub const TemplateExpression = struct {
    parts: []const TemplatePart,
};

pub const TaggedTemplateExpression = struct {
    tag: NodeId,
    template: NodeId,
};

pub const ImportExpression = struct {
    source: NodeId,
    options: ?NodeId = null,
    attributes: ?ImportAttributes = null,
};

pub const ImportAttribute = struct {
    key: []const u8,
    key_span: tokens.Span,
    value: NodeId,
    span: tokens.Span,
};

pub const ImportAttributes = struct {
    entries: []const ImportAttribute,
    span: tokens.Span,
};

pub const MetaPropertyKind = enum { import_meta, new_target };

pub const MetaProperty = struct {
    kind: MetaPropertyKind,
};

pub const ImportDeclaration = struct {
    kind: ImportKind,
    type_only: bool = false,
    names: []const []const u8,
    specifiers: []const ImportSpecifier = &.{},
    source: []const u8,
    source_span: tokens.Span,
    attributes: ?ImportAttributes = null,
};

pub const ImportKind = enum {
    named,
    default,
    namespace,
    side_effect,
    mixed,
};

pub const ImportSpecifierKind = enum {
    named,
    default,
    namespace,
};

pub const ImportSpecifier = struct {
    kind: ImportSpecifierKind = .named,
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

pub const ExportKind = enum {
    declaration,
    default_expression,
    local,
    re_export,
    export_all,
};

pub const ExportDeclaration = struct {
    kind: ExportKind = .local,
    type_only: bool = false,
    declaration: NodeId = invalid_node,
    expression: NodeId = invalid_node,
    specifiers: []const ExportSpecifier = &.{},
    default_name: ?[]const u8 = null,
    source: []const u8 = "",
    source_span: ?tokens.Span = null,
};

pub const TypeAliasDeclaration = struct {
    name: []const u8,
    type_parameters: []const GenericTypeParameter = &.{},
    type_annotation: TypeAnnotation,
};

pub const InterfaceDeclaration = struct {
    name: []const u8,
    type_parameters: []const GenericTypeParameter = &.{},
    extends: []const TypeNodeId = &.{},
    body: TypeNodeId,
};

pub const EnumDeclaration = struct {
    name: []const u8,
    members: []const NodeId,
};

pub const EnumMember = struct {
    name: []const u8 = "",
    computed_name: ?NodeId = null,
    initializer: ?NodeId = null,
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

pub const FunctionFlags = struct {
    is_async: bool = false,
    is_generator: bool = false,
};

pub const FunctionDeclaration = struct {
    name: []const u8,
    type_parameters: []const GenericTypeParameter = &.{},
    params: []const NodeId,
    body: NodeId,
    exported: bool = false,
    flags: FunctionFlags = .{},
    return_type: ?TypeAnnotation = null,
};

pub const FunctionExpression = struct {
    name: ?[]const u8 = null,
    params: []const NodeId,
    body: NodeId,
    flags: FunctionFlags = .{},
    return_type: ?TypeAnnotation = null,
};

pub const YieldExpression = struct {
    argument: ?NodeId = null,
    delegate: bool = false,
};

pub const ArrowFunctionExpression = struct {
    params: []const NodeId,
    body: NodeId,
    flags: FunctionFlags = .{},
    expression_body: bool,
    return_type: ?TypeAnnotation = null,
};

pub const Parameter = struct {
    name: []const u8,
    type_annotation: ?TypeAnnotation = null,
    rest: bool = false,
    optional: bool = false,
    initializer: ?NodeId = null,
    access: AccessModifier = .none,
    readonly: bool = false,
};

pub const AccessModifier = enum { none, public, private, protected };

pub const ClassDeclaration = struct {
    name: []const u8,
    type_parameters: []const GenericTypeParameter = &.{},
    super_class: ?NodeId = null,
    members: []const NodeId,
};

pub const ClassExpression = struct {
    name: ?[]const u8 = null,
    super_class: ?NodeId = null,
    members: []const NodeId,
};

pub const ClassField = struct {
    name: []const u8,
    type_annotation: ?TypeAnnotation = null,
    initializer: ?NodeId = null,
    is_static: bool = false,
    readonly: bool = false,
    access: AccessModifier = .none,
    optional: bool = false,
    definite: bool = false,
};

pub const ClassMethodKind = enum { method, constructor, getter, setter };

pub const ClassMethod = struct {
    name: []const u8,
    params: []const NodeId,
    body: NodeId,
    return_type: ?TypeAnnotation = null,
    is_static: bool = false,
    access: AccessModifier = .none,
    kind: ClassMethodKind = .method,
    flags: FunctionFlags = .{},
};

pub const SpreadElement = struct {
    argument: NodeId,
};

pub const ReturnStatement = struct {
    argument: ?NodeId,
};

pub const ThrowStatement = struct {
    argument: NodeId,
};

pub const DebuggerStatement = struct {};

pub const TryStatement = struct {
    block: NodeId,
    handler: ?NodeId,
    finalizer: ?NodeId,
};

pub const CatchClause = struct {
    parameter: ?NodeId,
    body: NodeId,
};

pub const FinallyClause = struct {
    body: NodeId,
};

pub const LabeledStatement = struct {
    label: []const u8,
    body: NodeId,
};

pub const BreakStatement = struct { label: ?[]const u8 = null };

pub const ContinueStatement = struct { label: ?[]const u8 = null };

pub const ExpressionStatement = struct {
    expression: NodeId,
};

pub const CallExpression = struct {
    callee: NodeId,
    arguments: []const NodeId,
    optional: bool = false,
};

pub const ThisExpression = struct {};

pub const SuperExpression = struct {};

pub const NewExpression = struct {
    callee: NodeId,
    arguments: []const NodeId,
};

pub const MemberExpression = struct {
    object: NodeId,
    property: []const u8,
    optional: bool = false,
};

pub const ElementAccessExpression = struct {
    object: NodeId,
    index: NodeId,
    optional: bool = false,
};

pub const AsExpression = struct {
    expression: NodeId,
    type_annotation: TypeAnnotation,
};

pub const SatisfiesExpression = struct {
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

pub const SequenceExpression = struct {
    expressions: []const NodeId,
};

pub const AssignmentExpression = struct {
    operator: tokens.TokenType,
    left: NodeId,
    right: NodeId,
};

pub const ConditionalExpression = struct {
    condition: NodeId,
    consequent: NodeId,
    alternate: NodeId,
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

pub const DoWhileStatement = struct {
    body: NodeId,
    condition: NodeId,
};

pub const ForStatementKind = enum {
    classic,
    in,
    of,
};

pub const ForStatement = struct {
    kind: ForStatementKind = .classic,
    await: bool = false,
    init: ?NodeId,
    condition: ?NodeId,
    update: ?NodeId,
    right: ?NodeId = null,
    body: NodeId,
};

pub const SwitchStatement = struct {
    discriminant: NodeId,
    cases: []const NodeId,
};

pub const SwitchCase = struct {
    condition: ?NodeId,
    consequent: []const NodeId,
};

pub const ObjectPropertyKind = enum {
    key_value,
    shorthand,
    computed,
    spread,
    method,
    async_method,
    getter,
    setter,
};

pub const ObjectProperty = struct {
    kind: ObjectPropertyKind,
    key: []const u8 = "",
    key_span: tokens.Span,
    computed_key: ?NodeId = null,
    value: NodeId,
};

pub const ObjectExpression = struct {
    properties: []const ObjectProperty,
};

pub const ArrayExpression = struct {
    elements: []const ?NodeId,
};

pub const NodeData = union(enum) {
    Program: Program,
    BlockStatement: BlockStatement,
    ExpressionStatement: ExpressionStatement,
    Identifier: Identifier,
    Literal: Literal,
    RegExpLiteral: RegExpLiteral,
    TemplateExpression: TemplateExpression,
    TaggedTemplateExpression: TaggedTemplateExpression,
    ImportExpression: ImportExpression,
    MetaProperty: MetaProperty,
    TypeAliasDeclaration: TypeAliasDeclaration,
    InterfaceDeclaration: InterfaceDeclaration,
    EnumDeclaration: EnumDeclaration,
    EnumMember: EnumMember,
    VariableDeclaration: VariableDeclaration,
    VariableDeclarator: VariableDeclarator,
    FunctionDeclaration: FunctionDeclaration,
    FunctionExpression: FunctionExpression,
    YieldExpression: YieldExpression,
    ArrowFunctionExpression: ArrowFunctionExpression,
    ClassDeclaration: ClassDeclaration,
    ClassExpression: ClassExpression,
    ClassField: ClassField,
    ClassMethod: ClassMethod,
    Parameter: Parameter,
    SpreadElement: SpreadElement,
    ReturnStatement: ReturnStatement,
    ThrowStatement: ThrowStatement,
    DebuggerStatement: DebuggerStatement,
    TryStatement: TryStatement,
    CatchClause: CatchClause,
    FinallyClause: FinallyClause,
    BreakStatement: BreakStatement,
    ContinueStatement: ContinueStatement,
    LabeledStatement: LabeledStatement,
    ThisExpression: ThisExpression,
    SuperExpression: SuperExpression,
    NewExpression: NewExpression,
    CallExpression: CallExpression,
    MemberExpression: MemberExpression,
    ElementAccessExpression: ElementAccessExpression,
    AsExpression: AsExpression,
    SatisfiesExpression: SatisfiesExpression,
    NonNullExpression: NonNullExpression,
    UnaryExpression: UnaryExpression,
    BinaryExpression: BinaryExpression,
    SequenceExpression: SequenceExpression,
    ConditionalExpression: ConditionalExpression,
    UpdateExpression: UpdateExpression,
    AssignmentExpression: AssignmentExpression,
    IfStatement: IfStatement,
    WhileStatement: WhileStatement,
    DoWhileStatement: DoWhileStatement,
    ForStatement: ForStatement,
    SwitchStatement: SwitchStatement,
    SwitchCase: SwitchCase,
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
    type_nodes: []const TypeNode = &.{},
    root: NodeId,

    pub fn node(self: Ast, id: NodeId) Node {
        return self.nodes[@intCast(id)];
    }

    pub fn typeNode(self: Ast, id: TypeNodeId) TypeNode {
        return self.type_nodes[@intCast(id)];
    }

    pub fn annotationName(self: Ast, annotation: TypeAnnotation) ?[]const u8 {
        const type_node = self.typeNode(annotation.root);
        return switch (type_node.data) {
            .Named => |named| if (named.type_arguments.len == 0) named.name else null,
            .Parenthesized => |inner| self.annotationName(.{ .root = inner, .span = self.typeNode(inner).span }),
            else => null,
        };
    }
};
