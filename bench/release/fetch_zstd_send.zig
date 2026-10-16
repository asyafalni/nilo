//! nilo_fetch with `-Dzstd`: one POST of a JSON body sent under a coding, on a
//! pooled keep-alive connection to an upstream that reads the body and says
//! 200 (ADR 293, ADR 295). The body is compressed on the compressor the
//! `Client` keeps, so the difference over the difference is the codec and
//! the framing, which is what a call that names a coding costs.
//!
//! `coding` is `fetch.zstd` or `fetch.gzip` and `body_len` is the plain
//! length; `bench/result/fetch.md` has the 4 KiB and the 1 MiB figures, one
//! from each constant. Built only when the release package is given `-Dzstd`
//! (`bench/release/build.zig`), because a ref older than the flag would refuse
//! the option; `bench/release.py` does not run it.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");
const harness = @import("harness");

/// The plain length of the body.
const body_len = 4096;
/// What the call names.
const coding = fetch.zstd;

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Program = struct {
    state: *State,

    const State = struct {
        threaded: std.Io.Threaded,
        client: fetch.Client,
        upstream: Upstream,
        url_buf: [64]u8,
        url: []const u8,
        body: []u8,
    };

    pub fn init(gpa: std.mem.Allocator) !Program {
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);
        state.threaded = .init(gpa, .{});
        errdefer state.threaded.deinit();
        const io = state.threaded.io();

        state.body = try bodyFor(gpa);
        try state.upstream.open(io);
        state.url = try std.fmt.bufPrint(&state.url_buf, "http://127.0.0.1:{d}/", .{state.upstream.port});

        state.client = .init(gpa, .{ .timeout_ms = 0 });
        try state.client.nilo_start(io, .off);
        return .{ .state = state };
    }

    pub fn deinit(self: *Program) void {
        self.state.client.deinit();
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, _: usize) !void {
        var scope: Scope = .{ .memory = scratch, .lifetime = .init() };
        defer scope.lifetime.deinit();
        const res = try self.state.client.post(&scope, self.state.url, self.state.body, .{ .encoding = coding });
        if (res.status != .ok or res.sent_encoding == null) return error.WrongAnswer;
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

/// Keep-alive HTTP/1.1 on loopback: the request read to its last body byte,
/// the same fixed answer to every one.
const Upstream = struct {
    const answer = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";

    server: std.Io.net.Server,
    port: u16,

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
        var in_buf: [16384]u8 = undefined;
        var out_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        while (true) {
            var length: usize = 0;
            while (true) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                if (line.len <= 2) break;
                if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                    length = std.fmt.parseInt(usize, std.mem.trim(u8, line["content-length:".len..], " \t\r\n"), 10) catch return;
                }
            }
            reader.interface.discardAll(length) catch return;
            writer.interface.writeAll(answer) catch return;
            writer.interface.flush() catch return;
        }
    }
};

/// `body_len` bytes of the JSON an agent posts: container inventory records,
/// padded with spaces to the length.
fn bodyFor(gpa: std.mem.Allocator) ![]u8 {
    var plain: std.Io.Writer.Allocating = .init(gpa);
    errdefer plain.deinit();
    var i: usize = 0;
    try plain.writer.writeByte('[');
    while (plain.written().len < body_len - 80) : (i += 1) {
        if (i != 0) try plain.writer.writeByte(',');
        try plain.writer.print("{{\"id\":{d},\"name\":\"container-{d}\",\"state\":\"running\"}}", .{ i, i % 7 });
    }
    while (plain.written().len < body_len - 1) try plain.writer.writeByte(' ');
    try plain.writer.writeByte(']');
    return plain.toOwnedSlice();
}
