# The transfer buffer serves nothing here

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

This replaces the `Begin.transfer_buffer` doc comment, the fetch guide's "bigger is fewer trips", the S3 guide's "the buffer is yours because its cost is yours", and lever 2 in `bench/result/fetch.md`.

`Begin.transfer_buffer` was documented as "what the body is read through:
bigger is fewer trips into the connection for a large object and more stack
held per connection", and `Client.send` declared 4 KiB of it. fdm read that
and gave every segment 64 KiB, sixteen segments, a mebibyte of stack per
download. Then it counted read syscalls through `/proc/<pid>/io` on a
38.8 MB object over TLS: 19,860 and 14,892 with 64 KiB, 18,758 and 19,032
with none. About 2.5 KB a read either way, the same hash, and the number
that decides the read size is `std.http.Client.read_buffer_size`, 8 KiB by
default, which nilo's `init` left at the default and `Settings` did not
name.

`std.http.bodyReader` says what the buffer is. It is the body reader's own
`std.Io.Reader.buffer`, and `stream` on a content-length body is
`reader.in.stream(w, limit)`: from the connection's reader, which has its
own buffer, straight into the caller's writer. The chunked path is the same
call with the chunk framing parsed out of `in` first. The buffer is filled
only by the *buffered* reads (`take`, `peek`, a delimiter) and by
`readVec` when the destination is smaller than the buffer, in which case it
is a copy the direct path would not have made. Nothing `nilo_fetch` does
with the body is one of those. `s3/bucket.zig` had already seen it without
reading it that way: `bench/result/s3.md` records dropping the streaming
route's buffer from 64 KB to 8 KB as worth one byte, and concluded the
lever was depth.

## Decision

**The buffer is documented as what it is, and nothing here declares one.**
`Begin.transfer_buffer` stays, for the caller who reads buffered off
`ex.reader`, and its comment says that `take`, `readInto`, `pipe` and
`stream` never fill it and that it does not change how much one socket read
brings in. `Client.send` no longer declares 4 KiB of it. `s3/bucket.zig`
no longer declares four 512-byte ones and a 4 KiB one, and
**`Bucket.stream(c, key, &reading)` no longer takes a buffer**, because a
parameter whose size the guide told the caller to weigh, and which no byte
ever crossed, is a false premise with an API around it.

**`Settings.read_buffer_size` is the number that does decide it**, passed
through to `std.http.Client`. It is per connection and lives on the heap
beside it, which is the right place for a download manager's sixteen
sockets and the wrong place for a handler's one call, so the default is
std's 8 KiB and the field says so. Whether 64 KiB there cuts fdm's syscalls
is a measurement fdm can make the day the field exists, and could not
before.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | `/call` at 5,000 connections moved from 9,450 to 9,437 bytes, interleaved twice, with ADR 056's 64 bytes of `Exchange` in the same diff: inside the spread. **The 4 KiB was never a resident page**: a stack buffer no byte touches is never faulted in, and ADR 062's per-connection figure counts pages. So lever 2 of `bench/result/fetch.md` (shrink the buffers) is measured now, and worth nothing |
| Throughput and p99 | unchanged; the direct path is the path it always took |
| Binary size | unchanged |

What it cost was the claim. Three documents said the buffer was the body's
window and its size was the caller's trade, one caller planned a mebibyte
against it, and a benchmark had the disproof on file under a different
heading.

## What was rejected

**An `Exchange` that carries its own 4 KiB inline**, so the ordinary call
declares nothing, the proposal's third item. It answers the wrong
question: the ordinary call *already* declares nothing, because an empty
buffer is not a missing one. Five kilobytes on the stack of every handler
that dials out, and of every S3 call that passes its own, to hold a buffer
the direct path never reads.

**Keeping `Bucket.stream`'s parameter and documenting it as unused.** An
argument that does nothing is a sentence in the reference nobody reads
before writing `var transfer: [64 * 1024]u8`, which is what the guide's own
example did.

## What proves it

`fetch/live.zig` reads a chunked body into the Scope through an empty
buffer, which is the framing that would go through one if any did, and a
100 KiB body through a client whose `read_buffer_size` is 64 KiB. Every
existing test in `fetch/live.zig` and `s3/canned.zig` passes with the
buffers gone, and `zig build snippets` compiles the guide examples that no
longer declare one.
