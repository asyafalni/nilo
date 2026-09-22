//! The benchmark target again, over TLS: the same routes, the same handlers,
//! the same ~1KB answer, with a TLS 1.3 handshake in front of the first
//! request on every connection. Built only under `-Dtls` (ADR 0288).
//!
//! It exists so the plain one has a control. `bench/mem.py --tls` reads
//! what an idle TLS connection holds against what a plain one holds, and
//! `wrk` over `https://` reads what the encryption costs a request; both
//! numbers are in `bench/result/http.md`, and the ones ADR 0288 quotes came
//! from here. Nothing is registered that `bench/main.zig` does not
//! register, because anything added here would be measured as TLS.
//!
//! The certificate is the suite's fixture, `http/testdata/tls/localhost.pem`,
//! read relative to the checkout: run it from the repository root, and point
//! a client at it with verification off (`curl -k`, `wrk` does not verify).

const std = @import("std");
const nilo = @import("nilo_http");
const plain = @import("main.zig");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

pub fn main() !void {
    var db = plain.Db{ .max_id = 1_000_000 };

    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.provide(&db);
    // The same middleware, for the same reason: a difference between the
    // two binaries that is not the encryption would be measured as it.
    try app.use(nilo.cors.permissive);
    try app.get("/users/:id", plain.getUser);
    try app.get("/health", plain.health);

    try app.listen(.{ .tls = .{
        .cert = "http/testdata/tls/localhost.pem",
        .key = "http/testdata/tls/localhost-key.pem",
    } });
}
