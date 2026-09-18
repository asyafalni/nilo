# 0244 — a response carries its headers

**Status:** accepted
**Extends:** [ADR 0240](./0240-a-head-that-outlives-its-body.md), which is
the same copy made by hand on an `Exchange`.
**Amends:** the "one allocation, and it is the body" figure in
`bench/result/fetch.md` and the fetch guide, which is now two.

## Context

A `Response` was a status and a body, and the ordinary handler needs one
more thing off the answer at least once: `Retry-After` on a 429, `ETag` for
the next conditional GET, `Location` on a 201, `Link` on a page-by-header
API, `X-RateLimit-Remaining` before deciding whether to make the next call.
`Exchange.Head.header(name)` already read one, case-insensitively, out of a
block that the first byte of body overwrites — so the whole-body calls, which
read the body before returning, had nothing left to hand back. The example's
429 branch said "rate-limited" and could not say until when.

## Decision

**`Response.headers` is the header block, kept into the Scope before the
body reads over it, and `res.header(name)` walks it.** The same copy
`head.keep(c)` makes (ADR 0240), made by `send` for the caller because a
whole-body call has no other moment to make it: one `arena.dupe` of
`head.bytes` between `begin` and `take`. The walk is the one function
`Exchange.Head.header` uses, so the two answer the same way, and it answers
null for a block with no line in it, because `std.http.HeaderIterator.init`
asserts the first `\r\n` is there and a `Response` built by hand in a test
has none.

The slice `header` hands back points into the block, so it lives as long as
the Scope does and no longer — a plain slice rather than a `Str`, the way
`Head.header` is, because the block's lifetime is the Scope's and the body
beside it already carries the trap.

## What was rejected

**A kept `Exchange.Head` on the `Response`.** It would bring
`content_length`, `content_type` and `redirected` along. `keep` copies a
`redirected` URI through an `Allocating` writer — a second allocation, and a
growing one, on every call that followed a redirect — and the URI otherwise
points into `send`'s own `redirect_buffer`, which is gone when `send`
returns. The block is what every caller wanted; `content_length` is
`body.len()` and `content-type` is one more `header`.

**Copying on demand.** There is no demand to copy on: by the time the
caller holds a `Response` the bytes have been read over.

**Keeping the block only when the caller asked.** A flag on `Call` for one
allocation the size of a header block, paid by a call that has already made
one for the body, is a decision nobody would make correctly at every call
site. ADR 0240 kept the borrowed head as the default on an `Exchange`
because an `Exchange` has the moment to read it; a `Response` does not.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | **two on the whole-body calls, from one**: the header block, then the body. `test "a call on a warm connection allocates twice: the header block, then the body"` in `fetch/live.zig` holds it. The `Exchange` path is unchanged and still allocates nothing in `begin` |
| Memory per idle connection | unchanged: the copy is arena, and in this framework the arena is cheaper than the stack |
| Throughput and p99 | one `memcpy` of a few hundred bytes per call, inside the noise of a network round trip |
| Binary size | unchanged |

## What proves it

`fetch/live.zig`: a canned 429 with `Retry-After: 30` answers `"30"` to
`retry-after` and to `RETRY-AFTER` after the body has been read, null for
`etag`, and the slice points inside `res.headers`. `fetch/fetch.zig`: the
same on a block written by hand, and null on a `Response` with no block.
