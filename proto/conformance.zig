//! Bytes another implementation wrote, and bytes the protobuf encoding guide
//! prints, read and written back by this module (ADR 245).
//!
//! The two fixtures under `fixtures/` were written by prost 0.13 from photon's
//! load generator (`photon-loadgen`, one record and then 37 across four
//! services), as OTLP logs requests. The test is the strongest one a codec
//! has when nobody can run the other implementation: decode what it wrote,
//! encode the result, and get the same bytes back. That only holds if field
//! order, packing and the omission of zero values all agree.
//!
//! The types are OTLP's, opentelemetry-proto 0.27, written the way a caller
//! would write them. They are test-only; nilo ships no schema.

const std = @import("std");
const proto = @import("proto.zig");

const testing = std.testing;

pub const AnyValue = struct {
    pub const wire = .{};
    value: ?Value = null,

    pub const Value = union(enum) {
        pub const wire = .{
            .string_value = 1,
            .bool_value = 2,
            .int_value = 3,
            .double_value = 4,
            .array_value = 5,
            .kvlist_value = 6,
            .bytes_value = .{ 7, .bytes },
        };
        string_value: []const u8,
        bool_value: bool,
        int_value: i64,
        double_value: f64,
        array_value: ArrayValue,
        kvlist_value: KeyValueList,
        bytes_value: []const u8,
    };
};

pub const ArrayValue = struct {
    pub const wire = .{ .values = 1 };
    values: []const AnyValue = &.{},
};

pub const KeyValueList = struct {
    pub const wire = .{ .values = 1 };
    values: []const KeyValue = &.{},
};

pub const KeyValue = struct {
    pub const wire = .{ .key = 1, .value = 2 };
    key: []const u8 = "",
    value: ?AnyValue = null,
};

pub const InstrumentationScope = struct {
    pub const wire = .{ .name = 1, .version = 2, .attributes = 3, .dropped_attributes_count = 4 };
    name: []const u8 = "",
    version: []const u8 = "",
    attributes: []const KeyValue = &.{},
    dropped_attributes_count: u32 = 0,
};

pub const Resource = struct {
    pub const wire = .{ .attributes = 1, .dropped_attributes_count = 2 };
    attributes: []const KeyValue = &.{},
    dropped_attributes_count: u32 = 0,
};

/// Open, as every proto3 enum is: a number this list does not name is kept.
pub const SeverityNumber = enum(i32) {
    unspecified = 0,
    trace = 1,
    debug = 5,
    info = 9,
    warn = 13,
    err = 17,
    fatal = 21,
    _,
};

pub const LogRecord = struct {
    pub const wire = .{
        .time_unix_nano = .{ 1, .fixed64 },
        .severity_number = 2,
        .severity_text = 3,
        .body = 5,
        .attributes = 6,
        .dropped_attributes_count = 7,
        .flags = .{ 8, .fixed32 },
        .trace_id = .{ 9, .bytes },
        .span_id = .{ 10, .bytes },
        .observed_time_unix_nano = .{ 11, .fixed64 },
    };
    time_unix_nano: u64 = 0,
    observed_time_unix_nano: u64 = 0,
    severity_number: SeverityNumber = .unspecified,
    severity_text: []const u8 = "",
    body: ?AnyValue = null,
    attributes: []const KeyValue = &.{},
    dropped_attributes_count: u32 = 0,
    flags: u32 = 0,
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
};

pub const ScopeLogs = struct {
    pub const wire = .{ .scope = 1, .log_records = 2, .schema_url = 3 };
    scope: ?InstrumentationScope = null,
    log_records: []const LogRecord = &.{},
    schema_url: []const u8 = "",
};

pub const ResourceLogs = struct {
    pub const wire = .{ .resource = 1, .scope_logs = 2, .schema_url = 3 };
    resource: ?Resource = null,
    scope_logs: []const ScopeLogs = &.{},
    schema_url: []const u8 = "",
};

pub const ExportLogsServiceRequest = struct {
    pub const wire = .{ .resource_logs = 1 };
    resource_logs: []const ResourceLogs = &.{},
};

fn records(req: ExportLogsServiceRequest) usize {
    var n: usize = 0;
    for (req.resource_logs) |rl| for (rl.scope_logs) |sl| {
        n += sl.log_records.len;
    };
    return n;
}

test "what prost wrote is read, and written back byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (.{
        .{ "fixtures/otlp-logs-1.pb", 1 },
        .{ "fixtures/otlp-logs-37.pb", 37 },
    }) |case| {
        const bytes = @embedFile(case[0]);
        const req = try proto.decode(ExportLogsServiceRequest, arena, bytes);
        try testing.expectEqual(@as(usize, case[1]), records(req));
        try testing.expectEqual(bytes.len, proto.encodedSize(ExportLogsServiceRequest, req));
        const again = try proto.encode(ExportLogsServiceRequest, arena, req);
        try testing.expectEqualSlices(u8, bytes, again);
    }
}

test "a record prost wrote keeps its text, its ids and its attributes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const req = try proto.decode(ExportLogsServiceRequest, arena_state.allocator(), @embedFile("fixtures/otlp-logs-1.pb"));
    const lr = req.resource_logs[0].scope_logs[0].log_records[0];
    try testing.expect(lr.time_unix_nano > 1_000_000_000_000_000_000);
    // The generator leaves ids out of some records: absent is empty, and
    // present is the 16 and 8 bytes an id is.
    try testing.expect(lr.trace_id.len == 0 or lr.trace_id.len == 16);
    try testing.expect(lr.span_id.len == 0 or lr.span_id.len == 8);
    try testing.expect(lr.severity_text.len > 0);
    try testing.expect(lr.attributes.len > 0);
    for (lr.attributes) |kv| {
        try testing.expect(kv.key.len > 0);
        try testing.expect(kv.value != null);
    }
    // The resource carries the service name every record is filed under.
    var found = false;
    for (req.resource_logs[0].resource.?.attributes) |kv| {
        if (std.mem.eql(u8, kv.key, "service.name")) found = true;
    }
    try testing.expect(found);
}

// The protobuf encoding guide's own examples, which every implementation is
// held to (protobuf.dev/programming-guides/encoding).

const Test1 = struct {
    pub const wire = .{ .a = 1 };
    a: i32 = 0,
};
const Test2 = struct {
    pub const wire = .{ .b = 2 };
    b: []const u8 = "",
};
const Test3 = struct {
    pub const wire = .{ .c = 3 };
    c: ?Test1 = null,
};
const Test4 = struct {
    pub const wire = .{ .d = 4 };
    d: []const i32 = &.{},
};

test "the guide's varint example is 08 96 01" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = [_]u8{ 0x08, 0x96, 0x01 };
    try testing.expectEqual(@as(i32, 150), (try proto.decode(Test1, a, &bytes)).a);
    try testing.expectEqualSlices(u8, &bytes, try proto.encode(Test1, a, .{ .a = 150 }));
}

test "the guide's string example is 12 07 testing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = [_]u8{ 0x12, 0x07, 0x74, 0x65, 0x73, 0x74, 0x69, 0x6e, 0x67 };
    try testing.expectEqualStrings("testing", (try proto.decode(Test2, a, &bytes)).b);
    try testing.expectEqualSlices(u8, &bytes, try proto.encode(Test2, a, .{ .b = "testing" }));
}

test "the guide's embedded message example is 1a 03 08 96 01" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = [_]u8{ 0x1a, 0x03, 0x08, 0x96, 0x01 };
    try testing.expectEqual(@as(i32, 150), (try proto.decode(Test3, a, &bytes)).c.?.a);
    try testing.expectEqualSlices(u8, &bytes, try proto.encode(Test3, a, .{ .c = .{ .a = 150 } }));
}

test "the guide's packed example is 22 06 03 8e 02 9e a7 05" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = [_]u8{ 0x22, 0x06, 0x03, 0x8e, 0x02, 0x9e, 0xa7, 0x05 };
    try testing.expectEqualSlices(i32, &.{ 3, 270, 86942 }, (try proto.decode(Test4, a, &bytes)).d);
    try testing.expectEqualSlices(u8, &bytes, try proto.encode(Test4, a, .{ .d = &.{ 3, 270, 86942 } }));
}

test "the guide's zigzag table, and a zero that is left out" {
    const Z = struct {
        pub const wire = .{ .a = .{ 1, .sint32 } };
        a: i32 = 0,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const table = [_]struct { v: i32, byte: u64 }{
        .{ .v = -1, .byte = 1 },
        .{ .v = 1, .byte = 2 },
        .{ .v = -2, .byte = 3 },
        .{ .v = 2147483647, .byte = 4294967294 },
        .{ .v = -2147483648, .byte = 4294967295 },
    };
    for (table) |row| {
        const bytes = try proto.encode(Z, a, .{ .a = row.v });
        var r: proto.Reader = .init(bytes);
        _ = try r.key();
        try testing.expectEqual(row.byte, try r.varint());
        try testing.expectEqual(row.v, (try proto.decode(Z, a, bytes)).a);
    }
    try testing.expectEqual(@as(usize, 0), (try proto.encode(Z, a, .{ .a = 0 })).len);
}

test "a negative int32 is ten bytes, as the guide says" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bytes = try proto.encode(Test1, a, .{ .a = -1 });
    try testing.expectEqualSlices(u8, &.{ 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, bytes);
    try testing.expectEqual(@as(i32, -1), (try proto.decode(Test1, a, bytes)).a);
}
