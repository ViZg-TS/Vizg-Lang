//! Deterministic debug and snapshot rendering for HIR v1.
//! This text is intentionally not a serialization or public ABI.

const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");

pub const Mode = enum {
    canonical,
    brief,
    with_types,
    with_origins,
    with_full_trace,
};

pub const Options = struct {
    brief: bool = false,
    types: bool = false,
    origins: bool = false,
    full_trace: bool = false,

    pub fn fromMode(mode: Mode) Options {
        return switch (mode) {
            .canonical => .{},
            .brief => .{ .brief = true },
            .with_types => .{ .types = true },
            .with_origins => .{ .origins = true },
            .with_full_trace => .{ .origins = true, .full_trace = true },
        };
    }
};

pub fn printAlloc(
    allocator: std.mem.Allocator,
    project: *const model.HirProject,
    domain: *const ids.IdentityDomain,
    mode: Mode,
) ![]u8 {
    return printAllocOptions(allocator, project, domain, Options.fromMode(mode));
}

pub fn printAllocOptions(
    allocator: std.mem.Allocator,
    project: *const model.HirProject,
    domain: *const ids.IdentityDomain,
    options: Options,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try write(&output.writer, project, domain, options);
    var bytes = output.toArrayList();
    return bytes.toOwnedSlice(allocator);
}

pub fn write(
    writer: *std.Io.Writer,
    project: *const model.HirProject,
    domain: *const ids.IdentityDomain,
    options: Options,
) !void {
    try writer.print("hir-v{} modules={} entities={} functions={} constants={} regions={}\n", .{
        project.version,
        project.modules.len,
        project.entities.len,
        project.functions.len,
        project.constants.len,
        project.regions.len,
    });
    if (options.brief) return;

    for (project.modules) |module| {
        try writer.print("module {} name=", .{@intFromEnum(module.module_id)});
        try writeQuoted(writer, module.logical_name);
        try writer.writeAll(" init=");
        try writeId(writer, module.initialization, domain);
        if (options.origins) {
            try writer.writeAll(" origin=");
            try writeId(writer, module.origin, domain);
        }
        try writer.print(" deps={} imports={} exports={} entities={}\n", .{
            module.dependencies.len, module.imports.len, module.exports.len, module.entities.len,
        });
        for (module.dependencies) |dependency| {
            try writer.writeAll("  dependency ");
            try writeValue(writer, dependency, domain);
            try writer.writeByte('\n');
        }
        for (module.imports) |import_binding| {
            try writer.writeAll("  import ");
            try writeValue(writer, import_binding, domain);
            try writer.writeByte('\n');
        }
        for (module.exports) |export_binding| {
            try writer.writeAll("  export ");
            try writeValue(writer, export_binding, domain);
            try writer.writeByte('\n');
        }
        for (module.entities) |entity_id| {
            try writer.writeAll("  module-entity ");
            try writeId(writer, entity_id, domain);
            try writer.writeByte('\n');
        }
    }

    for (project.entities) |entity| {
        try writer.writeAll("entity ");
        try writeId(writer, entity.id, domain);
        try writer.print(" module={} kind={s}", .{ @intFromEnum(entity.module_id), @tagName(entity.kind) });
        try writer.writeAll(" payload=");
        try writeValue(writer, entity.kind, domain);
        if (options.origins) {
            try writer.writeAll(" origin=");
            try writeId(writer, entity.origin, domain);
        }
        try writer.writeByte('\n');
    }

    for (project.functions) |function| {
        try writer.writeAll("function ");
        try writeId(writer, function.id, domain);
        try writer.print(" module={} kind={s} flags=", .{ @intFromEnum(function.module_id), @tagName(function.kind) });
        try writeValue(writer, function.flags, domain);
        if (options.types) try writer.print(" type={}", .{function.signature_type});
        if (options.origins) {
            try writer.writeAll(" origin=");
            try writeId(writer, function.origin, domain);
        }
        try writer.writeAll(" entry=");
        try writeId(writer, function.entry, domain);
        try writer.print(" params={} bindings={} captures={} places={} blocks={} regions={}\n", .{
            function.parameters.len,
            function.bindings.len,
            function.captures.len,
            function.places.len,
            function.blocks.len,
            function.regions.len,
        });

        for (function.parameters) |parameter| {
            try writer.writeAll("  parameter binding=");
            try writeId(writer, parameter.binding, domain);
            try writer.print(" argument={} optional={} default={} rest={} property={}", .{
                parameter.argument_index,
                parameter.optional,
                parameter.has_default,
                parameter.rest,
                parameter.parameter_property,
            });
            if (options.types) try writer.print(" type={}", .{parameter.type_id});
            if (options.origins) {
                try writer.writeAll(" origin=");
                try writeId(writer, parameter.origin, domain);
            }
            try writer.writeByte('\n');
        }

        for (function.bindings) |binding| {
            try writer.writeAll("  binding ");
            try writeId(writer, binding.id, domain);
            try writer.writeAll(" name=");
            try writeQuoted(writer, binding.name);
            try writer.print(" kind={s} mutable={} initial={s}", .{ @tagName(binding.kind), binding.mutable, @tagName(binding.initial_state) });
            if (options.types) try writer.print(" type={}", .{binding.type_id});
            if (options.origins) {
                try writer.writeAll(" origin=");
                try writeId(writer, binding.origin, domain);
            }
            try writer.writeByte('\n');
        }
        for (function.captures) |capture| {
            try writer.writeAll("  capture ");
            try writeValue(writer, capture, domain);
            try writer.writeByte('\n');
        }
        for (function.places) |place| {
            try writer.writeAll("  place ");
            try writeId(writer, place.id, domain);
            try writer.writeAll(" = ");
            try writeValue(writer, place.kind, domain);
            if (options.origins) {
                try writer.writeAll(" origin=");
                try writeId(writer, place.origin, domain);
            }
            try writer.writeByte('\n');
        }
        for (function.blocks) |block| {
            try writer.writeAll("  block ");
            try writeId(writer, block.id, domain);
            if (options.origins) {
                try writer.writeAll(" origin=");
                try writeId(writer, block.origin, domain);
            }
            try writer.writeByte('\n');
            for (block.parameters) |parameter| {
                try writer.writeAll("    parameter ");
                try writeId(writer, parameter.value, domain);
                if (options.types) try writer.print(" type={}", .{parameter.type_id});
                if (options.origins) {
                    try writer.writeAll(" origin=");
                    try writeId(writer, parameter.origin, domain);
                }
                try writer.writeByte('\n');
            }
            for (block.instructions) |instruction| {
                try writer.writeAll("    instruction ");
                try writeId(writer, instruction.id, domain);
                if (instruction.result) |result| {
                    try writer.writeAll(" result=");
                    try writeId(writer, result, domain);
                }
                if (options.types) if (instruction.result_type) |type_id| try writer.print(" type={}", .{type_id});
                try writer.writeAll(" effects=");
                try writeValue(writer, instruction.effects, domain);
                try writer.writeAll(" op=");
                try writeValue(writer, instruction.operation, domain);
                if (options.origins) {
                    try writer.writeAll(" origin=");
                    try writeId(writer, instruction.origin, domain);
                }
                try writer.writeByte('\n');
            }
            try writer.writeAll("    terminator ");
            try writeValue(writer, block.terminator, domain);
            try writer.writeByte('\n');
        }
        for (function.regions) |region_id| {
            try writer.writeAll("  function-region ");
            try writeId(writer, region_id, domain);
            try writer.writeByte('\n');
        }
    }

    for (project.constants, 0..) |constant, index| {
        try writer.print("constant {} = ", .{index});
        try writeValue(writer, constant, domain);
        try writer.writeByte('\n');
    }
    for (project.regions) |region| {
        try writer.writeAll("region ");
        try writeId(writer, region.id, domain);
        try writer.writeAll(" function=");
        try writeId(writer, region.function, domain);
        try writer.writeAll(" parent=");
        if (region.parent) |parent| try writeId(writer, parent, domain) else try writer.writeAll("null");
        try writer.print(" kind={s} protected=", .{@tagName(region.kind)});
        try writeValue(writer, region.protected_blocks, domain);
        try writer.writeAll(" handler=");
        try writeId(writer, region.handler, domain);
        try writer.writeAll(" continuation=");
        if (region.continuation) |continuation| try writeId(writer, continuation, domain) else try writer.writeAll("null");
        if (options.origins) {
            try writer.writeAll(" origin=");
            try writeId(writer, region.origin, domain);
        }
        try writer.writeByte('\n');
    }

    if (options.origins) for (project.origins.records, 0..) |record, index| {
        try writer.print("origin {} module={} span={}..{} syntax={s} rule={s} ast=", .{
            index,
            @intFromEnum(record.module_id),
            record.primary_span.start,
            record.primary_span.end,
            @tagName(record.original_syntax),
            @tagName(record.lowering_rule),
        });
        try writeValue(writer, record.ast_nodes, domain);
        if (options.types) if (record.type_id) |type_id| try writer.print(" type={}", .{type_id});
        try writer.writeByte('\n');
    };

    if (options.full_trace) {
        if (project.lowering_trace) |lowering_trace| {
            for (lowering_trace.events) |event| {
                try writer.print("trace {s} inputs=", .{@tagName(event.kind)});
                try writeValue(writer, event.inputs, domain);
                try writer.writeAll(" output=");
                try writeValue(writer, event.output, domain);
                try writer.writeByte('\n');
            }
        } else try writer.writeAll("trace <disabled>\n");
    }
}

fn writeId(writer: *std.Io.Writer, id: anytype, domain: *const ids.IdentityDomain) !void {
    const index = id.index() orelse return writer.writeAll("<invalid>");
    if (!id.isValidFor(domain)) return writer.print("<foreign:{}>", .{index});
    try writer.print("{}", .{index});
}

fn isHirId(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "debug_name") and @hasDecl(T, "index") and @hasDecl(T, "isValidFor");
}

fn writeValue(writer: *std.Io.Writer, value: anytype, domain: *const ids.IdentityDomain) !void {
    const T = @TypeOf(value);
    if (comptime isHirId(T)) return writeId(writer, value, domain);
    switch (@typeInfo(T)) {
        .void => try writer.writeAll("void"),
        .bool, .int, .comptime_int, .float, .comptime_float => try writer.print("{}", .{value}),
        .@"enum" => |info| {
            if (info.fields.len == 0) {
                try writer.print("{}", .{@intFromEnum(value)});
            } else {
                try writer.writeAll(@tagName(value));
            }
        },
        .optional => {
            if (value) |payload| try writeValue(writer, payload, domain) else try writer.writeAll("null");
        },
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                if (pointer.child == u8) return writeQuoted(writer, value);
                try writer.writeByte('[');
                for (value, 0..) |item, index| {
                    if (index != 0) try writer.writeByte(',');
                    try writeValue(writer, item, domain);
                }
                try writer.writeByte(']');
            } else try writeValue(writer, value.*, domain);
        },
        .array => {
            try writer.writeByte('[');
            for (value, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeValue(writer, item, domain);
            }
            try writer.writeByte(']');
        },
        .@"struct" => |info| {
            try writer.writeByte('{');
            inline for (info.fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try writer.print("{s}=", .{field.name});
                try writeValue(writer, @field(value, field.name), domain);
            }
            try writer.writeByte('}');
        },
        .@"union" => {
            const tag = std.meta.activeTag(value);
            try writer.writeAll(@tagName(tag));
            switch (value) {
                inline else => |payload| if (@TypeOf(payload) != void) {
                    try writer.writeByte('(');
                    try writeValue(writer, payload, domain);
                    try writer.writeByte(')');
                },
            }
        },
        else => try writer.writeAll("<unsupported-debug-value>"),
    }
}

fn writeQuoted(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
        else => try writer.print("\\x{x:0>2}", .{byte}),
    };
    try writer.writeByte('"');
}
