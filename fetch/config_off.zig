//! What `build.zig` generates as `fetch_config` for a build without
//! `-Dfetch_gzip` and `-Dfetch_zstd`, written down so that `zig test
//! fetch/fetch.zig` runs standalone (ADR 292, ADR 295). The build does not
//! read this file.
pub const gzip = false;
pub const zstd = false;
