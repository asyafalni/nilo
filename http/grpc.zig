//! gRPC over h2c: one listener's connections, spoken as HTTP/2 with prior
//! knowledge, each unary call handed to the App as the HTTP/1.1 request it
//! would have been ([ADR 0297](../docs/adr/0297-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! **A gRPC method is an ordinary route.** `POST /package.Service/Method`,
//! registered with `app.post`, reached through the same router, middleware,
//! services and logger as every other route. What this file does is carry a
//! call across: the HTTP/2 frames of one stream become `POST <path>` with
//! the call's metadata as headers and its one message as the body, the
//! length prefix and any gzip already taken off; and what the route answers
//! goes back as HEADERS, one DATA frame's worth of message per frame, and
//! trailers carrying `grpc-status`. A route that fails with a status is a
//! call that fails with the gRPC code that status means, and a path no route
//! answers is `UNIMPLEMENTED`, which is what the gRPC spec asks of a method a
//! server does not have.
//!
//! **Unary only.** A call carries one message each way. Streaming calls hold
//! a stream open for their whole life, which is the one shape that costs a
//! fiber for as long as it lasts, and they wait for a caller (ADR 0297).
//!
//! **One fiber reads and writes the socket; each call runs on a fiber of its
//! own.** The connection's fiber parses frames, collects a call's message,
//! and hands the finished call to `bulkhead.spawn`. The call's fiber runs
//! the route into memory and hands the answer back through a queue and a
//! `Waker.post`, and the connection's fiber writes it, as far as the flow-
//! control windows allow. So no two fibers ever write the socket, and a
//! slow route never holds up the frames of another call. A call in flight
//! costs a fiber, 4,547 bytes and the stack its route touches, which is what
//! a request in flight on HTTP/1.1 costs already
//! ([`bench/result/http.md`](../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost)).
//! With no server running `spawn` has nowhere to put one, and the call runs
//! on the connection's own fiber instead, which is how the tests below drive
//! a whole conversation through buffers in memory.
//!
//! **What a hostile client gets is bounded, and each bound is a test.** The
//! calls a connection may have in flight are capped, and a reset call still
//! counts until its route finishes, so resetting as fast as it opens (rapid
//! reset, CVE-2023-44487) gains a client nothing; one that keeps opening past
//! the cap is sent away. A header block is bounded however many CONTINUATION
//! frames it arrives in, and so is the header list it decodes to. A message
//! is bounded by `max_body`, compressed or not. PINGs and SETTINGS without a
//! call between them are counted, and a flood is sent away. A client that
//! stops reading while an answer waits on its window is cut off at the write
//! deadline.

const std = @import("std");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const encoded = @import("encoded.zig");
const core = @import("nilo_core");

/// What a gRPC connection asks of the App, handed over by `app.zig` rather
/// than named here. This file sits outside the App's core (`http_core` in
/// build.zig), and the App passing itself in as these few things is what
/// keeps it there: routing and dispatch stay the core's, and this file only
/// translates.
pub const Host = struct {
    ptr: *anyopaque,
    gpa: std.mem.Allocator,
    stop: *const bulkhead.Stop,
    max_body: usize,
    /// Whether a `POST` to this path reaches a route.
    routes: *const fn (ptr: *anyopaque, path: []const u8) bool,
    /// `App.handleRequest`, with no waker and no read limits: a call's fiber
    /// never reads from the socket, so there is nothing for either to arm.
    /// `until_ns` is the call's `grpc-timeout` as a `monotonicNanos` reading,
    /// or 0, and it is the request's deadline (ADR 0133).
    handle: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        lifetime: *core.Lifetime,
        in_flight: *fail.InFlight,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
        peer: bulkhead.Peer,
        until_ns: u64,
    ) void,
};

/// How many calls one connection may have in flight at once, advertised as
/// `SETTINGS_MAX_CONCURRENT_STREAMS`. A call is a fiber and the stack its
/// route touches, so this times that is the most one connection can hold:
/// about 1.7 MB on a route that reads a database (ADR 0297). Every client
/// measured queues past it rather than failing, so it caps what a connection
/// costs and never what it can do.
pub const max_streams = 100;

/// The most a header list may weigh by RFC 7541's count, advertised as
/// `SETTINGS_MAX_HEADER_LIST_SIZE`. The same sixteen kilobytes an HTTP/1.1
/// head may be (`Options.read_buffer`).
pub const max_header_list = 16 * 1024;

/// The most one header block may be on the wire, however many CONTINUATION
/// frames carry it. Four times the list: a block larger than the list it
/// decodes to is padding or a table being filled for nothing.
const max_header_block = 4 * max_header_list;

/// Calls refused for being past the cap before the connection is sent away.
/// A client honouring the setting is refused at most the calls it sent
/// before reading it, a handful; one that keeps opening is not waiting.
const max_refused = 1000;

/// PING and SETTINGS frames in a row, with no call between them, before the
/// connection is sent away. Each one is answered, so a flood is a client
/// making this side write.
const max_control_run = 1000;

/// How long a connection with nothing in flight waits before handing its
/// pages back, the way an HTTP/1.1 connection does between requests
/// (`serve.idle_peek_ms`).
const idle_peek_ms = 200;

/// How much of a finished call's arena a spare stream keeps for the next one.
/// A unary call with a small message stays inside it, so a busy connection's
/// calls stop reaching the general-purpose allocator at all.
const spare_arena_keep = 4096;

/// What one listener speaking gRPC runs for each connection, in place of
/// `serve.handleConnection`. Returns when the client has gone, the
/// connection was sent away, or it sat idle past `idle_timeout_ms`.
pub fn serveConnection(
    app: Host,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
) void {
    const shared = Shared.create(app.gpa, waker) catch return;
    var conn: Conn = .{
        .app = app,
        .gpa = app.gpa,
        .in = in,
        .out = out,
        .deadlines = deadlines,
        .waker = waker,
        .peer = peer,
        .shared = shared,
        .decoder = hpack.Decoder.init(app.gpa),
    };
    defer conn.deinit();
    deadlines.armWrite();
    conn.run();
}

/// What a call's fiber and the connection's fiber share: the queue of
/// answered calls, and whether the connection is still there to write them.
///
/// **On the heap and counted**, because a call's fiber can outlive the
/// connection: a client that hangs up while a route is running leaves that
/// route to finish, and when it does there has to be something to tell it
/// nobody is listening. The last one out frees it.
const Shared = struct {
    gpa: std.mem.Allocator,
    waker: bulkhead.Waker,
    lock: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(1),
    /// Answered calls, oldest first, not yet taken by the connection.
    head: ?*Stream = null,
    tail: ?*Stream = null,
    /// Set once by the connection on its way out. After it, a call's fiber
    /// frees its own stream rather than queueing it, and never posts.
    closed: bool = false,
    /// Calls whose fiber has not handed them back yet.
    running: std.atomic.Value(u32) = .init(0),

    fn create(gpa: std.mem.Allocator, waker: bulkhead.Waker) !*Shared {
        const s = try gpa.create(Shared);
        s.* = .{ .gpa = gpa, .waker = waker };
        return s;
    }

    /// A spin, not a lock that parks: what is inside is a pointer or two, and
    /// the waiting it would save costs more than it does. The same trade the
    /// cache makes, for the same reason (ADR 0138).
    fn acquire(s: *Shared) void {
        while (s.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(s: *Shared) void {
        s.lock.store(false, .release);
    }

    fn retain(s: *Shared) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    fn drop(s: *Shared) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) s.gpa.destroy(s);
    }

    /// A call's fiber, done. Queued for the connection and the connection
    /// woken, or freed if there is no connection any more.
    fn finish(s: *Shared, stream: *Stream) void {
        s.acquire();
        if (s.closed) {
            s.release();
            stream.destroy();
        } else {
            stream.next = null;
            if (s.tail) |t| t.next = stream else s.head = stream;
            s.tail = stream;
            s.waker.post();
            s.release();
        }
        _ = s.running.fetchSub(1, .release);
        s.drop();
    }

    fn takeAll(s: *Shared) ?*Stream {
        s.acquire();
        defer s.release();
        const all = s.head;
        s.head = null;
        s.tail = null;
        return all;
    }
};

/// One call, from its HEADERS frame to the last frame of its answer.
const Stream = struct {
    id: u31,
    gpa: std.mem.Allocator,
    /// Everything the call reads and writes, freed in one go when its answer
    /// has gone out.
    arena: std.heap.ArenaAllocator,
    state: State = .headers,
    /// The header block as it arrives, then the fields it decodes to.
    block: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(hpack.Field) = .empty,
    headers_over_limit: bool = false,
    /// The HEADERS frame said END_STREAM and its block continues: the call
    /// starts when the last CONTINUATION arrives.
    ends_with_headers: bool = false,
    /// The message as it arrives, length prefix and all.
    body: std.ArrayList(u8) = .empty,
    body_over_limit: bool = false,
    /// When the client stops waiting, from `grpc-timeout`, or 0.
    until_ns: u64 = 0,
    /// Bytes read since this stream's window was last topped up.
    unacked: u32 = 0,
    /// What may be sent on this stream before the client says more.
    send_window: i64,
    /// The client reset it. Its route still runs to the end, because nothing
    /// can stop it midway, and still counts against the cap until it does;
    /// its answer is thrown away.
    reset: bool = false,

    // The answer, filled by the call's fiber.
    head_block: []const u8 = "",
    data: []const u8 = "",
    trailers: []const u8 = "",
    /// Everything is in `head_block`, END_STREAM included: a call that failed
    /// before it had anything to say (§ "Trailers-Only" of the gRPC spec).
    trailers_only: bool = false,
    head_sent: bool = false,
    data_sent: usize = 0,

    // For the call's fiber.
    app: Host,
    peer: bulkhead.Peer,
    shared: *Shared,
    next: ?*Stream = null,

    const State = enum { headers, body, running, writing };

    fn create(gpa: std.mem.Allocator, id: u31, app: Host, peer: bulkhead.Peer, shared: *Shared, send_window: i64) !*Stream {
        const s = try gpa.create(Stream);
        s.* = .{
            .id = id,
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .send_window = send_window,
            .app = app,
            .peer = peer,
            .shared = shared,
        };
        return s;
    }

    fn destroy(s: *Stream) void {
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// Ready for the connection's next call: the arena keeps up to
    /// `spare_arena_keep` bytes and everything else is as `create` leaves it.
    fn recycle(s: *Stream) void {
        _ = s.arena.reset(.{ .retain_with_limit = spare_arena_keep });
        const kept = .{ s.gpa, s.arena, s.app, s.peer, s.shared };
        s.* = .{ .id = 0, .gpa = kept[0], .arena = kept[1], .send_window = 0, .app = kept[2], .peer = kept[3], .shared = kept[4] };
    }

    fn field(s: *const Stream, name: []const u8) ?[]const u8 {
        for (s.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }
};

/// Why a connection is being sent away; `goawayFor` says which GOAWAY.
const ConnError = error{ Protocol, FrameSize, FlowControl, Compression, Calm, Internal };

const Conn = struct {
    app: Host,
    gpa: std.mem.Allocator,
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    deadlines: bulkhead.Deadlines,
    waker: bulkhead.Waker,
    peer: bulkhead.Peer,
    shared: *Shared,
    decoder: hpack.Decoder,

    /// Every call this connection holds: collecting, running or being
    /// written. Its length is what the cap counts.
    streams: std.ArrayList(*Stream) = .empty,
    /// The stream whose header block is not finished: only CONTINUATION
    /// frames for it may come next (§6.10).
    continuing: ?*Stream = null,
    last_stream: u31 = 0,

    /// What the client said, and where its windows stand.
    peer_window: i64 = h2.default_window,
    peer_max_frame: u32 = h2.default_max_frame,
    send_window: i64 = h2.default_window,
    /// Bytes of DATA read since the connection's window was last topped up.
    unacked: u32 = 0,

    goaway_sent: bool = false,
    peer_goaway: bool = false,
    peer_gone: bool = false,
    released: bool = false,
    refused: u32 = 0,
    control_run: u32 = 0,
    /// When the oldest answer started waiting on a window, or 0.
    blocked_since: u64 = 0,
    /// Streams whose calls are over, kept for the next ones: at most
    /// `max_streams` of them, and none once the connection waits with no call
    /// in flight, so they cost a busy connection what its calls already held
    /// and a quiet one nothing.
    spare: ?*Stream = null,
    spares: u32 = 0,

    fn newStream(c: *Conn, id: u31) !*Stream {
        if (c.spare) |s| {
            c.spare = s.next;
            c.spares -= 1;
            s.next = null;
            s.id = id;
            s.send_window = c.peer_window;
            return s;
        }
        return Stream.create(c.gpa, id, c.app, c.peer, c.shared, c.peer_window);
    }

    fn dropSpares(c: *Conn) void {
        while (c.spare) |s| {
            c.spare = s.next;
            s.destroy();
        }
        c.spares = 0;
    }

    fn deinit(c: *Conn) void {
        // The calls still running keep `shared` alive and free themselves;
        // everything this side holds goes now.
        c.shared.acquire();
        c.shared.closed = true;
        var queued = c.shared.head;
        c.shared.head = null;
        c.shared.tail = null;
        c.shared.release();
        while (queued) |s| {
            queued = s.next;
            c.forget(s);
        }
        for (c.streams.items) |s| if (s.state != .running) s.destroy();
        c.streams.deinit(c.gpa);
        c.dropSpares();
        c.decoder.deinit();
        c.shared.drop();
    }

    fn run(c: *Conn) void {
        c.deadlines.armHeader();
        const got = c.in.takeArray(h2.preface.len) catch return;
        // Not HTTP/2: most likely HTTP/1.1 on the wrong port, which is said
        // the only way that client can read, and the connection closed.
        if (!std.mem.eql(u8, got, h2.preface)) {
            c.out.writeAll("HTTP/1.1 505 HTTP Version Not Supported\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch {};
            c.out.flush() catch {};
            return;
        }
        h2.writeSettings(c.out, &.{
            .{ .header_table_size, 0 },
            .{ .enable_push, 0 },
            .{ .max_concurrent_streams, max_streams },
            .{ .max_header_list_size, max_header_list },
        }) catch return;
        c.out.flush() catch return;

        while (true) {
            c.writeReady() catch break;
            if (c.goaway_sent or c.peer_goaway) {
                if (c.streams.items.len == 0) break;
            }
            if (!c.goaway_sent and c.app.stop.isRequested()) {
                c.goaway(.no_error) catch break;
                continue;
            }
            if (c.in.bufferedLen() == 0) {
                // Everything answered since the last wait goes out in one
                // write, rather than a write for every frame read (ADR 0297).
                c.out.flush() catch break;
                // Spares are for a connection with calls in flight. One that
                // is about to wait with none gives them back now rather than
                // at the idle release: held for those 200ms, a burst of
                // connections measured 5 MB of heap the allocator then kept.
                if (c.streams.items.len == 0) c.dropSpares();
                switch (c.wait()) {
                    .posted => continue,
                    .again => continue,
                    .stop => break,
                    .readable => {},
                }
            }
            c.released = false;
            c.readFrame() catch |err| {
                // Gone is a client that stopped sending, which may still be
                // reading: what it is owed is written on the way out.
                if (err != error.Gone) c.goawayFor(err);
                break;
            };
        }
        c.windDown();
    }

    const Waited = enum { readable, posted, again, stop };

    fn wait(c: *Conn) Waited {
        if (c.streams.items.len != 0) {
            // Something is in flight: wait as long as it takes, for the
            // client or for an answer, unless an answer is stuck on a
            // window, which gets the write deadline and no longer.
            const limit: u32 = if (c.blocked_since != 0) c.writeLimitMs() else 0;
            return switch (c.waker.wait(limit)) {
                .readable => .readable,
                .posted => .posted,
                .timed_out => if (c.blocked_since != 0) .stop else .again,
                .closed => blk: {
                    c.peer_gone = true;
                    break :blk .stop;
                },
            };
        }
        if (!c.released) {
            switch (c.waker.wait(idle_peek_ms)) {
                .readable => return .readable,
                .posted => return .posted,
                .closed => {
                    c.peer_gone = true;
                    return .stop;
                },
                .timed_out => {
                    // Quiet: hand the pages back, the way an idle HTTP/1.1
                    // connection does, and wait again from this frame.
                    bulkhead.releaseIdlePages(c.in, c.out);
                    c.dropSpares();
                    c.streams.clearAndFree(c.gpa);
                    c.waker.releaseStack();
                    c.released = true;
                    return .again;
                },
            }
        }
        return switch (c.waker.wait(c.deadlines.idle_ms)) {
            .readable => .readable,
            .posted => .posted,
            .closed => blk: {
                c.peer_gone = true;
                break :blk .stop;
            },
            .timed_out => blk: {
                // Idle past its limit: said with a GOAWAY, which a client
                // reads as "open a new connection next time".
                c.goaway(.no_error) catch {};
                break :blk .stop;
            },
        };
    }

    fn writeLimitMs(c: *const Conn) u32 {
        return if (c.deadlines.write_ms == 0) 30_000 else c.deadlines.write_ms;
    }

    /// Wait for the calls still running, then write what they answered if
    /// there is anybody left to read it.
    fn windDown(c: *Conn) void {
        while (c.shared.running.load(.acquire) != 0) {
            bulkhead.sleep(1) catch break;
            if (!c.peer_gone) c.flushReady() catch {
                c.peer_gone = true;
            };
        }
        if (!c.peer_gone) c.flushReady() catch {};
    }

    fn flushReady(c: *Conn) !void {
        try c.writeReady();
        try c.out.flush();
    }

    fn goaway(c: *Conn, code: h2.ErrorCode) !void {
        if (c.goaway_sent) return;
        c.goaway_sent = true;
        try h2.writeGoaway(c.out, c.last_stream, code);
        try c.out.flush();
    }

    fn goawayFor(c: *Conn, err: ReadError) void {
        const code: h2.ErrorCode = switch (err) {
            error.Gone => return,
            error.Protocol => .protocol_error,
            error.FrameSize => .frame_size_error,
            error.FlowControl => .flow_control_error,
            error.Compression => .compression_error,
            error.Calm => .enhance_your_calm,
            error.Internal => .internal_error,
        };
        c.goaway(code) catch {};
    }

    // ---- reading ----

    const ReadError = ConnError || error{Gone};

    fn take(c: *Conn, n: usize) ReadError![]u8 {
        return c.in.take(n) catch return error.Gone;
    }

    fn discard(c: *Conn, n: usize) ReadError!void {
        c.in.discardAll(n) catch return error.Gone;
    }

    fn readFrame(c: *Conn) ReadError!void {
        c.deadlines.armBody();
        const head = h2.Header.parse(c.in.takeArray(h2.header_len) catch return error.Gone);
        if (head.len > h2.default_max_frame) return error.FrameSize;

        if (c.continuing) |s| {
            if (head.type != .continuation or head.stream != s.id) return error.Protocol;
        }

        switch (head.type) {
            .data => try c.onData(head),
            .headers => try c.onHeaders(head),
            .continuation => {
                const s = c.continuing orelse return error.Protocol;
                try c.appendBlockBytes(s, head.len);
                if (head.has(h2.Flags.end_headers)) try c.headersDone(s);
            },
            .settings => try c.onSettings(head),
            .ping => {
                if (head.stream != 0) return error.Protocol;
                if (head.len != 8) return error.FrameSize;
                const data = (try c.take(8))[0..8];
                if (!head.has(h2.Flags.ack)) {
                    try c.control();
                    h2.writePingAck(c.out, data) catch return error.Gone;
                }
            },
            .window_update => try c.onWindowUpdate(head),
            .rst_stream => {
                if (head.stream == 0) return error.Protocol;
                if (head.len != 4) return error.FrameSize;
                try c.discard(4);
                if (head.stream > c.last_stream) return error.Protocol;
                if (c.find(head.stream)) |s| c.onReset(s);
            },
            .priority => {
                if (head.stream == 0) return error.Protocol;
                if (head.len != 5) return error.FrameSize;
                try c.discard(5);
            },
            .goaway => {
                if (head.stream != 0) return error.Protocol;
                if (head.len < 8) return error.FrameSize;
                try c.discard(head.len);
                c.peer_goaway = true;
            },
            // A client may not push (§8.4).
            .push_promise => return error.Protocol,
            // Unknown frame types are ignored (§5.5).
            _ => try c.discard(head.len),
        }
    }

    /// A PING or a SETTINGS with no call since the last one.
    fn control(c: *Conn) ReadError!void {
        c.control_run += 1;
        if (c.control_run > max_control_run) return error.Calm;
    }

    /// Strip the padding length off the front of a padded frame, and say how
    /// much padding follows the content.
    fn padding(c: *Conn, head: h2.Header, len: *usize) ReadError!usize {
        if (!head.has(h2.Flags.padded)) return 0;
        if (len.* < 1) return error.Protocol;
        const pad = (try c.take(1))[0];
        len.* -= 1;
        if (pad > len.*) return error.Protocol;
        len.* -= pad;
        return pad;
    }

    fn onHeaders(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream == 0 or head.stream % 2 == 0) return error.Protocol;
        var len: usize = head.len;
        const pad = try c.padding(head, &len);
        if (head.has(h2.Flags.priority)) {
            if (len < 5) return error.Protocol;
            try c.discard(5);
            len -= 5;
        }

        // Trailers from the client, on a call still sending its message.
        if (c.find(head.stream)) |s| {
            if (s.state != .body) return error.Protocol;
            if (!head.has(h2.Flags.end_stream)) return error.Protocol;
            s.block.clearRetainingCapacity();
            try c.appendBlockBytes(s, len);
            try c.discard(pad);
            s.state = .headers;
            s.ends_with_headers = true;
            if (head.has(h2.Flags.end_headers)) try c.headersDone(s) else c.continuing = s;
            return;
        }
        if (head.stream <= c.last_stream) return error.Protocol;
        c.last_stream = head.stream;
        c.control_run = 0;

        const s = c.newStream(head.stream) catch return error.Internal;
        c.streams.append(c.gpa, s) catch {
            s.destroy();
            return error.Internal;
        };
        // Read before anything else is decided: the block has to be decoded
        // whatever happens to the call, or the table falls out of step.
        try c.appendBlockBytes(s, len);
        try c.discard(pad);
        s.ends_with_headers = head.has(h2.Flags.end_stream);
        if (head.has(h2.Flags.end_headers)) try c.headersDone(s) else c.continuing = s;
    }

    fn appendBlockBytes(c: *Conn, s: *Stream, len: usize) ReadError!void {
        if (s.block.items.len + len > max_header_block) return error.Calm;
        const dest = s.block.addManyAsSlice(s.arena.allocator(), len) catch return error.Internal;
        c.in.readSliceAll(dest) catch return error.Gone;
    }

    /// The header block is whole: decode it, and either wait for the message
    /// or, if the client has nothing more to send, start the call.
    fn headersDone(c: *Conn, s: *Stream) ReadError!void {
        c.continuing = null;
        const end_stream = s.ends_with_headers;
        const is_trailers = s.fields.items.len != 0;
        const arena = s.arena.allocator();
        var scratch: std.ArrayList(hpack.Field) = .empty;
        const into = if (is_trailers) &scratch else &s.fields;
        const decoded = c.decoder.decode(s.block.items, arena, into, max_header_list) catch |err| switch (err) {
            error.Compression => return error.Compression,
            error.OutOfMemory => return error.Internal,
        };
        if (decoded.over_limit) s.headers_over_limit = true;
        if (is_trailers) {
            s.state = .body;
            return c.dispatch(s);
        }

        // Past the cap: refused, which a client reads as "try again", and
        // counted, because a client that keeps doing it is not waiting.
        if (c.streams.items.len > max_streams) {
            c.refused += 1;
            if (c.refused > max_refused) return error.Calm;
            const id = s.id;
            c.forget(s);
            h2.writeRstStream(c.out, id, .refused_stream) catch return error.Gone;
            return;
        }
        s.state = .body;
        if (end_stream) try c.dispatch(s);
    }

    fn onData(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream == 0) return error.Protocol;
        var len: usize = head.len;
        // The whole frame counts against the window, padding included (§6.9).
        try c.consumed(head.len);
        const pad = try c.padding(head, &len);
        const s = c.find(head.stream) orelse {
            if (head.stream > c.last_stream) return error.Protocol;
            // A call already answered, refused or reset: the bytes are
            // thrown away and nothing is said. §5.1 has a stream this side
            // reset ignore what was already in flight, and an RST for every
            // frame would be a client making this side write, uncounted.
            // The zig build fuzz -- --frames property found it (ADR 0297).
            try c.discard(len + pad);
            return;
        };
        if (s.state != .body) {
            try c.discard(len + pad);
            if (s.state == .headers) return error.Protocol;
            return;
        }
        if (s.body_over_limit or s.body.items.len + len > c.app.max_body + 5) {
            // Past `max_body`: read and dropped, so the connection stays in
            // step, and answered when the client says it is done.
            s.body_over_limit = true;
            try c.discard(len);
        } else {
            const dest = s.body.addManyAsSlice(s.arena.allocator(), len) catch return error.Internal;
            c.in.readSliceAll(dest) catch return error.Gone;
        }
        try c.discard(pad);
        if (head.has(h2.Flags.end_stream)) {
            try c.dispatch(s);
        } else {
            s.unacked += head.len;
            if (s.unacked >= h2.default_window / 2) {
                h2.writeWindowUpdate(c.out, s.id, @intCast(s.unacked)) catch return error.Gone;
                s.unacked = 0;
            }
        }
    }

    /// Top the connection's window back up once half of it has been read.
    fn consumed(c: *Conn, n: usize) ReadError!void {
        c.unacked += @intCast(n);
        if (c.unacked >= h2.default_window / 2) {
            h2.writeWindowUpdate(c.out, 0, @intCast(c.unacked)) catch return error.Gone;
            c.unacked = 0;
        }
    }

    fn onSettings(c: *Conn, head: h2.Header) ReadError!void {
        if (head.stream != 0) return error.Protocol;
        if (head.has(h2.Flags.ack)) {
            if (head.len != 0) return error.FrameSize;
            // The client has read ours: the table it may use is now 0.
            c.decoder.allow(0);
            return;
        }
        if (head.len % 6 != 0) return error.FrameSize;
        try c.control();
        var left = head.len / 6;
        while (left > 0) : (left -= 1) {
            const pair = try c.take(6);
            const id: h2.Setting = @enumFromInt(std.mem.readInt(u16, pair[0..2], .big));
            const value = std.mem.readInt(u32, pair[2..6], .big);
            switch (id) {
                .initial_window_size => {
                    if (value > h2.max_window) return error.FlowControl;
                    const delta = @as(i64, value) - c.peer_window;
                    c.peer_window = value;
                    for (c.streams.items) |s| s.send_window += delta;
                },
                .max_frame_size => {
                    if (value < h2.default_max_frame or value > 16_777_215) return error.Protocol;
                    c.peer_max_frame = value;
                },
                .enable_push => if (value > 1) return error.Protocol,
                // What the client's table for *our* headers may be. This side
                // never indexes, so there is nothing to shrink.
                else => {},
            }
        }
        h2.writeSettingsAck(c.out) catch return error.Gone;
    }

    fn onWindowUpdate(c: *Conn, head: h2.Header) ReadError!void {
        if (head.len != 4) return error.FrameSize;
        const bytes = try c.take(4);
        const increment = std.mem.readInt(u32, bytes[0..4], .big) & 0x7fff_ffff;
        if (head.stream == 0) {
            if (increment == 0) return error.Protocol;
            c.send_window += increment;
            if (c.send_window > h2.max_window) return error.FlowControl;
            return;
        }
        const s = c.find(head.stream) orelse return;
        if (increment == 0) {
            h2.writeRstStream(c.out, s.id, .protocol_error) catch return error.Gone;
            c.onReset(s);
            return;
        }
        s.send_window += increment;
        if (s.send_window > h2.max_window) {
            h2.writeRstStream(c.out, s.id, .flow_control_error) catch return error.Gone;
            c.onReset(s);
        }
    }

    fn onReset(c: *Conn, s: *Stream) void {
        switch (s.state) {
            // Its fiber owns it until it hands it back; the answer is
            // dropped then.
            .running => s.reset = true,
            else => {
                c.remove(s);
                s.destroy();
            },
        }
    }

    fn find(c: *const Conn, id: u31) ?*Stream {
        for (c.streams.items) |s| if (s.id == id) return s;
        return null;
    }

    fn remove(c: *Conn, s: *Stream) void {
        for (c.streams.items, 0..) |x, i| if (x == s) {
            _ = c.streams.orderedRemove(i);
            return;
        };
    }

    /// Take a stream out of the connection's hands for good.
    fn forget(c: *Conn, s: *Stream) void {
        c.remove(s);
        if (c.spares >= max_streams or c.goaway_sent) return s.destroy();
        s.recycle();
        s.next = c.spare;
        c.spare = s;
        c.spares += 1;
    }

    // ---- starting a call ----

    /// The client has sent everything. Check the call, take its message out
    /// of its framing, and run it.
    fn dispatch(c: *Conn, s: *Stream) ReadError!void {
        const a = s.arena.allocator();
        if (s.headers_over_limit) return c.answerNow(s, 8, "the call's metadata is larger than this server reads");
        if (s.body_over_limit) return c.answerNow(s, 8, "the message is larger than this server's max_body");

        const method = s.field(":method") orelse return c.malformed(s);
        const path = s.field(":path") orelse return c.malformed(s);
        if (!std.mem.eql(u8, method, "POST")) return c.malformed(s);
        if (path.len == 0 or path[0] != '/') return c.malformed(s);
        for (s.fields.items) |f| if (!validField(f)) return c.malformed(s);

        const content_type = s.field("content-type") orelse "";
        if (!std.mem.startsWith(u8, content_type, "application/grpc")) {
            // Not a gRPC call at all: the spec says 415, and nothing else.
            s.head_block = try c.headerBlock(a, &.{
                .{ .name = ":status", .value = "415" },
            });
            s.trailers_only = true;
            return c.ready(s);
        }
        if (!c.app.routes(c.app.ptr, path))
            return c.answerNow(s, 12, "no route answers this method");
        if (s.field("grpc-timeout")) |text| {
            const ns = timeoutNanos(text) orelse
                return c.answerNow(s, 3, "grpc-timeout is not a number of up to eight digits and a unit");
            s.until_ns = bulkhead.monotonicNanos() +| ns;
        }

        // Exactly one message: a five-byte prefix and what it says follows.
        const body = s.body.items;
        if (body.len < 5) return c.answerNow(s, 13, "a unary call carries exactly one message");
        const compressed = body[0];
        const len = std.mem.readInt(u32, body[1..5], .big);
        if (compressed > 1 or len != body.len - 5)
            return c.answerNow(s, 13, "a unary call carries exactly one message");
        var message: []const u8 = body[5..];
        if (compressed == 1) {
            const encoding = s.field("grpc-encoding") orelse "identity";
            if (!std.mem.eql(u8, encoding, "gzip"))
                return c.answerNow(s, 12, "the message is compressed with an encoding this server does not read");
            message = encoded.inflate(a, message, c.app.max_body) catch |err| switch (err) {
                error.BodyTooLarge => return c.answerNow(s, 8, "the message is larger than this server's max_body"),
                else => return c.answerNow(s, 13, "the message's gzip could not be read"),
            };
        }
        s.body.items = @constCast(message);
        s.state = .running;
        _ = s.shared.running.fetchAdd(1, .acquire);
        s.shared.retain();
        bulkhead.spawn(runCall, .{ s, true }) catch |err| switch (err) {
            // No server: a test driving the connection through buffers. The
            // call runs here, and is queued exactly as a fiber would queue it.
            error.NoServer => runCall(s, false),
            // The server is stopping, and has nowhere to put a fiber.
            else => {
                _ = s.shared.running.fetchSub(1, .release);
                s.shared.drop();
                s.state = .body;
                return c.answerNow(s, 14, "the server is stopping");
            },
        };
    }

    /// A request that is not a gRPC call and not a well-formed HTTP/2 one
    /// either: a stream error, and nothing else (§8.1.1).
    fn malformed(c: *Conn, s: *Stream) ReadError!void {
        h2.writeRstStream(c.out, s.id, .protocol_error) catch return error.Gone;
        c.forget(s);
    }

    /// Answer without running anything: one HEADERS frame carrying the
    /// status, which is what gRPC calls Trailers-Only.
    fn answerNow(c: *Conn, s: *Stream, code: u8, message: []const u8) ReadError!void {
        s.head_block = trailersOnly(s.arena.allocator(), code, message) catch return error.Internal;
        s.trailers_only = true;
        return c.ready(s);
    }

    fn ready(c: *Conn, s: *Stream) ReadError!void {
        s.state = .writing;
        _ = c.writeStream(s) catch return error.Gone;
    }

    fn headerBlock(c: *Conn, a: std.mem.Allocator, fields: []const hpack.Field) ReadError![]const u8 {
        _ = c;
        return encodeBlock(a, fields) catch return error.Internal;
    }

    // ---- writing ----

    /// Take the answered calls off the queue and write every answer as far
    /// as the windows let it go.
    fn writeReady(c: *Conn) !void {
        var answered = c.shared.takeAll();
        while (answered) |s| {
            answered = s.next;
            s.next = null;
            if (s.reset) {
                c.forget(s);
                continue;
            }
            s.state = .writing;
        }
        var i: usize = 0;
        var blocked = false;
        while (i < c.streams.items.len) {
            const s = c.streams.items[i];
            if (s.state != .writing) {
                i += 1;
                continue;
            }
            if (try c.writeStream(s)) continue;
            blocked = true;
            i += 1;
        }
        if (blocked) {
            if (c.blocked_since == 0) c.blocked_since = bulkhead.monotonicNanos();
        } else c.blocked_since = 0;
    }

    /// Write as much of one answer as the windows allow. True when it is all
    /// gone and the stream has been let go of.
    fn writeStream(c: *Conn, s: *Stream) !bool {
        if (!s.head_sent) {
            try h2.writeHeaderBlock(c.out, s.id, s.head_block, s.trailers_only, c.peer_max_frame);
            s.head_sent = true;
            if (s.trailers_only) {
                c.forget(s);
                return true;
            }
        }
        while (s.data_sent < s.data.len) {
            const room = @min(c.send_window, s.send_window);
            if (room <= 0) return false;
            const n: usize = @intCast(@min(@as(i64, @intCast(s.data.len - s.data_sent)), room, c.peer_max_frame));
            try h2.writeHeader(c.out, n, .data, 0, s.id);
            try c.out.writeAll(s.data[s.data_sent..][0..n]);
            s.data_sent += n;
            c.send_window -= @intCast(n);
            s.send_window -= @intCast(n);
        }
        try h2.writeHeaderBlock(c.out, s.id, s.trailers, true, c.peer_max_frame);
        c.forget(s);
        return true;
    }
};

// ---- the call's fiber ----

/// One call, run as the HTTP/1.1 request it would have been, and its answer
/// turned back into frames. On a fiber of its own; everything it touches is
/// the stream's, until `finish` hands the stream back.
fn runCall(s: *Stream, on_engine: bool) void {
    const shared = s.shared;
    defer shared.finish(s);

    // The box a fail function writes into, bound to this fiber the way a
    // connection binds its own (ADR 0007). With no Engine there is no fiber
    // to bind to, and the fallback slot is the one a test uses.
    var in_flight = fail.InFlight{};
    var binding = bulkhead.binding_unset;
    var previous: ?*anyopaque = null;
    if (on_engine) bulkhead.bindSlot(&binding, &in_flight) else previous = bulkhead.setFallbackSlot(&in_flight);
    defer if (on_engine) bulkhead.unbindSlot(&binding) else {
        _ = bulkhead.setFallbackSlot(previous);
    };

    answer(s, &in_flight) catch {
        s.head_block = trailersOnly(s.arena.allocator(), 13, "the server could not build its answer") catch "";
        s.trailers_only = true;
    };
}

fn answer(s: *Stream, in_flight: *fail.InFlight) !void {
    const a = s.arena.allocator();
    const request = try asRequest(a, s);

    var lifetime = core.Lifetime.init();
    defer lifetime.deinit();
    var in: std.Io.Reader = .fixed(request);
    var out: std.Io.Writer.Allocating = .init(a);
    s.app.handle(s.app.ptr, a, &lifetime, in_flight, &in, &out.writer, s.peer, s.until_ns);
    lifetime.end();
    try fromResponse(a, s, out.written());
}

/// `grpc-timeout`: at most eight digits and one unit, `H`, `M`, `S`, `m`,
/// `u` or `n` (gRPC over HTTP/2, "Requests"). Null for anything else.
pub fn timeoutNanos(text: []const u8) ?u64 {
    if (text.len < 2 or text.len > 9) return null;
    const digits = text[0 .. text.len - 1];
    for (digits) |ch| if (ch < '0' or ch > '9') return null;
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    const unit: u64 = switch (text[text.len - 1]) {
        'H' => std.time.ns_per_hour,
        'M' => std.time.ns_per_min,
        'S' => std.time.ns_per_s,
        'm' => std.time.ns_per_ms,
        'u' => std.time.ns_per_us,
        'n' => 1,
        else => return null,
    };
    return n *| unit;
}

/// The call as an HTTP/1.1 request: `POST <path>`, `:authority` as `Host`,
/// the metadata as headers, and the one message, unframed, as the body.
fn asRequest(a: std.mem.Allocator, s: *const Stream) ![]const u8 {
    var w: std.Io.Writer.Allocating = try .initCapacity(a, 256 + s.body.items.len);
    const out = &w.writer;
    try out.writeAll("POST ");
    try out.writeAll(s.field(":path").?);
    try out.writeAll(" HTTP/1.1\r\n");
    if (s.field(":authority")) |host| {
        try out.writeAll("host: ");
        try out.writeAll(host);
        try out.writeAll("\r\n");
    } else if (s.field("host") == null) {
        try out.writeAll("host: localhost\r\n");
    }
    for (s.fields.items) |f| {
        if (f.name.len == 0 or f.name[0] == ':') continue;
        if (hopByHop(f.name)) continue;
        if (std.mem.eql(u8, f.name, "content-length")) continue;
        try out.writeAll(f.name);
        try out.writeAll(": ");
        try out.writeAll(f.value);
        try out.writeAll("\r\n");
    }
    try out.print("content-length: {d}\r\n\r\n", .{s.body.items.len});
    try out.writeAll(s.body.items);
    return w.written();
}

/// Headers that belong to one HTTP/1.1 connection rather than to a request,
/// which HTTP/2 forbids (§8.2.2), plus `te`, which means something else in
/// HTTP/1.1.
fn hopByHop(name: []const u8) bool {
    const names = [_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te" };
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// A field that can be written into an HTTP/1.1 head as it is: a lowercase
/// token for a name, and a value with no line break and no NUL in it. What
/// makes turning a call into a request text safe; a field that is not this
/// is a malformed request (§8.2.1), refused before anything reads it.
fn validField(f: hpack.Field) bool {
    if (f.name.len == 0) return false;
    const name = if (f.name[0] == ':') f.name[1..] else f.name;
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    for (f.value) |ch| if (ch == 0 or ch == '\r' or ch == '\n') return false;
    return true;
}

/// Turn what the route answered into the call's answer: HEADERS with the
/// route's headers as metadata, the body as one length-prefixed message, and
/// trailers with `grpc-status`. A status other than 200 is a failed call,
/// said in one HEADERS frame.
fn fromResponse(a: std.mem.Allocator, s: *Stream, raw: []const u8) !void {
    const response = try parseResponse(a, raw);
    if (response.status != 200) {
        // A route that failed after the client's deadline failed because of
        // it, as far as the client can tell: `nilo.deadline`'s 503 and a wait
        // cut short both read as DEADLINE_EXCEEDED rather than UNAVAILABLE.
        const late = s.until_ns != 0 and bulkhead.monotonicNanos() >= s.until_ns;
        const code = response.grpc_status orelse if (late) 4 else codeForStatus(response.status);
        const message = response.grpc_message orelse try failureMessage(a, response);
        s.head_block = try trailersOnly(a, code, message);
        s.trailers_only = true;
        return;
    }
    if (response.grpc_status) |code| if (code != 0) {
        s.head_block = try trailersOnly(a, code, response.grpc_message orelse "");
        s.trailers_only = true;
        return;
    };

    if (response.headers.len == 0 and std.mem.eql(u8, response.content_type, "application/grpc")) {
        s.head_block = ok_head;
        s.data = try framed(a, response.body);
        s.trailers = ok_trailers;
        return;
    }

    var head: std.ArrayList(hpack.Field) = .empty;
    try head.append(a, .{ .name = ":status", .value = "200" });
    try head.append(a, .{ .name = "content-type", .value = if (std.mem.startsWith(u8, response.content_type, "application/grpc")) response.content_type else "application/grpc" });
    for (response.headers) |f| try head.append(a, f);
    s.head_block = try encodeBlock(a, head.items);

    s.data = try framed(a, response.body);
    s.trailers = ok_trailers;
}

/// The message with its five-byte prefix: uncompressed, and its length.
fn framed(a: std.mem.Allocator, message: []const u8) ![]const u8 {
    const data = try a.alloc(u8, 5 + message.len);
    data[0] = 0;
    std.mem.writeInt(u32, data[1..5], @intCast(message.len), .big);
    @memcpy(data[5..], message);
    return data;
}

/// The two blocks nearly every call is answered with, as `encodeBlock` would
/// write them: `:status 200` from the static table and `content-type` as a
/// literal with the static table's name, then `grpc-status 0`. Constant, so
/// an ordinary call encodes nothing. A test holds them to `encodeBlock`.
const ok_head = "\x88\x0f\x10\x10application/grpc";
const ok_trailers = "\x00\x0bgrpc-status\x010";

const Response = struct {
    status: u16,
    content_type: []const u8 = "",
    /// Everything else worth carrying as metadata, names lowercased.
    headers: []const hpack.Field = &.{},
    grpc_status: ?u8 = null,
    grpc_message: ?[]const u8 = null,
    body: []const u8,
};

/// Read back what `handleRequest` wrote: a status line, a head, and a body
/// that is either as long as it says or chunked.
fn parseResponse(a: std.mem.Allocator, raw: []const u8) !Response {
    const end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    var lines = std.mem.splitSequence(u8, raw[0..end], "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    if (status_line.len < 12) return error.BadResponse;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.BadResponse;

    var response: Response = .{ .status = status, .body = "" };
    var headers: std.ArrayList(hpack.Field) = .empty;
    var chunked = false;
    var length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const raw_name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const is = std.ascii.eqlIgnoreCase;
        if (is(raw_name, "content-type")) {
            response.content_type = value;
        } else if (is(raw_name, "content-length")) {
            length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (is(raw_name, "transfer-encoding")) {
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        } else if (is(raw_name, "grpc-status")) {
            response.grpc_status = std.fmt.parseInt(u8, value, 10) catch 2;
        } else if (is(raw_name, "grpc-message")) {
            response.grpc_message = value;
        } else if (!is(raw_name, "date")) {
            // Lowercased only when it is carried, which HTTP/2 requires.
            const name = try std.ascii.allocLowerString(a, raw_name);
            if (!hopByHop(name)) try headers.append(a, .{ .name = name, .value = value });
        }
    }
    response.headers = headers.items;
    const rest = raw[end + 4 ..];
    if (chunked) {
        response.body = try unchunk(a, rest);
    } else {
        response.body = rest[0..@min(rest.len, length orelse rest.len)];
    }
    return response;
}

fn unchunk(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = raw;
    while (true) {
        const line_end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadResponse;
        const size_text = std.mem.trim(u8, rest[0..line_end], " ");
        const semi = std.mem.indexOfScalar(u8, size_text, ';') orelse size_text.len;
        const size = std.fmt.parseInt(usize, size_text[0..semi], 16) catch return error.BadResponse;
        rest = rest[line_end + 2 ..];
        if (size == 0) return out.items;
        if (rest.len < size + 2) return error.BadResponse;
        try out.appendSlice(a, rest[0..size]);
        rest = rest[size + 2 ..];
    }
}

/// What a failed route said, for `grpc-message`: the `error` of nilo's own
/// failure body when that is what came back, or the body itself when it is
/// short text, or nothing.
fn failureMessage(a: std.mem.Allocator, response: Response) ![]const u8 {
    if (std.mem.startsWith(u8, response.content_type, "application/json")) {
        const Shape = struct { @"error": []const u8 = "" };
        const parsed = std.json.parseFromSliceLeaky(Shape, a, response.body, .{ .ignore_unknown_fields = true }) catch return "";
        return parsed.@"error";
    }
    if (std.mem.startsWith(u8, response.content_type, "text/plain") and response.body.len <= 1024) return response.body;
    return "";
}

/// The gRPC code an HTTP status means when a route failed with it. Chosen by
/// what the status says about the call rather than by gRPC's own table for
/// proxies, which reads a status as something that went wrong on the way:
/// a 404 from a route is a thing that was not found, not a method that does
/// not exist, and a path no route answers never gets here.
pub fn codeForStatus(status: u16) u8 {
    return switch (status) {
        200 => 0,
        400, 415, 422 => 3, // INVALID_ARGUMENT
        401 => 16, // UNAUTHENTICATED
        403 => 7, // PERMISSION_DENIED
        404 => 5, // NOT_FOUND
        405, 501 => 12, // UNIMPLEMENTED
        408, 504 => 4, // DEADLINE_EXCEEDED
        409 => 10, // ABORTED
        412 => 9, // FAILED_PRECONDITION
        413, 429 => 8, // RESOURCE_EXHAUSTED
        499 => 1, // CANCELLED
        503 => 14, // UNAVAILABLE
        500 => 13, // INTERNAL
        else => if (status >= 400 and status < 500) 9 else 2, // FAILED_PRECONDITION, UNKNOWN
    };
}

/// One HEADERS block carrying a whole failed call: the status, the content
/// type, `grpc-status` and `grpc-message`.
fn trailersOnly(a: std.mem.Allocator, code: u8, message: []const u8) ![]const u8 {
    var code_text: [3]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_text, "{d}", .{code}) catch unreachable;
    var fields: std.ArrayList(hpack.Field) = .empty;
    try fields.append(a, .{ .name = ":status", .value = "200" });
    try fields.append(a, .{ .name = "content-type", .value = "application/grpc" });
    try fields.append(a, .{ .name = "grpc-status", .value = try a.dupe(u8, code_str) });
    if (message.len != 0) try fields.append(a, .{ .name = "grpc-message", .value = try percentEncoded(a, message) });
    return encodeBlock(a, fields.items);
}

/// `grpc-message` is percent-encoded: everything outside printable ASCII,
/// and `%` itself (gRPC over HTTP/2, "Responses").
fn percentEncoded(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '%') {
            try out.print(a, "%{X:0>2}", .{ch});
        } else try out.append(a, ch);
    }
    return out.items;
}

fn encodeBlock(a: std.mem.Allocator, fields: []const hpack.Field) ![]const u8 {
    var w: std.Io.Writer.Allocating = try .initCapacity(a, 64);
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, ":status") and std.mem.eql(u8, f.value, "200")) {
            try hpack.writeIndexed(&w.writer, 8);
        } else try hpack.writeLiteral(&w.writer, f.name, f.value);
    }
    return w.written();
}

// ---- tests ----

const testing = std.testing;

test "the constant answer blocks are what encodeBlock writes for them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(try encodeBlock(a, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
    }), ok_head);
    try testing.expectEqualStrings(try encodeBlock(a, &.{.{ .name = "grpc-status", .value = "0" }}), ok_trailers);
}

test "grpc-timeout is eight digits at most and a unit, and anything else is refused" {
    try testing.expectEqual(@as(?u64, 5 * std.time.ns_per_s), timeoutNanos("5S"));
    try testing.expectEqual(@as(?u64, 250 * std.time.ns_per_ms), timeoutNanos("250m"));
    try testing.expectEqual(@as(?u64, 2 * std.time.ns_per_hour), timeoutNanos("2H"));
    try testing.expectEqual(@as(?u64, 99_999_999), timeoutNanos("99999999n"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("123456789S"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("5"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("5s"));
    try testing.expectEqual(@as(?u64, null), timeoutNanos("-5S"));
}

test "the gRPC code a failed route's status means" {
    try testing.expectEqual(@as(u8, 3), codeForStatus(400));
    try testing.expectEqual(@as(u8, 16), codeForStatus(401));
    try testing.expectEqual(@as(u8, 7), codeForStatus(403));
    try testing.expectEqual(@as(u8, 5), codeForStatus(404));
    try testing.expectEqual(@as(u8, 8), codeForStatus(429));
    try testing.expectEqual(@as(u8, 13), codeForStatus(500));
    try testing.expectEqual(@as(u8, 14), codeForStatus(503));
    try testing.expectEqual(@as(u8, 2), codeForStatus(302));
}

const ctx_mod = @import("ctx.zig");
const App = @import("app.zig").App;
const Ctx = ctx_mod.Ctx;

/// A client written the way the ones measured write: preface, SETTINGS, then
/// frames, all into one buffer the connection reads as if from a socket.
const TestClient = struct {
    buf: std.Io.Writer.Allocating,

    fn init() !TestClient {
        var c: TestClient = .{ .buf = .init(testing.allocator) };
        try c.buf.writer.writeAll(h2.preface);
        try h2.writeSettings(&c.buf.writer, &.{});
        return c;
    }

    fn deinit(c: *TestClient) void {
        c.buf.deinit();
    }

    fn w(c: *TestClient) *std.Io.Writer {
        return &c.buf.writer;
    }

    fn headersFor(c: *TestClient, stream: u31, path: []const u8, extra: []const hpack.Field, end_stream: bool) !void {
        var block: std.Io.Writer.Allocating = .init(testing.allocator);
        defer block.deinit();
        try hpack.writeInt(&block.writer, 0x80, 7, 3); // :method POST
        try hpack.writeInt(&block.writer, 0x80, 7, 6); // :scheme http
        try hpack.writeLiteral(&block.writer, ":path", path);
        try hpack.writeLiteral(&block.writer, ":authority", "localhost");
        try hpack.writeLiteral(&block.writer, "content-type", "application/grpc");
        try hpack.writeLiteral(&block.writer, "te", "trailers");
        for (extra) |f| try hpack.writeLiteral(&block.writer, f.name, f.value);
        try h2.writeHeaderBlock(c.w(), stream, block.written(), end_stream, h2.default_max_frame);
    }

    fn message(c: *TestClient, stream: u31, bytes: []const u8, compressed: bool) !void {
        try h2.writeHeader(c.w(), 5 + bytes.len, .data, h2.Flags.end_stream, stream);
        try c.w().writeByte(if (compressed) 1 else 0);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(bytes.len), .big);
        try c.w().writeAll(&len);
        try c.w().writeAll(bytes);
    }

    fn call(c: *TestClient, stream: u31, path: []const u8, bytes: []const u8) !void {
        try c.headersFor(stream, path, &.{}, false);
        try c.message(stream, bytes, false);
    }
};

const Frame = struct { head: h2.Header, payload: []const u8 };

/// What the server wrote, frame by frame, header blocks decoded.
const Answer = struct {
    arena: std.heap.ArenaAllocator,
    frames: std.ArrayList(Frame) = .empty,
    decoder: hpack.Decoder,

    fn deinit(self: *Answer) void {
        self.decoder.deinit();
        self.arena.deinit();
    }

    fn of(t: h2.Type, self: *const Answer, stream: u31) []const Frame {
        var out: std.ArrayList(Frame) = .empty;
        for (self.frames.items) |f| if (f.head.type == t and f.head.stream == stream)
            out.append(@constCast(&self.arena).allocator(), f) catch unreachable;
        return out.items;
    }

    fn fields(self: *Answer, block: []const u8) ![]const hpack.Field {
        var out: std.ArrayList(hpack.Field) = .empty;
        _ = try self.decoder.decode(block, self.arena.allocator(), &out, 1 << 20);
        return out.items;
    }

    fn value(fs: []const hpack.Field, name: []const u8) ?[]const u8 {
        for (fs) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }

    /// The trailers of a call: its last HEADERS frame's fields.
    fn trailers(self: *Answer, stream: u31) ![]const hpack.Field {
        const hs = of(.headers, self, stream);
        if (hs.len == 0) return error.NoHeaders;
        return self.fields(hs[hs.len - 1].payload);
    }

    fn message(self: *Answer, stream: u31) ![]const u8 {
        var all: std.ArrayList(u8) = .empty;
        for (of(.data, self, stream)) |f| try all.appendSlice(self.arena.allocator(), f.payload);
        if (all.items.len < 5) return error.NoMessage;
        return all.items[5..];
    }

    fn goaway(self: *const Answer) ?h2.ErrorCode {
        for (self.frames.items) |f| if (f.head.type == .goaway)
            return @enumFromInt(std.mem.readInt(u32, f.payload[4..8], .big));
        return null;
    }

    fn rst(self: *const Answer, stream: u31) ?h2.ErrorCode {
        for (self.frames.items) |f| if (f.head.type == .rst_stream and f.head.stream == stream)
            return @enumFromInt(std.mem.readInt(u32, f.payload[0..4], .big));
        return null;
    }
};

fn converse(app: *App, client: *TestClient) !Answer {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    serveConnection(app.grpcHost(), &in, &out.writer, .off, .off, .{});

    var answer_: Answer = .{ .arena = .init(testing.allocator), .decoder = .init(testing.allocator) };
    const a = answer_.arena.allocator();
    var rest = try a.dupe(u8, out.written());
    while (rest.len >= h2.header_len) {
        const head = h2.Header.parse(rest[0..h2.header_len]);
        const end = h2.header_len + head.len;
        try answer_.frames.append(a, .{ .head = head, .payload = rest[h2.header_len..end] });
        rest = rest[end..];
    }
    return answer_;
}

fn echoRoute(c: *Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

fn missingRoute(_: *Ctx) anyerror!void {
    return fail.notFound("no such order", .{});
}

fn metadataRoute(c: *Ctx) anyerror!void {
    const who = if (c.header("x-caller")) |v| v.view() else "nobody";
    try c.setHeader("x-seen", who);
    try c.send(200, "application/grpc", "");
}

/// Answers the way `nilo.deadline` does when the clock has run out.
fn clockRoute(c: *Ctx) anyerror!void {
    if (c.overdue()) return fail.status(503, "out of time", .{});
    try c.send(200, "application/grpc", "");
}

fn testApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.post("/test.Echo/Say", echoRoute);
    try app.post("/test.Orders/Get", missingRoute);
    try app.post("/test.Meta/Who", metadataRoute);
    try app.post("/test.Clock/Check", clockRoute);
    try app.resolveChains();
    return app;
}

test "a unary call reaches its route as a POST, and its answer comes back framed with grpc-status 0" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "hello over h2c");

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("200", Answer.value(head, ":status").?);
    try testing.expectEqualStrings("application/grpc", Answer.value(head, "content-type").?);
    try testing.expectEqualStrings("hello over h2c", try got.message(1));
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("0", Answer.value(trailers, "grpc-status").?);
}

test "the server's own SETTINGS ask for an HPACK table of 0, and cap the calls at max_streams" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var got = try converse(&app, &client);
    defer got.deinit();
    const settings = got.frames.items[0];
    try testing.expectEqual(h2.Type.settings, settings.head.type);
    var saw_table = false;
    var saw_cap = false;
    var i: usize = 0;
    while (i < settings.payload.len) : (i += 6) {
        const id: h2.Setting = @enumFromInt(std.mem.readInt(u16, settings.payload[i..][0..2], .big));
        const v = std.mem.readInt(u32, settings.payload[i + 2 ..][0..4], .big);
        if (id == .header_table_size) {
            try testing.expectEqual(@as(u32, 0), v);
            saw_table = true;
        }
        if (id == .max_concurrent_streams) {
            try testing.expectEqual(@as(u32, max_streams), v);
            saw_cap = true;
        }
    }
    try testing.expect(saw_table and saw_cap);
}

test "a path no route answers is UNIMPLEMENTED, said in one HEADERS frame" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Nowhere/Nothing", "x");

    var got = try converse(&app, &client);
    defer got.deinit();
    const hs = Answer.of(.headers, &got, 1);
    try testing.expectEqual(@as(usize, 1), hs.len);
    try testing.expect(hs[0].head.has(h2.Flags.end_stream));
    try testing.expectEqualStrings("12", Answer.value(try got.fields(hs[0].payload), "grpc-status").?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.data, &got, 1).len);
}

test "a route that fails with 404 is NOT_FOUND, and what it said is grpc-message" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Orders/Get", "x");

    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var got = try converse(&app, &client);
    defer got.deinit();
    const trailers = try got.trailers(1);
    try testing.expectEqualStrings("5", Answer.value(trailers, "grpc-status").?);
    try testing.expectEqualStrings("no such order", Answer.value(trailers, "grpc-message").?);
}

test "a call's metadata reaches the route as headers, and the route's headers come back as metadata" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Meta/Who", &.{.{ .name = "x-caller", .value = "the collector" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    const head = try got.fields(Answer.of(.headers, &got, 1)[0].payload);
    try testing.expectEqualStrings("the collector", Answer.value(head, "x-seen").?);
}

test "a gzipped message reaches the route inflated" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var zipped: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer zipped.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&zipped.writer, &window, .gzip, .default);
    try compress.writer.writeAll("squeezed " ** 20);
    try compress.finish();

    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "gzip" }}, false);
    try client.message(1, zipped.written(), true);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("squeezed " ** 20, try got.message(1));
}

test "a compressed message in an encoding this server does not read is UNIMPLEMENTED" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Echo/Say", &.{.{ .name = "grpc-encoding", .value = "snappy" }}, false);
    try client.message(1, "whatever", true);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("12", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a message larger than max_body is RESOURCE_EXHAUSTED, and the route never sees it" {
    var app = try testApp();
    defer app.deinit();
    app.limits.max_body = 16;
    var client = try TestClient.init();
    defer client.deinit();
    try client.call(1, "/test.Echo/Say", "this is well past sixteen bytes");

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a request that is not a gRPC call is a 415, and nothing else" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeInt(&block.writer, 0x80, 7, 3);
    try hpack.writeLiteral(&block.writer, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block.writer, "content-type", "application/json");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), true, h2.default_max_frame);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("415", Answer.value(try got.trailers(1), ":status").?);
}

test "a header value with a line break in it is refused before it can become a request" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Meta/Who", &.{.{ .name = "x-caller", .value = "a\r\nx-admin: yes" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.protocol_error, got.rst(1).?);
    try testing.expectEqual(@as(usize, 0), Answer.of(.headers, &got, 1).len);
}

test "a message split across DATA frames and a header block across CONTINUATION frames arrive whole" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();

    var block: std.Io.Writer.Allocating = .init(testing.allocator);
    defer block.deinit();
    try hpack.writeInt(&block.writer, 0x80, 7, 3);
    try hpack.writeLiteral(&block.writer, ":path", "/test.Echo/Say");
    try hpack.writeLiteral(&block.writer, "content-type", "application/grpc");
    try h2.writeHeaderBlock(client.w(), 1, block.written(), false, 5);

    const text = "in two halves";
    var prefix: [5]u8 = .{ 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, prefix[1..5], text.len, .big);
    try h2.writeHeader(client.w(), 5 + 3, .data, 0, 1);
    try client.w().writeAll(&prefix);
    try client.w().writeAll(text[0..3]);
    try h2.writeHeader(client.w(), text.len - 3, .data, h2.Flags.end_stream, 1);
    try client.w().writeAll(text[3..]);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings(text, try got.message(1));
}

test "an answer larger than the client's window waits for WINDOW_UPDATE, then finishes" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // A client that allows ten bytes a stream, then asks for forty.
    try h2.writeSettings(client.w(), &.{.{ .initial_window_size, 10 }});
    try client.call(1, "/test.Echo/Say", "0123456789" ** 4);
    try h2.writeWindowUpdate(client.w(), 1, 100);

    var got = try converse(&app, &client);
    defer got.deinit();
    const data = Answer.of(.data, &got, 1);
    try testing.expect(data.len >= 2);
    try testing.expectEqual(@as(u24, 10), data[0].head.len);
    try testing.expectEqualStrings("0123456789" ** 4, try got.message(1));
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a call past the cap is refused with REFUSED_STREAM, and the calls under it are not" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    // Opened and never finished, so every one of them is held.
    var id: u31 = 1;
    for (0..max_streams + 1) |_| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.refused_stream, got.rst(id - 2).?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.rst(1));
}

test "a client that keeps opening past the cap is sent away with ENHANCE_YOUR_CALM" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    var id: u31 = 1;
    for (0..max_streams + max_refused + 2) |_| {
        try client.headersFor(id, "/test.Echo/Say", &.{}, false);
        id += 2;
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a header block that never ends is sent away with ENHANCE_YOUR_CALM, however it is split" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const junk = [_]u8{0} ** 4096;
    try h2.writeHeader(client.w(), junk.len, .headers, 0, 1);
    try client.w().writeAll(&junk);
    for (0..20) |_| {
        try h2.writeHeader(client.w(), junk.len, .continuation, 0, 1);
        try client.w().writeAll(&junk);
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a flood of PINGs with no call between them is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    for (0..max_control_run + 1) |_| {
        try h2.writeHeader(client.w(), 8, .ping, 0, 0);
        try client.w().writeAll("12345678");
    }

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}

test "a client that is not speaking HTTP/2 is told so in HTTP/1.1, and the connection closed" {
    var app = try testApp();
    defer app.deinit();
    var client: TestClient = .{ .buf = .init(testing.allocator) };
    defer client.deinit();
    try client.w().writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(client.buf.written());
    serveConnection(app.grpcHost(), &in, &out.writer, .off, .off, .{});
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP/1.1 505"));
}

test "a frame larger than the server allows is a FRAME_SIZE_ERROR" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try h2.writeHeader(client.w(), h2.default_max_frame + 1, .data, 0, 1);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.frame_size_error, got.goaway().?);
}

// The HTTP/1.1 budget (`behaviour.zig`) counts allocations inside a request's
// arena, and a keep-alive connection's arena is warm. A call here has an
// arena of its own, made and dropped with it, so what is counted is what
// reaches the general-purpose allocator: the connection's first call is
// taken away by running one call and then two, and the difference is the
// second call's. Raising either number needs a reason; lowering it is welcome.
test "a unary call stays inside its budget of heap allocations" {
    var app = try testApp();
    defer app.deinit();
    var counting = @import("budget.zig").Counting{ .child = testing.allocator };

    var results: [2]struct { allocs: usize, bytes: usize } = undefined;
    for (&results, 1..) |*r, calls| {
        var client = try TestClient.init();
        defer client.deinit();
        var id: u31 = 1;
        for (0..calls) |_| {
            try client.call(id, "/test.Echo/Say", "a message of ordinary size, forty bytes");
            id += 2;
        }
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = counting.allocator();
        counting.reset();
        serveConnection(host, &in, &out.writer, .off, .off, .{});
        r.* = .{ .allocs = counting.allocs, .bytes = counting.bytes };
    }
    // None: the second call reuses the first one's stream and the arena it
    // kept (`spare_arena_keep`). It was four allocations and 3,342 bytes
    // before streams were kept (ADR 0297).
    try testing.expectEqual(@as(usize, 0), results[1].allocs - results[0].allocs);
    try testing.expectEqual(@as(usize, 0), results[1].bytes - results[0].bytes);
}

test "grpc-timeout is the request's deadline, and a route that runs out of it is DEADLINE_EXCEEDED" {
    var app = try testApp();
    defer app.deinit();
    // A default from listen() longer than the client's timeout does not
    // replace it: the client's is the one that decides.
    app.limits.request_deadline_ms = 60_000;
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "5S" }}, false);
    try client.message(1, "", false);
    try client.headersFor(3, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "1n" }}, false);
    try client.message(3, "", false);

    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("0", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqualStrings("4", Answer.value(try got.trailers(3), "grpc-status").?);
}

test "a grpc-timeout that is not one is INVALID_ARGUMENT, and the route never runs" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    try client.headersFor(1, "/test.Clock/Check", &.{.{ .name = "grpc-timeout", .value = "soon" }}, false);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("3", Answer.value(try got.trailers(1), "grpc-status").?);
}

test "a header block that decodes to more than max_header_list is RESOURCE_EXHAUSTED, however small it was" {
    // The HPACK bomb: one byte on the wire, `:method: GET` from the static
    // table, forty-five bytes against the list's limit every time it is said.
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    const bomb = [_]u8{0x82} ** 8000;
    try h2.writeHeaderBlock(client.w(), 1, &bomb, false, h2.default_max_frame);
    try client.message(1, "", false);

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqualStrings("8", Answer.value(try got.trailers(1), "grpc-status").?);
    try testing.expectEqual(@as(?h2.ErrorCode, null), got.goaway());
}

test "a flood of SETTINGS with no call between them is sent away" {
    var app = try testApp();
    defer app.deinit();
    var client = try TestClient.init();
    defer client.deinit();
    for (0..max_control_run + 1) |_| try h2.writeSettings(client.w(), &.{});

    var got = try converse(&app, &client);
    defer got.deinit();
    try testing.expectEqual(h2.ErrorCode.enhance_your_calm, got.goaway().?);
}
