# ViZG — Future Feature Configuration Specification

## Status

```txt
Status: Deferred design specification
Implementation target: After HIR v1
Current effect on ViZG: None
Current ABI impact: None
HIR v1 dependency: None
```

This document defines a future configuration layer for ViZG.

It does **not** require changes before HIR v1.

The purpose is to preserve the design decision now, so the configuration system can be implemented later without mixing it with HIR development.

---

# 1. Objective

ViZG should eventually accept a normalized configuration through its API.

The configuration may be created by:

- a bundler;
- a runtime;
- a compiler driver;
- an editor;
- a CLI;
- a build system;
- a compatibility layer;
- direct programmatic code.

ViZG must not decide how that configuration is stored or discovered.

ViZG will not require:

```txt
tsconfig.json
package.json
filesystem discovery
environment variables
project configuration files
```

A consumer may read a `tsconfig.json` or another format, but that translation happens outside ViZG.

The final flow is:

```txt
consumer configuration
        ↓
normalized ViZG options
        ↓
scanner / parser / semantic analysis
        ↓
HIR eligibility
        ↓
HIR lowering
```

---

# 2. Implementation timing

This configuration system is intentionally deferred until **after HIR v1**.

The recommended sequence is:

```txt
frontend and typed semantics
→ HIR v1
→ feature configuration infrastructure
→ optional feature experimentation
→ feature promotion when complete
```

HIR v1 should be designed around stable semantic input, not around feature flags.

The feature flags are evaluated before HIR lowering.

Therefore, the HIR does not need to understand:

```txt
whether JSX was enabled
whether decorators were experimental
whether a bundler inherited strict mode
where the configuration came from
whether a tsconfig existed
```

HIR only receives a semantic result that is eligible for lowering.

---

# 3. Core principle

Feature configuration belongs to the frontend pipeline.

```txt
ProjectOptions
    ↓
scanner
    ↓
parser
    ↓
binder / resolver
    ↓
semantic analysis
    ↓
HIR eligibility
    ↓
HIR
```

The configuration must not be interpreted inside HIR.

HIR should consume:

- normalized symbols;
- resolved types;
- control-flow information;
- module identities;
- semantic diagnostics;
- explicit lowering eligibility.

HIR should not consume raw feature flags unless a future feature requires a semantic distinction that survives lowering.

That case must be justified independently.

---

# 4. Default behavior

All experimental or deferred feature flags are disabled by default.

Example:

```zig
pub const ProjectOptions = struct {
    syntax: SyntaxOptions = .{},
    checking: CheckingOptions = .{},
};

pub const SyntaxOptions = struct {
    decorators: FeatureMode = .disabled,
    private_fields: FeatureMode = .disabled,
    jsx: FeatureMode = .disabled,
    namespaces: FeatureMode = .disabled,
    mapped_types: FeatureMode = .disabled,
    conditional_types: FeatureMode = .disabled,
    pipeline_operator: FeatureMode = .disabled,
    with_statement: FeatureMode = .disabled,
};
```

Calling ViZG without explicit options must preserve the current behavior:

```zig
const result = try vizg.analyzeSource(
    allocator,
    source,
    .{},
);
```

The default configuration must not silently enable experimental syntax.

---

# 5. Feature modes

A feature should not be represented only as a boolean.

Use an explicit mode:

```zig
pub const FeatureMode = enum(u8) {
    disabled,
    parse_only,
    enabled,
};
```

## 5.1 `disabled`

The feature is not part of the accepted language subset.

ViZG must:

1. recognize the syntax boundary;
2. emit a targeted diagnostic;
3. consume the correct token range;
4. recover parsing;
5. continue analyzing later code;
6. mark the module as not eligible for HIR.

Example:

```ts
@sealed
class Example {}

const after = 1;
```

Expected behavior:

```txt
decorator diagnostic emitted
class recovery completed
`after` remains present in the AST
module blocked from HIR
```

## 5.2 `parse_only`

The parser supports a real AST representation, but semantic analysis or HIR lowering is incomplete.

ViZG may use this mode for:

- tooling;
- AST inspection;
- editor integrations;
- compatibility transformations;
- experimental syntax;
- source rewriting.

A `parse_only` feature must block HIR unless a dedicated pre-HIR transformation removes or lowers it.

## 5.3 `enabled`

The feature is fully supported through every required stage:

```txt
scanner
parser
AST
binder
resolver
CFG when applicable
type system
checker
HIR lowering
tests
documentation
```

A feature must not be marked `enabled` merely because the parser accepts it.

---

# 6. Current unsupported feature set

The existing unsupported syntax corpus represents the default disabled configuration.

Current examples include:

```txt
decorators
private fields
TypeScript namespaces
mapped types
conditional types
JSX / TSX
pipeline operator
with statement
```

These features may remain unsupported after HIR v1.

Their presence in:

```txt
test/syntax/unsupported
```

does not mean HIR is incomplete.

It means the frontend has an explicit negative contract.

The expected pipeline is:

```txt
unsupported source
→ targeted diagnostic
→ recoverable partial AST
→ semantic result marked blocked
→ no HIR
```

---

# 7. Feature capability registry

The requested mode and the implemented capability are different concepts.

A consumer may request `.enabled`, but ViZG must reject that request if the feature is only implemented as `.disabled` or `.parse_only`.

Example:

```zig
pub const FeatureCapability = struct {
    maximum_mode: FeatureMode,
};

pub fn featureCapability(
    feature: LanguageFeature,
) FeatureCapability {
    return switch (feature) {
        .decorators => .{ .maximum_mode = .disabled },
        .private_fields => .{ .maximum_mode = .disabled },
        .jsx => .{ .maximum_mode = .disabled },
        .namespaces => .{ .maximum_mode = .disabled },
        .mapped_types => .{ .maximum_mode = .disabled },
        .conditional_types => .{ .maximum_mode = .disabled },
        .pipeline_operator => .{ .maximum_mode = .disabled },
        .with_statement => .{ .maximum_mode = .disabled },
    };
}
```

Validation:

```zig
pub fn validateFeatureMode(
    requested: FeatureMode,
    capability: FeatureCapability,
) !void {
    if (@intFromEnum(requested) > @intFromEnum(capability.maximum_mode)) {
        return error.UnsupportedFeatureMode;
    }
}
```

ViZG must never pretend that an unsupported mode works.

---

# 8. Central feature registry

Feature handling should be centralized.

```zig
pub const LanguageFeature = enum(u16) {
    decorators,
    private_fields,
    jsx,
    namespaces,
    mapped_types,
    conditional_types,
    pipeline_operator,
    with_statement,
};
```

A single lookup should determine the effective mode:

```zig
pub fn featureMode(
    options: *const ProjectOptions,
    feature: LanguageFeature,
) FeatureMode {
    return switch (feature) {
        .decorators => options.syntax.decorators,
        .private_fields => options.syntax.private_fields,
        .jsx => options.syntax.jsx,
        .namespaces => options.syntax.namespaces,
        .mapped_types => options.syntax.mapped_types,
        .conditional_types => options.syntax.conditional_types,
        .pipeline_operator => options.syntax.pipeline_operator,
        .with_statement => options.syntax.with_statement,
    };
}
```

The parser should not duplicate unrelated option logic throughout the codebase.

Preferred:

```zig
switch (self.featureMode(.decorators)) {
    .disabled => return self.recoverUnsupportedDecorator(),
    .parse_only => return self.parseDecorator(),
    .enabled => return self.parseDecorator(),
}
```

Avoid:

```zig
if (self.options.syntax.decorators == .disabled) {
    // duplicated feature-specific policy
}
```

---

# 9. Strict mode

Strict mode belongs to semantic checking options, not syntax feature options.

Suggested model:

```zig
pub const CheckingOptions = struct {
    strict: bool = true,

    strict_null_checks: ?bool = null,
    no_implicit_any: ?bool = null,
    no_implicit_returns: ?bool = null,
    no_fallthrough_cases: ?bool = null,
    no_unchecked_indexed_access: ?bool = null,
    exact_optional_property_types: ?bool = null,
    use_unknown_in_catch_variables: ?bool = null,
};
```

The optional booleans inherit from `strict`.

Example:

```zig
pub fn strictNullChecks(self: CheckingOptions) bool {
    return self.strict_null_checks orelse self.strict;
}
```

This allows:

```zig
const options: CheckingOptions = .{
    .strict = true,
    .no_implicit_returns = false,
};
```

Meaning:

```txt
strict defaults enabled
noImplicitReturns explicitly disabled
other strict-related flags inherit true
```

---

# 10. Configuration inheritance

ViZG receives normalized effective options.

It does not implement configuration inheritance itself.

A consumer may inherit options from:

- a bundler;
- a runtime;
- workspace defaults;
- a project preset;
- a compatibility profile;
- a translated tsconfig;
- command-line flags;
- environment-specific policy.

Example external flow:

```txt
bundler defaults
      ↓
project configuration
      ↓
entry-point overrides
      ↓
normalized EffectiveProjectOptions
      ↓
ViZG
```

The bundler or runtime decides precedence.

ViZG receives only the final effective structure.

Example:

```zig
const effective_options = bundler.resolveVizgOptions(.{
    .workspace_defaults = workspace_options,
    .project_options = project_options,
    .entry_overrides = entry_options,
});

const result = try vizg.analyzeProject(
    allocator,
    sources,
    effective_options,
);
```

ViZG does not need to know which layer supplied each value.

---

# 11. Optional provenance

Configuration provenance is not required for semantic operation.

However, a consumer may retain it externally for diagnostics or debugging.

Example external structure:

```zig
pub const OptionOrigin = enum {
    default,
    bundler,
    project,
    entry_point,
    command_line,
};

pub const ResolvedOption = struct {
    value: bool,
    origin: OptionOrigin,
};
```

This metadata should remain outside the core ViZG configuration unless a concrete requirement appears.

ViZG should prioritize a compact normalized options structure.

---

# 12. HIR eligibility

HIR eligibility must be explicit.

Suggested contract:

```zig
pub const LoweringEligibility = union(enum) {
    eligible,

    blocked: struct {
        reason: BlockingReason,
        feature: ?LanguageFeature,
        diagnostic_index: ?u32,
    },
};

pub const BlockingReason = enum {
    syntax_errors,
    unsupported_feature,
    parse_only_feature,
    incomplete_semantics,
    unresolved_module,
    semantic_errors,
};
```

Example:

```zig
pub fn hirEligibility(
    result: *const SemanticResult,
) LoweringEligibility {
    if (result.firstUnsupportedFeature()) |feature| {
        return .{
            .blocked = .{
                .reason = .unsupported_feature,
                .feature = feature.kind,
                .diagnostic_index = feature.diagnostic_index,
            },
        };
    }

    if (result.hasSyntaxErrors()) {
        return .{
            .blocked = .{
                .reason = .syntax_errors,
                .feature = null,
                .diagnostic_index = null,
            },
        };
    }

    if (!result.type_info_complete) {
        return .{
            .blocked = .{
                .reason = .incomplete_semantics,
                .feature = null,
                .diagnostic_index = null,
            },
        };
    }

    return .eligible;
}
```

HIR lowering:

```zig
pub fn lowerModule(
    allocator: std.mem.Allocator,
    result: *const SemanticResult,
) !HirModule {
    switch (result.hirEligibility()) {
        .eligible => {},
        .blocked => return error.ModuleNotEligibleForHir,
    }

    return lowerEligibleModule(allocator, result);
}
```

---

# 13. Why HIR v1 is not affected

HIR v1 is not expected to branch on feature configuration.

Feature options are consumed earlier.

Example:

```txt
decorators disabled
→ parser diagnostic
→ module blocked
→ HIR never sees decorator syntax
```

```txt
decorators parse_only
→ real AST node
→ semantic capability block
→ HIR never receives the module
```

```txt
decorators enabled in the future
→ parser + semantics normalize behavior
→ HIR receives a supported semantic representation
```

HIR should receive supported semantics, not experimental syntax policy.

If a future feature requires a new HIR concept, that should be introduced as a new HIR version or an additive HIR extension.

---

# 14. Features that may not require new HIR nodes

Some future syntax can be desugared before or during HIR lowering.

Examples:

```ts
value |> transform
```

may lower to:

```ts
transform(value)
```

Decorators may lower to ordinary calls or metadata operations.

Some namespace or type-only constructs may disappear entirely before HIR.

Therefore, enabling a syntax feature does not automatically imply adding a dedicated HIR instruction.

The lowering design should choose the smallest stable semantic representation.

---

# 15. Features that remain outside ViZG

The following options belong to the runtime, bundler or host:

```txt
moduleResolution
baseUrl
paths
rootDirs
package lookup
node_modules lookup
package.json exports/imports
URL resolution
filesystem extension probing
index file lookup
network fetch
virtual module policy
project file discovery
tsconfig extends resolution
```

ViZG only emits module requests and consumes host-supplied module identities and source/external metadata.

---

# 16. Possible API structure

Future Zig API:

```zig
pub const ProjectOptions = struct {
    syntax: SyntaxOptions = .{},
    checking: CheckingOptions = .{},
    modules: ModuleSemanticOptions = .{},
    limits: ResourceLimits = .{},
};
```

Module semantic options may include:

```zig
pub const ModuleSemanticOptions = struct {
    isolated_modules: bool = false,
    verbatim_module_syntax: bool = false,
    preserve_type_only_imports: bool = true,
};
```

They must not contain resolver policy.

---

# 17. C ABI considerations

This work is deferred until after HIR v1.

When implemented, the ABI structure should be extensible.

Suggested design:

```c
typedef enum Vizg_FeatureMode {
    VIZG_FEATURE_DISABLED = 0,
    VIZG_FEATURE_PARSE_ONLY = 1,
    VIZG_FEATURE_ENABLED = 2
} Vizg_FeatureMode;

typedef struct Vizg_SyntaxOptions {
    size_t struct_size;

    uint8_t decorators;
    uint8_t private_fields;
    uint8_t jsx;
    uint8_t namespaces;
    uint8_t mapped_types;
    uint8_t conditional_types;
    uint8_t pipeline_operator;
    uint8_t with_statement;

    uint8_t reserved[16];
} Vizg_SyntaxOptions;
```

The project configuration should include:

```c
typedef struct Vizg_ProjectConfig {
    size_t struct_size;

    void *workspace_ptr;
    size_t workspace_len;

    Vizg_SyntaxOptions syntax;
    Vizg_CheckingOptions checking;
    Vizg_ProjectLimits limits;

    uint8_t reserved[32];
} Vizg_ProjectConfig;
```

The exact layout must be designed against the ABI version active at implementation time.

This document does not authorize changing the frozen ABI v1 now.

---

# 18. Default initialization API

Consumers should not manually initialize every field.

Future C API:

```c
void vizg_project_config_init(Vizg_ProjectConfig *config);
```

Example:

```c
Vizg_ProjectConfig config;
vizg_project_config_init(&config);

config.syntax.jsx = VIZG_FEATURE_PARSE_ONLY;
config.checking.strict = 1;
```

Zig defaults:

```zig
pub fn defaultProjectOptions() ProjectOptions {
    return .{};
}
```

---

# 19. Testing strategy

## Disabled features

```zig
test "disabled decorator reports targeted diagnostic" {
    const result = try analyzeWithOptions(
        "@sealed class Example {}",
        .{},
    );

    try expectDiagnostic(result, .unsupported_decorator);
}
```

## Recovery

```zig
test "disabled feature preserves following statements" {
    const result = try analyzeWithOptions(
        \\@sealed class Example {}
        \\const after = 1;
    ,
        .{},
    );

    try expectTopLevelVariable(result.ast, "after");
}
```

## HIR blocking

```zig
test "disabled feature blocks HIR lowering" {
    const result = try analyzeWithOptions(
        "@sealed class Example {}",
        .{},
    );

    try std.testing.expectError(
        error.ModuleNotEligibleForHir,
        hir.lowerModule(std.testing.allocator, &result),
    );
}
```

## Unsupported mode request

```zig
test "requesting unsupported feature mode is rejected" {
    const options: ProjectOptions = .{
        .syntax = .{
            .jsx = .enabled,
        },
    };

    try std.testing.expectError(
        error.UnsupportedFeatureMode,
        validateOptions(options),
    );
}
```

## Strict inheritance

```zig
test "strict child option inherits strict default" {
    const options: CheckingOptions = .{
        .strict = true,
    };

    try std.testing.expect(options.strictNullChecks());
}

test "strict child option can override strict" {
    const options: CheckingOptions = .{
        .strict = true,
        .strict_null_checks = false,
    };

    try std.testing.expect(!options.strictNullChecks());
}
```

---

# 20. Migration of unsupported syntax tests

Existing fixtures should remain valid.

Future organization may become:

```txt
test/syntax/unsupported/
test/syntax/parse_only/
test/syntax/supported/
```

A feature can move through these states:

```txt
unsupported default
→ parse-only experiment
→ enabled experiment
→ officially supported
```

Even after a feature becomes supported, retain a test proving that a consumer can explicitly disable it when that behavior is part of the contract.

---

# 21. What exists today

At the time of this specification:

```txt
unsupported syntax diagnostics exist
unsupported syntax recovery exists
feature options do not exist
FeatureMode does not exist
strict inheritance configuration does not exist
ViZG does not read tsconfig
ViZG does not implement module resolution
HIR v1 does not exist yet
```

No current behavior should be described as configurable until the infrastructure is implemented.

---

# 22. What this specification does not require

This document does not require:

- changing the current parser before HIR v1;
- implementing JSX;
- implementing decorators;
- implementing private fields;
- implementing namespaces;
- implementing mapped types;
- implementing conditional types;
- enabling the pipeline operator;
- supporting `with`;
- reading `tsconfig.json`;
- cloning TypeScript compiler options;
- changing HIR v1;
- changing the current ABI immediately.

---

# 23. Future implementation milestone

After HIR v1, create a dedicated milestone:

```txt
Future ProjectOptions and Experimental Features
```

Recommended phases:

```txt
1. Define ProjectOptions and FeatureMode.
2. Propagate options through frontend and semantics.
3. Add capability registry and option validation.
4. Add HIR eligibility contract.
5. Add strict-mode inheritance.
6. Add API and ABI configuration structures.
7. Migrate unsupported tests to option-aware tests.
8. Enable individual experimental features one at a time.
```

Each feature must have its own separate goal.

Do not implement multiple experimental language features in one goal.

---

# 24. Final contract

The intended final contract is:

```txt
ViZG is a configurable language tool.
ViZG does not own configuration files.
ViZG does not own module resolution.
Consumers provide normalized options.
Experimental features are disabled by default.
Unsupported syntax remains recoverable.
Unsupported or parse-only modules do not reach HIR.
Strict options may inherit from a parent strict flag.
Bundlers and runtimes may calculate and inherit effective options externally.
HIR consumes validated semantic results, not raw configuration policy.
```

This specification is intentionally deferred until after HIR v1.