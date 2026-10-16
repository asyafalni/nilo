//! A test that sends a zstd body in a build that does not read zstd. The
//! server would answer 415, so the helper that writes the frame refuses to
//! exist until `.zstd = true` is passed (ADR 295).

const nilo = @import("nilo_http");

export fn refusal() void {
    var arena: @import("std").heap.ArenaAllocator = undefined;
    _ = nilo.testing.zstd(arena.allocator(), "{}") catch {};
}
