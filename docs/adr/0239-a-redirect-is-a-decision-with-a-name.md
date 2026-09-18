# 0239 — a redirect is a decision with a name

**Status:** accepted
**Extends:** [ADR 0232](./0232-a-followed-redirect-says-where-it-ended.md).
**Breaks:** `Begin.redirect_buffer`, which is now `.redirects = .{ .follow = &buf }`.

## Context

An empty `redirect_buffer` meant redirects were not followed and a 302
came back as itself. For anything signed that is the right default, and
the doc comment said why. But "I do not want this followed" and "I did not
think about redirects" were the same absence, and the symptom of the
second was a `Head` with status 301 that a caller read as a bad upstream
and reported as one. fdm did think about it, because `mirrors.kernel.org`
made it, and the next CLI on nilo would find it the same way: in the first
week, from a server that was right.

## Decision

**`Begin.redirects` is a union with three arms, and the default is the one
that says so out loud.**

- `.refuse`, the default: a 3xx with a `Location` is
  `error.RedirectRefused`. A 304 has no `Location`, is an answer to
  `if-none-match`, and is handed over as itself.
- `.follow = &buf`: walked, three deep at most, the `Location` resolved in
  the buffer, and `head.redirected` saying where it ended (ADR 0232).
- `.expose`: the 3xx as itself, 302 and all. For the signed request that
  checks where an object moved, and for the client that reads the body of
  the answer, which is where S3 puts the reason for a 301, so
  `s3/bucket.zig` says it on every call.

The intent has a name, the buffer goes where the one intent that needs it
is, and the absence of a decision is no longer spelled like one.
`Client.get` and the four beside it follow, as they did.

## What was rejected

**Keep the field and make a 3xx with an empty buffer the error.** Breaks
nobody, and leaves the buffer's emptiness carrying two meanings with an
error deciding between them at run time. The union costs every `begin`
with a `redirect_buffer` in it (fdm's two and nilo's own two tests) one
line each, and the release is untagged.

**An error on every 3xx.** A 304 is not a redirect, and a client sending
`if-none-match` is owed it as an answer rather than as a failure with the
right name.

## What it costs

Nothing per call: the union is the same slice and a tag. One error in the
set. `s3/bucket.zig` writes `.expose` six times, because a signature is
over one host and following would send it elsewhere.
