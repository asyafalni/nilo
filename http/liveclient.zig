//! The receive side of the live tests' clients: a reader over a socket whose
//! every read is bounded, and says what it was waiting for when the bound
//! runs out.
//!
//! The bound used to be `SO_RCVTIMEO` on the socket, which `std.Io.Threaded`
//! reads as a programmer bug when it fires (`EAGAIN` from a blocking read goes
//! to `errnoBug`), so a test that waited too long crashed the whole suite with
//! `programmer bug caused syscall error: AGAIN` and named nothing. std 0.17
//! has a timeout for datagram receives and for batches, and none for a stream
//! reader, so this polls the descriptor before each read instead, the way
//! `tls_live.zig`'s `readSome` already did. Only a test imports this file, so
//! it adds nothing to the shipped surface.
//!
//! A timeout returns `error.ReadFailed` through the `std.Io.Reader` interface,
//! like any other failed read, with `err` set to `error.TestReceiveTimedOut`
//! and a `warn` line naming `what`. It is `warn` and not `err` because the
//! `err` level is the server refusing to start (`CLAUDE.md`).

const std = @import("std");

const log = std.log.scoped(.live_client);

/// How long a read may wait. Long enough for a loaded 2-core box, short
/// enough that a stall is a failed test.
pub const default_limit_ms: i32 = 5_000;

pub const Reader = struct {
    io: std.Io,
    interface: std.Io.Reader,
    stream: std.Io.net.Stream,
    /// What the test is waiting for, in the words of the failure line.
    what: []const u8,
    limit_ms: i32,
    /// `error.TestReceiveTimedOut` after a timeout, or the read's own failure.
    err: ?anyerror,

    /// `what` is a short label for the failure line; `@src().fn_name` at the
    /// call site names the test or helper that was waiting.
    pub fn init(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, what: []const u8) Reader {
        return initWithLimit(stream, io, buffer, what, default_limit_ms);
    }

    pub fn initWithLimit(stream: std.Io.net.Stream, io: std.Io, buffer: []u8, what: []const u8, limit_ms: i32) Reader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .what = what,
            .limit_ms = limit_ms,
            .err = null,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    /// `std.Io.net.Stream.Reader.readVec` with a poll in front of the read.
    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        var fds = [_]std.posix.pollfd{.{ .fd = r.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, r.limit_ms) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (ready == 0) {
            log.warn("no answer within {d} ms while waiting for {s}", .{ r.limit_ms, r.what });
            r.err = error.TestReceiveTimedOut;
            return error.ReadFailed;
        }

        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const result = r.stream.readWithControl(r.io, dest, &.{}) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (result.data_len == 0) return error.EndOfStream;
        if (result.data_len > data_size) {
            io_r.end += result.data_len - data_size;
            return data_size;
        }
        return result.data_len;
    }
};

test "a read that waits for a server that never answers fails naming what it waited for" {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Listening and never accepting: the kernel completes the handshake from
    // its backlog, so the connect succeeds and the read has nothing to get.
    const bind: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var silent = try bind.listen(io, .{});
    defer silent.deinit(io);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(silent.socket.address.getPort()) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var buf: [64]u8 = undefined;
    var reader: Reader = .initWithLimit(stream, io, &buf, "an answer that never comes", 100);
    try std.testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try std.testing.expectEqual(@as(?anyerror, error.TestReceiveTimedOut), reader.err);
}
