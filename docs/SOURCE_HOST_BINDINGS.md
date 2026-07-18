# Source host bindings

ViZG can attach stable host identities to top-level value declarations whose
types remain defined by TypeScript source. This is intended for standard
environment prelude files that need normal TypeScript checking while a
downstream compiler still needs to recognize selected values.

Register mappings before adding or supplying any project source:

```zig
try project.registerSourceHostBindings(&.{
    .{ .name = "globalThis", .host_binding_id = 0 },
    .{ .name = "console", .host_binding_id = 1 },
});
```

The equivalent C API is
`vizg_project_register_source_host_bindings`. Its descriptor names are borrowed
for the duration of the call and copied into project-owned storage. Names must
be non-empty, and both names and host IDs must be unique within a project.
Registration after the first source is rejected.

Registration does not declare a global or supply its type. A matching
top-level value must exist in source, such as:

```ts
interface Console {
    log(value: number): void;
}

const console: Console;
```

HIR lowers the matching declaration as an immutable live host binding and
preserves its `host_binding_id`. A static property access on another host-bound
source value is normalized to the matching host binding only when the property
name and exact semantic `TypeId` agree. This preserves the same binding and
type identity without introducing a dynamic property operation.
