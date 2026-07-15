//! Deterministic pull-based module request scheduler.

const std = @import("std");
const contracts = @import("contracts.zig");

pub const RequestStatus = enum(u32) { queued, waiting, responded };
pub const ResponseKind = enum(u32) { source, external, not_found, denied, failed };

pub const Resolution = struct {
    kind: ResponseKind,
    module_id: ?contracts.ModuleId = null,
    external_module_id: ?contracts.ExternalModuleId = null,
};

pub const Step = union(enum) {
    request: contracts.ModuleRequest,
    complete: void,
};

pub const RequestRecord = struct {
    request: contracts.ModuleRequest,
    status: RequestStatus,
    resolution: ?Resolution = null,
};

pub const Checkpoint = struct {
    record_count: usize,
    next_id: u64,
};

/// Scheduling policy: insertion-order FIFO with at most one dispatched request.
/// Calling step repeatedly before responding returns the same request value.
pub const StateMachine = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(RequestRecord) = .empty,
    next_id: u64 = 1,
    max_requests: usize,

    pub fn init(allocator: std.mem.Allocator) StateMachine {
        return initWithLimit(allocator, std.math.maxInt(usize));
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, max_requests: usize) StateMachine {
        return .{ .allocator = allocator, .max_requests = max_requests };
    }

    pub fn deinit(self: *StateMachine) void {
        for (self.records.items) |record| self.freeRequest(record.request);
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn checkpoint(self: *const StateMachine) Checkpoint {
        return .{ .record_count = self.records.items.len, .next_id = self.next_id };
    }

    pub fn rollback(self: *StateMachine, checkpoint_value: Checkpoint) void {
        defer self.assertInvariants();
        while (self.records.items.len > checkpoint_value.record_count) {
            const index = self.records.items.len - 1;
            const record = self.records.items[index];
            self.freeRequest(record.request);
            self.records.items.len = index;
        }
        self.next_id = checkpoint_value.next_id;
    }

    pub fn enqueue(self: *StateMachine, input: contracts.ModuleRequestInput) !contracts.RequestId {
        defer self.assertInvariants();
        for (self.records.items) |record| {
            if (equivalent(record.request, input)) return record.request.id;
        }

        if (self.records.items.len >= self.max_requests) return error.RequestLimitExceeded;
        if (self.next_id == 0) return error.RequestIdExhausted;

        const specifier = try self.allocator.dupe(u8, input.raw_specifier);
        errdefer self.allocator.free(specifier);
        const attributes = try self.copyAttributes(input.attributes);
        errdefer self.freeAttributes(attributes);

        const id = contracts.RequestId.init(self.next_id);
        try self.records.append(self.allocator, .{
            .request = .{
                .id = id,
                .importer = input.importer,
                .raw_specifier = specifier,
                .operation = input.operation,
                .type_only = input.type_only,
                .attributes = attributes,
                .span = input.span,
            },
            .status = .queued,
        });
        self.next_id +%= 1;
        return id;
    }

    pub fn step(self: *StateMachine) Step {
        defer self.assertInvariants();
        for (self.records.items) |*record| {
            if (record.status == .waiting) return .{ .request = record.request };
        }
        for (self.records.items) |*record| {
            if (record.status == .queued) {
                record.status = .waiting;
                return .{ .request = record.request };
            }
        }
        return .{ .complete = {} };
    }

    pub fn validateResponse(self: *StateMachine, id: contracts.RequestId) !void {
        const record = self.findMut(id) orelse return error.ForeignRequest;
        switch (record.status) {
            .queued => return error.InvalidResponseOrder,
            .waiting => {},
            .responded => return error.DuplicateResponse,
        }
    }

    pub fn commitResponse(self: *StateMachine, id: contracts.RequestId, resolution: Resolution) !void {
        defer self.assertInvariants();
        try self.validateResponse(id);
        const record = self.findMut(id).?;
        record.resolution = resolution;
        record.status = .responded;
    }

    pub fn lookup(self: *const StateMachine, id: contracts.RequestId) ?RequestRecord {
        for (self.records.items) |record| if (record.request.id == id) return record;
        return null;
    }

    pub fn count(self: *const StateMachine) usize {
        return self.records.items.len;
    }

    pub fn recordsView(self: *const StateMachine) []const RequestRecord {
        return self.records.items;
    }

    pub fn hasUnresolved(self: *const StateMachine) bool {
        for (self.records.items) |record| {
            if (record.status == .queued or record.status == .waiting) return true;
        }
        return false;
    }

    pub fn hasFailures(self: *const StateMachine) bool {
        for (self.records.items) |record| {
            if (record.resolution) |resolution| switch (resolution.kind) {
                .not_found, .denied, .failed => return true,
                .source, .external => {},
            };
        }
        return false;
    }

    /// Debug/test ownership assertions for every scheduler mutation boundary.
    pub fn assertInvariants(self: *const StateMachine) void {
        std.debug.assert(self.next_id != 0);
        std.debug.assert(self.records.items.len <= self.max_requests);
        for (self.records.items, 0..) |record, index| {
            std.debug.assert(record.request.id.value() != 0);
            std.debug.assert((record.status == .responded) == (record.resolution != null));
            for (self.records.items[0..index]) |previous| {
                std.debug.assert(previous.request.id != record.request.id);
            }
        }
    }

    fn findMut(self: *StateMachine, id: contracts.RequestId) ?*RequestRecord {
        for (self.records.items) |*record| if (record.request.id == id) return record;
        return null;
    }

    fn copyAttributes(self: *StateMachine, source: []const contracts.RequestAttribute) ![]const contracts.RequestAttribute {
        const result = try self.allocator.alloc(contracts.RequestAttribute, source.len);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |attribute| {
                self.allocator.free(attribute.key);
                self.allocator.free(attribute.value);
            }
            self.allocator.free(result);
        }
        for (source, 0..) |attribute, index| {
            const key = try self.allocator.dupe(u8, attribute.key);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, attribute.value);
            result[index] = .{ .key = key, .value = value, .span = attribute.span };
            initialized += 1;
        }
        return result;
    }

    fn freeAttributes(self: *StateMachine, attributes: []const contracts.RequestAttribute) void {
        for (attributes) |attribute| {
            self.allocator.free(attribute.key);
            self.allocator.free(attribute.value);
        }
        self.allocator.free(attributes);
    }

    fn freeRequest(self: *StateMachine, request: contracts.ModuleRequest) void {
        self.allocator.free(request.raw_specifier);
        self.freeAttributes(request.attributes);
    }
};

fn equivalent(request: contracts.ModuleRequest, input: contracts.ModuleRequestInput) bool {
    if (request.importer != input.importer or request.operation != input.operation or request.type_only != input.type_only) return false;
    if (!std.mem.eql(u8, request.raw_specifier, input.raw_specifier)) return false;
    if (request.attributes.len != input.attributes.len) return false;
    for (request.attributes, input.attributes) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key) or !std.mem.eql(u8, left.value, right.value)) return false;
    }
    return true;
}

test "mutated request inputs and response order cannot alter retained state" {
    var machine = StateMachine.init(std.testing.allocator);
    defer machine.deinit();

    var specifier: [24]u8 = undefined;
    var key: [8]u8 = undefined;
    var value: [12]u8 = undefined;
    for (0..128) |iteration| {
        for (&specifier, 0..) |*byte, index| byte.* = @truncate(iteration * 17 + index * 31);
        for (&key, 0..) |*byte, index| byte.* = @truncate(iteration * 13 + index * 19);
        for (&value, 0..) |*byte, index| byte.* = @truncate(iteration * 11 + index * 23);
        const expected_specifier = specifier;
        const expected_key = key;
        const expected_value = value;
        const attributes = [_]contracts.RequestAttribute{.{
            .key = &key,
            .value = &value,
            .span = .{ .start = 2, .end = 7, .line = 1, .column = 2 },
        }};
        const id = try machine.enqueue(.{
            .importer = .init(iteration + 1),
            .raw_specifier = &specifier,
            .operation = @enumFromInt(iteration % 3),
            .type_only = iteration % 2 == 0,
            .attributes = &attributes,
            .span = .{ .start = 0, .end = 24, .line = 1, .column = 0 },
        });

        try std.testing.expectError(error.InvalidResponseOrder, machine.commitResponse(id, .{ .kind = .failed }));
        const dispatched = machine.step().request;
        try std.testing.expectEqual(id, dispatched.id);
        @memset(&specifier, 0xaa);
        @memset(&key, 0xbb);
        @memset(&value, 0xcc);

        const retained = machine.lookup(id).?.request;
        try std.testing.expectEqualSlices(u8, &expected_specifier, retained.raw_specifier);
        try std.testing.expectEqualSlices(u8, &expected_key, retained.attributes[0].key);
        try std.testing.expectEqualSlices(u8, &expected_value, retained.attributes[0].value);
        try machine.commitResponse(id, .{ .kind = .failed });
        try std.testing.expectError(error.DuplicateResponse, machine.commitResponse(id, .{ .kind = .failed }));
    }
    try std.testing.expect(machine.step() == .complete);
    try std.testing.expectError(error.ForeignRequest, machine.commitResponse(.init(999_999), .{ .kind = .failed }));
}

test "request limit is checked before copying and holds the N boundary" {
    const span: contracts.SourceSpan = .{ .start = 0, .end = 1, .line = 1, .column = 0 };
    const attributes = [_]contracts.RequestAttribute{.{
        .key = "type",
        .value = "json",
        .span = span,
    }};
    const input: contracts.ModuleRequestInput = .{
        .importer = .init(1),
        .raw_specifier = "./dependency",
        .operation = .static_import,
        .attributes = &attributes,
        .span = span,
    };

    var no_storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_storage);
    var zero_limit = StateMachine.initWithLimit(fixed.allocator(), 0);
    defer zero_limit.deinit();
    try std.testing.expectError(error.RequestLimitExceeded, zero_limit.enqueue(input));
    try std.testing.expectEqual(@as(usize, 0), zero_limit.count());

    var bounded = StateMachine.initWithLimit(std.testing.allocator, 1);
    defer bounded.deinit();
    _ = try bounded.enqueue(input);
    var second = input;
    second.raw_specifier = "./other";
    try std.testing.expectError(error.RequestLimitExceeded, bounded.enqueue(second));
    try std.testing.expectEqual(@as(usize, 1), bounded.count());
}
