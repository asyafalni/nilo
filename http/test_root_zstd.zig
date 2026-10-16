//! The root of the zstd request tests, built with `nilo_build.zstd` on
//! whatever the flag said ([ADR 295](../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)).
//!
//! `test_root.zig` is the suite as a dependent gets it, where `zstd` is an
//! encoding the server does not read. This one compiles `zstd_request.zig`
//! alone, so the path that reads it is held by `zig build test` without
//! `-Dzstd`, for the price of the files that file reaches and not a second
//! pass over the whole suite.

test {
    _ = @import("zstd_request.zig");
}
