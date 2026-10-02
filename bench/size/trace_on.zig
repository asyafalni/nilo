//! The fourth axis for `app.trace` (ADR 017, ADR 247): the server of
//! [`s3_none.zig`](./s3_none.zig) with one line added, the call that turns
//! tracing on.
//!
//!     zig build size-trace
//!     ls -l zig-out/bin/nilo-size-trace-* zig-out/bin/nilo-size-s3_none
//!
//! The difference against `s3_none` is what tracing costs a program that
//! asks for it: the exporter, `nilo_fetch` and `std.http.Client` under it,
//! TLS, and the protobuf writer. `s3_none` built before and after the change
//! is what it costs a program that does not, which ADR 247 says is the
//! number that has to stay small.

const std = @import("std");
const nilo = @import("nilo_http");

fn avatar(c: *nilo.Ctx, id: nilo.Str) !void {
    const bytes = try c.arena().alloc(u8, 1024);
    @memset(bytes, 'x');
    _ = id;
    return c.send(200, "application/octet-stream", bytes);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.trace(.{ .service = "avatars" });
    try app.get("/avatars/:id", avatar);
    try app.listen(.{ .port = 8080 });
}
