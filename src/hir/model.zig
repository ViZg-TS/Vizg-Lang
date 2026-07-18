//! Target-independent HIR v1 records and legal operation set.

const std = @import("std");
const ids = @import("ids.zig");
const origin_mod = @import("origin.zig");
const project = @import("../project/contracts.zig");
const trace = @import("trace.zig");
const types = @import("../types/root.zig");

pub const schema_version: u32 = 1;
pub const ModuleId = project.ModuleId;
pub const ExternalModuleId = project.ExternalModuleId;
pub const ExternalSymbolId = project.ExternalSymbolId;
pub const SemanticDeclId = types.SemanticDeclId;
pub const TypeId = types.TypeId;

pub const HirProject = struct {
    version: u32 = schema_version,
    modules: []const HirModule = &.{},
    external_declarations: []const HirExternalDeclaration = &.{},
    entities: []const HirEntity = &.{},
    functions: []const HirFunction = &.{},
    constants: []const HirConstant = &.{},
    regions: []const HirRegion = &.{},
    origins: origin_mod.OriginTable = .{},
    lowering_trace: ?trace.LoweringTrace = null,
};

/// Body-less declaration supplied by the host. Identity is the pair
/// (external module, external symbol); source declaration ids never alias it.
pub const HirExternalDeclaration = struct {
    module_id: ExternalModuleId,
    symbol_id: ExternalSymbolId,
    exported_name: []const u8,
    kind: project.ExternalDeclarationKind,
    type_id: TypeId,
    effects: project.ExternalEffectSet,
};

pub const HirModule = struct {
    module_id: ModuleId,
    logical_name: []const u8,
    initialization: ids.FunctionId,
    dependencies: []const HirModuleDependency = &.{},
    imports: []const HirImportBinding = &.{},
    exports: []const HirExportBinding = &.{},
    entities: []const ids.EntityId = &.{},
    origin: ids.OriginId,
};

pub const HirModuleDependency = struct {
    module_id: ModuleId,
    initialization_required: bool,
};

pub const HirModuleReference = union(enum) {
    source: ModuleId,
    external: ExternalModuleId,
};

pub const HirSemanticNamespace = enum { value, type, namespace };

/// Exact linked semantic identity retained by module metadata. It refers to
/// project semantic state; it never implies an executable HIR body exists.
pub const HirSemanticIdentity = struct {
    symbol_id: ?u32,
    declaration: SemanticDeclId,
    type_id: TypeId,
    namespace: HirSemanticNamespace,
    external_module_id: ?ExternalModuleId = null,
    external_symbol_id: ?ExternalSymbolId = null,
    /// Host-assigned identity for ambient globals or registered source values;
    /// `null` for ordinary source-derived symbols.
    host_binding_id: ?u64 = null,
};

pub const HirImportBinding = struct {
    local: ?ids.BindingId,
    source: HirModuleReference,
    exported_name: []const u8,
    target: HirSemanticIdentity,
    type_only: bool,
};

pub const HirExportBinding = struct {
    exported_name: []const u8,
    binding: ?ids.BindingId,
    entity: ?ids.EntityId,
    target: HirSemanticIdentity,
    type_only: bool,

    pub fn init(
        exported_name: []const u8,
        binding: ?ids.BindingId,
        entity: ?ids.EntityId,
        target: HirSemanticIdentity,
        type_only: bool,
    ) error{InvalidExportTarget}!HirExportBinding {
        const target_count: u2 = @intFromBool(binding != null) + @as(u2, @intFromBool(entity != null));
        if (type_only) {
            if (target_count != 0) return error.InvalidExportTarget;
        } else if (target_count != 1) return error.InvalidExportTarget;
        return .{
            .exported_name = exported_name,
            .binding = binding,
            .entity = entity,
            .target = target,
            .type_only = type_only,
        };
    }

    pub fn initShell(exported_name: []const u8, target: HirSemanticIdentity, type_only: bool) HirExportBinding {
        return .{
            .exported_name = exported_name,
            .binding = null,
            .entity = null,
            .target = target,
            .type_only = type_only,
        };
    }
};

pub const HirEntity = struct {
    id: ids.EntityId,
    module_id: ModuleId,
    declaration: ?SemanticDeclId,
    origin: ids.OriginId,
    kind: Kind,

    pub const Kind = union(enum) {
        function: HirFunctionEntity,
        class: HirClassEntity,
        enum_object: HirEnumEntity,
        module_binding: HirModuleBindingEntity,
    };
};

pub const HirFunctionEntity = struct { function: ids.FunctionId };
pub const HirClassEntity = struct {
    constructor: ids.FunctionId,
    instance_initializer: ?ids.FunctionId,
    static_initializer: ?ids.FunctionId,
    methods: []const HirMethod = &.{},
};
pub const HirMethod = struct {
    name: PropertyKey,
    function: ids.FunctionId,
    is_static: bool,
};
pub const HirEnumEntity = struct { binding: ids.BindingId };
pub const HirModuleBindingEntity = struct { binding: ids.BindingId };

pub const HirFunction = struct {
    id: ids.FunctionId,
    module_id: ModuleId,
    symbol: ?SemanticDeclId,
    kind: HirFunctionKind,
    flags: HirFunctionFlags,
    signature_type: TypeId,
    parameters: []const HirParameter = &.{},
    bindings: []const HirBinding = &.{},
    captures: []const HirCapture = &.{},
    places: []const HirPlace = &.{},
    blocks: []const HirBlock = &.{},
    entry: ids.BlockId,
    regions: []const ids.RegionId = &.{},
    origin: ids.OriginId,
};

pub const HirFunctionKind = enum {
    module_initialization,
    ordinary,
    method,
    constructor,
    getter,
    setter,
};

pub const HirFunctionFlags = packed struct {
    lexical_this: bool = false,
    dynamic_this: bool = false,
    constructor: bool = false,
    getter: bool = false,
    setter: bool = false,
    async_: bool = false,
    generator: bool = false,
    async_generator: bool = false,
    uses_super: bool = false,
    uses_new_target: bool = false,
};

pub const HirParameter = struct {
    binding: ids.BindingId,
    type_id: TypeId,
    argument_index: u32,
    optional: bool = false,
    has_default: bool = false,
    rest: bool = false,
    parameter_property: bool = false,
    origin: ids.OriginId,
};

pub const HirBinding = struct {
    id: ids.BindingId,
    name: []const u8,
    kind: HirBindingKind,
    type_id: TypeId,
    declaration: ?SemanticDeclId,
    mutable: bool,
    initial_state: HirBindingInitialState,
    origin: ids.OriginId,
    /// Stable host identity for ambient or registered source bindings.
    host_binding_id: ?u64 = null,
};

pub const HirBindingKind = enum {
    var_,
    let_,
    const_,
    parameter,
    import,
    catch_,
    function,
    class,
    enum_,
    synthetic,
    temporary,
};

/// State at function entry. Lexical declarations remain uninitialized until
/// their source-order `initialize_binding`; live imports never store a local
/// value, and parameters/catch bindings are initialized by their entry plans.
pub const HirBindingInitialState = enum {
    hoisted_undefined,
    hoisted_function,
    temporal_dead_zone,
    initialized,
    live_import,
};

pub const HirCapture = struct {
    source: CaptureSource,
    local: ids.BindingId,
    mode: CaptureMode,
};
pub const CaptureSource = union(enum) {
    binding: ids.BindingId,
    this,
    arguments,
    super,
    new_target,
};
pub const CaptureMode = enum { live_binding, lexical_value };

pub const HirBlock = struct {
    id: ids.BlockId,
    parameters: []const HirBlockParameter = &.{},
    instructions: []const HirInstruction = &.{},
    terminator: HirTerminator,
    origin: ids.OriginId,
};

pub const HirBlockParameter = struct {
    value: ids.ValueId,
    type_id: TypeId,
    origin: ids.OriginId,
};

pub const HirInstruction = struct {
    id: ids.InstructionId,
    result: ?ids.ValueId,
    result_type: ?TypeId,
    operation: HirOperation,
    effects: EffectSet,
    origin: ids.OriginId,

    pub fn init(
        id: ids.InstructionId,
        result: ?ids.ValueId,
        result_type: ?TypeId,
        operation: HirOperation,
        origin: ids.OriginId,
    ) OperationError!HirInstruction {
        const checked_operation = try operation.checked();
        if ((result == null) != (result_type == null)) return error.ResultTypeMismatch;
        if ((result != null) != checked_operation.producesValue()) return error.ResultPresenceMismatch;
        return .{
            .id = id,
            .result = result,
            .result_type = result_type,
            .operation = checked_operation,
            .effects = checked_operation.effectSet(),
            .origin = origin,
        };
    }
};

pub const Operand = union(enum) {
    value: ids.ValueId,
    binding: ids.BindingId,
    constant: HirConstant,
};

pub const PropertyKey = union(enum) {
    static: []const u8,
    computed: ids.ValueId,
    private: SemanticDeclId,
};

pub const HirPlace = struct {
    id: ids.PlaceId,
    kind: Kind,
    origin: ids.OriginId,

    pub const Kind = union(enum) {
        binding: ids.BindingId,
        property: struct { base: ids.ValueId, key: PropertyKey },
        element: struct { base: ids.ValueId, key: ids.ValueId },
        super_property: struct { receiver: ids.ValueId, key: PropertyKey },
    };
};

pub const HirRegion = struct {
    id: ids.RegionId,
    function: ids.FunctionId,
    parent: ?ids.RegionId,
    kind: HirRegionKind,
    protected_blocks: []const ids.BlockId,
    handler: ids.BlockId,
    continuation: ?ids.BlockId,
    origin: ids.OriginId,
};
pub const HirRegionKind = enum { catch_, finally, iterator_close };

pub const HirConstant = union(enum) {
    undefined,
    null_,
    boolean: bool,
    number: f64,
    bigint: []const u8,
    string: []const u8,
};

pub const HirTerminator = union(enum) {
    jump: Jump,
    branch: Branch,
    return_: ?ids.ValueId,
    throw: ids.ValueId,
    unreachable_,
    leave_region: LeaveRegion,
    resume_completion,

    pub const Jump = struct {
        target: ids.BlockId,
        arguments: []const ids.ValueId = &.{},
    };
    pub const Branch = struct {
        condition: ids.ValueId,
        true_target: ids.BlockId,
        false_target: ids.BlockId,
    };
    pub const LeaveRegion = struct {
        region: ids.RegionId,
        completion: Completion,
        cleanup: ids.BlockId,
    };
};

pub const Completion = union(enum) {
    normal: ?ids.BlockId,
    return_: ?ids.ValueId,
    throw: ids.ValueId,
    break_: ids.BlockId,
    continue_: ids.BlockId,
};

pub const AddMode = enum { numeric, string_concat, dynamic };
pub const NumericMode = enum { number, bigint, dynamic };
pub const UnaryOperator = enum {
    plus,
    negate,
    logical_not,
    bit_not,
};
pub const BinaryOperator = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    exponentiate,
    bit_and,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    shift_right_unsigned,
    less,
    less_equal,
    greater,
    greater_equal,
    equal_loose,
    equal_strict,
    not_equal_loose,
    not_equal_strict,
    in,
    instanceof,
};
pub const MetaKind = enum { import_meta, new_target };

pub const CallArgument = union(enum) {
    value: ids.ValueId,
    spread: ids.ValueId,

    pub fn operand(self: CallArgument) ids.ValueId {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

pub const Call = struct {
    callee: ids.ValueId,
    arguments: []const CallArgument = &.{},
};
pub const MethodCall = struct {
    callee: ?ids.ValueId = null,
    receiver: ids.ValueId,
    key: PropertyKey,
    arguments: []const CallArgument = &.{},
};
pub const DynamicImportAttribute = struct {
    key: []const u8,
    value: []const u8,
};
pub const DynamicImport = struct {
    source: ids.ValueId,
    options: ?ids.ValueId = null,
    attributes: []const DynamicImportAttribute = &.{},
};
pub const TaggedTemplateCall = struct {
    tag: ids.ValueId,
    receiver: ?ids.ValueId = null,
    template_site: ids.ValueId,
    substitutions: []const ids.ValueId = &.{},
};
pub const ClassCreation = struct {
    entity: ids.EntityId,
    base: ?ids.ValueId = null,
};
pub const PropertyDefinition = struct {
    object: ids.ValueId,
    key: PropertyKey,
    value: ids.ValueId,
};
pub const MethodDefinition = struct {
    object: ids.ValueId,
    key: PropertyKey,
    function: ids.FunctionId,
    kind: HirFunctionKind,
    is_static: bool,
};
pub const TemplatePart = union(enum) {
    text: []const u8,
    value: ids.ValueId,
};

pub const HirOperation = union(enum) {
    constant: HirConstant,
    copy: ids.ValueId,
    load_binding: ids.BindingId,
    initialize_binding: struct { binding: ids.BindingId, value: ids.ValueId },
    store_binding: struct { binding: ids.BindingId, value: ids.ValueId },
    load_this,
    load_super,
    load_meta: MetaKind,

    make_binding_place: struct { result: ids.PlaceId, binding: ids.BindingId },
    make_property_place: struct { result: ids.PlaceId, base: ids.ValueId, key: PropertyKey },
    make_element_place: struct { result: ids.PlaceId, base: ids.ValueId, key: ids.ValueId },
    make_super_place: struct { result: ids.PlaceId, receiver: ids.ValueId, key: PropertyKey },
    load_place: ids.PlaceId,
    store_place: struct { place: ids.PlaceId, value: ids.ValueId },
    delete_place: ids.PlaceId,

    to_boolean: ids.ValueId,
    is_nullish: ids.ValueId,
    typeof_value: ids.ValueId,
    void_value: ids.ValueId,
    unary: struct { operator: UnaryOperator, operand: ids.ValueId, mode: NumericMode },
    binary: struct { operator: BinaryOperator, left: ids.ValueId, right: ids.ValueId, mode: NumericMode },
    add: struct { left: ids.ValueId, right: ids.ValueId, mode: AddMode },

    call: Call,
    call_method: MethodCall,
    call_super_method: MethodCall,
    call_super_constructor: []const CallArgument,
    construct: Call,
    tagged_template_call: TaggedTemplateCall,
    dynamic_import: DynamicImport,

    create_object,
    create_array,
    create_closure: ids.FunctionId,
    create_class: ClassCreation,
    create_enum_object: ids.EntityId,
    create_regexp: struct { pattern: []const u8, flags: []const u8, source_site: ids.SourceSiteId },
    create_template_site: struct { source_site: ids.SourceSiteId, cooked: []const ?[]const u8, raw: []const []const u8 },

    define_property: PropertyDefinition,
    define_method: MethodDefinition,
    copy_object_properties: struct { target: ids.ValueId, source: ids.ValueId },
    array_append: struct { array: ids.ValueId, value: ids.ValueId },
    array_append_hole: ids.ValueId,
    array_append_iterable: struct { array: ids.ValueId, iterable: ids.ValueId },

    build_string: []const TemplatePart,
    to_string: ids.ValueId,

    get_iterator: ids.ValueId,
    get_async_iterator: ids.ValueId,
    iterator_next: ids.ValueId,
    iterator_done: ids.ValueId,
    iterator_value: ids.ValueId,
    iterator_close: ids.ValueId,
    enumerate_properties: ids.ValueId,
    enumerator_next: ids.ValueId,
    enumerator_done: ids.ValueId,
    enumerator_value: ids.ValueId,

    collect_rest_arguments: u32,
    read_argument: u32,
    create_arguments_object,

    await_: ids.ValueId,
    yield_: ids.ValueId,
    yield_delegate: ids.ValueId,
    debugger_trap,

    pub fn checked(self: HirOperation) OperationError!HirOperation {
        switch (self) {
            .call, .construct => |payload| try checkArity(payload.arguments.len),
            .call_method, .call_super_method => |payload| try checkArity(payload.arguments.len),
            .call_super_constructor => |arguments| try checkArity(arguments.len),
            .tagged_template_call => |payload| try checkArity(payload.substitutions.len),
            .create_template_site => |payload| {
                if (payload.cooked.len != payload.raw.len) return error.TemplateArityMismatch;
                try checkArity(payload.cooked.len);
            },
            .build_string => |parts| {
                if (parts.len == 0) return error.EmptyStringBuild;
                try checkArity(parts.len);
            },
            else => {},
        }
        return self;
    }

    pub fn producesValue(self: HirOperation) bool {
        return switch (self) {
            .initialize_binding,
            .store_binding,
            .make_binding_place,
            .make_property_place,
            .make_element_place,
            .make_super_place,
            .store_place,
            .define_property,
            .define_method,
            .copy_object_properties,
            .array_append,
            .array_append_hole,
            .array_append_iterable,
            .iterator_close,
            .debugger_trap,
            => false,
            else => true,
        };
    }

    pub fn effectSet(self: HirOperation) EffectSet {
        return switch (self) {
            .constant, .copy, .to_boolean, .is_nullish, .void_value => EffectSet.pure_effect,
            .load_this, .load_super, .load_meta, .read_argument => EffectSet.read_effect,
            .load_binding => EffectSet.read_throw_effect,
            .initialize_binding, .store_binding => EffectSet.write_throw_effect,
            .make_binding_place, .make_property_place, .make_element_place, .make_super_place => EffectSet.pure_effect,
            .load_place, .typeof_value => EffectSet.user_read_effect,
            .store_place, .delete_place => EffectSet.user_write_effect,
            .unary, .binary, .add, .to_string, .build_string => EffectSet.user_effect,
            .call,
            .call_method,
            .call_super_method,
            .call_super_constructor,
            .construct,
            .tagged_template_call,
            .dynamic_import,
            => EffectSet.call_effect,
            .create_object,
            .create_array,
            .create_closure,
            .create_class,
            .create_enum_object,
            .create_regexp,
            .create_template_site,
            .create_arguments_object,
            => EffectSet.identity_effect,
            .define_property,
            .define_method,
            .copy_object_properties,
            .array_append,
            .array_append_hole,
            .array_append_iterable,
            => EffectSet.user_write_effect,
            .get_iterator,
            .iterator_next,
            .iterator_done,
            .iterator_value,
            .iterator_close,
            .enumerate_properties,
            .enumerator_next,
            .enumerator_done,
            .enumerator_value,
            => EffectSet.user_effect,
            .get_async_iterator, .await_, .yield_, .yield_delegate => EffectSet.suspend_effect,
            .collect_rest_arguments => EffectSet.read_effect,
            .debugger_trap => EffectSet.debug_effect,
        };
    }
};

pub const OperationError = error{
    ArityOverflow,
    EmptyStringBuild,
    TemplateArityMismatch,
    ResultPresenceMismatch,
    ResultTypeMismatch,
};

fn checkArity(length: usize) error{ArityOverflow}!void {
    if (length > std.math.maxInt(u32)) return error.ArityOverflow;
}

pub const EffectSet = packed struct {
    pure: bool = false,
    may_throw: bool = false,
    may_call_user_code: bool = false,
    reads_state: bool = false,
    writes_state: bool = false,
    may_suspend: bool = false,
    creates_identity: bool = false,

    pub const pure_effect: EffectSet = .{ .pure = true };
    pub const read_effect: EffectSet = .{ .reads_state = true };
    pub const read_throw_effect: EffectSet = .{ .may_throw = true, .reads_state = true };
    pub const write_throw_effect: EffectSet = .{ .may_throw = true, .writes_state = true };
    pub const user_effect: EffectSet = .{ .may_throw = true, .may_call_user_code = true, .reads_state = true };
    pub const user_read_effect: EffectSet = .{ .may_throw = true, .may_call_user_code = true, .reads_state = true };
    pub const user_write_effect: EffectSet = .{ .may_throw = true, .may_call_user_code = true, .reads_state = true, .writes_state = true };
    pub const call_effect: EffectSet = .{ .may_throw = true, .may_call_user_code = true, .reads_state = true, .writes_state = true };
    pub const identity_effect: EffectSet = .{ .may_throw = true, .writes_state = true, .creates_identity = true };
    pub const suspend_effect: EffectSet = .{ .may_throw = true, .may_call_user_code = true, .reads_state = true, .writes_state = true, .may_suspend = true };
    pub const debug_effect: EffectSet = .{ .may_call_user_code = true, .reads_state = true, .writes_state = true };
};
