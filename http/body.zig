//! Reading a request body in pieces, for the ones too big to hold (ADR 019).
//!
//! ```zig
//! fn upload(c: *nilo.Ctx, store: *Store) !Receipt {
//!     var incoming = try c.bodyStream();
//!     var buf: [64 * 1024]u8 = undefined;
//!     while (try incoming.read(&buf)) |part| try store.append(part);
//!     return .{ .bytes = incoming.seen };
//! }
//! ```
//!
//! `c.body()` reads the whole thing into the request arena and refuses past
//! a megabyte, which is right for a JSON body and wrong for a file. This is
//! the other one: memory is bounded by the buffer the handler passes in, and
//! **nothing is allocated at all** — not even the one buffer a response
//! stream takes, because a body reader has somewhere to put bytes already.
//!
//! Content-Length and chunked look the same from here, the same way they do
//! to `Ctx.body`, and so does a body on HTTP/2, which ends where its stream
//! does (ADR 260). The handler asks for the body, not for the way it arrived.

const std = @import("std");

const http1 = @import("http1.zig");
const watchdog = @import("watchdog.zig");
const framing = @import("framing.zig");
const inbound = @import("inbound.zig");

pub const Options = struct {
    /// The most a body may be. A `Content-Length` past this is refused
    /// before a byte is read; a chunked body is counted as it arrives and
    /// stopped when it crosses.
    ///
    /// There has to be a number. A chunked body announces no size, so
    /// "however much they send" is a client's decision about the server's
    /// memory and time — and the default is a file upload's worth rather
    /// than an invitation.
    max_bytes: u64 = 64 * 1024 * 1024,
};

pub const Error = error{
    /// More body than `Options.max_bytes` allows.
    BodyTooLarge,
    /// The chunk sizes and the stream have come apart. Where this body ends
    /// is now a guess, so the connection cannot be reused.
    BadChunk,
    /// The connection ended while body bytes were still owed: a client that
    /// promised a `Content-Length` and stopped short, or closed inside a
    /// chunk's data. Not the clean end `read` reports as null (ADR 019).
    BodyTruncated,
    ReadFailed,
    EndOfStream,
    WriteFailed,
};

/// How far through a body the reader has got. Lives on the `Ctx` rather than
/// on the `Body`, because the `Body` is on the handler's stack and App has to
/// finish what the handler left when it has returned.
pub const Progress = struct {
    state: State,
    seen: u64 = 0,
    max_bytes: u64,
    /// What the request said the body would be, or null for a chunked one.
    /// Kept separately from `state`, so asking after the body has been read
    /// still answers — the first version worked it out from what was left,
    /// and went null the moment there was nothing left.
    announced: ?u64,
    /// The transport ends the body: a request on HTTP/2, read until its stream
    /// does, and held to `max_bytes` as a chunked body is. It is `between`
    /// until the stream ends. A flag and not a `State`, and absent from a build
    /// without HTTP/2, so that build's `Progress` and every switch on its
    /// state are what they were before there was one.
    transport: if (framing.http2_built) bool else void = if (framing.http2_built) false else {},

    pub const State = union(enum) {
        /// Bytes still to come in a Content-Length body.
        sized: u64,
        /// Bytes still to come in the chunk being read.
        chunk: u64,
        /// Between chunks: the next thing on the wire is a size line.
        between,
        /// The body is over and the connection is at the next request.
        done,
        /// Something went wrong in a way that leaves the connection at an
        /// unknown byte. Nothing may be read from it again.
        broken,
        /// The connection ended with body bytes still owed. Like `broken`
        /// nothing may be read from it again, and it is told apart so the
        /// reader answers `BodyTruncated`, a 400, where `broken` is a
        /// chunk framing fault or a body over the ceiling.
        cut,
    };

    pub fn start(request: *const http1.Request, max_bytes: u64) Progress {
        return .{
            .state = if (request.chunked)
                .between
            else if (framing.http2_built and request.ends_with_stream)
                .between
            else if (request.content_length == 0)
                .done
            else
                .{ .sized = request.content_length },
            .max_bytes = max_bytes,
            .announced = if (request.chunked or (framing.http2_built and request.ends_with_stream and !request.has_content_length))
                null
            else
                request.content_length,
            .transport = if (framing.http2_built) request.ends_with_stream else {},
        };
    }

    pub fn finished(self: Progress) bool {
        return self.state == .done;
    }

    /// The most body there can still be to read: what a sized one has left,
    /// and what a chunked one may still send before `max_bytes`.
    pub fn mostLeft(self: Progress) u64 {
        return switch (self.state) {
            .sized => |left| left,
            .chunk, .between => self.max_bytes -| self.seen,
            .done, .broken, .cut => 0,
        };
    }
};

/// A request body, arriving in pieces.
pub const Body = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Body";

    /// The body as a `std.Io.Reader`, for handing to something in the
    /// standard library that asks for runs of bytes (`streamRemaining`,
    /// `readSliceAll`). Unbuffered, so it allocates nothing and a parser that
    /// peeks has nowhere to peek: **a parser that does, `std.json.Reader` or a
    /// line at a time, takes `buffered` instead**, which is this reader with a
    /// buffer the caller owns. Do not set `reader.buffer` by hand: `buffered`
    /// is the one place that does it, and checks what the by-hand version did
    /// not.
    reader: std.Io.Reader,

    /// The connection.
    _in: *std.Io.Reader,
    /// The `Ctx`'s record of how far this has got.
    _progress: *Progress,
    /// The request's blocking detector, or null when there is no request
    /// behind this — a Body a test built against a fixed reader. A stretch of
    /// handler time ends at every read (ADR 013).
    _watch: ?*watchdog.Watch = null,

    /// The body as a buffered `std.Io.Reader`, for a parser that peeks, takes
    /// a line or refills as it goes: `std.json.Reader`, `takeDelimiter` over
    /// NDJSON, `takeInt`.
    ///
    /// ```zig
    /// var incoming = try c.bodyStream();
    /// var buf: [4096]u8 = undefined;
    /// const r = try try incoming.buffered(&buf);
    /// while (try r.takeDelimiter('\n')) |line| try store.add(line);
    /// ```
    ///
    /// **The buffer is the caller's**, on the stack or from `c.arena()`, and
    /// nothing is allocated here, so the path that does not ask for it costs
    /// what it did. It is also the longest a line, a token or a peek may be:
    /// `takeDelimiter` answers `error.StreamTooLong` past it.
    ///
    /// **The limit holds the same way** (`max_bytes`, ADR 019), because the
    /// bytes still come through the one counting read. A `std.Io.Reader` can
    /// only say `ReadFailed`, so a failed read through it is turned back into
    /// what happened with `incoming.explain(err)`: `BodyTooLarge`,
    /// `BodyTruncated`, `BadChunk`. `seen` counts what was pulled from the
    /// connection, which is up to one buffer ahead of what the parser has
    /// used.
    ///
    /// **Size the buffer from what the parser needs, never from the request.**
    /// `incoming.size()` is the client's word: `Content-Length: 0` would make
    /// an empty buffer, and a large one would hand the client the memory. An
    /// empty buffer is `error.EmptyBuffer` rather than an assertion, which a
    /// ReleaseFast build does not check and a reader with no room would spin
    /// on.
    ///
    /// Call it once, before reading, and read through the returned reader
    /// from then on.
    pub fn buffered(self: *Body, buffer: []u8) error{EmptyBuffer}!*std.Io.Reader {
        if (buffer.len == 0) return error.EmptyBuffer;
        std.debug.assert(self.reader.end == self.reader.seek);
        self.reader.buffer = buffer;
        self.reader.seek = 0;
        self.reader.end = 0;
        return &self.reader;
    }

    /// The next piece of the body, or null once there is none.
    ///
    /// The slice is `buf`, so it is the caller's memory and lives exactly as
    /// long as the caller decides. Nothing here is copied twice.
    pub fn read(self: *Body, buf: []u8) Error!?[]u8 {
        var out: std.Io.Writer = .fixed(buf);
        const n = self.reader.stream(&out, .limited(buf.len)) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return self.explain(e),
        };
        return buf[0..n];
    }

    /// Pump the whole body into `w`, returning how many bytes that was.
    /// The shortest way to put an upload somewhere.
    pub fn writeTo(self: *Body, w: *std.Io.Writer) Error!u64 {
        var total: u64 = 0;
        while (true) {
            const n = self.reader.stream(w, .unlimited) catch |err| switch (err) {
                error.EndOfStream => return total,
                else => |e| return self.explain(e),
            };
            total += n;
        }
    }

    /// Read and throw away the rest, so the connection is clean. App calls
    /// this for a handler that read part of a body and stopped.
    pub fn discardRest(self: *Body) Error!void {
        while (true) {
            _ = self.reader.discard(.unlimited) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return self.explain(e),
            };
        }
    }

    /// How many bytes of body have been read so far.
    pub fn seen(self: *const Body) u64 {
        return self._progress.seen;
    }

    /// How long the body is, when it said so up front. Null for a chunked
    /// one, which is the whole reason chunked exists.
    ///
    /// Answers the same before, during and after reading.
    pub fn size(self: *const Body) ?u64 {
        return self._progress.announced;
    }

    /// Turn `ReadFailed`, the one error a `Reader` can carry out of `stream`,
    /// back into the one that actually happened: `BodyTooLarge`,
    /// `BodyTruncated` or `BadChunk`, recorded on the way past and read back
    /// here. **Every other error passes through unchanged**, so
    /// `takeDelimiter`'s `StreamTooLong` and `takeInt`'s `EndOfStream` are
    /// still those, and a handler can answer each as what it is.
    pub fn explain(self: *Body, err: anytype) (Error || @TypeOf(err)) {
        if (!std.mem.eql(u8, @errorName(err), "ReadFailed")) return err;
        if (self._progress.state == .cut) return error.BodyTruncated;
        if (self._progress.state == .broken) {
            return if (self._progress.seen > self._progress.max_bytes)
                error.BodyTooLarge
            else
                error.BadChunk;
        }
        return error.ReadFailed;
    }

    /// nilo's own: `Ctx.bodyStream` builds one of these.
    pub fn init(in: *std.Io.Reader, progress: *Progress) Body {
        return .{
            .reader = .{
                .vtable = &.{ .stream = streamFn, .discard = discardFn },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            ._in = in,
            ._progress = progress,
        };
    }

    /// How many bytes may be taken straight from the connection right now,
    /// advancing past chunk framing as needed. Zero means the body is over.
    fn runLength(self: *Body) error{ReadFailed}!u64 {
        const p = self._progress;
        // One byte past the ceiling is asked for, so a body that goes on past
        // it is told from one that ends there; `streamFn` stops it.
        if (self.transported()) return p.max_bytes -| p.seen +| 1;
        while (true) switch (p.state) {
            .sized => |left| return left,
            .chunk => |left| {
                if (left > 0) return left;
                // The CRLF after a chunk's data. Anything else and the sizes
                // and the stream have drifted apart, which is how a smuggled
                // request gets through.
                http1.endOfChunk(self._in) catch return self.breakOff();
                p.state = .between;
            },
            .between => {
                const size_of_chunk = http1.readChunkSize(self._in) catch return self.breakOff();
                if (size_of_chunk == 0) {
                    http1.skipTrailers(self._in) catch return self.breakOff();
                    p.state = .done;
                    return 0;
                }
                if (p.seen + size_of_chunk > p.max_bytes) {
                    p.seen += size_of_chunk;
                    return self.breakOff();
                }
                p.state = .{ .chunk = size_of_chunk };
            },
            .done => return 0,
            .broken, .cut => return error.ReadFailed,
        };
    }

    /// Whether this body is the transport's, and still being read.
    inline fn transported(self: *const Body) bool {
        if (comptime !framing.http2_built) return false;
        return self._progress.transport and self._progress.state == .between;
    }

    /// A read of the transport's body ended in failure. What it was is in the
    /// pipe: a client that stopped sending is a timeout and says no more, and
    /// a stream that was reset or did not add up is a body that ended short.
    fn openFailed(self: *Body) error{ReadFailed} {
        if (comptime framing.http2_built) {
            if (inbound.Inbox.of(self._in).cause()) |why| switch (why) {
                .gone, .length => self._progress.state = .cut,
                .slow, .deadline => {},
            };
        }
        return error.ReadFailed;
    }

    /// What a read of the transport's body that ended says: the end of the
    /// stream is the end of the body, and the rest is as for any other.
    fn openEnded(self: *Body, err: std.Io.Reader.Error) std.Io.Reader.Error {
        switch (err) {
            error.EndOfStream => {
                self._progress.state = .done;
                return error.EndOfStream;
            },
            error.ReadFailed => return self.openFailed(),
        }
    }

    /// The connection ran out while `run` bytes of body were still owed. The
    /// connection's `EndOfStream` is the clean end of a body only when none
    /// are, and `run` is never zero here, so it is not: record it, and let
    /// `explain` say so (ADR 019).
    fn cutShort(self: *Body, err: std.Io.Reader.Error) std.Io.Reader.Error {
        if (err == error.EndOfStream) {
            self._progress.state = .cut;
            return error.ReadFailed;
        }
        return err;
    }

    fn breakOff(self: *Body) error{ReadFailed} {
        self._progress.state = .broken;
        return error.ReadFailed;
    }

    fn advance(self: *Body, n: u64) void {
        const p = self._progress;
        p.seen += n;
        switch (p.state) {
            .sized => |*left| {
                left.* -= n;
                if (left.* == 0) p.state = .done;
            },
            .chunk => |*left| left.* -= n,
            else => {},
        }
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Body = @alignCast(@fieldParentPtr("reader", r));
        // Waiting for the client to send more is not the handler holding its
        // thread, and saying so is what lets a body reader be watched at all
        // rather than excused (ADR 013). Through the slot rather than a
        // pointer on `Body`, because a read is a syscall and the lookup is
        // not.
        const token = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, token);

        const run = try self.runLength();
        if (run == 0) return error.EndOfStream;
        const open = self.transported();
        const n = self._in.stream(w, limit.min(.limited64(run))) catch |err| switch (err) {
            // The writer's own failure is not the connection's end.
            error.WriteFailed => return error.WriteFailed,
            else => |e| return if (open) self.openEnded(e) else self.cutShort(e),
        };
        self.advance(n);
        if (open and self._progress.seen > self._progress.max_bytes) return self.breakOff();
        return n;
    }

    fn discardFn(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *Body = @alignCast(@fieldParentPtr("reader", r));
        const token = watchdog.waiting(self._watch);
        defer watchdog.waited(self._watch, token);

        const run = try self.runLength();
        if (run == 0) return error.EndOfStream;
        const open = self.transported();
        const n = self._in.discard(limit.min(.limited64(run))) catch |err| return if (open) self.openEnded(err) else self.cutShort(err);
        self.advance(n);
        if (open and self._progress.seen > self._progress.max_bytes) return self.breakOff();
        return n;
    }
};

// ---- tests ----

const testing = std.testing;

const Case = struct {
    in: std.Io.Reader,
    progress: Progress,

    fn init(self: *Case, wire: []const u8, request: http1.Request, max_bytes: u64) void {
        self.in = .fixed(wire);
        self.progress = .start(&request, max_bytes);
    }

    fn body(self: *Case) Body {
        return .init(&self.in, &self.progress);
    }
};

fn sized(len: u64) http1.Request {
    return .{ .content_length = len };
}

const chunked_request = http1.Request{ .chunked = true };

test "a Content-Length body arrives in pieces and stops at the right byte" {
    var case: Case = undefined;
    case.init("hello world!next", sized(12), 1024);
    var incoming = case.body();

    try testing.expectEqual(@as(?u64, 12), incoming.size());

    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectEqualStrings(" worl", (try incoming.read(&buf)).?);
    try testing.expectEqualStrings("d!", (try incoming.read(&buf)).?);
    try testing.expectEqual(@as(?[]u8, null), try incoming.read(&buf));
    try testing.expectEqual(@as(u64, 12), incoming.seen());

    // The connection is left at the next request, not one byte off.
    try testing.expect(case.progress.finished());
    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "a chunked body is de-framed, and its size is not known up front" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\nnext", chunked_request, 1024);
    var incoming = case.body();

    try testing.expectEqual(@as(?u64, null), incoming.size());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const total = try incoming.writeTo(&out.writer);

    try testing.expectEqualStrings("hello, world", out.written());
    try testing.expectEqual(@as(u64, 12), total);

    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "a read can land in the middle of a chunk" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n", chunked_request, 1024);
    var incoming = case.body();

    // Four bytes at a time through chunks of five and seven: the framing is
    // not something the handler's buffer size has to line up with.
    var buf: [4]u8 = undefined;
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    while (try incoming.read(&buf)) |part| try seen.appendSlice(testing.allocator, part);

    try testing.expectEqualStrings("hello, world", seen.items);
}

test "an empty body is over before it starts" {
    var case: Case = undefined;
    case.init("", sized(0), 1024);
    var incoming = case.body();

    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), try incoming.read(&buf));
    try testing.expectEqual(@as(u64, 0), incoming.seen());
}

test "a chunked body past the limit is refused rather than swallowed" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n", chunked_request, 8);
    var incoming = case.body();

    var buf: [16]u8 = undefined;
    // The first chunk fits under the limit; the second is what crosses it,
    // and it is refused before its bytes are read.
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectError(error.BodyTooLarge, incoming.read(&buf));
    try testing.expectEqual(Progress.State.broken, case.progress.state);
}

test "chunk sizes that have come apart from the stream stop the reader" {
    var case: Case = undefined;
    // The chunk says five bytes and there is no CRLF where one has to be.
    case.init("5\r\nhelloXX\r\n0\r\n\r\n", chunked_request, 1024);
    var incoming = case.body();

    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectError(error.BadChunk, incoming.read(&buf));
    try testing.expectEqual(Progress.State.broken, case.progress.state);
}

test "the rest of a body nobody wanted is discarded, and the connection survives" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\nnext", chunked_request, 1024);
    var incoming = case.body();

    var buf: [3]u8 = undefined;
    _ = try incoming.read(&buf);
    try incoming.discardRest();

    try testing.expect(case.progress.finished());
    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "reading nothing and then discarding is the same as never asking" {
    var case: Case = undefined;
    case.init("hello worldnext", sized(11), 1024);
    var incoming = case.body();
    try incoming.discardRest();

    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "the announced size is still there after the body has been read" {
    var case: Case = undefined;
    case.init("hello world!", sized(12), 1024);
    var incoming = case.body();

    var buf: [16]u8 = undefined;
    while (try incoming.read(&buf)) |_| {}

    // Worked out from what was left, this went null the moment the body
    // ended — which is exactly when a handler wants to report on it.
    try testing.expectEqual(@as(?u64, 12), incoming.size());
    try testing.expectEqual(@as(u64, 12), incoming.seen());
}

test "an upload the connection ended before its Content-Length is a failure on every way of reading it" {
    var buf: [16]u8 = undefined;

    var by_read: Case = undefined;
    by_read.init("hello", sized(12), 1024);
    var a = by_read.body();
    try testing.expectEqualStrings("hello", (try a.read(&buf)).?);
    try testing.expectError(error.BodyTruncated, a.read(&buf));
    try testing.expectEqual(Progress.State.cut, by_read.progress.state);

    var by_write: Case = undefined;
    by_write.init("hello", sized(12), 1024);
    var b = by_write.body();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.BodyTruncated, b.writeTo(&out.writer));

    var by_discard: Case = undefined;
    by_discard.init("hello", sized(12), 1024);
    var c = by_discard.body();
    try testing.expectError(error.BodyTruncated, c.discardRest());

    // Inside a chunk's data too, and nothing can be read from it after.
    var chunked: Case = undefined;
    chunked.init("a\r\n01234", chunked_request, 1024);
    var d = chunked.body();
    try testing.expectEqualStrings("01234", (try d.read(&buf)).?);
    try testing.expectError(error.BodyTruncated, d.read(&buf));
    try testing.expectError(error.BodyTruncated, d.read(&buf));
    try testing.expectEqual(Progress.State.cut, chunked.progress.state);
}

test "a JSON body bigger than the buffer is parsed by std.json.Reader through buffered" {
    var case: Case = undefined;
    const doc = "{\"items\":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20],\"name\":\"a fairly long string value\"}";
    case.init(doc ++ "next", sized(doc.len), 1024);
    var incoming = case.body();
    var buf: [16]u8 = undefined;
    var json_reader: std.json.Reader = .init(testing.allocator, try incoming.buffered(&buf));
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(
        struct { items: []const u32, name: []const u8 },
        testing.allocator,
        &json_reader,
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 20), parsed.value.items.len);
    try testing.expectEqualStrings("a fairly long string value", parsed.value.name);
    try testing.expectEqual(@as(u64, doc.len), incoming.seen());
    // Past the last byte of the body is the next request's, untouched.
    try testing.expect(case.progress.finished());
}

test "NDJSON lines arrive one at a time through buffered, across chunk edges" {
    var case: Case = undefined;
    case.init("4\r\none\n\r\n1\r\n\n\r\n8\r\ntwo\nthre\r\n3\r\ne\n\n\r\n0\r\n\r\n", chunked_request, 1024);
    var incoming = case.body();
    var buf: [8]u8 = undefined;
    const r = try incoming.buffered(&buf);

    try testing.expectEqualStrings("one", (try r.takeDelimiter('\n')).?);
    try testing.expectEqualStrings("", (try r.takeDelimiter('\n')).?);
    try testing.expectEqualStrings("two", (try r.takeDelimiter('\n')).?);
    try testing.expectEqualStrings("three", (try r.takeDelimiter('\n')).?);
    try testing.expectEqualStrings("", (try r.takeDelimiter('\n')).?);
    try testing.expectEqual(@as(?[]u8, null), try r.takeDelimiter('\n'));
    try testing.expect(case.progress.finished());
}

test "a line longer than the buffer is StreamTooLong and not a spin" {
    var case: Case = undefined;
    case.init("a line that does not fit\n", sized(24), 1024);
    var incoming = case.body();
    var buf: [8]u8 = undefined;
    const r = try incoming.buffered(&buf);
    try testing.expectError(error.StreamTooLong, r.takeDelimiter('\n'));
    // `explain` leaves it as what it is, for a handler to answer as such.
    try testing.expectEqual(error.StreamTooLong, incoming.explain(error.StreamTooLong));
    try testing.expectEqual(error.EndOfStream, incoming.explain(error.EndOfStream));
}

test "buffered refuses a buffer with no room, and a handler need not size one from the request" {
    var case: Case = undefined;
    case.init("", sized(0), 1024);
    var incoming = case.body();
    var none: [0]u8 = undefined;
    try testing.expectError(error.EmptyBuffer, incoming.buffered(&none));
}

test "a body past the limit is still refused through buffered, and explain says why" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n", chunked_request, 8);
    var incoming = case.body();
    var buf: [4]u8 = undefined;
    const r = try incoming.buffered(&buf);

    var out: [16]u8 = undefined;
    const err = r.readSliceAll(&out);
    try testing.expectError(error.ReadFailed, err);
    try testing.expectEqual(error.BodyTooLarge, incoming.explain(error.ReadFailed));
}

test "a body the connection cut short is BodyTruncated through buffered" {
    var case: Case = undefined;
    case.init("only ten b", sized(20), 1024);
    var incoming = case.body();
    var buf: [4]u8 = undefined;
    const r = try incoming.buffered(&buf);

    var out: [32]u8 = undefined;
    try testing.expectError(error.ReadFailed, r.readSliceAll(&out));
    try testing.expectEqual(error.BodyTruncated, incoming.explain(error.ReadFailed));
}

test "what a handler left in the buffer does not stop the rest being discarded" {
    var case: Case = undefined;
    case.init("0123456789next", sized(10), 1024);
    var incoming = case.body();
    var buf: [4]u8 = undefined;
    const r = try incoming.buffered(&buf);
    try testing.expectEqualStrings("012", try r.take(3));

    try incoming.discardRest();
    try testing.expect(case.progress.finished());
    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}
