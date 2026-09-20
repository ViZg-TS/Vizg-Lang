//! Portable, versioned cache codec for one completed source frontend.
//!
//! The payload contains only immutable value data from scanner/parser/binder/
//! resolver/CFG output. It never serializes allocator state or pointers. Every
//! slice/string is rebuilt into the destination allocator on decode.

const std = @import("std");
const frontend = @import("frontend.zig");

pub const schema_version: u32 = 2;
const magic = "VZGFC002";

pub const Error = error{ InvalidCache, BufferTooSmall, OutOfMemory };

const Encoder = struct {
    output: ?[]u8,
    source_text: []const u8,
    index: usize = 0,

    fn bytes(self: *Encoder, value: []const u8) Error!void {
        const end = std.math.add(usize, self.index, value.len) catch return error.BufferTooSmall;
        if (self.output) |output| {
            if (end > output.len) return error.BufferTooSmall;
            @memcpy(output[self.index..end], value);
        }
        self.index = end;
    }

    fn byte(self: *Encoder, value: u8) Error!void {
        var one = [1]u8{value};
        try self.bytes(&one);
    }

    fn u64Value(self: *Encoder, value: u64) Error!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .little);
        try self.bytes(&buffer);
    }
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    source_text: []const u8,
    index: usize = 0,

    fn bytes(self: *Decoder, len: usize) Error![]const u8 {
        const end = std.math.add(usize, self.index, len) catch return error.InvalidCache;
        if (end > self.input.len) return error.InvalidCache;
        const result = self.input[self.index..end];
        self.index = end;
        return result;
    }

    fn byte(self: *Decoder) Error!u8 {
        const value = try self.bytes(1);
        return value[0];
    }

    fn u64Value(self: *Decoder) Error!u64 {
        const value = try self.bytes(8);
        return std.mem.readInt(u64, value[0..8], .little);
    }

    fn length(self: *Decoder) Error!usize {
        const raw = try self.u64Value();
        const value = std.math.cast(usize, raw) orelse return error.InvalidCache;
        // A valid encoded slice requires at least one input byte for its length
        // itself, so no individual decoded item count may exceed the entire
        // snapshot size. This also prevents hostile/corrupt cache blobs from
        // requesting absurd allocations before the decoder discovers EOF.
        if (value > self.input.len) return error.InvalidCache;
        return value;
    }
};

pub fn encodedSize(result: *const frontend.FrontendResult) Error!usize {
    var encoder: Encoder = .{ .output = null, .source_text = result.source.text };
    try encodeFrontend(&encoder, result);
    return encoder.index;
}

pub fn encodeInto(result: *const frontend.FrontendResult, output: []u8) Error!usize {
    var encoder: Encoder = .{ .output = output, .source_text = result.source.text };
    try encodeFrontend(&encoder, result);
    return encoder.index;
}

pub fn decode(
    allocator: std.mem.Allocator,
    source: frontend.SourceFile,
    input: []const u8,
) Error!frontend.FrontendResult {
    var decoder: Decoder = .{ .allocator = allocator, .input = input, .source_text = source.text };
    if (!std.mem.eql(u8, try decoder.bytes(magic.len), magic)) return error.InvalidCache;
    if (try decoder.u64Value() != schema_version) return error.InvalidCache;

    const tokens = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).tokens), &decoder);
    const comments = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).comments), &decoder);
    const ast = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).ast), &decoder);
    const bind = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).bind), &decoder);
    const resolve = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).resolve), &decoder);
    const cfgs = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).cfgs), &decoder);
    const diagnostics = try decodeValue(@TypeOf(@as(frontend.FrontendResult, undefined).diagnostics), &decoder);
    if (decoder.index != input.len) return error.InvalidCache;

    return .{
        .source = source,
        .tokens = tokens,
        .comments = comments,
        .ast = ast,
        .bind = bind,
        .resolve = resolve,
        .cfgs = cfgs,
        .diagnostics = diagnostics,
    };
}

fn encodeFrontend(encoder: *Encoder, result: *const frontend.FrontendResult) Error!void {
    try encoder.bytes(magic);
    try encoder.u64Value(schema_version);
    try encodeValue(@TypeOf(result.tokens), encoder, result.tokens);
    try encodeValue(@TypeOf(result.comments), encoder, result.comments);
    try encodeValue(@TypeOf(result.ast), encoder, result.ast);
    try encodeValue(@TypeOf(result.bind), encoder, result.bind);
    try encodeValue(@TypeOf(result.resolve), encoder, result.resolve);
    try encodeValue(@TypeOf(result.cfgs), encoder, result.cfgs);
    try encodeValue(@TypeOf(result.diagnostics), encoder, result.diagnostics);
}

fn encodeValue(comptime T: type, encoder: *Encoder, value: T) Error!void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try encoder.byte(@intFromBool(value)),
        .int => |info| {
            if (info.bits > 64) @compileError("frontend cache integer wider than 64 bits");
            if (info.signedness == .signed) {
                const wide: i64 = @intCast(value);
                try encoder.u64Value(@bitCast(wide));
            } else {
                try encoder.u64Value(@intCast(value));
            }
        },
        .float => |info| {
            if (info.bits > 64) @compileError("frontend cache float wider than 64 bits");
            const UInt = std.meta.Int(.unsigned, info.bits);
            const bits: UInt = @bitCast(value);
            try encoder.u64Value(@intCast(bits));
        },
        .@"enum" => try encoder.u64Value(@intCast(@intFromEnum(value))),
        .optional => {
            if (value) |payload| {
                try encoder.byte(1);
                try encodeValue(@TypeOf(payload), encoder, payload);
            } else try encoder.byte(0);
        },
        .array => |info| {
            if (info.child == u8) {
                try encoder.bytes(value[0..]);
            } else {
                for (value) |item| try encodeValue(info.child, encoder, item);
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    const bytes: []const u8 = value;
                    if (info.is_const) {
                        if (sourceSliceOffset(encoder.source_text, bytes)) |offset| {
                            try encoder.byte(1);
                            try encoder.u64Value(@intCast(offset));
                            try encoder.u64Value(@intCast(bytes.len));
                            return;
                        }
                    }
                    try encoder.byte(0);
                    try encoder.u64Value(@intCast(bytes.len));
                    try encoder.bytes(bytes);
                } else {
                    try encoder.u64Value(@intCast(value.len));
                    for (value) |item| try encodeValue(info.child, encoder, item);
                }
            },
            else => @compileError("frontend cache supports slices only, got pointer field of type " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime) try encodeValue(field.type, encoder, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("frontend cache requires tagged unions");
            const tag: Tag = std.meta.activeTag(value);
            try encodeValue(Tag, encoder, tag);
            switch (value) {
                inline else => |payload| try encodeValue(@TypeOf(payload), encoder, payload),
            }
        },
        else => @compileError("unsupported frontend cache field type: " ++ @typeName(T)),
    }
}

fn decodeValue(comptime T: type, decoder: *Decoder) Error!T {
    return switch (@typeInfo(T)) {
        .void => {},
        .bool => blk: {
            const value = try decoder.byte();
            if (value > 1) return error.InvalidCache;
            break :blk value == 1;
        },
        .int => |info| blk: {
            if (info.bits > 64) @compileError("frontend cache integer wider than 64 bits");
            const raw = try decoder.u64Value();
            if (info.signedness == .signed) {
                const wide: i64 = @bitCast(raw);
                break :blk std.math.cast(T, wide) orelse return error.InvalidCache;
            }
            break :blk std.math.cast(T, raw) orelse return error.InvalidCache;
        },
        .float => |info| blk: {
            if (info.bits > 64) @compileError("frontend cache float wider than 64 bits");
            const UInt = std.meta.Int(.unsigned, info.bits);
            const bits = std.math.cast(UInt, try decoder.u64Value()) orelse return error.InvalidCache;
            break :blk @bitCast(bits);
        },
        .@"enum" => |info| blk: {
            const raw = try decoder.u64Value();
            const tag = std.math.cast(info.tag_type, raw) orelse return error.InvalidCache;
            if (!info.is_exhaustive) {
                const value: T = @enumFromInt(tag);
                break :blk value;
            }
            inline for (info.fields) |field| {
                if (raw == field.value) {
                    const value: T = @enumFromInt(tag);
                    break :blk value;
                }
            }
            return error.InvalidCache;
        },
        .optional => |info| blk: {
            const present = try decoder.byte();
            if (present > 1) return error.InvalidCache;
            if (present == 0) break :blk null;
            break :blk try decodeValue(info.child, decoder);
        },
        .array => |info| blk: {
            var output: T = undefined;
            if (info.child == u8) {
                const raw = try decoder.bytes(info.len);
                @memcpy(output[0..], raw);
            } else {
                for (&output) |*item| item.* = try decodeValue(info.child, decoder);
            }
            break :blk output;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (info.child == u8) {
                    const storage = try decoder.byte();
                    switch (storage) {
                        0 => {
                            const len = try decoder.length();
                            const raw = try decoder.bytes(len);
                            const output = try decoder.allocator.alloc(u8, len);
                            @memcpy(output, raw);
                            break :blk output;
                        },
                        1 => {
                            if (!info.is_const) return error.InvalidCache;
                            const offset = std.math.cast(usize, try decoder.u64Value()) orelse return error.InvalidCache;
                            const len = std.math.cast(usize, try decoder.u64Value()) orelse return error.InvalidCache;
                            const end = std.math.add(usize, offset, len) catch return error.InvalidCache;
                            if (end > decoder.source_text.len) return error.InvalidCache;
                            break :blk decoder.source_text[offset..end];
                        },
                        else => return error.InvalidCache,
                    }
                }
                const len = try decoder.length();
                const output = try decoder.allocator.alloc(info.child, len);
                for (output) |*item| item.* = try decodeValue(info.child, decoder);
                break :blk output;
            },
            else => @compileError("frontend cache supports slices only, got pointer field of type " ++ @typeName(T)),
        },
        .@"struct" => |info| blk: {
            var output: T = undefined;
            inline for (info.fields) |field| {
                if (!field.is_comptime) @field(output, field.name) = try decodeValue(field.type, decoder);
            }
            break :blk output;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("frontend cache requires tagged unions");
            const tag = try decodeValue(Tag, decoder);
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    const payload = try decodeValue(field.type, decoder);
                    break :blk @unionInit(T, field.name, payload);
                }
            }
            return error.InvalidCache;
        },
        else => @compileError("unsupported frontend cache field type: " ++ @typeName(T)),
    };
}

fn sourceSliceOffset(source: []const u8, bytes: []const u8) ?usize {
    if (bytes.len == 0) return if (source.len == 0) 0 else null;
    if (source.len == 0) return null;
    const source_start = @intFromPtr(source.ptr);
    const source_end = std.math.add(usize, source_start, source.len) catch return null;
    const bytes_start = @intFromPtr(bytes.ptr);
    const bytes_end = std.math.add(usize, bytes_start, bytes.len) catch return null;
    if (bytes_start < source_start or bytes_end > source_end) return null;
    return bytes_start - source_start;
}

test "frontend cache round trips parser binder resolver and CFG output" {
    var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer source_arena.deinit();
    const source = frontend.SourceFile{
        .path = "src/main.ts",
        .text = "export function add(a: number, b: number): number { return a + b; }\\nadd(1, 2);\\n",
    };
    const first = try frontend.analyze(source_arena.allocator(), source, .{});
    const size = try encodedSize(&first);
    const bytes = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(size, try encodeInto(&first, bytes));

    var restored_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer restored_arena.deinit();
    const restored_source = frontend.SourceFile{
        .path = try restored_arena.allocator().dupe(u8, source.path),
        .text = try restored_arena.allocator().dupe(u8, source.text),
    };
    const restored = try decode(restored_arena.allocator(), restored_source, bytes);
    try std.testing.expectEqual(first.tokens.len, restored.tokens.len);
    try std.testing.expectEqual(first.ast.nodes.len, restored.ast.nodes.len);
    try std.testing.expectEqual(first.bind.symbols.len, restored.bind.symbols.len);
    try std.testing.expectEqual(first.resolve.references.len, restored.resolve.references.len);
    try std.testing.expectEqual(first.cfgs.len, restored.cfgs.len);
    try std.testing.expectEqualStrings(first.bind.module.exports[0].name, restored.bind.module.exports[0].name);
}
