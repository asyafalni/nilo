//! A request body under `Content-Encoding: zstd`, from the head to the
//! handler ([ADR 295](../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)).
//!
//! **Every test here is about one of two builds.** `test_root.zig` compiles
//! this file in the suite as a dependent gets it, where zstd is an encoding
//! the server does not read, and the tests that hold that (a 415 naming what
//! the route reads, a route that names `"zstd"` getting the raw bytes) run
//! there. `test_root_zstd.zig` compiles it with `nilo_build.zstd` on, where
//! the tests of the path that reads it run; each half skips in the other
//! build, so `zig build test` covers both without `-Dzstd` and without a
//! second pass over the whole suite, and `zig build test -Dzstd` runs the
//! second half in the main root.
//!
//! The decoder's own cases (windows, ratios, every frame error) are
//! `zstd/zstd.zig`'s; the cases here are the ones that are the server's: where
//! the ceiling is checked, what the status of each failure is, that the
//! connection survives, and that a frame says the same thing through
//! `c.body()`, `c.json`, a typed argument, `bodyStream` and HTTP/2.

const std = @import("std");

const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;
const nilo_testing = @import("testing.zig");
const zstdbody = @import("zstdbody.zig");
const bodyencodings = @import("bodyencodings.zig");
const h2 = @import("h2.zig");
const h2test = @import("h2test.zig");

const testing = std.testing;

// ---- fixtures ----

/// `n` bytes of JSON-looking lines that vary, so the frame is smaller than the
/// text and not a single repeated run.
fn sample(gpa: std.mem.Allocator, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, n);
    var i: usize = 0;
    var k: u32 = 0;
    while (i < n) : (k += 1) {
        const line = std.fmt.bufPrint(out[i..], "{{\"id\":{d},\"name\":\"user-{d}\",\"tags\":[\"a\",\"b\"]}},\n", .{ k * 7919 % 100_003, k % 97 }) catch {
            @memset(out[i..], ' ');
            break;
        };
        i += line.len;
    }
    return out;
}

/// `bytes` as one frame that announces its size and carries a checksum, the
/// way a client with the whole body in hand writes one.
fn announced(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (comptime !zstdbody.enabled) unreachable;
    return nilo_testing.zstd(arena, bytes);
}

/// `bytes` as a frame written by a streaming encoder, which cannot know the
/// size and so announces none (the OpenTelemetry Collector's zstd is one).
fn unannounced(arena: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (comptime !zstdbody.enabled) unreachable;
    const codec = zstdbody.zstd;
    const memory = try arena.alignedAlloc(u8, codec.workspace_alignment, codec.StreamCompressor.contextSize(.{ .window_log = 17 }));
    var out: std.Io.Writer.Allocating = .init(arena);
    var encoder = try codec.StreamCompressor.init(memory, &out.writer, &.{}, .{ .window_log = 17 });
    try encoder.writer.writeAll(bytes);
    try encoder.finish();
    const frame = out.written();
    try testing.expect((try codec.Frame.parse(frame)).content_size == null);
    return frame;
}

const post_zstd = "POST {s} HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\n";

/// A request with `frame` as its body under `Content-Encoding: zstd`.
fn request(arena: std.mem.Allocator, path: []const u8, frame: []const u8) ![]u8 {
    const head = try std.fmt.allocPrint(arena, post_zstd ++ "Content-Length: {d}\r\n\r\n", .{ path, frame.len });
    return std.mem.concat(arena, u8, &.{ head, frame });
}

/// The same body in chunks of `piece` bytes.
fn chunkedRequest(arena: std.mem.Allocator, path: []const u8, frame: []const u8, piece: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print(post_zstd ++ "Transfer-Encoding: chunked\r\n\r\n", .{path});
    var rest = frame;
    while (rest.len > 0) {
        const n = @min(rest.len, piece);
        try out.writer.print("{x}\r\n", .{n});
        try out.writer.writeAll(rest[0..n]);
        try out.writer.writeAll("\r\n");
        rest = rest[n..];
    }
    try out.writer.writeAll("0\r\n\r\n");
    return out.written();
}

fn digest(buf: *[40]u8, bytes: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x}:{d}", .{ std.hash.Wyhash.hash(0, bytes), bytes.len }) catch unreachable;
}

const Greeting = struct { name: []const u8, times: u32 };

fn greet(g: Greeting) ![]const u8 {
    _ = g.times;
    return g.name;
}

fn echo(c: *Ctx) anyerror!void {
    try c.send(200, "application/octet-stream", (try c.body()).view());
}

fn json(c: *Ctx) anyerror!void {
    const g = try c.json(Greeting);
    try c.sendText(200, g.name);
}

/// Reads through `bodyStream` into a hash, so a body of any size is compared
/// without being held.
fn hash(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStreamWith(.{ .max_bytes = 64 * 1024 });
    var buf: [1000]u8 = undefined;
    var hasher: std.hash.Wyhash = .init(0);
    var total: u64 = 0;
    while (try incoming.read(&buf)) |part| {
        hasher.update(part);
        total += part.len;
    }
    var text: [40]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&text, "{x}:{d}", .{ hasher.final(), total }) catch unreachable);
}

/// `hash`, read eight bytes at a time through a buffered reader: the decoder
/// is asked for pieces smaller than a block.
fn tiny(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var window: [8]u8 = undefined;
    const r = try incoming.buffered(&window);
    var hasher: std.hash.Wyhash = .init(0);
    var total: u64 = 0;
    while (true) {
        const part = r.take(5) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return incoming.explain(e),
        };
        hasher.update(part);
        total += part.len;
    }
    // `take(5)` leaves what is under five bytes: the tail is read as it is.
    const tail = r.buffered();
    hasher.update(tail);
    total += tail.len;
    var text: [40]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&text, "{x}:{d}", .{ hasher.final(), total }) catch unreachable);
}

fn app() !App {
    var a = App.init(testing.allocator);
    errdefer a.deinit();
    try a.post("/echo", echo);
    try a.post("/greet", greet);
    try a.post("/json", json);
    try a.post("/hash", hash);
    try a.post("/tiny", tiny);
    return a;
}

// ---- a build that does not read zstd ----

test "without the flag a zstd body is a 415 that names the codings the server reads" {
    if (zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const refused = try client.send(&a, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\nContent-Length: 4\r\n\r\n\x28\xb5\x2f\xfd");
    try testing.expectEqual(@as(u16, 415), refused.status);
    try testing.expect(std.mem.indexOf(u8, refused.body, "decodes Content-Encoding: gzip and nothing else") != null);
    // A request with no body under the header says nothing about anything.
    const bodyless = try client.send(&a, "GET /nowhere HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), bodyless.status);
}

test "without the flag a route that names zstd reads the frame as it arrived, and the 415 lists only what is read" {
    if (zstdbody.enabled) return error.SkipZigTest;
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.with(bodyencodings.with(.{"zstd"})).post("/raw", echo);
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const frame = "\x28\xb5\x2f\xfd\x20\x00\x01\x00\x00";
    const got = try client.send(&a, "POST /raw HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\nContent-Length: 9\r\n\r\n" ++ frame);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings(frame, got.body);

    const refused = try client.send(&a, "POST /raw HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), refused.status);
    try testing.expectEqualStrings("identity, gzip, zstd", refused.header("Accept-Encoding").?);
}

// ---- a build that reads it ----

test "a zstd body is the plain bytes to c.body, c.json and a typed argument, whichever way it is framed" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 20_000);
    for ([_][]const u8{ try announced(s, text), try unannounced(s, text) }) |frame| {
        try testing.expect(frame.len < text.len / 3);
        const sized = try client.send(&a, try request(s, "/echo", frame));
        try testing.expectEqual(@as(u16, 200), sized.status);
        try testing.expectEqualSlices(u8, text, sized.body);
        const chunked = try client.send(&a, try chunkedRequest(s, "/echo", frame, 777));
        try testing.expectEqual(@as(u16, 200), chunked.status);
        try testing.expectEqualSlices(u8, text, chunked.body);
    }

    const greeting = "{\"name\":\"wati\",\"times\":3}";
    for ([_][]const u8{ "/json", "/greet" }) |path| {
        const typed = try client.send(&a, try request(s, path, try announced(s, greeting)));
        try testing.expectEqual(@as(u16, 200), typed.status);
        try testing.expectEqualStrings("wati", typed.body);
    }
}

test "a zstd body of no bytes is an empty body, and a frame of nothing is an empty body" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const none = try client.send(&a, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), none.status);
    try testing.expectEqualStrings("", none.body);
    const empty = try client.send(&a, try request(s, "/echo", try announced(s, "")));
    try testing.expectEqual(@as(u16, 200), empty.status);
    try testing.expectEqualStrings("", empty.body);
    const streamed_empty = try client.send(&a, try request(s, "/hash", try announced(s, "")));
    try testing.expectEqual(@as(u16, 200), streamed_empty.status);
    var empty_digest: [40]u8 = undefined;
    try testing.expectEqualStrings(digest(&empty_digest, ""), streamed_empty.body);
}

test "a frame announcing more than max_body is a 413 before anything is decoded or allocated" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const zeros = try s.alloc(u8, 1 << 20);
    @memset(zeros, 0);
    const frame = try announced(s, zeros);
    try testing.expect(frame.len < 200);

    // The unit: an allocator that fails on its first call is never asked.
    var pool: zstdbody.Pool = try .init(testing.allocator, 1, .{});
    defer pool.deinit(testing.allocator);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.BodyTooLarge, zstdbody.decode(failing.allocator(), &pool, frame, (1 << 20) - 1));
    try testing.expect(!failing.has_induced_failure);

    // And through the server, on both ways of reading it.
    var a = try app();
    defer a.deinit();
    a.limits.max_body = 64 * 1024;
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const over = try client.send(&a, try request(s, "/echo", frame));
    try testing.expectEqual(@as(u16, 413), over.status);
    const streamed = try client.send(&a, try request(s, "/hash", frame));
    try testing.expectEqual(@as(u16, 413), streamed.status);
}

test "a bomb that announces nothing is a 413 having held at most the ceiling, on c.body and bodyStream" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const zeros = try s.alloc(u8, 8 << 20);
    @memset(zeros, 0);
    const frame = try unannounced(s, zeros);
    try testing.expect(frame.len < 2_000);

    // The unit: the arena is a buffer that holds the context and a few
    // ceilings and nowhere near the frame's own size, so a decoder that
    // sized itself by the frame's bound (8 MB here) would be out of memory
    // and not over the ceiling.
    const limit = 64 * 1024;
    const room = try testing.allocator.alloc(u8, zstdbody.zstd.Decompressor.contextSize() * 2 + limit * 4);
    defer testing.allocator.free(room);
    var fixed: std.heap.FixedBufferAllocator = .init(room);
    var arena = std.heap.ArenaAllocator.init(fixed.allocator());
    try testing.expectError(error.BodyTooLarge, zstdbody.decode(arena.allocator(), null, frame, limit));

    var a = try app();
    defer a.deinit();
    a.limits.max_body = limit;
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    const whole = try client.send(&a, try request(s, "/echo", frame));
    try testing.expectEqual(@as(u16, 413), whole.status);
    const streamed = try client.send(&a, try request(s, "/hash", frame));
    try testing.expectEqual(@as(u16, 413), streamed.status);
    // The ceiling is the ceiling and not a byte under it: a body of exactly
    // `limit` is read.
    const exact = try s.alloc(u8, limit);
    @memset(exact, 'q');
    const ok = try client.send(&a, try request(s, "/hash", try unannounced(s, exact)));
    try testing.expectEqual(@as(u16, 200), ok.status);
    var want: [40]u8 = undefined;
    try testing.expectEqualStrings(digest(&want, exact), ok.body);
}

test "a frame that is corrupt, cut short, not zstd or fails its checksum is a 400 and the connection goes on" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 20_000);
    const good = try announced(s, text);

    const flipped = try s.dupe(u8, good);
    flipped[flipped.len - 1] ^= 0x01; // the checksum, which libzstd verifies
    const damaged = try s.dupe(u8, good);
    damaged[damaged.len / 2] ^= 0xff;
    const bad = [_][]const u8{
        flipped,
        damaged,
        good[0 .. good.len - 9],
        "{\"name\":\"wati\",\"times\":3}",
        good[0..3],
    };
    for (bad, 0..) |frame, i| {
        errdefer std.debug.print("frame {d} of {d}\n", .{ i, bad.len });
        for ([_][]const u8{ "/echo", "/hash", "/tiny" }) |path| {
            const got = try client.send(&a, try request(s, path, frame));
            try testing.expectEqual(@as(u16, 400), got.status);
            try testing.expect(got.keep_alive);
        }
    }
    // The same connection reads the next body.
    const next = try client.send(&a, try request(s, "/echo", good));
    try testing.expectEqual(@as(u16, 200), next.status);
    try testing.expectEqualSlices(u8, text, next.body);

    // And a second read of a body that failed is the same refusal, never the
    // compressed bytes (ADR 089).
    const twice = try client.send(&a, try request(s, "/echo", flipped));
    try testing.expectEqual(@as(u16, 400), twice.status);
}

test "bodyStream hands over the plain bytes in pieces of any size, one frame or several chunks" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 50_000);
    var want: [40]u8 = undefined;
    const expected = digest(&want, text);
    for ([_][]const u8{ try announced(s, text), try unannounced(s, text) }) |frame| {
        for ([_][]const u8{ "/hash", "/tiny" }) |path| {
            const whole = try client.send(&a, try request(s, path, frame));
            try testing.expectEqual(@as(u16, 200), whole.status);
            try testing.expectEqualStrings(expected, whole.body);
            const chunked = try client.send(&a, try chunkedRequest(s, path, frame, 100));
            try testing.expectEqual(@as(u16, 200), chunked.status);
            try testing.expectEqualStrings(expected, chunked.body);
        }
    }
}

test "a handler that reads part of a zstd body and stops leaves the connection good" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    const Part = struct {
        fn first(c: *Ctx) anyerror!void {
            var incoming = try c.bodyStream();
            var buf: [16]u8 = undefined;
            const part = (try incoming.read(&buf)).?;
            try c.sendText(200, part);
        }
    };
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.post("/first", Part.first);
    try a.post("/echo", echo);
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 30_000);
    const got = try client.send(&a, try request(s, "/first", try announced(s, text)));
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings(text[0..16], got.body);
    const next = try client.send(&a, try request(s, "/echo", try announced(s, "after")));
    try testing.expectEqual(@as(u16, 200), next.status);
    try testing.expectEqualStrings("after", next.body);
}

test "a route that names zstd reads the frame as it arrived, in a build that decodes it too" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.with(bodyencodings.with(.{"zstd"})).post("/raw", echo);
    try a.post("/echo", echo);
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 5_000);
    const frame = try announced(s, text);
    const raw = try client.send(&a, try request(s, "/raw", frame));
    try testing.expectEqual(@as(u16, 200), raw.status);
    try testing.expectEqualSlices(u8, frame, raw.body);
    // And the route beside it decodes.
    const decoded = try client.send(&a, try request(s, "/echo", frame));
    try testing.expectEqualSlices(u8, text, decoded.body);
}

test "the 415 for a coding the server does not read lists zstd beside gzip" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.with(bodyencodings.with(.{"snappy"})).post("/api", echo);
    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const refused = try client.send(&a, "POST /api HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), refused.status);
    try testing.expectEqualStrings("identity, gzip, zstd, snappy", refused.header("Accept-Encoding").?);

    var plain = try app();
    defer plain.deinit();
    const other = try client.send(&plain, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), other.status);
    try testing.expect(std.mem.indexOf(u8, other.body, "gzip or zstd") != null);
}

test "an App driven with no pool still decodes, from a context in the arena" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const text = try sample(s, 9_000);
    const out = try zstdbody.decode(s, null, try announced(s, text), 1 << 20);
    try testing.expectEqualSlices(u8, text, out);
    // And from a pool whose every slot is out: the same.
    var pool: zstdbody.Pool = try .init(testing.allocator, 1, .{});
    defer pool.deinit(testing.allocator);
    const held = pool.borrow(0).?;
    defer pool.give(held);
    const again = try zstdbody.decode(s, &pool, try announced(s, text), 1 << 20);
    try testing.expectEqualSlices(u8, text, again);
}

// ---- HTTP/2 ----

const zstd_field = [_]@import("hpack.zig").Field{.{ .name = "content-encoding", .value = "zstd" }};

test "on HTTP/2 a zstd body is decoded for c.body and as it is read, a bomb is a 413 and a bad frame a 400" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = try app();
    defer a.deinit();
    try a.with(bodyencodings.with(.{"zstd"})).post("/raw", echo);
    try a.resolveChains();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const text = try sample(s, 40_000);
    var want: [40]u8 = undefined;
    const expected = digest(&want, text);
    for ([_][]const u8{ try announced(s, text), try unannounced(s, text) }) |frame| {
        var whole = try h2test.roundTrip(&a, .{ .method = "POST", .path = "/echo", .fields = &zstd_field, .body = frame, .frame = 3_000 });
        defer whole.deinit();
        try testing.expectEqual(@as(u16, 200), whole.status);
        try testing.expectEqualSlices(u8, text, whole.body);
        var streamed = try h2test.roundTrip(&a, .{ .method = "POST", .path = "/hash", .fields = &zstd_field, .body = frame, .frame = 3_000 });
        defer streamed.deinit();
        try testing.expectEqual(@as(u16, 200), streamed.status);
        try testing.expectEqualStrings(expected, streamed.body);
    }

    // The route that named zstd gets the frame.
    const frame = try announced(s, text);
    var raw = try h2test.roundTrip(&a, .{ .method = "POST", .path = "/raw", .fields = &zstd_field, .body = frame });
    defer raw.deinit();
    try testing.expectEqualSlices(u8, frame, raw.body);

    const zeros = try s.alloc(u8, 4 << 20);
    @memset(zeros, 0);
    for ([_][]const u8{ try announced(s, zeros), try unannounced(s, zeros) }) |bomb_frame| {
        for ([_][]const u8{ "/echo", "/hash" }) |path| {
            var bomb = try h2test.roundTrip(&a, .{ .method = "POST", .path = path, .fields = &zstd_field, .body = bomb_frame });
            defer bomb.deinit();
            try testing.expectEqual(@as(u16, 413), bomb.status);
        }
    }

    const damaged = try s.dupe(u8, frame);
    damaged[damaged.len - 1] ^= 0x01;
    for ([_][]const u8{ "/echo", "/hash" }) |path| {
        var bad = try h2test.roundTrip(&a, .{ .method = "POST", .path = path, .fields = &zstd_field, .body = damaged });
        defer bad.deinit();
        try testing.expectEqual(@as(u16, 400), bad.status);
    }
}

fn grpcEcho(c: *Ctx) anyerror!void {
    try c.send(200, "application/grpc", (try c.body()).view());
}

test "a gRPC message under grpc-encoding zstd reaches the route decoded, and the refusals carry the codes" {
    if (!zstdbody.enabled) return error.SkipZigTest;
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.post("/test.Echo/Say", grpcEcho);
    a.limits.max_body = 100_000;
    try a.resolveChains();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const s = scratch.allocator();
    const encoding = [_]@import("hpack.zig").Field{.{ .name = "grpc-encoding", .value = "zstd" }};

    const text = try sample(s, 30_000);
    for ([_][]const u8{ try announced(s, text), try unannounced(s, text) }) |frame| {
        var client = try h2test.TestClient.init();
        defer client.deinit();
        try client.headersFor(1, "/test.Echo/Say", &encoding, false);
        try client.message(1, frame, true);
        var got = try h2test.converse(&a, &client);
        defer got.deinit();
        try testing.expectEqualSlices(u8, text, try got.message(1));
    }

    const zeros = try s.alloc(u8, 4 << 20);
    @memset(zeros, 0);
    const bad = [_]struct { frame: []const u8, code: []const u8 }{
        .{ .frame = try announced(s, zeros), .code = "8" },
        .{ .frame = try unannounced(s, zeros), .code = "8" },
        .{ .frame = "not a frame at all", .code = "13" },
    };
    for (bad) |case| {
        var client = try h2test.TestClient.init();
        defer client.deinit();
        try client.headersFor(1, "/test.Echo/Say", &encoding, false);
        try client.message(1, case.frame, true);
        var got = try h2test.converse(&a, &client);
        defer got.deinit();
        const trailers = try got.trailers(1);
        try testing.expectEqualStrings(case.code, h2test.Answer.value(trailers, "grpc-status").?);
    }

    // What this server does not read still says which it does.
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "snappy" }}, false);
    try client.message(1, "whatever", true);
    var got = try h2test.converse(&a, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("12", h2test.Answer.value(trailers, "grpc-status").?);
    try testing.expectEqualStrings("identity,gzip,zstd", h2test.Answer.value(trailers, "grpc-accept-encoding").?);
}

test "without the flag a gRPC message under grpc-encoding zstd is UNIMPLEMENTED" {
    if (zstdbody.enabled) return error.SkipZigTest;
    var a = App.init(testing.allocator);
    defer a.deinit();
    try a.post("/test.Echo/Say", grpcEcho);
    try a.resolveChains();
    var client = try h2test.TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "zstd" }}, false);
    try client.message(1, "whatever", true);
    var got = try h2test.converse(&a, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("12", h2test.Answer.value(trailers, "grpc-status").?);
    try testing.expectEqualStrings("identity,gzip", h2test.Answer.value(trailers, "grpc-accept-encoding").?);
}
