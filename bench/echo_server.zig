//! A 10 KB body posted and handed straight back, over TLS and in plain, from
//! one binary: what the record layer costs when both directions are loaded at
//! once.
//!
//! ADR 212 measured the handshake and what a request costs on a connection
//! kept alive, and left one row open in so many words: "Throughput at
//! saturation over `https://` was not measured, for want of a load generator
//! with TLS on the box." This is the server for that row. The shape is the
//! benchmark arena's `8gbit` profile, which is the only profile anywhere here
//! that loads ingest and egress together: `POST /echo`, 10 KB up, the same
//! 10 KB back, 512 connections, a rate held at 50,000 req/s. That is 512 MB/s
//! through the decrypt path and 512 MB/s through the encrypt path, and the
//! question is what of it is the encryption and what is everything else.
//!
//! **TLS is a switch rather than a second binary**, for the reason
//! `bench/tls_server.zig` gives: a difference between two builds that is not
//! the encryption gets measured as the encryption. Here the plain run and the
//! TLS run are the same bytes of machine code with `ECHO_TLS` unset or set.
//! The build is still `-Dtls`, so both sides also carry the page per idle
//! connection that flag costs every listener (ADR 212), and neither side has
//! an advantage the other lacks.
//!
//! ```
//! zig build -Dtls -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3+aes+pclmul bench-echo-server
//!
//! ./zig-out/bin/nilo-bench-echo-server                    # plain, :8793
//! ECHO_TLS=1 ./zig-out/bin/nilo-bench-echo-server         # TLS, the same port
//! ECHO_WRITE_BUFFER=16384 ECHO_TLS=1 ./zig-out/bin/…      # one record, not three
//! ```
//!
//! **`-Dcpu` is not a detail on this one.** Zig's `x86_64_v3` carries no
//! `aes` and no `pclmul`, and `std.crypto`'s AES-128-GCM without them is
//! 74 MB/s on a core against 5,867 with them. tls.zig prefers ChaCha20 when
//! it finds no hardware AES, but the server takes the first suite in the
//! *client's* list it supports (`handshake_server.zig`), and an OpenSSL
//! client offers AES-128-GCM first, so the fallback never runs. Build this
//! for a machine with the instructions or the number is about the build.
//!
//! Three routes, each taking a layer off the one above:
//!
//! - `/health` — a constant, no `Ctx`, no body. The floor both transports
//!   share, and the same route the other bench servers use for it.
//! - `/drop` — the body arrives and nobody asks for it. nilo reads it to
//!   leave the connection clean, so this is ingest with no egress and no
//!   hold: what the decrypt path costs on its own.
//! - `/echo` — the profile's route. `c.body()` in, the same bytes out.
//!
//! The load generator is whatever is on the box; `bench/result/http.md`
//! carries what was used and what each side was pinned to.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// The floor: no `Ctx`, no body, no allocation.
fn health() []const u8 {
    return "alive\n";
}

/// Ingest alone. The bytes arrive and are discarded by the framework, so
/// what this costs over TLS is the decrypt path and nothing else.
fn drop(c: *nilo.Ctx) !void {
    try c.sendText(200, "dropped\n");
}

/// The profile's contract: the bytes that arrived, unchanged, under the type
/// they arrived as. Not a buffer of the right size and not a length read off
/// `Content-Length` — the arena's validation posts random bodies and compares
/// them byte for byte, so answering without reading fails there.
fn echo(c: *nilo.Ctx) !void {
    const body = try c.body();
    try c.send(200, "application/octet-stream", body.view());
}

/// A positive number in `name`, or `fallback` when it is unset or unreadable.
fn envNumber(comptime T: type, environ: anytype, name: []const u8, fallback: T) T {
    const raw = environ.getPosix(name) orelse return fallback;
    if (raw.len == 0) return fallback;
    return std.fmt.parseInt(T, raw, 10) catch fallback;
}

pub fn main(init: std.process.Init) !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/health", health);
    try app.post("/drop", drop);
    try app.post("/echo", echo);

    const environ = init.minimal.environ;
    const port = envNumber(u16, environ, "ECHO_PORT", 8793);
    // nilo's own default, so the plain run is what a caller would get. A
    // 10 KB answer leaves as three records at this size and one at 16 KB,
    // which is the second thing this server exists to put a number on.
    const write_buffer = envNumber(usize, environ, "ECHO_WRITE_BUFFER", 4 * 1024);
    // Both sides of a saturation run get pinned, or the number is about the
    // scheduler rather than the server. A cpuset without this is still
    // sixteen executors on eight CPUs.
    const threads = envNumber(u8, environ, "ECHO_THREADS", 0);
    const tls_on = environ.getPosix("ECHO_TLS") != null;

    // The suite's own fixture, read relative to the checkout: run from the
    // repository root, and point the client at it with verification off.
    const material: nilo.Options.Tls = .{
        .cert = "http/testdata/tls/localhost.pem",
        .key = "http/testdata/tls/localhost-key.pem",
    };

    std.log.info("echo server on :{d}, tls={}, write_buffer={d}, threads={d}", .{ port, tls_on, write_buffer, threads });
    try app.listen(.{
        .address = "0.0.0.0",
        .port = port,
        .write_buffer = write_buffer,
        .threads = threads,
        .tls = if (tls_on) material else null,
    });
}

test "the echo routes are ordinary handlers" {
    try std.testing.expectEqualStrings("alive\n", health());
}
