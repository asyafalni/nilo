# A head that outlives its body, and a response that carries its headers

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

Every slice in `Exchange.Head` points into the connection's read buffer, and the first byte of body overwrites it. The doc says so, the bargain is the one `sql`'s Borrowed row makes, and it is the right default: an allocation per call for text most callers glance at once. What follows is that every caller who needs a header *after* the body invents a copy. fdm's was a `[512]u8` and a length with `from`, `fmt` and `slice` on it, thirty lines, for one job: the `etag` taken before the body so the next run can compare against it.

`Response`, the whole-body call's answer, had the same gap with no way out at all: a status and a body, and the ordinary handler needs one more thing off the answer at least once, `Retry-After` on a 429, `ETag` for the next conditional GET, `Location` on a 201, `Link` on a page-by-header API, `X-RateLimit-Remaining` before deciding whether to make the next call. `Exchange.Head.header(name)` already read one out of a block the first byte of body overwrites, but a whole-body call reads the body before returning, so it had nothing left to hand back. An example's 429 branch could say "rate-limited" and could not say until when.

## Decision

### `head.keep(c)` copies the `Head` into the Scope

The header block is duplicated into the arena, `content_type` moves with it (std cut it out of the block, so it is re-pointed rather than copied twice), and a `redirected` URI, eight slices into the redirect buffer, is written out as one string and read back. `header(name)` on the result walks the copy. One arena allocation the size of the header block, on the calls that ask, and the borrowed head on the ones that do not.

`keep` is the word `Str` uses for the same act, and `CONTEXT.md` refuses `dupe`; a Scope rather than an allocator because the copy lives exactly as long as the request does and nobody frees it.

### `Response.headers` is the same copy, made automatically before the body reads over it

A whole-body call has no other moment to make it, so `send` makes it for the caller: one `arena.dupe` of `head.bytes` between `begin` and `take`. `res.header(name)` walks it with the same function `Exchange.Head.header` uses, so the two answer the same way, and it answers null for a block with no line in it (a `Response` built by hand in a test has none). The slice `header` hands back points into the block, so it lives as long as the Scope does and no longer, a plain slice rather than a `Str`, the way `Head.header` is, because the block's lifetime is the Scope's and the body beside it already carries the trap.

`Response.headers` carries only the block, not the rest of a kept `Head`: `content_length` is `body.len()` and `content-type` is one more `header` call, so neither needs a second field.

## What was rejected

**`headerOwned(c, name)` for the one header most callers keep.** Narrower, and it leaves `content_length`, `status` and the rest behind a second call. The whole head is one allocation either way.

**Copying by default.** The bargain the borrowed head makes is the reason `begin` allocates nothing, and most callers read the head once.

**A kept `Exchange.Head` on the `Response`.** It would bring `content_length`, `content_type` and `redirected` along, but `keep` copies a `redirected` URI through an `Allocating` writer, a second, growing allocation on every call that followed a redirect, and the URI otherwise points into `send`'s own `redirect_buffer`, gone when `send` returns. The block is what every caller wanted.

**Copying on demand.** There is no demand to copy on: by the time the caller holds a `Response` the bytes have been read over.

**Keeping the block only when the caller asked, a flag on `Call`.** One allocation the size of a header block, paid by a call that has already made one for the body, is a decision nobody would make correctly at every call site. The borrowed head stays the default on an `Exchange` because an `Exchange` has the moment to read it; a `Response` does not.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | `head.keep`: 0 unless called, then one arena allocation the size of the header block. Whole-body calls (`get`, `post`, `postJson`, …): two, the header block then the body, from one before this decision. The `Exchange` path is unchanged and still allocates nothing in `begin` |
| Memory per idle connection | unchanged: the copy is arena, and in this framework the arena is cheaper than the stack |
| Throughput and p99 | one `memcpy` of a few hundred bytes per call, inside the noise of a network round trip |
| Binary size | unchanged |

## What proves it

`fetch/live.zig`: a head kept before a 3,000-byte body (larger than the connection's buffer, so the borrowed bytes are read over for certain) reads the same `etag`, `content_type`, status and length after `take`, and its `content_type` points inside the kept block rather than at a second copy. A canned 429 with `Retry-After: 30` answers `"30"` to `retry-after` and to `RETRY-AFTER` after the body has been read, null for `etag`, and the slice points inside `res.headers`. `fetch/fetch.zig`: the same on a block written by hand, and null on a `Response` with no block.
