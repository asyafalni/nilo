//! gRPC over TLS: a listener with `.grpc` and `.tls` both set offers `h2` by
//! ALPN and nothing else ([ADR 0297](../docs/adr/0297-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! The client is tls.zig's own, the library the server runs on, because std's
//! TLS client sends no ALPN. That makes this evidence that the protocol was
//! chosen and the frames arrive, and not that two implementations agree about
//! TLS: `tls_live.zig` is where that is held, against std's client.
//!
//! Compiled only into a build with both TLS and gRPC in it.

const std = @import("std");
const tls = @import("tls");
const nilo = @import("http.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");

const testing = std.testing;

const cert_path = "http/testdata/tls/localhost.pem";
const key_path = "http/testdata/tls/localhost-key.pem";

fn hush() void {
    std.testing.log_level = .err;
}

fn echo(c: *nilo.Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

const Serving = struct {
    app: *nilo.App,
    bound: std.atomic.Value(bool) = .init(true),

    fn run(self: *Serving) void {
        self.app.tryListen(.{
            .port = 0,
            .threads = 1,
            .stop_on_signal = false,
            .grpc = true,
            .tls = .{ .cert = cert_path, .key = key_path },
        }) catch {
            self.bound.store(false, .release);
        };
    }

    fn waitForPort(self: *const Serving, io: std.Io) !u16 {
        for (0..300) |_| {
            if (self.app.boundPort()) |port| return port;
            if (!self.bound.load(.acquire)) return error.ServerNeverCameUp;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.ServerNeverCameUp;
    }
};

/// A TCP connection with a five-second receive limit, so a server that never
/// answers fails the test (std's reader panics on the timeout, see
/// `grpc_live.zig`) rather than leaving the suite waiting.
fn connect(io: std.Io, port: u16) !std.Io.net.Stream {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    const limit: std.posix.timeval = .{ .sec = 5, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&limit));
    return stream;
}

fn handshake(io: std.Io, r: *std.Io.Reader, w: *std.Io.Writer, alpn: []const []const u8) !tls.Connection {
    var rng_source: std.Random.IoSource = .{ .io = io };
    return tls.client(r, w, .{
        .rng = rng_source.interface(),
        .now = std.Io.Clock.real.now(io),
        .host = "localhost",
        // The suite's self-signed certificate: what is under test is the
        // protocol chosen, and `tls_live.zig` holds the certificate check.
        .root_ca = .empty,
        .insecure_skip_verify = true,
        .alpn_protocols = alpn,
    });
}

test "a gRPC listener with TLS offers h2, and answers a unary call through it" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    var stream = try connect(io, port);
    defer stream.close(io);
    var raw_in: [tls.input_buffer_len]u8 = undefined;
    var raw_out: [tls.output_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &raw_in);
    var writer = stream.writer(io, &raw_out);
    var conn = try handshake(io, &reader.interface, &writer.interface, &.{ "h2", "http/1.1" });
    try testing.expectEqualStrings("h2", conn.alpn_protocol.?);

    var clear_in: [16 * 1024]u8 = undefined;
    var clear_out: [4 * 1024]u8 = undefined;
    var cr = conn.reader(&clear_in);
    var cw = conn.writer(&clear_out);
    const w = &cw.interface;

    var block_buf: [256]u8 = undefined;
    var block: std.Io.Writer = .fixed(&block_buf);
    try hpack.writeInt(&block, 0x80, 7, 3); // :method POST
    try hpack.writeInt(&block, 0x80, 7, 7); // :scheme https
    try hpack.writeLiteral(&block, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block, ":authority", "localhost");
    try hpack.writeLiteral(&block, "content-type", "application/grpc");
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try h2.writeHeaderBlock(w, 1, block.buffered(), false, h2.default_max_frame);
    const message = "through tls";
    try h2.writeHeader(w, 5 + message.len, .data, h2.Flags.end_stream, 1);
    try w.writeAll(&.{ 0, 0, 0, 0, message.len });
    try w.writeAll(message);
    try w.flush();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var decoder = hpack.Decoder.init(gpa);
    defer decoder.deinit();
    var got: std.ArrayList(u8) = .empty;
    var status: ?[]const u8 = null;
    while (true) {
        const head = h2.Header.parse(try cr.interface.takeArray(h2.header_len));
        const payload = try cr.interface.take(head.len);
        if (head.stream != 1) continue;
        if (head.type == .data) try got.appendSlice(arena.allocator(), payload);
        if (head.type == .headers) {
            var fields: std.ArrayList(hpack.Field) = .empty;
            _ = try decoder.decode(payload, arena.allocator(), &fields, 1 << 16);
            for (fields.items) |f| if (std.mem.eql(u8, f.name, "grpc-status")) {
                status = f.value;
            };
            if (head.has(h2.Flags.end_stream)) break;
        }
    }
    try testing.expectEqualStrings("0", status.?);
    try testing.expectEqualStrings(message, got.items[5..]);
}

test "a client that offers only HTTP/1.1 to a gRPC listener with TLS is refused in the handshake" {
    hush();
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.post("/test.Echo/Say", echo);

    var serving: Serving = .{ .app = &app };
    const thread = try std.Thread.spawn(.{}, Serving.run, .{&serving});
    defer {
        if (serving.bound.load(.acquire)) app.shutdown();
        thread.join();
    }
    const port = try serving.waitForPort(io);

    var stream = try connect(io, port);
    defer stream.close(io);
    var raw_in: [tls.input_buffer_len]u8 = undefined;
    var raw_out: [tls.output_buffer_len]u8 = undefined;
    var reader = stream.reader(io, &raw_in);
    var writer = stream.writer(io, &raw_out);
    if (handshake(io, &reader.interface, &writer.interface, &.{"http/1.1"})) |_| {
        return error.HandshakeShouldHaveFailed;
    } else |_| {}
}
