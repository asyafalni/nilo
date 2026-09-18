# 0232 — a followed redirect says where it ended

**Status:** accepted

## Context

`Exchange.Head` did not say where a followed redirect landed. fdm needs it —
the sixteen connections after the probe should hit the final URL rather than
repeat the chain sixteen times — and got it by reaching through the
`Exchange` into `std.http.Client.Request.uri`, which nilo does not promise,
and formatting it before the `redirect_buffer` went out of scope. The
comment explaining the lifetime was longer than the code.

## Decision

**`Head.redirected` is the `std.Uri` a followed redirect ended at, or null,
and `head.location(buf)` writes it out as one string.**

std counts the redirects it has left in `RedirectBehavior`; fewer than it
started with is a chain it walked, and `req.uri` is then the end of it,
resolved by std's own `resolveInPlace` into the `redirect_buffer` the call
was given. That is where the text lives, and the doc comment says so: good
for as long as the buffer is, which the caller owns.

The string form takes a buffer because a `std.Uri` is components, and
writing them out needs somewhere to go. `error.NoSpaceLeft` is a URL longer
than the buffer that held it, which is the only way it fails.

## Alternatives rejected

**`location: ?[]const u8` on the Head, as a slice.** The obvious shape and
the one the feedback asked for. There is no memory for it: the resolved URL
is components pointing into `redirect_buffer`, and formatting them into the
same buffer overwrites what they point at. A slice would need an allocation
per redirected call, and `begin` has no Scope to take it from.

**On `Response` as well.** `Client.send` keeps its redirect buffer on its
own stack, so by the time a `Response` exists the text is gone; a `Str` in
the Scope would be an allocation on a path that did not ask for it. The
Exchange is where the buffer is the caller's, and it is the shape a caller
that will open more connections is using anyway.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 |
| Memory per idle connection | `@sizeOf(?std.Uri)` on a `Head`, which is a value the caller holds for the head's window and not for the connection |
| Throughput and p99 | 0 — a comparison of two integers at `begin` |
| Binary size | not measured separately |

The test serves a `302` to `/moved` and a `200` on one connection, and reads
`http://127.0.0.1:<port>/moved` back out of the head; the control asks the
same of an answer that came from the URL it asked for and gets null. One
connection rather than two, because std pools the first and comes back on
it — a server that hung up after the `302` handed the client a reaped
socket, and the stale-connection retry then sent the *original* URL again,
which is a different test and the one that was accidentally written first.
