//! The reading side of a compressed answer, for the builds that asked for it
//! ([ADR 292](../docs/adr/292-a-fetch-build-can-read-a-gzip-answer.md) for
//! gzip, [ADR 295](../docs/adr/295-zstd-is-a-module-whose-contexts-are-the-callers-memory.md)
//! for zstd).
//!
//! **A coding is a case here and nowhere else.** `Coding` is the list,
//! `coding` maps the answer's `Content-Encoding` to one this build reads,
//! `open` is the one switch on it, and `fetch.zig` names only those and a
//! `Reading`. A `Reading` is a header (the wire it reads from, the decoded
//! face a caller reads, two questions to ask after a failure) that sits at
//! the front of a decoder allocated from the client's allocator when an
//! answer announces its coding and given back by `Exchange.end`. The
//! decoders are `gzip.zig` and `zstd_read.zig`; neither is analysed by a
//! build whose constant for it is false, so a program that dials out without
//! `-Dfetch_gzip` or `-Dfetch_zstd` links no codec and holds no window.

const std = @import("std");
const config = @import("fetch_config");

/// Whether this build reads a gzip answer (`-Dfetch_gzip`).
pub const reads_gzip = config.gzip;
/// Whether this build reads a zstd answer (`-Dfetch_zstd`).
pub const reads_zstd = config.zstd;

/// The codings this build reads. `deflate` is ambiguous on the wire
/// (zlib-wrapped by the RFC, raw by habit) and nobody sends it.
pub const Coding = enum { gzip, zstd };

/// What the answer's `Content-Encoding` is, when this build reads it.
pub fn coding(encoding: std.http.ContentEncoding) ?Coding {
    return switch (encoding) {
        .gzip => if (reads_gzip) .gzip else null,
        .zstd => if (reads_zstd) .zstd else null,
        else => null,
    };
}

/// The value of `Accept-Encoding` a call sends in this build, best coding
/// first: zstd compresses a body smaller and faster than gzip, and a server
/// that reads only gzip picks gzip (RFC 9110 section 12.5.3). `identity`
/// stays last so a server that cannot compress is not refused.
pub const advertised = if (reads_zstd and reads_gzip)
    "zstd, gzip, identity"
else if (reads_zstd)
    "zstd, identity"
else if (reads_gzip)
    "gzip, identity"
else
    "identity";

/// The front of a decoder. Address sensitive (the decoder is found from it
/// by `@fieldParentPtr`), so a decoder is made on the heap and never moved.
pub const Reading = struct {
    /// The body as the connection delivers it, compressed: `tap` under a
    /// `stall_ms`, std's own reader otherwise. `Exchange.end` drains this one
    /// and never the decoded side, so a bomb is not decoded to be thrown away.
    source: *std.Io.Reader,
    /// The decoded body as the caller reads it. Unbuffered.
    out: std.Io.Reader,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (self: *Reading) void,
        undecodable: *const fn (self: *const Reading) bool,
        outOfMemory: *const fn (self: *const Reading) bool,
    };

    /// Nothing is read from `source` until the first read of `reader()`.
    pub fn open(gpa: std.mem.Allocator, source: *std.Io.Reader, how: Coding) error{OutOfMemory}!*Reading {
        return switch (how) {
            .gzip => if (comptime reads_gzip) try @import("gzip.zig").Gunzip.open(gpa, source) else unreachable,
            .zstd => if (comptime reads_zstd) try @import("zstd_read.zig").Unzstd.open(gpa, source) else unreachable,
        };
    }

    pub fn close(self: *Reading) void {
        self.vtable.close(self);
    }

    /// The decoded body.
    pub fn reader(self: *Reading) *std.Io.Reader {
        return &self.out;
    }

    /// Whether the last `ReadFailed` of `reader()` was the bytes and not the
    /// connection: a header that is not the coding, a block that does not
    /// decode, a checksum or a length that disagrees, a body that ends before
    /// the stream does. A failure of the connection is the same error the
    /// decoder gets from `source`, and it is the caller's to blame on a clock.
    pub fn undecodable(self: *const Reading) bool {
        return self.vtable.undecodable(self);
    }

    /// Whether the last `ReadFailed` was the decoder's own memory running
    /// out (a zstd decoder is sized from the frame, when the first bytes
    /// are in).
    pub fn outOfMemory(self: *const Reading) bool {
        return self.vtable.outOfMemory(self);
    }
};

test {
    if (reads_gzip) _ = @import("gzip.zig");
    if (reads_zstd) _ = @import("zstd_read.zig");
}
