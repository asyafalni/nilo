# 0240 — a head that outlives its body

**Status:** accepted
**Extends:** the borrowed `Head`, which stays the default.

## Context

Every slice in `Head` points into the connection's read buffer, and the
first byte of body overwrites it. The doc says so, the bargain is the one
`sql`'s Borrowed row makes, and it is the right default: an allocation per
call for text most callers glance at once. What follows is that every
caller who needs a header *after* the body invents a copy. fdm's was a
`[512]u8` and a length with `from`, `fmt` and `slice` on it, thirty lines,
for one job: the `etag` taken before the body so the next run can compare
against it.

## Decision

**`head.keep(c)` is the same `Head`, copied into the Scope.** The header
block is duplicated into the arena, `content_type` moves with it (std cut
it out of the block, so it is re-pointed rather than copied twice) and a
`redirected` URI, which is eight slices into the redirect buffer, is
written out as one string and read back. `header(name)` on the result
walks the copy. One arena allocation the size of the header block, on the
calls that ask, and the borrowed head on the ones that do not.

`keep` is the word `Str` uses for the same act, and `CONTEXT.md` refuses
`dupe`; a Scope rather than an allocator because the copy lives exactly as
long as the request does and nobody frees it.

## What was rejected

**`headerOwned(c, name)` for the one header most callers keep.** Narrower,
and it leaves `content_length`, `status` and the rest behind a second
call. The whole head is one allocation either way.

**Copying by default.** The bargain the borrowed head makes is the reason
`begin` allocates nothing, and most callers read the head once.

## What proves it

`fetch/live.zig`: a head kept before a 3,000-byte body (larger than the
connection's buffer, so the borrowed bytes are read over for certain)
reads the same `etag`, `content_type`, status and length after `take`, and
its `content_type` points inside the kept block rather than at a second
copy.
