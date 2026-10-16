//! nilo_fetch with `-Dfetch_gzip`: one GET on a pooled keep-alive connection
//! to an upstream that answers under `Content-Encoding: gzip`, the body
//! decoded into the Scope (ADR 292).
//!
//! The same shape as `fetch.zig`, and the difference between the two is the
//! decode: the gzip stream is made once, in `init`, so the upstream's work is
//! a constant write and what is left in the difference is the client's. The
//! decoded body is `decoded_len` bytes of JSON; `bench/result/fetch.md` has
//! the 4 KiB and the 1 MiB figures, the second from this file with the
//! constant changed. Built only when the release package is given
//! `-Dfetch_gzip` (`bench/release/build.zig`), because a ref older than the
//! flag would refuse the option; `bench/release.py` does not run it.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");
const harness = @import("harness");

/// The decoded length of the answer.
const decoded_len = 4096;

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Program = struct {
    /// On the heap, because an `Io` points at its `Threaded` and the client's
    /// pool points at the client, and `init` returns the Program by value.
    state: *State,

    const State = struct {
        threaded: std.Io.Threaded,
        client: fetch.Client,
        upstream: Upstream,
        url_buf: [64]u8,
        url: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.threaded = .init(gpa, .{});
        errdefer state.threaded.deinit();
        const io = state.threaded.io();

        Upstream.answer = try answerFor(gpa);
        try state.upstream.open(io);
        state.url = try std.fmt.bufPrint(&state.url_buf, "http://127.0.0.1:{d}/", .{state.upstream.port});

        state.client = .init(gpa, .{ .timeout_ms = 0 });
        try state.client.nilo_start(io, .off);
        return .{ .state = state };
    }

    /// The client closes its pooled connection, which ends the upstream's
    /// connection thread. The `Threaded` and the state are left for the
    /// process to take: the upstream's threads are detached and still hold
    /// the `Io`, and freeing it under them is a use after free for nothing.
    pub fn deinit(self: *Program) void {
        self.state.client.deinit();
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var scope: Scope = .{ .memory = scratch, .lifetime = .init() };
        defer scope.lifetime.deinit();
        const res = try self.state.client.get(&scope, self.state.url, .{});
        if (res.status != .ok or res.body.view().len != decoded_len) return error.WrongAnswer;
        harness.keep(res.body.view().ptr);
    }
};

/// A Scope over the harness's counting arena, so every allocation the call
/// makes is one the harness sees. A `Run` would put its own arena between
/// them and count only the arena's chunks.
const Scope = struct {
    memory: std.mem.Allocator,
    lifetime: core.Lifetime,

    pub fn arena(self: *Scope) std.mem.Allocator {
        return self.memory;
    }

    pub fn str(self: *Scope, bytes: []const u8) core.Str {
        return .fromRequest(bytes, &self.lifetime);
    }
};

/// Keep-alive HTTP/1.1 on loopback, the same fixed answer to every request.
/// The answer is one constant written with one flush, so each call is one
/// read and one write on either side and nothing in it varies run to run.
const Upstream = struct {
    /// The whole answer, head and gzip stream, built by `answerFor` before
    /// the thread that serves it exists.
    var answer: []const u8 = "";

    server: std.Io.net.Server,
    port: u16,

    /// Bound here, before the thread exists, so the port is known and the
    /// first call cannot race the listen.
    fn open(self: *Upstream, io: std.Io) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        self.server = try address.listen(io, .{});
        self.port = self.server.socket.address.getPort();
        const thread = try std.Thread.spawn(.{}, accept, .{ self.server, io });
        thread.detach();
    }

    fn accept(server: std.Io.net.Server, io: std.Io) void {
        var listening = server;
        while (true) {
            const stream = listening.accept(io) catch return;
            const thread = std.Thread.spawn(.{}, serve, .{ stream, io }) catch {
                stream.close(io);
                continue;
            };
            thread.detach();
        }
    }

    fn serve(stream: std.Io.net.Stream, io: std.Io) void {
        defer stream.close(io);
        var in_buf: [4096]u8 = undefined;
        var out_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        while (true) {
            // A GET has no body, so the blank line ends the request.
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
            }
            writer.interface.writeAll(answer) catch return;
            writer.interface.flush() catch return;
        }
    }
};

/// What the upstream sends: `decoded_len` bytes of JSON, gzipped once.
fn answerFor(gpa: std.mem.Allocator) ![]const u8 {
    var plain: std.Io.Writer.Allocating = .init(gpa);
    defer plain.deinit();
    var i: usize = 0;
    try plain.writer.writeByte('[');
    while (plain.written().len < decoded_len - 80) : (i += 1) {
        if (i != 0) try plain.writer.writeByte(',');
        try plain.writer.print("{{\"id\":{d},\"name\":\"host-{d}\",\"state\":\"running\"}}", .{ i, i % 17 });
    }
    // Padded to the length the client checks, with the closing bracket last.
    while (plain.written().len < decoded_len - 1) try plain.writer.writeByte(' ');
    try plain.writer.writeByte(']');

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, decoded_len + 1024);
    errdefer out.deinit();
    try out.writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: ");
    // The stream first, to know its length.
    var packed_bytes: std.Io.Writer.Allocating = try .initCapacity(gpa, decoded_len + 1024);
    defer packed_bytes.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&packed_bytes.writer, window, .gzip, .default);
    try c.writer.writeAll(plain.written());
    try c.finish();
    try out.writer.print("{d}\r\n\r\n", .{packed_bytes.written().len});
    try out.writer.writeAll(packed_bytes.written());
    return out.toOwnedSlice();
}
